import Foundation
import XCTest
@testable import EditorCore

final class AudioSourceSelectionTests: XCTestCase {
    private func selection(_ stream: Int, _ layout: ChannelLayout) -> AudioSourceSelection {
        AudioSourceSelection(channels: layout.channels.indices.map { SourceChannel(streamIndex: stream, channelIndex: $0) }, layout: layout)
    }

    private func fixture(cleanup: Bool = true) throws -> (Project, UUID) {
        let asset = MediaAsset(name: "Camera", duration: try RationalTime(30), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 1, kind: .audio, audioLayout: .stereo),
            MediaStream(index: 2, kind: .audio, audioLayout: .mono),
            MediaStream(index: 3, kind: .audio, audioLayout: .mono),
            MediaStream(index: 4, kind: .audio, audioLayout: .surround51),
            MediaStream(index: 5, kind: .audio, audioLayout: ChannelLayout(channels: Array(repeating: nil, count: 6)))
        ])
        let audioFamily = TrackFamily(baseName: "Sound", template: TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.6))
        let videoFamily = TrackFamily(baseName: "Picture", template: TrackTemplate(kind: .video))
        let group = UUID()
        let range = try TimeRange(start: RationalTime(2), duration: RationalTime(5))
        let audio = TimelineClip(assetID: asset.id, sourceRange: range, timelineStart: try RationalTime(10), selection: .audio(selection(1, .stereo)), linkGroupID: group)
        let video = TimelineClip(assetID: asset.id, sourceRange: range, timelineStart: audio.timelineStart, selection: .video(streamIndex: 0), linkGroupID: group)
        let tracks = [TimelineTrack(familyID: audioFamily.id, customName: "Dialogue", template: audioFamily.template, retained: true, clips: [audio]), TimelineTrack(familyID: videoFamily.id, template: videoFamily.template, clips: [video])]
        return (Project(settings: try SequenceSettings(), assets: [asset], families: [audioFamily, videoFamily], tracks: tracks, preferences: EditorPreferences(automaticallyRemoveEmptyTracks: cleanup)), audio.id)
    }

    func testSoloReconfigurationPreservesIdentityTimingSettingsAndHistory() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        let ids = try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [AudioRouting(outputChannels: [1])])
        XCTAssertEqual(ids, [id])
        let edited = engine.project
        XCTAssertEqual(edited.tracks[0].id, project.tracks[0].id)
        XCTAssertEqual(edited.tracks[0].customName, "Dialogue")
        XCTAssertTrue(edited.tracks[0].retained)
        XCTAssertEqual(edited.tracks[0].template.gain, 0.6)
        XCTAssertEqual(edited.tracks[0].audioLayout, .mono)
        XCTAssertEqual(edited.tracks[1], project.tracks[1])
        XCTAssertEqual(edited.tracks[0].clips[0].sourceRange, project.tracks[0].clips[0].sourceRange)
        XCTAssertEqual(edited.tracks[0].clips[0].timelineStart, project.tracks[0].clips[0].timelineStart)
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project, edited)
        try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [AudioRouting(outputChannels: [1])])
        engine.undo(); XCTAssertEqual(engine.project, project, "An identical selection adds no history")
    }

    func testSharedTrackCreatesSiblingCopiesGainAndLeavesOtherClipIntact() throws {
        var (project, id) = try fixture()
        var other = project.tracks[0].clips[0]
        other.id = UUID(); other.timelineStart = try RationalTime(20); other.linkGroupID = nil
        project.tracks[0].clips.append(other)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [AudioRouting(outputChannels: [0])]))
        XCTAssertEqual(engine.project.tracks.count, 3)
        XCTAssertEqual(engine.project.tracks[0].clips, [other])
        XCTAssertEqual(engine.project.tracks[0].template, project.tracks[0].template)
        XCTAssertEqual(engine.project.tracks[1].clips[0].id, id)
        XCTAssertEqual(engine.project.tracks[1].template.gain, 0.6)
        XCTAssertEqual(engine.project.tracks[1].familyID, project.tracks[0].familyID)
        XCTAssertEqual(engine.project.tracks[1].template.routing.outputChannels, [0])
        XCTAssertEqual(engine.project.tracks[0].customName, "Dialogue")
        engine.undo(); XCTAssertEqual(engine.project, project)
    }

    func testMatchingFreeSiblingReusePreservesIndependentSettings() throws {
        var (project, id) = try fixture(cleanup: false)
        var other = project.tracks[0].clips[0]
        other.id = UUID(); other.timelineStart = try RationalTime(20); other.linkGroupID = nil
        project.tracks[0].clips.append(other)
        let sibling = TimelineTrack(familyID: project.tracks[0].familyID, customName: "Boom", template: TrackTemplate(kind: .audio, audioLayout: .mono, routing: AudioRouting(outputChannels: [0]), gain: 0.3))
        project.tracks.append(sibling)
        var engine = try TimelineEditEngine(project: project)
        try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [sibling.template.routing])
        XCTAssertEqual(engine.project.tracks.count, 3)
        XCTAssertEqual(engine.project.tracks.last?.id, sibling.id)
        XCTAssertEqual(engine.project.tracks.last?.template.gain, 0.3)
        XCTAssertEqual(engine.project.tracks.last?.clips.first?.id, id)
    }

    func testSeparateMonoComponentsRemainLinkedAndMoveWithPicture() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        let ids = try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono), selection(3, .mono)], routing: [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])])
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], id)
        let components = engine.project.tracks.flatMap(\.clips)
        XCTAssertEqual(components.count, 3)
        XCTAssertEqual(Set(components.compactMap(\.linkGroupID)).count, 1)
        let destination = try XCTUnwrap(engine.project.tracks.first { $0.clips.contains { $0.id == id } })
        try engine.apply(.move(clipID: id, trackID: destination.id, start: RationalTime(12)))
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).map(\.timelineStart)), [try RationalTime(12)])
        engine.undo(); engine.undo(); XCTAssertEqual(engine.project, project)
    }

    func testExplicitMultipleMonoAndSurroundMapsReachRenderPlanUnchanged() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        let map = AudioSourceSelection(channels: [SourceChannel(streamIndex: 3, channelIndex: 0), SourceChannel(streamIndex: 2, channelIndex: 0)], layout: .stereo)
        try engine.selectAudioSource(clipID: id, selections: [map], routing: [AudioRouting(outputChannels: [1, 0])])
        XCTAssertEqual(try TimelineRenderPlan(project: engine.project).components.first?.selection, .audio(map))
        let surround = selection(4, .surround51)
        let route = AudioRouting(outputChannels: [0, 1, 0, 1, 0, 1])
        try engine.selectAudioSource(clipID: id, selections: [surround], routing: [route])
        let rendered = try TimelineRenderPlan(project: engine.project).components.first
        XCTAssertEqual(rendered?.selection, .audio(surround))
        XCTAssertEqual(rendered?.routing, route)
        XCTAssertEqual(engine.project.tracks[0].audioLayout, .surround51)
        let unknown = selection(5, ChannelLayout(channels: Array(repeating: nil, count: 6)))
        try engine.selectAudioSource(clipID: id, selections: [unknown], routing: [route])
        XCTAssertEqual(engine.project.tracks[0].audioLayout?.channels, Array(repeating: nil, count: 6))
    }

    func testInvalidRouteAndSourceRollBackIncludingRedoAndCreatedSiblings() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [AudioRouting(outputChannels: [0])])
        engine.undo()
        for route in [AudioRouting(), AudioRouting(outputChannels: [0, 1]), AudioRouting(outputChannels: [2])] {
            XCTAssertThrowsError(try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: [route]))
            XCTAssertEqual(engine.project, project)
            XCTAssertTrue(engine.canRedo)
        }
        XCTAssertThrowsError(try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono), selection(999, .mono)], routing: [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])]))
        XCTAssertEqual(engine.project, project)
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(engine.canRedo)
        XCTAssertThrowsError(try engine.selectAudioSource(clipID: id, selections: [], routing: []))
        XCTAssertThrowsError(try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono)], routing: []))
        let videoID = project.tracks[1].clips[0].id
        XCTAssertThrowsError(try engine.selectAudioSource(clipID: videoID, selections: [selection(2, .mono)], routing: [AudioRouting(outputChannels: [0])]))
    }

    func testLinkedMonoCollisionMoveAndTrimPreserveEachRouteAndGain() throws {
        let (project, id) = try fixture(cleanup: false)
        var engine = try TimelineEditEngine(project: project)
        let ids = try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono), selection(3, .mono)], routing: [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])])
        var obstructed = engine.project
        let first = try XCTUnwrap(obstructed.tracks.firstIndex { $0.clips.contains { $0.id == ids[0] } })
        var blocker = obstructed.tracks[first].clips[0]
        blocker.id = UUID(); blocker.linkGroupID = nil; blocker.timelineStart = try RationalTime(15)
        obstructed.tracks[first].clips.append(blocker)
        // An empty compatible-layout sibling with different gain is also unsuitable for collision placement.
        var quieter = obstructed.tracks[first].template; quieter.gain = 0.1
        let quietSibling = TimelineTrack(familyID: obstructed.tracks[first].familyID, template: quieter)
        obstructed.tracks.append(quietSibling)
        engine = try TimelineEditEngine(project: obstructed)
        let sourceTrackID = obstructed.tracks[first].id
        try engine.apply(.move(clipID: id, trackID: sourceTrackID, start: RationalTime(15)))
        func assertRoutes(_ state: Project) throws {
            for (index, clipID) in ids.enumerated() {
                let track = try XCTUnwrap(state.tracks.first { $0.clips.contains { $0.id == clipID } })
                XCTAssertEqual(track.template.routing.outputChannels, [index])
                XCTAssertEqual(track.template.gain, 0.6)
            }
            XCTAssertTrue(try XCTUnwrap(state.tracks.first { $0.id == quietSibling.id }).clips.isEmpty)
        }
        try assertRoutes(engine.project)
        let moved = engine.project
        engine.undo(); XCTAssertEqual(engine.project, obstructed)
        // Extending the original clip through the adjacent blocker exercises trim collision placement.
        let oldRange = obstructed.tracks[first].clips[0].sourceRange
        try engine.apply(.trim(clipID: id, sourceRange: TimeRange(start: oldRange.start, duration: RationalTime(6)), timelineStart: RationalTime(10)))
        try assertRoutes(engine.project)
        engine.undo(); XCTAssertEqual(engine.project, obstructed)
        try engine.apply(.move(clipID: id, trackID: sourceTrackID, start: RationalTime(15)))
        // Fresh sibling IDs may differ across separate executions; placement and routing stay equivalent.
        XCTAssertEqual(engine.project.tracks.count, moved.tracks.count)
        try assertRoutes(engine.project)
    }
}
