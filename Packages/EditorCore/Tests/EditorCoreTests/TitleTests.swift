import Foundation
import XCTest
@testable import EditorCore

final class TitleTests: XCTestCase {
    private let image = URL(fileURLWithPath: "/private/tmp/title-a.png")

    func testTitlesGoOnAFrontTitlesTrackAndRenderAsStills() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/title-music.wav")
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        project.families.append(family)
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/title-movie.mov"),
                               duration: try RationalTime(20), streams: [.init(index: 0, kind: .video)])
        project.assets.append(movie)
        project.tracks.insert(TimelineTrack(familyID: family.id, template: family.template, clips: [
            TimelineClip(assetID: movie.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(10)), selection: .video(streamIndex: 0))]), at: 0)
        let first = try project.addTitle(TitleDefinition(text: "Hello"), imageURL: image, at: RationalTime(1))
        XCTAssertEqual(project.tracks[0].displayName(in: project), "Titles")
        XCTAssertEqual(project.tracks[0].clips.map(\.id), [first])
        XCTAssertEqual(project.assets.last?.name, "Title: Hello")
        // An overlapping second title gets a sibling title track, still in front of the movie.
        let second = try project.addTitle(TitleDefinition(text: "World"), imageURL: image, at: RationalTime(3))
        let titleTracks = project.tracks.prefix(2)
        XCTAssertTrue(titleTracks.allSatisfy { $0.clips.allSatisfy { $0.selection == .still } })
        XCTAssertTrue(titleTracks.contains { $0.clips.contains { $0.id == second } })

        let plan = try TimelineRenderPlan(project: project)
        let title = try XCTUnwrap(plan.components.first { $0.clipID == first })
        let picture = try XCTUnwrap(plan.components.first { $0.assetID == movie.id })
        XCTAssertTrue(TimelineRenderPlan.Component.isInFront(title, of: picture))
        XCTAssertEqual(title.timelineRange, try TimeRange(start: RationalTime(1), duration: RationalTime(5)))
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/title-render.mov"))
        XCTAssertTrue(command.arguments.contains(image.path))

        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), project)
    }

    func testUpdatingATitleKeepsItsClipsAndValidatesStyle() throws {
        var project = try DemoProjectFactory.musicCollision()
        let id = try project.addTitle(TitleDefinition(text: "One"), imageURL: image, at: .zero)
        let assetID = try XCTUnwrap(project.tracks.flatMap(\.clips).first { $0.id == id }?.assetID)
        let updated = TitleDefinition(text: "Two\nLines", fontSize: 0.1, color: "#FF000080", position: .top, bold: false, background: true)
        let other = URL(fileURLWithPath: "/private/tmp/title-b.png")
        try project.updateTitle(assetID: assetID, to: updated, imageURL: other)
        let asset = try XCTUnwrap(project.assets.first { $0.id == assetID })
        XCTAssertEqual(asset.title, updated)
        XCTAssertEqual(asset.originalURL, other)
        XCTAssertEqual(asset.name, "Title: Two")
        XCTAssertEqual(updated.rgba?.alpha ?? 0, 128.0 / 255, accuracy: 1e-9)
        for invalid in [TitleDefinition(text: "  "), TitleDefinition(fontSize: 0.9), TitleDefinition(color: "red")] {
            var copy = project
            XCTAssertThrowsError(try copy.updateTitle(assetID: assetID, to: invalid, imageURL: other))
        }
        XCTAssertThrowsError(try project.updateTitle(assetID: project.assets[0].id, to: updated, imageURL: other), "Media is not a title")
    }
}
