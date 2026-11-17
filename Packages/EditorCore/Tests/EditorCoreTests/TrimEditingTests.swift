import Foundation
import XCTest
@testable import EditorCore

final class TrimEditingTests: XCTestCase {
    /// Three linked A/V shots of four seconds: [0,4) [4,8) [8,12), source in = timeline start.
    private func fixture() throws -> (Project, [[UUID]]) {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/trim.mov"), duration: try RationalTime(30),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie])
        var shots: [[UUID]] = []
        for index in 0..<3 {
            let start = try RationalTime(Int64(index * 4))
            shots.append(try project.appendAsset(movie.id, at: start, sourceRange: TimeRange(start: start, duration: RationalTime(4))))
        }
        return (project, shots)
    }
    private func clip(_ id: UUID, in project: Project) throws -> TimelineClip { try XCTUnwrap(project.tracks.flatMap(\.clips).first { $0.id == id }) }
    private func seconds(_ value: Int64, _ scale: Int64 = 1) throws -> RationalTime { try RationalTime(value, scale) }
    private func range(_ start: Int64, _ duration: Int64) throws -> TimeRange { try TimeRange(start: RationalTime(start), duration: RationalTime(duration)) }

    func testRollMovesTheCutAndTrimsBothSidesWithTheirSound() throws {
        let (project, shots) = try fixture()
        let trackCount = project.tracks.count
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.roll(clipID: shots[0][0], edge: .trailing, delta: seconds(1)))
        for (outgoing, incoming) in zip(shots[0], shots[1]) {
            XCTAssertEqual(try clip(outgoing, in: engine.project).sourceRange, try range(0, 5))
            XCTAssertEqual(try clip(incoming, in: engine.project).timelineStart, try seconds(5))
            XCTAssertEqual(try clip(incoming, in: engine.project).sourceRange, try range(5, 3))
        }
        XCTAssertEqual(try clip(shots[2][0], in: engine.project).timelineStart, try seconds(8), "Nothing else moves")
        XCTAssertEqual(engine.project.tracks.count, trackCount)
        XCTAssertEqual(try TimelineRenderPlan(project: engine.project).duration, try seconds(12))

        // Rolling the incoming clip's leading edge is the same cut from the other side.
        try engine.apply(.roll(clipID: shots[1][1], edge: .leading, delta: seconds(-2)))
        XCTAssertEqual(try clip(shots[0][0], in: engine.project).sourceRange, try range(0, 3))
        XCTAssertEqual(try clip(shots[1][0], in: engine.project).sourceRange, try range(3, 5))
        engine.undo(); engine.undo()
        XCTAssertEqual(engine.project, project)

        XCTAssertThrowsError(try engine.apply(.roll(clipID: shots[0][0], edge: .leading, delta: seconds(1)))) {
            XCTAssertEqual($0 as? TimelineEditError, .noAdjacentClip)
        }
        XCTAssertThrowsError(try engine.apply(.roll(clipID: shots[1][0], edge: .leading, delta: seconds(-4)))) {
            XCTAssertEqual($0 as? TimelineEditError, .trimBeyondMedia, "The outgoing clip would vanish")
        }
        XCTAssertEqual(engine.project, project)
    }

    func testRollKeepsADissolveAtTheCut() throws {
        let (project, shots) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: shots[0][0], incomingClipID: shots[1][0], duration: seconds(1), curve: .linear))
        try engine.apply(.roll(clipID: shots[0][0], edge: .trailing, delta: seconds(1, 2)))
        XCTAssertEqual(engine.project.audioCrossfades.count, 1)
        XCTAssertEqual(try clip(shots[1][0], in: engine.project).timelineStart, try seconds(9, 2))
    }

    func testRollBoundsStopAtTheNeighboursMedia() throws {
        let (project, shots) = try fixture()
        let quantum = 1.0 / 25
        let outgoing = try clip(shots[0][0], in: project), incoming = try clip(shots[1][0], in: project)
        XCTAssertEqual(TimelineGesture.rollDelta(10, edge: .trailing, clip: outgoing, project: project, quantum: quantum), 4 - quantum, accuracy: 1e-9)
        XCTAssertEqual(TimelineGesture.rollDelta(-10, edge: .leading, clip: incoming, project: project, quantum: quantum), quantum - 4, accuracy: 1e-9)
        XCTAssertEqual(TimelineGesture.rollDelta(1.01, edge: .trailing, clip: outgoing, project: project, quantum: quantum), 1, accuracy: 1e-9)
        XCTAssertEqual(TimelineGesture.rollDelta(1, edge: .leading, clip: outgoing, project: project, quantum: quantum), 0, "No neighbour, no roll")
        XCTAssertEqual(project.adjacentClip(to: outgoing.id, edge: .trailing)?.id, incoming.id)
        XCTAssertNil(project.adjacentClip(to: outgoing.id, edge: .leading))
    }

    func testSlipChangesTheSourceInPlaceAndKeepsKeyframesInTheClip() throws {
        var (project, shots) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setVolumeKeyframes(clipIDs: [shots[1][1]], keyframes: [
            VolumeKeyframe(time: seconds(1), gain: 0.2), VolumeKeyframe(time: seconds(5), gain: 1)]))
        project = engine.project
        try engine.apply(.slip(clipID: shots[1][0], delta: seconds(2)))
        for id in shots[1] {
            XCTAssertEqual(try clip(id, in: engine.project).sourceRange, try range(6, 4))
            XCTAssertEqual(try clip(id, in: engine.project).timelineStart, try seconds(4))
        }
        XCTAssertEqual(try clip(shots[1][1], in: engine.project).volumeKeyframes.map(\.time), [try seconds(3), try seconds(7)])
        engine.undo()

        // A point pushed before the media start becomes one point at zero on the same curve.
        try engine.apply(.slip(clipID: shots[1][0], delta: seconds(-2)))
        let keyframes = try clip(shots[1][1], in: engine.project).volumeKeyframes
        XCTAssertEqual(keyframes.map(\.time), [.zero, try seconds(3)])
        XCTAssertEqual(keyframes[0].gain, 0.4, accuracy: 1e-9)
        engine.undo()
        XCTAssertEqual(engine.project, project)

        for delta in [try seconds(-5), try seconds(23)] {
            XCTAssertThrowsError(try engine.apply(.slip(clipID: shots[1][0], delta: delta))) {
                XCTAssertEqual($0 as? TimelineEditError, .trimBeyondMedia)
            }
        }
        XCTAssertNoThrow(try engine.apply(.slip(clipID: shots[1][0], delta: seconds(22))), "Up to the end of the media")
    }

    func testSlideMovesTheClipBetweenItsNeighbours() throws {
        let (project, shots) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.slide(clipID: shots[1][0], delta: seconds(1)))
        for index in 0..<2 {
            XCTAssertEqual(try clip(shots[0][index], in: engine.project).sourceRange, try range(0, 5))
            XCTAssertEqual(try clip(shots[1][index], in: engine.project).sourceRange, try range(4, 4), "The sliding clip keeps its source")
            XCTAssertEqual(try clip(shots[1][index], in: engine.project).timelineStart, try seconds(5))
            XCTAssertEqual(try clip(shots[2][index], in: engine.project).sourceRange, try range(9, 3))
            XCTAssertEqual(try clip(shots[2][index], in: engine.project).timelineStart, try seconds(9))
        }
        XCTAssertEqual(try TimelineRenderPlan(project: engine.project).duration, try seconds(12))
        engine.undo()
        XCTAssertThrowsError(try engine.apply(.slide(clipID: shots[1][0], delta: seconds(-4)))) {
            XCTAssertEqual($0 as? TimelineEditError, .trimBeyondMedia)
        }
        XCTAssertEqual(engine.project, project)
    }

    func testLiftLeavesAGapAndExtractClosesIt() throws {
        let (project, shots) = try fixture()
        var lifted = project
        try lifted.lift(range(2, 4))
        XCTAssertEqual(try clip(shots[0][0], in: lifted).sourceRange, try range(0, 2))
        let remainder = try XCTUnwrap(lifted.tracks[0].clips.first { $0.timelineStart == (try! RationalTime(6)) })
        XCTAssertEqual(remainder.sourceRange, try range(6, 2))
        XCTAssertEqual(try TimelineRenderPlan(project: lifted).duration, try seconds(12))

        var extracted = project
        try extracted.extract(range(2, 4))
        XCTAssertEqual(extracted.tracks[0].clips.map(\.timelineStart.seconds).sorted(), [0, 2, 4])
        XCTAssertEqual(try clip(shots[2][1], in: extracted).timelineStart, try seconds(4))
        XCTAssertEqual(try TimelineRenderPlan(project: extracted).duration, try seconds(8))
    }
}
