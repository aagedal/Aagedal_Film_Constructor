import Foundation
import XCTest
@testable import EditorCore

final class TimelineGestureTests: XCTestCase {
    func testSnappingChoosesNearestLeadingOrTrailingEdge() {
        XCTAssertEqual(TimelineGesture.snap(3.95, movingEdges: [0, 2], targets: [0, 6], tolerance: 0.1), 4, accuracy: 1e-10)
        XCTAssertEqual(TimelineGesture.snap(3.8, movingEdges: [0, 2], targets: [0, 6], tolerance: 0.1), 3.8)
        XCTAssertEqual(TimelineGesture.snap(5.97, movingEdges: [0], targets: [6], tolerance: 0.1), 6)
    }

    func testLinkedTrimBoundsUseEveryComponentAndFrameGrid() throws {
        let asset = MediaAsset(name: "Source", duration: try RationalTime(10))
        let group = UUID()
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(2), duration: RationalTime(4)), timelineStart: try RationalTime(3), selection: .still, linkGroupID: group)
        var linked = clip
        linked.id = UUID()
        linked.sourceRange = try TimeRange(start: RationalTime(1), duration: RationalTime(3))
        linked.timelineStart = try RationalTime(2)
        let track = TimelineTrack(familyID: UUID(), template: TrackTemplate(kind: .video), clips: [clip, linked])
        let project = Project(settings: try SequenceSettings(), assets: [asset], tracks: [track])
        XCTAssertEqual(TimelineGesture.trimDelta(-5, edge: .leading, clip: clip, project: project, quantum: 0.04), -1)
        XCTAssertEqual(TimelineGesture.trimDelta(10, edge: .leading, clip: clip, project: project, quantum: 0.04), 2.96, accuracy: 1e-10)
        XCTAssertEqual(TimelineGesture.trimDelta(10, edge: .trailing, clip: clip, project: project, quantum: 0.04), 4)
        XCTAssertEqual(TimelineGesture.trimDelta(-10, edge: .trailing, clip: clip, project: project, quantum: 0.04), -2.96, accuracy: 1e-10)
        XCTAssertEqual(TimelineGesture.components(of: clip, in: project).count, 2)
        // An Option-drag trim is bounded by the dragged component alone.
        XCTAssertEqual(TimelineGesture.trimDelta(-5, edge: .leading, clip: clip, project: project, quantum: 0.04, alone: true), -2)
        XCTAssertEqual(TimelineGesture.trimDelta(-10, edge: .trailing, clip: clip, project: project, quantum: 0.04, alone: true), -3.96, accuracy: 1e-10)
        XCTAssertEqual(TimelineGesture.components(of: clip, in: project, alone: true).map(\.id), [clip.id])
    }

    func testSourceBoundsBetweenFramesRoundInward() throws {
        let asset = MediaAsset(name: "Source", duration: try RationalTime(1001, 1000))
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), selection: .still)
        let track = TimelineTrack(familyID: UUID(), template: TrackTemplate(kind: .video), clips: [clip])
        let project = Project(settings: try SequenceSettings(), assets: [asset], tracks: [track])
        XCTAssertEqual(TimelineGesture.trimDelta(1, edge: .trailing, clip: clip, project: project, quantum: 0.04), 0)
    }
}
