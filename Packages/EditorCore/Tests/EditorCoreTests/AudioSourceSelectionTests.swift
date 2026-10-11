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

    private func separatedFixture(cleanup: Bool = true) throws -> (Project, [UUID]) {
        let (project, id) = try fixture(cleanup: cleanup)
        var engine = try TimelineEditEngine(project: project)
        let ids = try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono), selection(3, .mono)],
                                              routing: [.init(outputChannels: [0]), .init(outputChannels: [1])])
        return (engine.project, ids)
    }

    func testConsolidateMonoToSurroundPreservesPictureTimingGainIdentityAndHistory() throws {
        let (project, ids) = try separatedFixture()
        var engine = try TimelineEditEngine(project: project)
        let origin = try XCTUnwrap(project.tracks.first { $0.clips.contains { $0.id == ids[0] } })
        XCTAssertEqual(try project.audioConsolidationCandidates(for: ids[0]).map(\.id), [ids[1]])
        let map = selection(4, .surround51)
        let route = AudioRouting(outputChannels: [0, 1, 0, 1, 0, 1])
        try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: map, routing: route)
        let edited = engine.project
        let track = try XCTUnwrap(edited.tracks.first { $0.clips.contains { $0.id == ids[0] } })
        XCTAssertEqual(track.id, origin.id)
        XCTAssertEqual(track.customName, origin.customName)
        XCTAssertEqual(track.retained, origin.retained)
        XCTAssertEqual(track.template.gain, 0.6)
        XCTAssertEqual(track.template.routing, route)
        XCTAssertEqual(track.audioLayout, .surround51)
        XCTAssertEqual(track.clips[0].sourceRange, origin.clips[0].sourceRange)
        XCTAssertEqual(track.clips[0].timelineStart, origin.clips[0].timelineStart)
        XCTAssertEqual(track.clips[0].linkGroupID, origin.clips[0].linkGroupID)
        XCTAssertEqual(edited.tracks.filter { $0.kind == .video }, project.tracks.filter { $0.kind == .video })
        XCTAssertFalse(edited.tracks.flatMap(\.clips).contains { $0.id == ids[1] })
        XCTAssertEqual(edited.tracks.count, 2)
        XCTAssertEqual(edited.families, project.families)
        let component = try XCTUnwrap(TimelineRenderPlan(project: edited).components.first { $0.clipID == ids[0] })
        XCTAssertEqual(component.selection, .audio(map))
        XCTAssertEqual(component.routing, route)
        let data = try JSONEncoder().encode(edited)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), edited)
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project, edited)
        try engine.apply(.move(clipID: ids[0], trackID: track.id, start: RationalTime(12)))
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).map(\.timelineStart)), [try RationalTime(12)])
    }

    func testConsolidationCleanupHonorsRetainedTracksAndPreference() throws {
        for cleanup in [true, false] {
            for retained in [true, false] {
                var (project, ids) = try separatedFixture(cleanup: cleanup)
                let index = try XCTUnwrap(project.tracks.firstIndex { $0.clips.contains { $0.id == ids[1] } })
                project.tracks[index].retained = retained
                let oldTrack = project.tracks[index]
                var engine = try TimelineEditEngine(project: project)
                try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(1, .stereo), routing: .init())
                let remaining = engine.project.tracks.first { $0.id == oldTrack.id }
                XCTAssertEqual(remaining != nil, retained || !cleanup)
                if let remaining {
                    var expected = oldTrack; expected.clips = []
                    XCTAssertEqual(remaining, expected)
                }
                engine.undo(); XCTAssertEqual(engine.project, project)
            }
        }
    }

    func testConsolidationOnlyRemovesExplicitComponentsAndPreservesOccupiedTrack() throws {
        let (original, id) = try fixture()
        var engine = try TimelineEditEngine(project: original)
        let ids = try engine.selectAudioSource(clipID: id, selections: [selection(2, .mono), selection(3, .mono), selection(2, .mono)],
                                              routing: [.init(outputChannels: [0]), .init(outputChannels: [1]), .init(outputChannels: [0])])
        var project = engine.project
        let originIndex = try XCTUnwrap(project.tracks.firstIndex { $0.clips.contains { $0.id == id } })
        var blocker = project.tracks[originIndex].clips[0]
        blocker.id = UUID(); blocker.linkGroupID = nil; blocker.timelineStart = try RationalTime(20)
        project.tracks[originIndex].clips.append(blocker)
        let origin = project.tracks[originIndex]
        let untouched = try XCTUnwrap(project.tracks.first { $0.clips.contains { $0.id == ids[2] } })
        engine = try TimelineEditEngine(project: project)
        try engine.consolidateAudioSources(clipID: id, replacingClipIDs: [ids[1]], selection: selection(1, .stereo), routing: .init())
        XCTAssertEqual(engine.project.tracks.first { $0.id == origin.id }?.clips, [blocker])
        XCTAssertEqual(engine.project.tracks.first { $0.id == origin.id }?.template, origin.template)
        XCTAssertEqual(engine.project.tracks.first { $0.id == untouched.id }, untouched)
        XCTAssertEqual(engine.project.tracks.flatMap(\.clips).count, 4)
        engine.undo(); XCTAssertEqual(engine.project, project)
    }

    func testConsolidationRejectsAmbiguousComponentsWithoutMutatingHistory() throws {
        let (project, ids) = try separatedFixture()
        let secondIndex = try XCTUnwrap(project.tracks.firstIndex { $0.clips.contains { $0.id == ids[1] } })
        var variants: [Project] = []
        var modified = project; modified.tracks[secondIndex].clips[0].timelineStart = try RationalTime(11); variants.append(modified)
        modified = project; modified.tracks[secondIndex].clips[0].sourceRange = try TimeRange(start: RationalTime(3), duration: RationalTime(5)); variants.append(modified)
        modified = project; modified.tracks[secondIndex].clips[0].linkGroupID = UUID(); variants.append(modified)
        modified = project; modified.tracks[secondIndex].template.gain = 0.2; variants.append(modified)
        modified = project
        var otherAsset = project.assets[0]; otherAsset.id = UUID(); modified.assets.append(otherAsset)
        modified.tracks[secondIndex].clips[0].assetID = otherAsset.id; variants.append(modified)
        modified = project
        let family = TrackFamily(baseName: "Other", template: modified.tracks[secondIndex].template)
        modified.families.append(family); modified.tracks[secondIndex].familyID = family.id; variants.append(modified)
        for variant in variants {
            XCTAssertTrue(try variant.audioConsolidationCandidates(for: ids[0]).isEmpty)
            var engine = try TimelineEditEngine(project: variant)
            XCTAssertThrowsError(try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(1, .stereo), routing: .init())) {
                XCTAssertEqual($0 as? TimelineEditError, .incompatibleAudioConsolidation)
            }
            XCTAssertEqual(engine.project, variant)
            XCTAssertFalse(engine.canUndo)
        }
    }

    func testInvalidConsolidationIDsAndMappingPreserveRedo() throws {
        let (project, ids) = try separatedFixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(1, .stereo), routing: .init())
        engine.undo()
        let videoID = project.tracks.first { $0.kind == .video }!.clips[0].id
        for replacement in [[], [ids[0]], [UUID()], [videoID], [ids[1], ids[1]]] {
            XCTAssertThrowsError(try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: replacement, selection: selection(1, .stereo), routing: .init()))
            XCTAssertEqual(engine.project, project)
            XCTAssertTrue(engine.canRedo)
        }
        XCTAssertThrowsError(try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(999, .stereo), routing: .init()))
        XCTAssertThrowsError(try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(1, .stereo), routing: .init(outputChannels: [0, 99])))
        XCTAssertEqual(engine.project, project)
        XCTAssertTrue(engine.canRedo)
        // Removing an explicitly selected component still commits when the retained map is identical.
        try engine.consolidateAudioSources(clipID: ids[0], replacingClipIDs: [ids[1]], selection: selection(2, .mono), routing: .init(outputChannels: [0]))
        XCTAssertFalse(engine.project.tracks.flatMap(\.clips).contains { $0.id == ids[1] })
        engine.undo(); XCTAssertEqual(engine.project, project)
    }
}
