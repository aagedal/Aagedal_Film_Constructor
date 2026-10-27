import Foundation
import XCTest
@testable import EditorCore

final class OTIOExporterTests: XCTestCase {
    private func fixture(rate: FrameRate = try! FrameRate(24)) throws -> Project {
        let settings = try SequenceSettings(frameRate: rate, startTimecode: Timecode(frameCount: 86400, mode: rate.supportsDropFrame ? .dropFrame : .nonDropFrame))
        let vt = TrackTemplate(kind: .video)
        let vf = TrackFamily(baseName: "Picture", template: vt)
        let at = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let af = TrackFamily(baseName: "Sound", template: at)
        let asset = MediaAsset(name: "Original & \"film\"\n雪.mov", originalURL: URL(fileURLWithPath: "/tmp/Original & 雪.mov"), duration: try RationalTime(60), streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        let unit = try rate.time(forFrames: 120)
        let front = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: rate.time(forFrames: 240), duration: unit), timelineStart: unit, selection: .video(streamIndex: 0))
        let back = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: unit.multiplied(by: 3)), selection: .video(streamIndex: 0))
        // Sample-position source/timeline offsets independent of the video clock.
        let audio = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1, 48000), duration: RationalTime(47999, 48000)), timelineStart: try RationalTime(1, 48000), selection: .audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo)))
        return Project(settings: settings, assets: [asset], families: [vf, af], tracks: [
            .init(familyID: vf.id, template: vt, clips: [front]),
            .init(familyID: vf.id, template: vt, clips: [back]),
            .init(familyID: af.id, template: at, clips: [audio]),
            .init(familyID: vf.id, template: vt)
        ])
    }
    private func reasons(_ project: Project) throws -> [String] {
        do { _ = try OTIOExporter.export(project: project); XCTFail("Expected unsupported sequence"); return [] }
        catch OTIOExportError.unsupported(let reasons) { return reasons }
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func children(_ object: [String: Any]) throws -> [[String: Any]] { try XCTUnwrap(object["children"] as? [[String: Any]]) }
    private func rangeTime(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        let range = try XCTUnwrap(object["source_range"] as? [String: Any])
        return try XCTUnwrap(range[key] as? [String: Any])
    }
    func testLayerOrderGapsSourceRangesAndOriginalReferences() throws {
        let project = try fixture()
        let json = try OTIOExporter.export(project: project, projectName: "Assembly & 雪")
        let timeline = try object(json)
        XCTAssertEqual(timeline["name"] as? String, "Assembly & 雪")
        let tracks = try children(XCTUnwrap(timeline["tracks"] as? [String: Any]))
        XCTAssertEqual(tracks.count, 4)
        for (track, original) in zip(tracks, project.tracks.reversed()) {
            let metadata = try XCTUnwrap(track["metadata"] as? [String: Any])
            let app = try XCTUnwrap(metadata["aagedal_film_constructor"] as? [String: Any])
            XCTAssertEqual(app["track_id"] as? String, original.id.uuidString)
        }
        XCTAssertEqual(try children(tracks[0]).first?["OTIO_SCHEMA"] as? String, "Gap.1")
        XCTAssertEqual(tracks[1]["kind"] as? String, "Audio")
        let audio = try children(tracks[1])
        XCTAssertEqual(audio.count, 3)
        XCTAssertEqual(try rangeTime(audio[0], "duration")["value"] as? Int, 1)
        XCTAssertEqual(try rangeTime(audio[1], "start_time")["value"] as? Int, 1)
        XCTAssertEqual(try rangeTime(audio[1], "duration")["value"] as? Int, 47999)
        XCTAssertEqual(try rangeTime(audio[1], "duration")["rate"] as? Int, 48000)
        let front = try children(tracks[3])
        XCTAssertEqual(front.count, 3)
        XCTAssertEqual(try rangeTime(front[0], "duration")["value"] as? Int, 120)
        XCTAssertEqual(try rangeTime(front[1], "start_time")["value"] as? Int, 240)
        let refs = try XCTUnwrap(front[1]["media_references"] as? [String: [String: Any]])
        XCTAssertEqual(refs["DEFAULT_MEDIA"]?["target_url"] as? String, project.assets[0].originalURL?.absoluteString)
        XCTAssertEqual(front[1]["name"] as? String, project.assets[0].name)
        XCTAssertEqual(try OTIOExporter.export(project: project, projectName: "Assembly & 雪"), json)
    }
    func testFractionalFrameRatesAndDropFrameMetadata() throws {
        for (n, d): (Int64, Int64) in [(24, 1), (25, 1), (24000, 1001), (30000, 1001), (60000, 1001)] {
            let project = try fixture(rate: FrameRate(n, d))
            let timeline = try object(OTIOExporter.export(project: project))
            let start = try XCTUnwrap(timeline["global_start_time"] as? [String: Any])
            XCTAssertEqual(start["value"] as? Int, 86400)
            XCTAssertEqual(start["rate"] as? Double, Double(n) / Double(d))
            let metadata = try XCTUnwrap(timeline["metadata"] as? [String: [String: Any]])
            XCTAssertEqual(metadata["aagedal_film_constructor"]?["timecode_mode"] as? String, project.settings.startTimecode.mode.rawValue)
        }
    }
    func testRefusesSubframesSampleRoundingAndNonlocalMedia() throws {
        var project = try fixture()
        project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48)
        XCTAssertTrue(try reasons(project).contains { $0.contains("frame") })
        project = try fixture()
        project.tracks[2].clips[0].sourceRange.start = try RationalTime(1, 96000)
        XCTAssertTrue(try reasons(project).contains { $0.contains("sample") })
        project = try fixture(rate: FrameRate(60000, 1001))
        project.tracks[1].clips[0].sourceRange.duration = try project.settings.frameRate.time(forFrames: 361)
        XCTAssertTrue(try reasons(project).contains { $0.contains("audio sample boundary") })
        project = try fixture()
        project.assets[0].originalURL = URL(string: "https://example.com/media.mov")
        XCTAssertTrue(try reasons(project).contains { $0.contains("local file") })
    }
    func testRefusesAudioEffectsAndLossySelections() throws {
        var project = try fixture()
        project.tracks[2].template.gain = 0.5
        project.tracks[2].clips[0].fadeIn = .init(duration: try RationalTime(1, 4))
        project.tracks[2].template.routing.outputChannels = [1, 0]
        let errors = try reasons(project)
        XCTAssertTrue(errors.contains { $0.contains("gain") })
        XCTAssertTrue(errors.contains { $0.contains("fades") })
        XCTAssertTrue(errors.contains { $0.contains("routing") })
        project = try fixture()
        project.tracks[2].clips[0].selection = .audio(.init(channels: [.init(streamIndex: 1, channelIndex: 1), .init(streamIndex: 1, channelIndex: 0)], layout: .stereo))
        XCTAssertTrue(try reasons(project).contains { $0.contains("reordered") })
        project = try fixture()
        project.assets[0].streams.append(.init(index: 2, kind: .audio, audioLayout: .stereo))
        XCTAssertTrue(try reasons(project).contains { $0.contains("complete audio stream") })
        project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/tmp/music.wav")
        project.audioCrossfades = [.init(outgoingClipID: project.tracks[0].clips[0].id, incomingClipID: project.tracks[0].clips[1].id, duration: try RationalTime(2))]
        XCTAssertTrue(try reasons(project).contains { $0.contains("crossfades") })
    }
    func testRefusesUnknownSourceTimecodeGeometryAndStreamOffsets() throws {
        var project = try fixture()
        project.assets[0].sourceTimecode = .init(frameCount: 1)
        project.tracks[0].clips[0].scalingMode = .fill
        project.assets[0].streams[0].timeOffset = try RationalTime(1)
        let errors = try reasons(project)
        XCTAssertTrue(errors.contains { $0.contains("source timecode") })
        XCTAssertTrue(errors.contains { $0.contains("geometry") })
        XCTAssertTrue(errors.contains { $0.contains("offsets") })
        project = try fixture()
        project.assets[0].streams.append(.init(index: 2, kind: .video))
        XCTAssertTrue(try reasons(project).contains { $0.contains("multiple video") })
        project = try fixture()
        project.tracks = []
        XCTAssertTrue(try reasons(project).contains { $0.contains("no clips") })
    }
    func testRefusesEndpointsBeyondExactDoubleIntegers() throws {
        let limit: Int64 = 9_007_199_254_740_992
        var project = try fixture(rate: FrameRate(1))
        project.tracks = [project.tracks[0]]
        project.settings.startTimecode = .init()
        project.tracks[0].clips[0].timelineStart = .zero
        project.tracks[0].clips[0].sourceRange = try TimeRange(start: RationalTime(limit), duration: RationalTime(1))
        project.assets[0].duration = try RationalTime(limit + 1)
        XCTAssertTrue(try reasons(project).contains { $0.contains("time exceeds") })
        project.assets[0].duration = try RationalTime(60)
        project.tracks[0].clips[0].sourceRange.start = .zero
        project.settings.startTimecode = .init(frameCount: limit)
        XCTAssertTrue(try reasons(project).contains { $0.contains("record endpoint") })
    }
    func testOfficialOTIOCoreReadWriteAndTiming() throws {
        guard let python = ProcessInfo.processInfo.environment["OTIO_PYTHON"] else {
            throw XCTSkip("Set OTIO_PYTHON to Python with official opentimelineio bindings for core qualification")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("otio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (n, d): (Int64, Int64) in [(24, 1), (25, 1), (24000, 1001), (30000, 1001), (60000, 1001)] {
            var project = try fixture(rate: FrameRate(n, d))
            try project.addMarker(at: project.settings.frameRate.time(forFrames: 30), color: .purple)
            try project.updateMarker(id: project.markers[0].id, name: "Chorus 雪", note: "Lift & hold", color: .purple)
            let file = directory.appendingPathComponent("\(n)-\(d).otio")
            try OTIOExporter.export(project: project).write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [root.appendingPathComponent("scripts/validate-otio.py").path, file.path]
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, text)
        }
    }

    func testSourceRangesUseTheMediaTimecodeClock() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/otio-timecode.wav")
        project.tracks[0].template.gain = 1
        project.assets[0].sourceTimecodeStart = try RationalTime(3600)
        let json = try OTIOExporter.export(project: project)
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        func clips(_ object: Any) -> [[String: Any]] {
            if let dict = object as? [String: Any] {
                return ((dict["OTIO_SCHEMA"] as? String)?.hasPrefix("Clip") == true ? [dict] : []) + dict.values.flatMap(clips)
            }
            return (object as? [Any])?.flatMap(clips) ?? []
        }
        let found = clips(root)
        XCTAssertFalse(found.isEmpty)
        for clip in found {
            let start = (clip["source_range"] as! [String: Any])["start_time"] as! [String: Any]
            let seconds = (start["value"] as! NSNumber).doubleValue / (start["rate"] as! NSNumber).doubleValue
            XCTAssertGreaterThanOrEqual(seconds, 3600)
            let reference = (clip["media_references"] as! [String: Any])["DEFAULT_MEDIA"] as! [String: Any]
            let available = ((reference["available_range"] as! [String: Any])["start_time"] as! [String: Any])
            XCTAssertEqual((available["value"] as! NSNumber).doubleValue / (available["rate"] as! NSNumber).doubleValue, 3600)
        }
    }
    func testSequenceMarkersAreWrittenOnTheStack() throws {
        var project = try fixture()
        try project.addMarker(at: RationalTime(2))
        try project.updateMarker(id: project.markers[0].id, name: "Chorus", note: "Lift", color: .green)
        let timeline = try object(OTIOExporter.export(project: project))
        let stack = try XCTUnwrap(timeline["tracks"] as? [String: Any])
        let markers = try XCTUnwrap(stack["markers"] as? [[String: Any]])
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0]["OTIO_SCHEMA"] as? String, "Marker.2")
        XCTAssertEqual(markers[0]["name"] as? String, "Chorus")
        XCTAssertEqual(markers[0]["comment"] as? String, "Lift")
        XCTAssertEqual(markers[0]["color"] as? String, "GREEN")
        let range = try XCTUnwrap(markers[0]["marked_range"] as? [String: Any])
        let start = try XCTUnwrap(range["start_time"] as? [String: Any])
        XCTAssertEqual((start["value"] as? NSNumber)?.int64Value, 48)
        XCTAssertEqual((start["rate"] as? NSNumber)?.doubleValue, 24)
        XCTAssertEqual(((range["duration"] as? [String: Any])?["value"] as? NSNumber)?.int64Value, 1)

        try project.addMarker(at: RationalTime(1, 100))
        XCTAssertTrue(try reasons(project).contains { $0.contains("frame boundary") })
    }
}
