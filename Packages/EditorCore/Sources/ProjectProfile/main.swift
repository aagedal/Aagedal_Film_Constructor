import EditorCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Run in release mode. This profiles the Codable Project boundary, not SwiftUI,
// security-scoped bookmark resolution, media decoding, or rendered exports.
struct Options {
    var clips = 5_000
    var tracks = 8
    var iterations = 3
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("Usage: swift run -c release ProjectProfile [--clips 5000] [--tracks 8] [--iterations 3]")
            exit(0)
        }
        guard args.count.isMultiple(of: 2) else { throw ProfileError.arguments }
        for offset in stride(from: 0, to: args.count, by: 2) {
            guard let value = Int(args[offset + 1]), value > 0 else { throw ProfileError.arguments }
            switch args[offset] {
            case "--clips": clips = value
            case "--tracks": tracks = value
            case "--iterations": iterations = value
            default: throw ProfileError.arguments
            }
        }
        guard tracks <= clips else { throw ProfileError.arguments }
    }
}
enum ProfileError: Error { case arguments, roundTrip }
struct Measurement: Codable {
    var operation: String
    var milliseconds: [Double]
    var medianMilliseconds: Double
}
struct Report: Codable {
    var schemaVersion = 1
    var scope = "EditorCore synthetic mixed-media Project Codable; excludes app document envelope, UI, media I/O and decoding"
    var operatingSystem: String
    var processorCount: Int
    var clips: Int
    var tracks: Int
    var assets: Int
    var audioCrossfades: Int
    var iterations: Int
    var encodedBytes: Int
    var peakResidentBytes: UInt64?
    var measurements: [Measurement]
}

func fixture(_ options: Options) throws -> Project {
    let video = TrackTemplate(kind: .video)
    let audio = TrackTemplate(kind: .audio, audioLayout: .stereo)
    let families = [TrackFamily(baseName: "Picture", template: video), TrackFamily(baseName: "Sound", template: audio)]
    var tracks = (0..<options.tracks).map { index in
        TimelineTrack(familyID: families[index % 2].id, template: index % 2 == 0 ? video : audio)
    }
    let selection = ClipSelection.audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo))
    var assets: [MediaAsset] = []
    for index in 0..<options.clips {
        let asset = MediaAsset(name: "Source \(index)", originalURL: URL(fileURLWithPath: "/synthetic/source-\(index).mov"),
                               duration: try RationalTime(60), streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        assets.append(asset)
        let track = index % options.tracks
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(10), duration: RationalTime(2)),
                                timelineStart: try RationalTime(Int64(index / options.tracks * 2)),
                                selection: track % 2 == 0 ? .video(streamIndex: 0) : selection)
        tracks[track].clips.append(clip)
    }
    var crossfades: [AudioCrossfade] = []
    for track in tracks where track.kind == .audio {
        for index in stride(from: 1, to: track.clips.count, by: 4) {
            crossfades.append(.init(outgoingClipID: track.clips[index - 1].id, incomingClipID: track.clips[index].id, duration: try RationalTime(1, 2)))
        }
    }
    // Reverse clip storage to exercise sorting independently of insertion history.
    for index in tracks.indices { tracks[index].clips.reverse() }
    return Project(settings: try SequenceSettings(), assets: assets, families: families, tracks: tracks, audioCrossfades: crossfades)
}

func peakResidentBytes() -> UInt64? {
    var usage = rusage()
    #if canImport(Darwin)
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    return UInt64(usage.ru_maxrss) // Darwin reports bytes; Linux reports KiB.
    #else
    guard getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0 else { return nil }
    return UInt64(usage.ru_maxrss) * 1024
    #endif
}

do {
    let options = try Options()
    let project = try fixture(options)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // Matches app document save settings.
    let data = try encoder.encode(project)
    var measurements: [Measurement] = []
    func measure(_ name: String, _ body: () throws -> Void) throws {
        try body() // Untimed warmup; validates the workload before collecting samples.
        var timings: [Double] = []
        for _ in 0..<options.iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let sorted = timings.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        measurements.append(.init(operation: name, milliseconds: timings, medianMilliseconds: median))
    }
    try measure("validate") { try project.validate() }
    try measure("save_project_json") {
        try project.validate()
        guard try encoder.encode(project).count == data.count else { throw ProfileError.roundTrip }
    }
    try measure("load_project_json") {
        guard try JSONDecoder().decode(Project.self, from: data) == project else { throw ProfileError.roundTrip }
    }
    try measure("timeline_render_plan") {
        guard try TimelineRenderPlan(project: project).components.count == options.clips else { throw ProfileError.roundTrip }
    }
    // Schedule only: canonical project validation and media preparation are
    // separate costs. This exercises dense adjacent cuts and overlapping lanes.
    let renderPlan = try TimelineRenderPlan(project: project)
    let pictureCount = renderPlan.components.filter {
        if case .audio = $0.selection { return false }; return true
    }.count
    try measure("video_composition_schedule") {
        let schedule = try VideoCompositionPlan(renderPlan)
        guard schedule.placements.count == pictureCount,
              schedule.trackCount <= project.tracks.filter({ $0.kind == .video }).count,
              schedule.instructions.first?.timeRange.start == .zero,
              try schedule.instructions.last?.timeRange.end() == renderPlan.duration else { throw ProfileError.roundTrip }
    }
    // Moving the final video clip into free space avoids crossfade dissolution.
    let track = project.tracks[0]
    let clip = track.clips[0]
    try measure("move_undo_redo") {
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.move(clipID: clip.id, trackID: track.id, start: clip.timelineStart.adding(RationalTime(2))))
        engine.undo()
        guard engine.project == project else { throw ProfileError.roundTrip }
        engine.redo()
        try engine.project.validate()
    }
    let report = Report(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                        processorCount: ProcessInfo.processInfo.processorCount,
                        clips: options.clips, tracks: options.tracks, assets: project.assets.count,
                        audioCrossfades: project.audioCrossfades.count, iterations: options.iterations,
                        encodedBytes: data.count, peakResidentBytes: peakResidentBytes(), measurements: measurements)
    let reportEncoder = JSONEncoder()
    reportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try reportEncoder.encode(report), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("ProjectProfile failed: \(error). Use --help for options.\n".utf8))
    exit(1)
}
