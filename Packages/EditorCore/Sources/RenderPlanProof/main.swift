import Foundation
import EditorCore

// The proof runner must force --demuxer=lavf for all loaded files before capturing
// this list. This mode compiles the actual loaded tracks, never fixture IDs.
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "resolve-mpv" {
    let arguments = CommandLine.arguments
    let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let tracks = try JSONDecoder().decode([MPVTrackListEntry].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
    let plan = try TimelineRenderPlan(project: project)
    let output = URL(fileURLWithPath: arguments[5])
    let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/__editor_mpv_graph__.mov"))
    let bindings = try MPVTrackResolver.resolve(inputs: command.inputs, trackList: tracks, primaryURL: URL(fileURLWithPath: arguments[4]), demuxer: "lavf")
    let graph = try MPVRenderCompiler.compile(plan, bindings: bindings)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(graph).write(to: output)
} else {
// Development fixture generator; emits a reviewable document and argv manifest.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: RenderPlanProof /fixture/directory OR resolve-mpv <project.json> <track-list.json> <primary-path> <output.json> (all sources loaded with --demuxer=lavf)") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let rate = try FrameRate(30000, 1001)
let settings = try SequenceSettings(width: 160, height: 90, frameRate: rate, startTimecode: .init(frameCount: 107892, mode: .dropFrame))
let video = TrackTemplate(kind: .video)
let audio = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.5)
let vf = TrackFamily(baseName: "Video", template: video)
let af = TrackFamily(baseName: "Audio", template: audio)
let a = MediaAsset(name: "A", originalURL: root.appendingPathComponent("a.mov"), duration: try rate.time(forFrames: 300), streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .mono), .init(index: 2, kind: .audio, audioLayout: .mono)])
let b = MediaAsset(name: "B", originalURL: root.appendingPathComponent("b.mov"), duration: try rate.time(forFrames: 300), streams: [.init(index: 0, kind: .video)])
func range(_ start: Int64, _ count: Int64) throws -> TimeRange {
    try TimeRange(start: rate.time(forFrames: start), duration: rate.time(forFrames: count))
}
let lower = TimelineClip(assetID: a.id, sourceRange: try range(30, 180), selection: .video(streamIndex: 0))
let upper = TimelineClip(assetID: b.id, sourceRange: try range(60, 117), timelineStart: try rate.time(forFrames: 3), selection: .video(streamIndex: 0))
let tone = TimelineClip(assetID: a.id, sourceRange: try range(30, 120), timelineStart: try rate.time(forFrames: 30), selection: .audio(.init(channels: [.init(streamIndex: 2, channelIndex: 0), .init(streamIndex: 1, channelIndex: 0)], layout: .stereo)))
let project = Project(settings: settings, assets: [a, b], families: [vf, af], tracks: [.init(familyID: vf.id, template: video, clips: [upper]), .init(familyID: vf.id, template: video, clips: [lower]), .init(familyID: af.id, template: audio, clips: [tone])])
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
// Exercise decoding validation too, rather than compile only the constructed value.
let restored = try JSONDecoder().decode(Project.self, from: encoder.encode(project))
let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: restored), outputURL: root.appendingPathComponent("render.mov"))
try encoder.encode(command).write(to: root.appendingPathComponent("command.json"))
try command.filterGraph.write(to: root.appendingPathComponent("filtergraph.txt"), atomically: true, encoding: .utf8)

let bindings = [
    MPVTrackBinding(url: a.originalURL!, streamIndex: 0, kind: .video, trackID: 1),
    MPVTrackBinding(url: b.originalURL!, streamIndex: 0, kind: .video, trackID: 2),
    MPVTrackBinding(url: a.originalURL!, streamIndex: 1, kind: .audio, trackID: 1),
    MPVTrackBinding(url: a.originalURL!, streamIndex: 2, kind: .audio, trackID: 2)
]
// Fixture-only known enumeration; a production controller must resolve track-list.
let monitor = try MPVRenderCompiler.compile(TimelineRenderPlan(project: restored), bindings: bindings)
try encoder.encode(monitor).write(to: root.appendingPathComponent("mpv-command.json"))
}
