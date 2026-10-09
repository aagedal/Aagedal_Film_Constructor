import Foundation
import Testing
@testable import EditorCore

private let primary = URL(fileURLWithPath: "/private/tmp/a 'quoted';.mov")
private let external = URL(fileURLWithPath: "/private/tmp/b.mov")

@Test func mpvTrackListDecodesRuntimeNamesAndOptionalMetadata() throws {
    let json = #"[{"id":7,"type":"video","ff-index":2,"external":true,"external-filename":"/private/tmp/b.mov","selected":false},{"id":1,"type":"sub"}]"#
    let entries = try JSONDecoder().decode([MPVTrackListEntry].self, from: Data(json.utf8))
    #expect(entries[0] == .init(id: 7, type: "video", ffIndex: 2, external: true, externalFilename: external.path))
    #expect(entries[1].ffIndex == nil)
    #expect(!entries[1].external)
    let encoded = try JSONEncoder().encode(entries)
    #expect(try JSONDecoder().decode([MPVTrackListEntry].self, from: encoded) == entries)
    #expect(String(decoding: encoded, as: UTF8.self).contains("ff-index"))
    let invalid = #"[{"id":1,"type":"audio","ff-index":"2"}]"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode([MPVTrackListEntry].self, from: Data(invalid.utf8)) }
}

@Test func mpvResolverMatchesFileIndexAndKindWithoutEnumeration() throws {
    let inputs = [RenderSourceInput(url: primary, streamIndex: 3, kind: .audio),
                  RenderSourceInput(url: external, streamIndex: 0, kind: .video),
                  RenderSourceInput(url: primary, streamIndex: 0, kind: .video)]
    let tracks: [MPVTrackListEntry] = [
        .init(id: 23, type: "video", ffIndex: 0, external: true, externalFilename: external.absoluteString),
        .init(id: 11, type: "audio", ffIndex: 3),
        .init(id: 11, type: "video", ffIndex: 0),
        .init(id: 2, type: "audio", ffIndex: 1),
        .init(id: 1, type: "sub")
    ]
    let bindings = try MPVTrackResolver.resolve(inputs: inputs + [inputs[0]], trackList: tracks, primaryURL: primary, demuxer: "lavf")
    #expect(bindings.count == 3)
    #expect(bindings.map(\.trackID) == [11, 23, 11])
    #expect(bindings.map(\.source) == inputs)
}

@Test func mpvResolverRejectsMissingAmbiguousAndInvalidMetadata() throws {
    let input = RenderSourceInput(url: primary, streamIndex: 3, kind: .audio)
    let good = MPVTrackListEntry(id: 7, type: "audio", ffIndex: 3)
    let invalidLists: [[MPVTrackListEntry]] = [
        [], [good, good], [.init(id: 7, type: "video", ffIndex: 3)],
        [.init(id: 7, type: "audio", ffIndex: 0)], [.init(id: 7, type: "audio")],
        [.init(id: 0, type: "audio", ffIndex: 3)], [.init(id: 7, type: "audio", ffIndex: -1)],
        [.init(id: 7, type: "audio", ffIndex: 3, external: true)],
        [.init(id: 7, type: "audio", ffIndex: 3, external: true, externalFilename: "relative.mov")],
        [.init(id: 7, type: "audio", ffIndex: 3, externalFilename: primary.path)],
        [.init(id: 7, type: "audio", ffIndex: 3, external: true, externalFilename: external.path)]
    ]
    for tracks in invalidLists {
        #expect(throws: (any Error).self) {
            try MPVTrackResolver.resolve(inputs: [input], trackList: tracks, primaryURL: primary, demuxer: "lavf")
        }
    }
    #expect(throws: (any Error).self) {
        try MPVTrackResolver.resolve(inputs: [input], trackList: [good], primaryURL: primary, demuxer: "mkv")
    }
}

@Test func mpvResolverRejectsAliasedTracksAcrossStreamsAndFiles() throws {
    let input = RenderSourceInput(url: primary, streamIndex: 0, kind: .video)
    for second in [RenderSourceInput(url: primary, streamIndex: 2, kind: .video), RenderSourceInput(url: external, streamIndex: 0, kind: .video)] {
        let tracks: [MPVTrackListEntry] = [
            .init(id: 1, type: "video", ffIndex: 0),
            .init(id: 1, type: "video", ffIndex: second.streamIndex, external: second.url == external,
                  externalFilename: second.url == external ? external.path : nil)
        ]
        #expect(throws: (any Error).self) {
            try MPVTrackResolver.resolve(inputs: [input, second], trackList: tracks, primaryURL: primary, demuxer: "lavf")
        }
    }
}

@Test func mpvResolvedRepeatedInputsCompileToSplitGraph() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = primary
    let plan = try TimelineRenderPlan(project: project)
    let command = try FFmpegRenderCompiler.compile(plan, outputURL: external)
    let bindings = try MPVTrackResolver.resolve(inputs: command.inputs, trackList: [.init(id: 19, type: "audio", ffIndex: 0)], primaryURL: primary, demuxer: "lavf")
    #expect(bindings.count == 1)
    let graph = try MPVRenderCompiler.compile(plan, bindings: bindings)
    #expect(graph.filterGraph.hasPrefix("[aid19]asplit=4"))
    #expect(graph.videoFrames == command.videoFrames)
    #expect(graph.audioSamples == command.audioSamples)
}
