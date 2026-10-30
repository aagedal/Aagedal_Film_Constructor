import Foundation
import Testing
@testable import EditorCore

@Test func disabledClipsHoldTheirPlaceButAreLeftOutOfRender() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/source.mov")
    let ids = project.tracks[0].clips.map(\.id)
    var engine = try TimelineEditEngine(project: project)
    try engine.apply(.setEnabled(clipIDs: [ids[1]], enabled: false))
    let plan = try TimelineRenderPlan(project: engine.project)
    #expect(plan.components.map(\.clipID) == [ids[0]])
    // The sequence keeps its length, so the disabled clip renders as silence.
    #expect(plan.duration == (try RationalTime(10)))
    let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(engine.project))
    #expect(restored.tracks[0].clips.first { $0.id == ids[1] }?.isEnabled == false)
    try engine.apply(.setEnabled(clipIDs: [ids[1]], enabled: true))
    #expect(try TimelineRenderPlan(project: engine.project).components.count == 2)
    #expect(throws: TimelineEditError.missingClip) { try engine.apply(.setEnabled(clipIDs: [UUID()], enabled: false)) }
}

@Test func rangeRenderKeepsOnlyTheMarkedFramesAndSamples() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/source.mov")
    project.settings.startTimecode = Timecode(frameCount: 24 * 3600)
    let plan = try TimelineRenderPlan(project: project)
    let output = URL(fileURLWithPath: "/private/tmp/output.mov")
    let full = try FFmpegRenderCompiler.compile(plan, outputURL: output)
    #expect(full.startTimecode == "01:00:00:00")
    let range = try TimeRange(start: RationalTime(2), duration: RationalTime(3))
    let command = try FFmpegRenderCompiler.compile(plan, outputURL: output, range: range)
    #expect(command.videoFrames == 72 && command.audioSamples == 144000)
    #expect(command.startTimecode == "01:00:02:00")
    #expect(command.arguments.contains("01:00:02:00"))
    #expect(command.filterGraph.contains("trim=start_frame=48:end_frame=120,setpts=PTS-STARTPTS"))
    #expect(command.filterGraph.contains("[audio]atrim=start_sample=96000:end_sample=240000,asetpts=PTS-STARTPTS[audior]"))
    #expect(command.arguments.contains("[audior]") && !command.arguments.contains("[audio]"))
    // An Out past the end stops at the sequence end; an empty range is refused.
    let tail = try FFmpegRenderCompiler.compile(plan, outputURL: output, range: TimeRange(start: RationalTime(8), duration: RationalTime(5)))
    #expect(tail.videoFrames == 48 && tail.audioSamples == 96000)
    #expect(throws: (any Error).self) {
        try FFmpegRenderCompiler.compile(plan, outputURL: output, range: TimeRange(start: RationalTime(12), duration: RationalTime(1)))
    }
}
