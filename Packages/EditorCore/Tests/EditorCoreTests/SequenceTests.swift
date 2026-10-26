import Foundation
import XCTest
@testable import EditorCore

final class SequenceTests: XCTestCase {
    func testNewSequenceStoresTheOpenOneAndSwitchesBack() throws {
        var project = try DemoProjectFactory.musicCollision()
        let original = project
        let firstID = project.sequenceID
        let render = try TimelineRenderPlan(project: project)
        let settings = try SequenceSettings(width: 1280, height: 720)
        let secondID = try project.createSequence(name: " Trailer ", settings: settings)
        XCTAssertEqual(project.sequenceName, "Trailer")
        XCTAssertEqual(project.settings, settings)
        XCTAssertTrue(project.tracks.isEmpty)
        XCTAssertEqual(project.assets, original.assets)
        XCTAssertEqual(project.sequenceSummaries.map(\.name), ["Sequence 1", "Trailer"])
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        try project.openSequence(id: firstID)
        XCTAssertEqual(try TimelineRenderPlan(project: project), render)
        XCTAssertEqual(project.storedSequences.map(\.id), [secondID])
        XCTAssertEqual(project.tracks, original.tracks)
        XCTAssertEqual(project.nextSequenceName, "Sequence 3")
    }

    func testRemovingTheOpenSequenceOpensAnotherAndTheLastStays() throws {
        var project = try DemoProjectFactory.musicCollision()
        let firstID = project.sequenceID
        XCTAssertThrowsError(try project.removeSequence(id: firstID))
        let bin = try project.createMediaBin(name: "Cuts")
        let secondID = try project.createSequence(name: "Sequence 2", settings: project.settings, binID: bin)
        XCTAssertEqual(project.sequenceBinAssignments[secondID], bin)
        try project.removeMediaBin(id: bin)
        XCTAssertNil(project.sequenceBinAssignments[secondID])
        try project.removeSequence(id: secondID)
        XCTAssertEqual(project.sequenceID, firstID)
        XCTAssertFalse(project.tracks.isEmpty)
        XCTAssertTrue(project.storedSequences.isEmpty)
    }

    func testInvalidSequenceEditsRollBackAndOldFilesDecode() throws {
        var project = try DemoProjectFactory.musicCollision()
        let before = project
        XCTAssertThrowsError(try project.createSequence(name: "  ", settings: project.settings))
        XCTAssertThrowsError(try project.openSequence(id: UUID()))
        XCTAssertThrowsError(try project.renameSequence(id: UUID(), name: "X"))
        XCTAssertEqual(project, before)
        // Files saved before sequences existed open as one default sequence.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        for key in ["sequenceID", "sequenceName", "storedSequences", "sequenceBinAssignments"] { json[key] = nil }
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, project)
        XCTAssertEqual(Project(settings: try SequenceSettings()), Project(settings: try SequenceSettings()))
    }
}
