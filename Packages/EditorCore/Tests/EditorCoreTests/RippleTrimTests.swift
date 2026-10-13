import Foundation
import XCTest
@testable import EditorCore

final class RippleTrimTests: XCTestCase {
    private func fixture() throws -> (Project, UUID) {
        let asset = MediaAsset(name: "Linked", duration: try RationalTime(100), streams: [
            MediaStream(index: 0, kind: .video), MediaStream(index: 1, kind: .audio, audioLayout: .stereo)])
        let vt = TrackTemplate(kind: .video), at = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let vf = TrackFamily(baseName: "Video", template: vt), af = TrackFamily(baseName: "Audio", template: at)
        let group = UUID(), laterGroup = UUID()
        let range = try TimeRange(start: RationalTime(10), duration: RationalTime(4))
        let video = TimelineClip(assetID: asset.id, sourceRange: range, timelineStart: try RationalTime(2),
            selection: .video(streamIndex: 0), linkGroupID: group)
        var audio = video; audio.id = UUID()
        audio.selection = .audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo))
        audio.fadeOut = .init(duration: try RationalTime(3), curve: .equalPower)
        var laterVideo = video; laterVideo.id = UUID(); laterVideo.timelineStart = try RationalTime(6); laterVideo.linkGroupID = laterGroup
        var laterAudio = audio; laterAudio.id = UUID(); laterAudio.timelineStart = try RationalTime(6); laterAudio.linkGroupID = laterGroup
        let project = Project(settings: try SequenceSettings(frameRate: FrameRate(30000, 1001)), assets: [asset], families: [vf, af], tracks: [
            TimelineTrack(familyID: vf.id, template: vt, clips: [video, laterVideo]),
            TimelineTrack(familyID: af.id, template: at, clips: [audio, laterAudio])])
        return (project, video.id)
    }

    func testLeadingRippleClosesAllTracksPreservesSourceSyncAndUndo() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.rippleTrim(clipID: id, edge: .leading, at: RationalTime(4)))
        for track in engine.project.tracks {
            XCTAssertEqual(track.clips[0].timelineStart, try RationalTime(2))
            XCTAssertEqual(track.clips[0].sourceRange.start, try RationalTime(12))
            XCTAssertEqual(track.clips[0].sourceRange.duration, try RationalTime(2))
            XCTAssertEqual(track.clips[1].timelineStart, try RationalTime(4))
            XCTAssertEqual(track.clips[1].sourceRange, project.tracks[0].clips[1].sourceRange)
        }
        XCTAssertEqual(engine.project.tracks[1].clips[0].fadeOut.duration, try RationalTime(2))
        let edited = engine.project
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project, edited)
    }

    func testTrailingRippleUsesExactFractionalTimeAndKeepsSourceIn() throws {
        let (project, id) = try fixture()
        let at = try project.settings.frameRate.time(forFrames: 100)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.rippleTrim(clipID: id, edge: .trailing, at: at))
        for track in engine.project.tracks {
            XCTAssertEqual(track.clips[0].sourceRange.start, try RationalTime(10))
            XCTAssertEqual(track.clips[0].sourceRange.duration, try at.subtracting(RationalTime(2)))
            XCTAssertEqual(track.clips[1].timelineStart, at)
        }
    }

    func testOverlappingUnrelatedClipRejectsAtomicallyAndPreservesRedo() throws {
        var (project, id) = try fixture()
        var overlapping = project.tracks[0].clips[0]
        overlapping.id = UUID(); overlapping.linkGroupID = nil
        project.tracks.append(TimelineTrack(familyID: project.tracks[0].familyID, template: project.tracks[0].template, clips: [overlapping]))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.delete(clipID: overlapping.id)); engine.undo()
        XCTAssertThrowsError(try engine.apply(.rippleTrim(clipID: id, edge: .leading, at: RationalTime(4)))) {
            XCTAssertEqual($0 as? TimelineEditError, .rippleTrimOverlap)
        }
        XCTAssertEqual(engine.project, project)
        XCTAssertFalse(engine.canUndo); XCTAssertTrue(engine.canRedo)
    }

    func testBoundaryAndUnalignedLinkedComponentsReject() throws {
        var (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        for frame in [1, 2, 6, 7] {
            XCTAssertThrowsError(try engine.apply(.rippleTrim(clipID: id, edge: .trailing, at: RationalTime(Int64(frame)))))
            XCTAssertEqual(engine.project, project)
        }
        project.tracks[1].clips[0].sourceRange.duration = try RationalTime(3)
        engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try engine.apply(.rippleTrim(clipID: id, edge: .leading, at: RationalTime(4))))
        XCTAssertEqual(engine.project, project)
    }

    func testEarlierClipsAndDownstreamGapsArePreserved() throws {
        var (project, id) = try fixture()
        for ti in project.tracks.indices {
            var earlier = project.tracks[ti].clips[0]
            earlier.id = UUID(); earlier.linkGroupID = nil; earlier.timelineStart = .zero
            earlier.sourceRange.duration = try RationalTime(1); earlier.fadeOut = .init()
            project.tracks[ti].clips.append(earlier)
            project.tracks[ti].clips[1].timelineStart = try RationalTime(8)
        }
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.rippleTrim(clipID: id, edge: .trailing, at: RationalTime(4)))
        for ti in project.tracks.indices {
            XCTAssertEqual(engine.project.tracks[ti].clips[2], project.tracks[ti].clips[2])
            XCTAssertEqual(engine.project.tracks[ti].clips[1].timelineStart, try RationalTime(6))
        }
    }
}
