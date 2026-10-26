import Foundation
import XCTest
@testable import EditorCore

final class PlacementEditingTests: XCTestCase {
    /// Three linked A/V shots of four seconds: [0,4) [4,8) [8,12), source in = timeline start.
    private func fixture() throws -> (Project, UUID, [[UUID]]) {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/placement.mov"), duration: try RationalTime(30),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie])
        var shots: [[UUID]] = []
        for index in 0..<3 {
            let start = try RationalTime(Int64(index * 4))
            shots.append(try project.appendAsset(movie.id, at: start, sourceRange: TimeRange(start: start, duration: RationalTime(4))))
        }
        return (project, movie.id, shots)
    }
    private func clip(_ id: UUID, in project: Project) -> TimelineClip? { project.tracks.flatMap(\.clips).first { $0.id == id } }
    private func starts(_ project: Project) -> [Double] {
        project.tracks[0].clips.map(\.timelineStart.seconds).sorted()
    }

    func testRippleDeleteClosesTheGapOnEveryTrackAndRefusesCrossingClips() throws {
        let (project, _, shots) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.rippleDelete(clipID: shots[1][0])
        XCTAssertNil(clip(shots[1][1], in: engine.project), "Linked audio goes with the picture")
        XCTAssertEqual(clip(shots[2][0], in: engine.project)?.timelineStart, try RationalTime(4))
        XCTAssertEqual(clip(shots[2][1], in: engine.project)?.timelineStart, try RationalTime(4))
        XCTAssertEqual(try TimelineRenderPlan(project: engine.project).duration, try RationalTime(8))
        engine.undo()
        XCTAssertEqual(engine.project, project)

        var music = project
        let song = MediaAsset(name: "Song", duration: try RationalTime(30), streams: [.init(index: 0, kind: .audio, audioLayout: .stereo)])
        try music.addAsset(song)
        try music.appendAsset(song.id, at: RationalTime(5), sourceRange: TimeRange(start: .zero, duration: RationalTime(2)))
        var blocked = try TimelineEditEngine(project: music)
        XCTAssertThrowsError(try blocked.rippleDelete(clipID: shots[1][0])) { XCTAssertEqual($0 as? TimelineEditError, .rippleTrimOverlap) }
        XCTAssertEqual(blocked.project, music)
    }

    func testInsertSplitsAtThePlayheadAndPushesLaterClips() throws {
        var (project, movie, shots) = try fixture()
        let trackCount = project.tracks.count
        let ids = try project.placeAsset(movie, at: RationalTime(6), sourceRange: TimeRange(start: RationalTime(20), duration: RationalTime(2)), mode: .insert)
        XCTAssertEqual(project.tracks.count, trackCount, "Inserted media lands on the existing tracks")
        XCTAssertEqual(starts(project), [0, 4, 6, 8, 10])
        XCTAssertEqual(clip(ids[0], in: project)?.timelineStart, try RationalTime(6))
        XCTAssertEqual(clip(shots[1][0], in: project)?.sourceRange.duration, try RationalTime(2), "The crossed shot is split at the playhead")
        XCTAssertEqual(clip(shots[2][1], in: project)?.timelineStart, try RationalTime(10))
        let tail = try XCTUnwrap(project.tracks[0].clips.first { $0.timelineStart == (try! RationalTime(8)) })
        XCTAssertEqual(tail.sourceRange, try TimeRange(start: RationalTime(6), duration: RationalTime(2)))
        XCTAssertEqual(try TimelineRenderPlan(project: project).duration, try RationalTime(14))
    }

    func testOverwriteReplacesTheDestinationRangeWithoutMovingOtherClips() throws {
        var (project, movie, shots) = try fixture()
        let trackCount = project.tracks.count
        let ids = try project.placeAsset(movie, at: RationalTime(6), sourceRange: TimeRange(start: RationalTime(20), duration: RationalTime(3)), mode: .overwrite)
        XCTAssertEqual(project.tracks.count, trackCount)
        XCTAssertEqual(starts(project), [0, 4, 6, 9])
        XCTAssertEqual(clip(shots[1][0], in: project)?.sourceRange.duration, try RationalTime(2))
        XCTAssertEqual(clip(shots[2][0], in: project)?.timelineStart, try RationalTime(9))
        XCTAssertEqual(clip(shots[2][0], in: project)?.sourceRange, try TimeRange(start: RationalTime(9), duration: RationalTime(3)))
        XCTAssertEqual(clip(ids[1], in: project)?.timelineStart, try RationalTime(6), "Audio is overwritten too")
        XCTAssertEqual(try TimelineRenderPlan(project: project).duration, try RationalTime(12))

        // Overwriting inside one shot splits it; both remainders keep linked picture and sound together.
        var (inner, innerMovie, innerShots) = try fixture()
        try inner.placeAsset(innerMovie, at: RationalTime(5), sourceRange: TimeRange(start: RationalTime(20), duration: RationalTime(1)), mode: .overwrite)
        let rights = inner.tracks.flatMap(\.clips).filter { $0.timelineStart == (try! RationalTime(6)) }
        XCTAssertEqual(rights.count, 2)
        XCTAssertNotNil(rights[0].linkGroupID)
        XCTAssertEqual(rights[0].linkGroupID, rights[1].linkGroupID)
        XCTAssertNotEqual(rights[0].linkGroupID, clip(innerShots[1][0], in: inner)?.linkGroupID)
    }

    func testInsertingAtADissolvedCutDropsTheDissolve() throws {
        var (project, movie, shots) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: shots[0][0], incomingClipID: shots[1][0], duration: RationalTime(1), curve: .linear))
        project = engine.project
        try project.placeAsset(movie, at: RationalTime(4), sourceRange: TimeRange(start: RationalTime(20), duration: RationalTime(2)), mode: .insert)
        XCTAssertTrue(project.audioCrossfades.isEmpty)
        XCTAssertEqual(starts(project), [0, 4, 6, 10])
    }
}

final class ClipClipboardTests: XCTestCase {
    func testCopyPasteKeepsLinkedComponentsTogetherWithNewIdentities() throws {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/clipboard.mov"), duration: try RationalTime(30),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie])
        let ids = try project.appendAsset(movie.id, at: .zero, sourceRange: TimeRange(start: RationalTime(3), duration: RationalTime(4)))
        project.tracks[1].clips[0].gain = 0.5
        let clipboard = try project.copyClips(linkedTo: ids[1])
        XCTAssertEqual(clipboard.entries.count, 2)
        XCTAssertEqual(clipboard.duration, try RationalTime(4))
        let pasted = try project.pasteClips(clipboard, at: RationalTime(10))
        let clips = project.tracks.flatMap(\.clips).filter { pasted.contains($0.id) }
        XCTAssertEqual(clips.count, 2)
        XCTAssertTrue(clips.allSatisfy { $0.timelineStart == (try! RationalTime(10)) && $0.sourceRange.start == (try! RationalTime(3)) })
        XCTAssertEqual(Set(clips.map(\.linkGroupID)).count, 1)
        XCTAssertNotEqual(clips[0].linkGroupID, project.tracks[0].clips[0].linkGroupID)
        XCTAssertEqual(project.tracks.count, 2, "Pasted clips reuse the original tracks")
        XCTAssertTrue(clips.contains { $0.gain == 0.5 })
        // Pasting over existing clips stacks on sibling tracks instead of overwriting.
        try project.pasteClips(clipboard, at: RationalTime(1))
        XCTAssertEqual(project.tracks.count, 4)
        XCTAssertNoThrow(try project.validate())
    }
}

final class ReplacePictureMediaTests: XCTestCase {
    func testPictureMovesToMediaStartingLaterAndKeepsTimingAndLinkedSound() throws {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/shaky.mov"), duration: try RationalTime(30),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        let steady = MediaAsset(name: "Movie (stabilised)", originalURL: URL(fileURLWithPath: "/private/tmp/steady.mov"), duration: try RationalTime(8),
                                streams: [.init(index: 0, kind: .video)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie, steady])
        let ids = try project.appendAsset(movie.id, at: RationalTime(2), sourceRange: TimeRange(start: RationalTime(11), duration: RationalTime(6)))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.replacePictureMedia(clipID: ids[0], assetID: steady.id, streamIndex: 0, sourceOffset: RationalTime(10)))
        let picture = try XCTUnwrap(engine.project.tracks.flatMap(\.clips).first { $0.id == ids[0] })
        XCTAssertEqual(picture.assetID, steady.id)
        XCTAssertEqual(picture.sourceRange, try TimeRange(start: RationalTime(1), duration: RationalTime(6)))
        XCTAssertEqual(picture.timelineStart, try RationalTime(2))
        XCTAssertEqual(engine.project.tracks.flatMap(\.clips).first { $0.id == ids[1] }?.assetID, movie.id, "Linked sound stays on the original")
        XCTAssertThrowsError(try engine.apply(.replacePictureMedia(clipID: ids[0], assetID: steady.id, streamIndex: 0, sourceOffset: RationalTime(20))),
                             "The new media must cover the clip")
        engine.undo()
        XCTAssertEqual(engine.project, project)
    }

    func testStabilisingKeepsDissolvesTheNewMediaSupports() throws {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/shaky.mov"), duration: try RationalTime(30), streams: [.init(index: 0, kind: .video)])
        let steady = MediaAsset(name: "Movie (stabilised)", originalURL: URL(fileURLWithPath: "/private/tmp/steady.mov"), duration: try RationalTime(7),
                                streams: [.init(index: 0, kind: .video)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie, steady])
        let a = try project.appendAsset(movie.id, at: .zero, sourceRange: TimeRange(start: RationalTime(2), duration: RationalTime(4)))[0]
        let b = try project.appendAsset(movie.id, at: RationalTime(4), sourceRange: TimeRange(start: RationalTime(11), duration: RationalTime(5)))[0]
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a, incomingClipID: b, duration: RationalTime(1), curve: .linear))
        // The copy starts a second before the shot's source in, leaving room for the dissolve.
        try engine.apply(.replacePictureMedia(clipID: b, assetID: steady.id, streamIndex: 0, sourceOffset: RationalTime(10)))
        XCTAssertEqual(engine.project.audioCrossfades.count, 1)
        XCTAssertNoThrow(try TimelineRenderPlan(project: engine.project))
    }
}
