import Foundation
import Testing
@testable import EditorCore

@Test func compilerRefusesUnqualifiedMediaAndDestinations() throws {
    var project = try DemoProjectFactory.musicCollision()
    let output = URL(fileURLWithPath: "/private/tmp/output.mov")
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/source.mov")
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(command.videoFrames == 240)
    #expect(command.audioSamples == 480000)
    #expect(command.arguments.last == output.path)
    #expect(command.arguments.contains("-n"))
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/out.mp4")) }
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: project.assets[0].originalURL!) }
    project.assets[0].streams[0].timeOffset = try RationalTime(1, 2)
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
}

@Test func compilerKeepsPathsAsArgumentsAndRejectsSubsampleEdits() throws {
    var project = try DemoProjectFactory.musicCollision()
    let path = "/private/tmp/source 'quoted'; $(example).mov"
    project.assets[0].originalURL = URL(fileURLWithPath: path)
    let output = URL(fileURLWithPath: "/private/tmp/output.mov")
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(command.arguments.filter { $0 == path }.count == 4)
    #expect(!command.filterGraph.contains(path))
    project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 96000)
    #expect(throws: (any Error).self) { try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output) }
}

@Test func compilerFadesRetainExactSubsampleDurationBeforeTimelineDelay() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/fade-source.mov")
    project.tracks[0].clips[1].fadeIn = .init(duration: try RationalTime(250001, 96000), curve: .equalPower)
    project.tracks[0].clips[1].fadeOut = .init(duration: try RationalTime(4), curve: .linear)
    let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/fade-out.mov"))
    #expect(command.audioSamples == 480000)
    #expect(command.filterGraph.contains("(n)*2/250001"))
    #expect(command.filterGraph.contains("(240000-n)*1/192000"))
    #expect(command.filterGraph.contains("sin(PI/2*"))
    #expect(command.filterGraph.contains("val(0)*"))
    #expect(command.filterGraph.contains("val(1)*"))
    // Float conversion precedes gain/envelopes to preserve low-level PCM.
    #expect(command.filterGraph.contains("aformat=sample_fmts=flt,volume=0.8:precision=float,aeval="))
    #expect(command.filterGraph.contains(":channel_layout=stereo,adelay=240000S:all=1"))
}
