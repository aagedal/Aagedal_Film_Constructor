import Foundation
import XCTest
@testable import EditorCore

final class MediaBinTests: XCTestCase {
    func testOrganizationPreservesRenderAndRoundTrips() throws {
        var project = try DemoProjectFactory.musicCollision()
        let render = try TimelineRenderPlan(project: project)
        let asset = project.assets[0]
        let parent = try project.createMediaBin(name: "  Sound  ")
        let child = try project.createMediaBin(name: "Music", parentID: parent)
        try project.moveAssets([asset.id], toMediaBin: child)
        XCTAssertEqual(project.mediaBinPath(id: child), "Sound / Music")
        XCTAssertEqual(project.assets[0], asset)
        XCTAssertEqual(try TimelineRenderPlan(project: project), render)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        try project.updateMediaBin(id: child, name: "Score", parentID: nil)
        XCTAssertEqual(project.mediaBinPath(id: child), "Score")
        try project.moveAssets([asset.id], toMediaBin: nil)
        XCTAssertTrue(project.assetBinAssignments.isEmpty)
    }

    func testDissolvePromotesContentsWithoutDeletingMedia() throws {
        var project = try DemoProjectFactory.musicCollision()
        let render = try TimelineRenderPlan(project: project)
        let parent = try project.createMediaBin(name: "Audio")
        let child = try project.createMediaBin(name: "Music", parentID: parent)
        let grandchild = try project.createMediaBin(name: "Alternates", parentID: child)
        let assetID = project.assets[0].id
        try project.moveAssets([assetID], toMediaBin: child)
        try project.removeMediaBin(id: child)
        XCTAssertEqual(project.assetBinAssignments[assetID], parent)
        XCTAssertEqual(project.mediaBins.first { $0.id == grandchild }?.parentID, parent)
        try project.removeMediaBin(id: parent)
        XCTAssertNil(project.assetBinAssignments[assetID])
        XCTAssertNil(project.mediaBins.first { $0.id == grandchild }?.parentID)
        XCTAssertEqual(try TimelineRenderPlan(project: project), render)
    }

    func testInvalidOperationsRollBack() throws {
        var project = try DemoProjectFactory.musicCollision()
        let parent = try project.createMediaBin(name: "Audio")
        let child = try project.createMediaBin(name: "Music", parentID: parent)
        let before = project
        XCTAssertThrowsError(try project.updateMediaBin(id: parent, name: "Audio", parentID: child))
        XCTAssertEqual(project, before)
        XCTAssertThrowsError(try project.updateMediaBin(id: child, name: "Music", parentID: child))
        XCTAssertThrowsError(try project.createMediaBin(name: " \n "))
        XCTAssertThrowsError(try project.createMediaBin(name: "Missing", parentID: UUID()))
        XCTAssertThrowsError(try project.moveAssets([UUID()], toMediaBin: parent))
        XCTAssertThrowsError(try project.moveAssets([project.assets[0].id], toMediaBin: UUID()))
        XCTAssertThrowsError(try project.removeMediaBin(id: UUID()))
        XCTAssertEqual(project, before)
    }

    func testLegacyProjectsAndMalformedDocuments() throws {
        let project = try DemoProjectFactory.musicCollision()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "mediaBins")
        object.removeValue(forKey: "assetBinAssignments")
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object)), project)
        var malformed = project
        let a = MediaBin(name: "A"), b = MediaBin(name: "B", parentID: a.id)
        malformed.mediaBins = [a, b]
        malformed.mediaBins[0].parentID = b.id
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(malformed)))
        malformed.mediaBins = [a, a]
        XCTAssertThrowsError(try malformed.validate())
        malformed.mediaBins = [a]
        malformed.assetBinAssignments[UUID()] = a.id
        XCTAssertThrowsError(try malformed.validate())
    }
}
