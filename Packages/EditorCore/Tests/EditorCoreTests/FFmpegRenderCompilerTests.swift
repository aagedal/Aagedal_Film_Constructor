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
