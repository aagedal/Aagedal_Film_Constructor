import Foundation
import XCTest
@testable import EditorCore

final class MarkerTests: XCTestCase {
    func testMarkersStayInTimeOrderWithOneMarkerPerTime() throws {
        var project = try DemoProjectFactory.musicCollision()
        let late = try project.addMarker(at: RationalTime(4))
        let early = try project.addMarker(at: RationalTime(1), color: .red)
        XCTAssertEqual(project.markers.map(\.id), [early, late])
        XCTAssertEqual(project.markers.map(\.name), ["Marker 2", "Marker 1"])
        XCTAssertThrowsError(try project.addMarker(at: RationalTime(4)))
        XCTAssertThrowsError(try project.moveMarker(id: early, to: RationalTime(4)))
        try project.moveMarker(id: early, to: RationalTime(6))
        XCTAssertEqual(project.markers.map(\.id), [late, early])
        try project.updateMarker(id: late, name: "  Chorus ", note: "Lift the music", color: .green)
        XCTAssertEqual(project.markers[0].name, "Chorus")
        XCTAssertEqual(project.markers[0].color, .green)
        XCTAssertThrowsError(try project.addMarker(at: RationalTime(-1)))
        try project.removeMarker(id: late)
        XCTAssertEqual(project.markers.map(\.id), [early])
        XCTAssertEqual(project.nextMarkerName, "Marker 3")
        // Out-of-order markers are refused when a document is validated.
        project.markers.append(SequenceMarker(time: try RationalTime(2), name: "Out of order"))
        XCTAssertThrowsError(try project.validate())
    }

    func testMarkerAndEditPointNavigation() throws {
        var project = try DemoProjectFactory.musicCollision()
        try project.addMarker(at: RationalTime(2))
        try project.addMarker(at: RationalTime(7))
        XCTAssertEqual(try project.marker(after: RationalTime(2), forward: true)?.time, try RationalTime(7))
        XCTAssertEqual(try project.marker(after: RationalTime(2), forward: false)?.time, nil)
        XCTAssertEqual(try project.marker(after: RationalTime(9), forward: false)?.time, try RationalTime(7))
        // Clips at 0–5 and 5–10.
        XCTAssertEqual(try project.editPoints, [.zero, try RationalTime(5), try RationalTime(10)])
        XCTAssertEqual(try project.editPoint(after: RationalTime(1), forward: true), try RationalTime(5))
        XCTAssertEqual(try project.editPoint(after: RationalTime(5), forward: true), try RationalTime(10))
        XCTAssertNil(try project.editPoint(after: RationalTime(10), forward: true))
        XCTAssertEqual(try project.editPoint(after: RationalTime(5), forward: false), .zero)
    }

    func testMarkersTravelWithTheirSequenceAndOldFilesDecode() throws {
        var project = try DemoProjectFactory.musicCollision()
        let first = project.sequenceID
        let marker = try project.addMarker(at: RationalTime(3))
        try project.createSequence(name: "Second", settings: project.settings)
        XCTAssertTrue(project.markers.isEmpty)
        try project.addMarker(at: RationalTime(1))
        try project.openSequence(id: first)
        XCTAssertEqual(project.markers.map(\.id), [marker])
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(saved, project)
        XCTAssertEqual(saved.storedSequences.first?.markers.count, 1)
        // Files saved before markers existed open without markers.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        json["markers"] = nil
        var stored = json["storedSequences"] as! [[String: Any]]
        stored[0]["markers"] = nil
        json["storedSequences"] = stored
        var markerJSON = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(project.markers)) as! [[String: Any]])
        markerJSON[0]["note"] = nil; markerJSON[0]["color"] = nil
        json["markers"] = markerJSON
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.markers.first?.color, .blue)
        XCTAssertEqual(decoded.markers.first?.note, "")
        XCTAssertEqual(decoded.storedSequences.first?.markers, [])
    }
}
