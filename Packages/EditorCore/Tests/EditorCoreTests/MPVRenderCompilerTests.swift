import Foundation
import Testing
@testable import EditorCore

@Test func mpvGraphSharesExportFiltersAndSplitsRepeatedStreams() throws {
    var project = try DemoProjectFactory.musicCollision()
    let url = URL(fileURLWithPath: "/private/tmp/media 'quoted';.mov")
    project.assets[0].originalURL = url
    let plan = try TimelineRenderPlan(project: project)
    let binding = MPVTrackBinding(url: url, streamIndex: 0, kind: .audio, trackID: 7)
    let graph = try MPVRenderCompiler.compile(plan, bindings: [binding])
    #expect(graph.filterGraph.hasPrefix("[aid7]asplit=4"))
    #expect(!graph.filterGraph.contains("[0:0]"))
    #expect(!graph.filterGraph.contains(url.path))
    #expect(graph.filterGraph.contains("[vo]"))
    #expect(graph.filterGraph.contains("[ao]"))
    let export = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/out.mov"))
    #expect(graph.videoFrames == export.videoFrames)
    #expect(graph.audioSamples == export.audioSamples)
    #expect(export.inputs.count == 4)
    #expect(export.inputs.allSatisfy { $0.url == url && $0.streamIndex == 0 && $0.kind == .audio })
}

@Test func mpvGraphRequiresUnambiguousPositiveTrackIDs() throws {
    var project = try DemoProjectFactory.musicCollision()
    let url = URL(fileURLWithPath: "/private/tmp/source.mov")
    project.assets[0].originalURL = url
    let plan = try TimelineRenderPlan(project: project)
    let binding = MPVTrackBinding(url: url, streamIndex: 0, kind: .audio, trackID: 1)
    for bindings in [[], [binding, binding], [MPVTrackBinding(url: url, streamIndex: 0, kind: .audio, trackID: 0)], [MPVTrackBinding(url: url, streamIndex: 0, kind: .video, trackID: 1)]] {
        #expect(throws: (any Error).self) { try MPVRenderCompiler.compile(plan, bindings: bindings) }
    }
}

@Test func mpvGraphRejectsAliasedSourceBindings() throws {
    var project = try DemoProjectFactory.musicCollision()
    let url = URL(fileURLWithPath: "/private/tmp/source.mov")
    project.assets[0].originalURL = url
    project.assets[0].streams.append(MediaStream(index: 2, kind: .audio, audioLayout: .stereo))
    project.tracks[0].clips[1].selection = .audio(.init(channels: [.init(streamIndex: 2, channelIndex: 0), .init(streamIndex: 2, channelIndex: 1)], layout: .stereo))
    let bindings = [0, 2].map { MPVTrackBinding(url: url, streamIndex: $0, kind: .audio, trackID: 1) }
    #expect(throws: (any Error).self) { try MPVRenderCompiler.compile(TimelineRenderPlan(project: project), bindings: bindings) }
}
