import Foundation
import XCTest
@testable import EditorCore

final class TimelineEditEngineTests: XCTestCase {
    private func time(_ value: Int64) throws -> RationalTime { try RationalTime(value) }
    private func range(_ start: Int64, _ duration: Int64) throws -> TimeRange {
        try TimeRange(start: time(start), duration: time(duration))
    }
    private func range(_ duration: Int64) throws -> TimeRange { try range(0, duration) }
    private func fixture(cleanup: Bool = true) throws -> (Project, TimelineClip, TimelineTrack) {
        let asset = MediaAsset(name: "Music", duration: try time(100), streams: [
            MediaStream(index: 0, kind: .audio, audioLayout: .stereo),
            MediaStream(index: 1, kind: .video)
        ])
        let template = TrackTemplate(kind: .audio, audioLayout: .stereo, routing: AudioRouting(outputChannels: [1, 0]), gain: 0.75)
        let family = TrackFamily(baseName: "Music", template: template)
        let selection = AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0), SourceChannel(streamIndex: 0, channelIndex: 1)], layout: .stereo)
        let clip = TimelineClip(assetID: asset.id, sourceRange: try range(4), selection: .audio(selection))
        let track = TimelineTrack(familyID: family.id, template: template, clips: [clip])
        let project = Project(settings: try SequenceSettings(), assets: [asset], families: [family], tracks: [track], preferences: EditorPreferences(automaticallyRemoveEmptyTracks: cleanup))
        return (project, clip, track)
    }

    func testAdjacentPlacementUsesExistingTrackAndTrimCollisionIsAtomic() throws {
        let (project, first, track) = try fixture()
        var second = first; second.id = UUID(); second.timelineStart = try time(4)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.place(clip: second, trackID: track.id))
        XCTAssertEqual(engine.project.tracks.count, 1)
        let adjacent = engine.project
        try engine.apply(.trim(clipID: first.id, sourceRange: range(6), timelineStart: .zero))
        XCTAssertEqual(engine.project.tracks.count, 2)
        XCTAssertEqual(engine.project.tracks.map { $0.displayName(in: engine.project) }, ["Music 1", "Music 2"])
        XCTAssertEqual(engine.project.tracks[1].template, track.template)
        XCTAssertEqual(engine.project.tracks[0].clips.first?.timelineStart, second.timelineStart)
        let extended = engine.project
        engine.undo(); XCTAssertEqual(engine.project, adjacent)
        engine.redo(); XCTAssertEqual(engine.project, extended)
    }

    func testFreeSiblingReuseAndIndependentCopiedSettings() throws {
        var (project, clip, track) = try fixture(cleanup: false)
        let sibling = TimelineTrack(familyID: track.familyID, customName: "Solo", template: track.template)
        project.tracks.append(sibling)
        var engine = try TimelineEditEngine(project: project)
        clip.id = UUID(); clip.timelineStart = try time(1)
        try engine.apply(.place(clip: clip, trackID: track.id))
        XCTAssertEqual(engine.project.tracks.count, 2)
        XCTAssertEqual(engine.project.tracks[1].clips.first?.id, clip.id)
        XCTAssertEqual(engine.project.tracks[1].displayName(in: engine.project), "Solo")
        project = engine.project
        project.tracks[0].template.gain = 0.2
        XCTAssertEqual(project.tracks[1].template.gain, 0.75)
    }

    func testMultipleOverlapsCreateSiblingWithoutMovingOtherClips() throws {
        let (project, initial, track) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        for start in [1, 2] {
            var clip = initial; clip.id = UUID(); clip.timelineStart = try time(Int64(start))
            try engine.apply(.place(clip: clip, trackID: track.id))
        }
        XCTAssertEqual(engine.project.tracks.count, 3)
        XCTAssertEqual(engine.project.tracks.map { $0.displayName(in: engine.project) }, ["Music 1", "Music 2", "Music 3"])
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).map(\.timelineStart)), Set([try time(0), try time(1), try time(2)]))
    }

    func testCleanupCollapsesNamesRetainsTemplateAndRecreatesFamily() throws {
        let (project, clip, track) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.delete(clipID: clip.id))
        XCTAssertTrue(engine.project.tracks.isEmpty)
        XCTAssertEqual(engine.project.families, project.families)
        try engine.apply(.placeInFamily(clip: clip, familyID: track.familyID))
        XCTAssertEqual(engine.project.tracks.count, 1)
        XCTAssertEqual(engine.project.tracks[0].template, track.template)
        XCTAssertEqual(engine.project.tracks[0].displayName(in: engine.project), "Music")
        engine.undo(); XCTAssertTrue(engine.project.tracks.isEmpty)
        engine.undo(); XCTAssertEqual(engine.project, project)
    }

    func testRetainedTracksAndDisabledCleanupKeepSettings() throws {
        var (project, clip, _) = try fixture()
        project.tracks[0].retained = true
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.delete(clipID: clip.id))
        XCTAssertEqual(engine.project.tracks.count, 1)
        (project, clip, _) = try fixture(cleanup: false)
        engine = try TimelineEditEngine(project: project)
        try engine.apply(.delete(clipID: clip.id))
        XCTAssertEqual(engine.project.tracks.count, 1)
    }

    func testFailedEditRestoresProjectAndPreservesRedo() throws {
        let (project, clip, track) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.move(clipID: clip.id, trackID: track.id, start: time(1)))
        engine.undo()
        XCTAssertTrue(engine.canRedo)
        XCTAssertThrowsError(try engine.apply(.trim(clipID: clip.id, sourceRange: range(101), timelineStart: .zero)))
        XCTAssertEqual(engine.project, project)
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(engine.canRedo)
        XCTAssertThrowsError(try engine.apply(.move(clipID: clip.id, trackID: UUID(), start: time(2))))
        XCTAssertEqual(engine.project, project)
        engine.redo()
        XCTAssertEqual(engine.project.tracks[0].clips[0].timelineStart, try time(1))
    }

    func testSplitPreservesExactSourceContinuityAndUndo() throws {
        let (project, clip, _) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        let at = try RationalTime(1001, 30000)
        try engine.apply(.split(clipID: clip.id, at: at))
        let pieces = engine.project.tracks[0].clips
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].sourceRange.duration, at)
        XCTAssertEqual(pieces[1].sourceRange.start, try pieces[0].sourceRange.end())
        XCTAssertEqual(try pieces[1].sourceRange.end(), try clip.sourceRange.end())
        XCTAssertEqual(pieces[1].timelineStart, at)
        XCTAssertThrowsError(try engine.apply(.split(clipID: clip.id, at: .zero)))
        engine.undo(); XCTAssertEqual(engine.project, project)
    }

    func testLinkedMoveSplitTrimAndDeletePreserveAVSync() throws {
        var (project, audio, track) = try fixture()
        let group = UUID(); audio.linkGroupID = group
        project.tracks[0].clips = [audio]
        let family = TrackFamily(baseName: "Picture", template: TrackTemplate(kind: .video))
        let video = TimelineClip(assetID: audio.assetID, sourceRange: audio.sourceRange, selection: .video(streamIndex: 1), linkGroupID: group)
        let videoTrack = TimelineTrack(familyID: family.id, template: family.template, clips: [video])
        project.families.append(family); project.tracks.append(videoTrack)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.move(clipID: audio.id, trackID: track.id, start: time(10)))
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).map(\.timelineStart)), [try time(10)])
        try engine.apply(.trim(clipID: audio.id, sourceRange: range(1, 3), timelineStart: time(11)))
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).map(\.sourceRange)), [try range(1, 3)])
        try engine.apply(.split(clipID: audio.id, at: time(12)))
        let rights = engine.project.tracks.flatMap(\.clips).filter { $0.timelineStart == (try! time(12)) }
        XCTAssertEqual(rights.count, 2)
        XCTAssertEqual(rights[0].linkGroupID, rights[1].linkGroupID)
        XCTAssertNotEqual(rights[0].linkGroupID, group)
        try engine.apply(.delete(clipID: rights[0].id))
        XCTAssertEqual(engine.project.tracks.flatMap(\.clips).count, 2)
        engine.undo(); XCTAssertEqual(engine.project.tracks.flatMap(\.clips).count, 4)
    }
    func testCollisionSkipsFreeSiblingWithIncompatibleLayout() throws {
        var (project, clip, track) = try fixture(cleanup: false)
        let mono = TimelineTrack(familyID: track.familyID, template: TrackTemplate(kind: .audio, audioLayout: .mono, routing: AudioRouting(outputChannels: [0])))
        project.tracks.append(mono)
        var engine = try TimelineEditEngine(project: project)
        clip.id = UUID()
        try engine.apply(.place(clip: clip, trackID: track.id))
        XCTAssertEqual(engine.project.tracks.count, 3)
        XCTAssertTrue(engine.project.tracks.first { $0.id == mono.id }!.clips.isEmpty)
        XCTAssertEqual(engine.project.tracks[1].template, track.template)
        let before = engine.project
        XCTAssertThrowsError(try engine.apply(.move(clipID: clip.id, trackID: mono.id, start: .zero)))
        XCTAssertEqual(engine.project, before)
    }

    func testFailedLinkedMoveAndSplitRestoreAllComponents() throws {
        var (project, audio, track) = try fixture()
        let group = UUID(); audio.linkGroupID = group
        project.tracks[0].clips = [audio]
        let family = TrackFamily(baseName: "Picture", template: TrackTemplate(kind: .video))
        let video = TimelineClip(assetID: audio.assetID, sourceRange: try range(2), timelineStart: try time(1), selection: .video(streamIndex: 1), linkGroupID: group)
        project.families.append(family)
        project.tracks.append(TimelineTrack(familyID: family.id, template: family.template, clips: [video]))
        var engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try engine.apply(.move(clipID: audio.id, trackID: track.id, start: time(-2))))
        XCTAssertEqual(engine.project, project)
        // The chosen cut lies inside the audio but outside its linked video.
        XCTAssertThrowsError(try engine.apply(.split(clipID: audio.id, at: RationalTime(1, 2))))
        XCTAssertEqual(engine.project, project)
        XCTAssertFalse(engine.canUndo)
    }

}
