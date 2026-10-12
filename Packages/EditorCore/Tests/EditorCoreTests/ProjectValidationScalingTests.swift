import Foundation
import XCTest
@testable import EditorCore

final class ProjectValidationScalingTests: XCTestCase {
    private func fixture(_ ranges: [(Int64, Int64)]) throws -> Project {
        let template = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Picture", template: template)
        let asset = MediaAsset(name: "Still", duration: try RationalTime(100))
        let clips = try ranges.map { start, duration in
            TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(duration)),
                         timelineStart: try RationalTime(start), selection: .still)
        }
        return Project(settings: try SequenceSettings(), assets: [asset], families: [family],
                       tracks: [.init(familyID: family.id, template: template, clips: clips)])
    }

    func testUnsortedAdjacentRangesAreValidAndPreserveStoredOrder() throws {
        let project = try fixture([(8, 2), (0, 3), (3, 5)])
        try project.validate()
        XCTAssertEqual(project.tracks[0].clips.map(\.timelineStart), try [8, 0, 3].map { try RationalTime($0) })
        let plan = try TimelineRenderPlan(project: project)
        XCTAssertEqual(plan.components.map(\.clipID), [project.tracks[0].clips[1].id, project.tracks[0].clips[2].id, project.tracks[0].clips[0].id])
        XCTAssertEqual(plan.duration, try RationalTime(10))
    }

    func testNestedAndEqualStartOverlapsAreRejectedRegardlessOfStorageOrder() throws {
        for ranges: [(Int64, Int64)] in [[(9, 1), (0, 10), (3, 1)], [(3, 2), (3, 1)], [(0, 3), (2, 3)]] {
            let project = try fixture(ranges)
            XCTAssertThrowsError(try project.validate()) { error in
                XCTAssertEqual(error as? EditorCoreError, .invalidModel("Overlapping clips on one track"))
            }
        }
    }

    func testDuplicateAndMissingIdentitiesThrowWithoutDictionaryTrap() throws {
        var project = try fixture([(0, 2)])
        project.assets.append(project.assets[0])
        XCTAssertThrowsError(try project.validate())
        project.assets.removeLast()
        project.tracks[0].clips[0].assetID = UUID()
        XCTAssertThrowsError(try project.validate())
        XCTAssertThrowsError(try TimelineRenderPlan(project: project))
    }

    func testLargeRationalComparisonDoesNotRoundAdjacentClipStarts() throws {
        var project = try fixture([(0, 1), (1, 1)])
        // Both starts round to the same Double; cross-product comparison is exact.
        let start = try RationalTime(Int64.max - 2)
        project.tracks[0].clips[0].timelineStart = start
        project.tracks[0].clips[0].sourceRange.duration = try RationalTime(1, 2)
        project.tracks[0].clips[1].timelineStart = try RationalTime(Int64.max - 1)
        project.tracks[0].clips[1].sourceRange.duration = try RationalTime(1)
        // An intermediate half-second end at this magnitude cannot be represented
        // by RationalTime's Int64 numerator and must still fail rather than wrap.
        XCTAssertThrowsError(try project.validate()) { error in
            XCTAssertEqual(error as? EditorCoreError, .overflow)
        }
        project.tracks[0].clips[0].sourceRange.duration = try RationalTime(1)
        try project.validate()
        project.tracks[0].clips[1].timelineStart = start
        XCTAssertThrowsError(try project.validate())
    }

    func testFractionalAdjacencyUsesExactRationalComparison() throws {
        var project = try fixture([(0, 1), (1, 1)])
        project.tracks[0].clips[0].sourceRange.duration = try RationalTime(1, 3)
        project.tracks[0].clips[1].timelineStart = try RationalTime(1, 3)
        try project.validate()
        project.tracks[0].clips[1].timelineStart = try RationalTime(1, 4)
        XCTAssertThrowsError(try project.validate())
    }
}
