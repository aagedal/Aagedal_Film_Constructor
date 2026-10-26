import Foundation
import XCTest
@testable import EditorCore

final class ClipVolumeTests: XCTestCase {
    func testClipVolumeMultipliesTrackGainPersistsAndSurvivesSplits() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/clip-volume.wav")
        let id = project.tracks[0].clips[0].id
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setGain(clipIDs: [id], gain: 0.5))
        let plan = try TimelineRenderPlan(project: engine.project)
        XCTAssertEqual(plan.components.first { $0.clipID == id }?.gain ?? 0, 0.4, accuracy: 1e-12, "Track gain 0.8 × clip 0.5")
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/clip-volume.mov"))
        XCTAssertTrue(command.filterGraph.contains("volume=0.4:precision=float"))

        let data = try JSONEncoder().encode(engine.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), engine.project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        var clips = try XCTUnwrap(tracks[0]["clips"] as? [[String: Any]])
        clips[0].removeValue(forKey: "gain"); tracks[0]["clips"] = clips; json["tracks"] = tracks
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.tracks[0].clips[0].gain, 1, "Projects without clip volume open at unity")

        try engine.apply(.split(clipID: id, at: RationalTime(2)))
        XCTAssertEqual(engine.project.tracks[0].clips.filter { $0.gain == 0.5 }.count, 2)
        engine.undo(); engine.undo()
        XCTAssertEqual(engine.project, project)
    }

    func testClipVolumeIsBoundedAndAudioOnly() throws {
        var project = try DemoProjectFactory.musicCollision()
        var engine = try TimelineEditEngine(project: project)
        let id = project.tracks[0].clips[0].id
        for invalid in [-1, 17, .infinity, .nan] {
            XCTAssertThrowsError(try engine.apply(.setGain(clipIDs: [id], gain: invalid)))
        }
        try engine.apply(.setGain(clipIDs: [id], gain: 0))
        XCTAssertThrowsError(try engine.apply(.setGain(clipIDs: [UUID()], gain: 1)))
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        project.families.append(family)
        project.assets[0].streams.append(.init(index: 1, kind: .video))
        let picture = TimelineClip(assetID: project.assets[0].id, sourceRange: project.tracks[0].clips[0].sourceRange, selection: .video(streamIndex: 1))
        project.tracks.append(TimelineTrack(familyID: family.id, template: family.template, clips: [picture]))
        var withPicture = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try withPicture.apply(.setGain(clipIDs: [picture.id], gain: 0.5)))
    }

    func testInterchangeRefusesClipVolume() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/clip-volume.wav")
        project.tracks[0].template.gain = 1
        project.tracks[0].clips[0].gain = 0.5
        XCTAssertThrowsError(try FCPXMLExporter.export(project: project)) { error in
            guard case FCPXMLExportError.unsupported(let reasons) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reasons.contains { $0.contains("clip volume") })
        }
    }
}
