import CNativeDecoder
import EditorCore
import Foundation
import NativePlaybackRuntime

struct VideoCapture: Codable {
    let frame: Int64
    let rebuilt: Bool
    let rgbFile: String
    let pngFile: String
    let asynchronousFile: String
    let request: NativeVideoFrameRequest?
}
struct AudioCapture: Codable {
    let startSample: Int64
    let sampleCount: Int
    let rebuilt: Bool
    let mixedFile: String
    let scheduledFile: String
    let asynchronousFile: String
    let requests: [NativeAudioReadRequest]
}
struct Manifest: Codable {
    let libraryVersion: String
    let videoFrames: Int64
    let audioSamples: Int64
    let width: Int
    let height: Int
    let channels: Int
    let sampleRate: Int
    let initialPlanReplaced: Bool
    let videoCaptures: [VideoCapture]
    let audioCaptures: [AudioCapture]
    let asynchronousCacheBytes: Int
    let asynchronousPendingRequests: Int
    let transportClock: [TransportClockCapture]
}
struct TransportClockCapture: Codable {
    let presentedSamples: Int64
    let frame: Int64?
    let sample: Int64
    let playing: Bool
}

func createOutput(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw ProofFailure("Cannot create \(url.path)")
    }
    return try FileHandle(forWritingTo: url)
}

func bytes(_ samples: [Float]) -> Data {
    // macOS proof hosts are little endian; Python validates the declared f32le.
    samples.withUnsafeBytes { Data($0) }
}

func executeProof(projectURL: URL, output: URL, replacementURL: URL?) async throws {
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ProofFailure("Output must be a new directory")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
    let monitor = try NativeMonitor(project: project)
    let session = try NativePlaybackSession(project: project, maximumCacheBytes: 128 * 1024)
    if let replacementURL {
        // Prime both source kinds against the old plan before invalidation.
        _ = try monitor.video(frame: min(60, monitor.plan.videoFrames - 1))
        _ = try monitor.audio(start: min(48048, monitor.plan.audioSamples - 1), count: 1)
        _ = try await session.video(frame: min(60, monitor.plan.videoFrames - 1))
        _ = try await session.audio(start: min(48048, monitor.plan.audioSamples - 1), count: 1)
        // Invalid edits must retain the old plan and the usable decoder state.
        let priorPlan = monitor.plan
        var invalid = project
        invalid.settings.width = 0
        do {
            try monitor.replace(project: invalid)
            throw ProofFailure("Invalid replacement unexpectedly succeeded")
        } catch is EditorCoreError {
            guard monitor.plan == priorPlan else { throw ProofFailure("Invalid replacement changed playback plan") }
            _ = try monitor.video(frame: min(60, monitor.plan.videoFrames - 1))
        }
        let replacement = try JSONDecoder().decode(Project.self, from: Data(contentsOf: replacementURL))
        try monitor.replace(project: replacement)
        try await session.replace(project: replacement)
    }
    let plan = monitor.plan
    // Keep development runs bounded independently of source sizes.
    guard plan.videoFrames <= 18000, plan.audioSamples <= 28800000 else {
        throw ProofFailure("Proof supports at most 18000 video frames and 28.8M audio samples")
    }
    let video = try createOutput(output.appendingPathComponent("native.rgb"))
    defer { try? video.close() }
    for frame in 0..<plan.videoFrames { try video.write(contentsOf: monitor.video(frame: frame)) }
    let asyncVideo = try createOutput(output.appendingPathComponent("asynchronous.rgb"))
    defer { try? asyncVideo.close() }
    for frame in 0..<plan.videoFrames {
        let decoded = try await session.video(frame: frame)
        guard await session.accepts(decoded.epoch) else { throw ProofFailure("Stale sequential video") }
        try asyncVideo.write(contentsOf: decoded.value)
    }
    let mixed = try createOutput(output.appendingPathComponent("mixed.f32"))
    defer { try? mixed.close() }
    let asyncAudio = try createOutput(output.appendingPathComponent("asynchronous.f32"))
    defer { try? asyncAudio.close() }
    var start: Int64 = 0
    // Irregular block sizes exercise intersections independently of video frames.
    let sizes = [997, 4096, 511, 2048, 1537]
    var block = 0
    while start < plan.audioSamples {
        let count = Int(min(Int64(sizes[block % sizes.count]), plan.audioSamples - start))
        try mixed.write(contentsOf: bytes(monitor.audio(start: start, count: count)))
        let decoded = try await session.audio(start: start, count: count)
        guard await session.accepts(decoded.epoch) else { throw ProofFailure("Stale sequential audio") }
        try asyncAudio.write(contentsOf: bytes(decoded.value))
        start += Int64(count)
        block += 1
    }
    let scheduled = try createOutput(output.appendingPathComponent("scheduled.f32"))
    defer { try? scheduled.close() }
    var transport = try NativePlaybackTransport(plan: plan)
    let clockGeneration = try transport.play()
    var clockCaptures: [TransportClockCapture] = []
    try renderNativeAudio(monitor: monitor, start: 0, count: plan.audioSamples, presented: { sample in
        guard try transport.update(clockSample: sample, generation: clockGeneration) else {
            throw ProofFailure("Native sample clock rejected by current transport")
        }
        clockCaptures.append(.init(presentedSamples: sample, frame: transport.frameIndex,
                                   sample: transport.sampleIndex, playing: transport.isPlaying))
    }) {
        try scheduled.write(contentsOf: bytes($0))
    }
    guard transport.position == transport.duration, !transport.isPlaying,
          transport.frameIndex == nil, transport.sampleIndex == plan.audioSamples else {
        throw ProofFailure("Transport did not stop at exact sequence end")
    }
    var videoCaptures: [VideoCapture] = []
    let seekFrames: [Int64] = [0, 2, 3, 60, 119, 120, 179, 60, 15, 15]
    for (index, frame) in seekFrames.enumerated() where frame < plan.videoFrames {
        let rebuilt = index == seekFrames.count - 1
        if rebuilt { monitor.resetDecoders() }
        let rgbName = "seek-\(index)-frame-\(frame).rgb"
        let pngName = "seek-\(index)-frame-\(frame).png"
        let rgb = try monitor.video(frame: frame)
        await session.invalidate()
        let asyncName = "async-seek-\(index)-frame-\(frame).rgb"
        let asyncDecoded = try await session.video(frame: frame)
        guard await session.accepts(asyncDecoded.epoch) else { throw ProofFailure("Stale seek video") }
        try asyncDecoded.value.write(to: output.appendingPathComponent(asyncName))
        try rgb.write(to: output.appendingPathComponent(rgbName))
        try writeNativeImage(rgb: rgb, width: plan.settings.width, height: plan.settings.height,
                             to: output.appendingPathComponent(pngName))
        videoCaptures.append(VideoCapture(frame: frame, rebuilt: rebuilt, rgbFile: rgbName,
            pngFile: pngName, asynchronousFile: asyncName, request: try plan.videoFrame(at: frame)))
    }
    var audioCaptures: [AudioCapture] = []
    let seekSamples: [Int64] = [0, 48047, 48048, 240239, 115315, 48048, plan.audioSamples - 1024, 48047]
    for (index, sample) in seekSamples.enumerated() where sample >= 0 && sample < plan.audioSamples {
        let count = Int(min(2048, plan.audioSamples - sample))
        let rebuilt = index == seekSamples.count - 1
        if rebuilt { monitor.resetDecoders() }
        let mixedName = "audio-seek-\(index)-\(sample)-mixed.f32"
        let scheduledName = "audio-seek-\(index)-\(sample)-scheduled.f32"
        try bytes(monitor.audio(start: sample, count: count)).write(to: output.appendingPathComponent(mixedName))
        await session.invalidate()
        let asyncName = "async-audio-seek-\(index)-\(sample).f32"
        let asyncDecoded = try await session.audio(start: sample, count: count)
        guard await session.accepts(asyncDecoded.epoch) else { throw ProofFailure("Stale seek audio") }
        try bytes(asyncDecoded.value).write(to: output.appendingPathComponent(asyncName))
        let handle = try createOutput(output.appendingPathComponent(scheduledName))
        do {
            try renderNativeAudio(monitor: monitor, start: sample, count: Int64(count)) {
                try handle.write(contentsOf: bytes($0))
            }
            try handle.close()
        } catch { try? handle.close(); throw error }
        audioCaptures.append(AudioCapture(startSample: sample, sampleCount: count, rebuilt: rebuilt,
            mixedFile: mixedName, scheduledFile: scheduledName,
            asynchronousFile: asyncName,
            requests: try plan.audioBlock(startSample: sample, sampleCount: count)))
    }
    let version = String(cString: afc_decoder_version())
    let statistics = await session.statistics()
    guard statistics.cachedBytes <= 128 * 1024, statistics.pendingRequests == 0 else {
        throw ProofFailure("Asynchronous bounds exceeded")
    }
    await session.close()
    let manifest = Manifest(libraryVersion: version, videoFrames: plan.videoFrames,
        audioSamples: plan.audioSamples, width: plan.settings.width, height: plan.settings.height,
        channels: plan.settings.audioLayout.channels.count, sampleRate: plan.settings.audioSampleRate,
        initialPlanReplaced: replacementURL != nil,
        videoCaptures: videoCaptures, audioCaptures: audioCaptures,
        asynchronousCacheBytes: statistics.cachedBytes, asynchronousPendingRequests: statistics.pendingRequests,
        transportClock: clockCaptures)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"))
    print("Native capture completed: \(plan.videoFrames) frames, \(plan.audioSamples) samples/channel")
}

do {
    guard (3...4).contains(CommandLine.arguments.count),
          CommandLine.arguments[1].hasPrefix("/"), CommandLine.arguments[2].hasPrefix("/") else {
        throw ProofFailure("Usage: NativeSequenceProof /absolute/project.json /new/absolute/output [/replacement/project.json]")
    }
    let replacement = CommandLine.arguments.count == 4 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
    if CommandLine.arguments.count == 4, !CommandLine.arguments[3].hasPrefix("/") {
        throw ProofFailure("Replacement document requires an absolute path")
    }
    try await executeProof(projectURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                     output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), replacementURL: replacement)
} catch {
    FileHandle.standardError.write(Data("Native proof failed: \(error)\n".utf8))
    exit(1)
}
