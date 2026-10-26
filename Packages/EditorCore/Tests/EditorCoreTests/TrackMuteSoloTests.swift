import Foundation
import XCTest
@testable import EditorCore

final class TrackMuteSoloTests: XCTestCase {
    func testMutedAndUnsoloedTracksLeaveTheRenderPlan() throws {
        var project = try DemoProjectFactory.musicCollision()
        let song = project.tracks[0]
        var second = TimelineTrack(familyID: song.familyID, template: song.template, clips: song.clips.map { var c = $0; c.id = UUID(); return c })
        second.customName = "Voice"
        project.tracks.append(second)
        let video = TrackFamily(baseName: "Video", template: .init(kind: .video))
        project.families.append(video)
        project.assets[0].streams.append(.init(index: 1, kind: .video))
        project.tracks.append(TimelineTrack(familyID: video.id, template: video.template, clips: [
            TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(12)), selection: .video(streamIndex: 1))]))
        func tracks(_ project: Project) throws -> Set<UUID> { Set(try TimelineRenderPlan(project: project).components.map(\.trackID)) }
        XCTAssertEqual(try tracks(project).count, 3)

        try project.setTrackSoloed(id: second.id, soloed: true)
        XCTAssertEqual(try tracks(project), [second.id, project.tracks[2].id], "Solo silences other sound but keeps picture")
        try project.setTrackMuted(id: project.tracks[2].id, muted: true)
        XCTAssertEqual(try tracks(project), [second.id])
        XCTAssertEqual(try TimelineRenderPlan(project: project).duration, try RationalTime(10), "Hidden picture no longer sets the length")
        XCTAssertThrowsError(try project.setTrackSoloed(id: project.tracks[2].id, soloed: true))

        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["tracks"] = (json["tracks"] as! [[String: Any]]).map { var t = $0; t.removeValue(forKey: "muted"); t.removeValue(forKey: "soloed"); return t }
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.tracks.allSatisfy { !$0.muted && !$0.soloed })

        // Collisions on a muted track create a muted sibling.
        var engine = try TimelineEditEngine(project: project)
        let overlap = TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)), selection: .video(streamIndex: 1))
        try engine.apply(.place(clip: overlap, trackID: project.tracks[2].id))
        XCTAssertTrue(engine.project.tracks.filter { $0.familyID == video.id }.allSatisfy(\.muted))
    }
}
