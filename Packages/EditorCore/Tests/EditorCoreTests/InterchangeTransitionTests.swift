import Foundation
import XCTest
@testable import EditorCore

/// Dissolves, crossfades and speed changes in FCPXML, OTIO and CMX3600 exports.
final class InterchangeTransitionTests: XCTestCase {
    struct Fixture {
        var project: Project
        var a: TimelineClip, b: TimelineClip, c: TimelineClip
        var soundA: TimelineClip, soundB: TimelineClip
    }

    /// At 25 fps: shot A (source 2–7 s) cuts to B (source 10–15 s) at 5 s with a two-second
    /// dissolve on the picture and a crossfade on the linked sound; C plays at 50% from 10 s.
    func fixture() throws -> Fixture {
        let settings = try SequenceSettings(width: 1920, height: 1080, frameRate: FrameRate(25), audioLayout: .stereo)
        let picture = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let sound = TrackFamily(baseName: "Audio", template: .init(kind: .audio, audioLayout: .stereo))
        let asset = MediaAsset(name: "Shot", originalURL: URL(fileURLWithPath: "/private/tmp/interchange-shot.mov"), duration: try RationalTime(30),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        let stereo = ClipSelection.audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo))
        let linkA = UUID(), linkB = UUID()
        let a = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(2), duration: RationalTime(5)),
                             selection: .video(streamIndex: 0), linkGroupID: linkA)
        let b = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(10), duration: RationalTime(5)),
                             timelineStart: try RationalTime(5), selection: .video(streamIndex: 0), linkGroupID: linkB)
        let c = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(20), duration: RationalTime(4)),
                             timelineStart: try RationalTime(10), selection: .video(streamIndex: 0), speed: try RationalTime(1, 2))
        var soundA = a, soundB = b
        soundA.id = UUID(); soundA.selection = stereo
        soundB.id = UUID(); soundB.selection = stereo
        var project = Project(settings: settings, assets: [asset], families: [picture, sound], tracks: [
            .init(familyID: picture.id, template: picture.template, clips: [a, b, c]),
            .init(familyID: sound.id, template: sound.template, clips: [soundA, soundB])
        ])
        project.audioCrossfades = [
            AudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: try RationalTime(2), curve: .linear),
            AudioCrossfade(outgoingClipID: soundA.id, incomingClipID: soundB.id, duration: try RationalTime(2), curve: .equalPower)
        ]
        try project.validate()
        return Fixture(project: project, a: a, b: b, c: c, soundA: soundA, soundB: soundB)
    }

    func testTransitionsAreCentredOnTheEditorialCut() throws {
        let f = try fixture()
        let cuts = try f.project.interchangeCuts()
        let dissolve = try XCTUnwrap(cuts.transition(outgoing: f.a.id))
        XCTAssertEqual(dissolve.cut, try RationalTime(5))
        XCTAssertEqual(dissolve.before, try RationalTime(1))
        XCTAssertEqual(dissolve.after, try RationalTime(1))
        XCTAssertEqual(dissolve.start, try RationalTime(4))
        XCTAssertEqual(cuts.ranges[f.b.id]?.source, f.b.sourceRange, "Clips that meet keep their editorial ranges")
        XCTAssertEqual(cuts.transition(incoming: f.soundB.id)?.cut, try RationalTime(5))
    }

    func testOverlappingCrossfadeIsCutAtTheMiddleOfTheOverlap() throws {
        var project = try DemoProjectFactory.musicCollision()
        // B starts two seconds before A ends: an existing overlap crossfade.
        project.tracks[0].clips[1].timelineStart = try RationalTime(3)
        let a = project.tracks[0].clips[0], b = project.tracks[0].clips[1]
        project.audioCrossfades = [AudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: try RationalTime(2))]
        let cuts = try project.interchangeCuts()
        let transition = try XCTUnwrap(cuts.transitions.first)
        XCTAssertEqual(transition.cut, try RationalTime(4))
        XCTAssertEqual(transition.before, try RationalTime(1))
        XCTAssertEqual(transition.after, try RationalTime(1))
        XCTAssertEqual(cuts.ranges[a.id]?.timeline, try TimeRange(start: .zero, duration: RationalTime(4)))
        XCTAssertEqual(cuts.ranges[b.id]?.timeline, try TimeRange(start: RationalTime(4), duration: RationalTime(4)))
        XCTAssertEqual(cuts.ranges[b.id]?.source, try TimeRange(start: RationalTime(11), duration: RationalTime(4)))
    }

    // MARK: OTIO

    private func otioTracks(_ project: Project) throws -> [[String: Any]] {
        let json = try OTIOExporter.export(project: project).json
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let stack = try XCTUnwrap(root["tracks"] as? [String: Any])
        return try XCTUnwrap(stack["children"] as? [[String: Any]])
    }
    private func value(_ object: Any?) -> Int64? { ((object as? [String: Any])?["value"] as? NSNumber)?.int64Value }

    func testOTIOWritesDissolvesCrossfadesAndTimeWarps() throws {
        let f = try fixture()
        let tracks = try otioTracks(f.project)
        // Stack children run back to front: sound, then picture.
        let picture = try XCTUnwrap(tracks[1]["children"] as? [[String: Any]])
        XCTAssertEqual(picture.map { $0["OTIO_SCHEMA"] as? String }, ["Clip.2", "Transition.1", "Clip.2", "Clip.2"])
        XCTAssertEqual(picture[1]["transition_type"] as? String, "SMPTE_Dissolve")
        XCTAssertEqual(value(picture[1]["in_offset"]), 25)
        XCTAssertEqual(value(picture[1]["out_offset"]), 25)
        // Clips keep their editorial cut-point ranges; the transition uses their handles.
        let range = try XCTUnwrap(picture[2]["source_range"] as? [String: Any])
        XCTAssertEqual(value(range["start_time"]), 250)
        XCTAssertEqual(value(range["duration"]), 125)
        let warp = try XCTUnwrap((picture[3]["effects"] as? [[String: Any]])?.first)
        XCTAssertEqual(warp["OTIO_SCHEMA"] as? String, "LinearTimeWarp.1")
        XCTAssertEqual(warp["time_scalar"] as? Double, 0.5)
        let slow = try XCTUnwrap(picture[3]["source_range"] as? [String: Any])
        XCTAssertEqual(value(slow["duration"]), 100, "A time-warped clip keeps its duration in the track")

        let sound = try XCTUnwrap(tracks[0]["children"] as? [[String: Any]])
        XCTAssertEqual(sound.map { $0["OTIO_SCHEMA"] as? String }, ["Clip.2", "Transition.1", "Clip.2", "Gap.1"])
        XCTAssertEqual(value(sound[1]["in_offset"]), 48000)
    }

    func testOTIOWritesMovingTransitionsAsDissolvesAndWarnsOfLeftOutFades() throws {
        var f = try fixture()
        f.project.audioCrossfades[0].style = .pushLeft
        var result = try OTIOExporter.export(project: f.project)
        XCTAssertEqual(result.warnings, ["Slide, push and wipe transitions are exported as cross dissolves. (Shot)"])
        // The push's motion is not mistaken for the clip's own placement.
        XCTAssertTrue(result.json.contains("\"SMPTE_Dissolve\""))
        // A fade (dip to black) is left out with a warning; the clip itself is exported.
        f = try fixture()
        f.project.tracks[0].clips[2].fadeOut = AudioFade(duration: try RationalTime(1), curve: .linear)
        result = try OTIOExporter.export(project: f.project)
        XCTAssertEqual(result.warnings, ["Fades are not exported. (Shot)"])
        XCTAssertEqual(result.json.components(separatedBy: "\"Clip.2\"").count - 1, 5)
    }

    func testWarningsNameEachAffectedClipOnce() {
        var warnings = ExportWarnings()
        for name in ["A", "B", "A", "C", "D", "E"] { warnings.add("EQ is not exported.", for: name) }
        warnings.add("Track effects are not exported.")
        XCTAssertEqual(warnings.list, ["EQ is not exported. (A, B, C and 2 more)", "Track effects are not exported."])
    }

    func testCrossTrackCrossfadesAndLeftOutClipsBecomeCuts() throws {
        var f = try fixture()
        // Offline media cannot be exported; the picture dissolve into the next clip goes with it.
        let offline = MediaAsset(name: "Offline", originalURL: nil, duration: try RationalTime(30), streams: f.project.assets[0].streams)
        f.project.assets.append(offline)
        f.project.tracks[0].clips[0].assetID = offline.id
        let otio = try OTIOExporter.export(project: f.project)
        XCTAssertEqual(otio.warnings, ["Clips left out: an original local file reference is required. (Offline)"])
        XCTAssertEqual(otio.json.components(separatedBy: "\"Cross Dissolve\"").count - 1, 0)
        XCTAssertEqual(otio.json.components(separatedBy: "\"Crossfade\"").count - 1, 1)
        let xml = try FCPXMLExporter.export(project: f.project)
        XCTAssertFalse(xml.xml.contains("<transition name=\"Cross Dissolve\""))
        XCTAssertTrue(xml.xml.contains("<transition name=\"Audio Crossfade\""))
        XCTAssertEqual(xml.report.warnings, ["Clips left out: an original local file reference is required. (Offline)"])
        // A crossfade from the picture track to the sound track's clip is written as a cut.
        f = try fixture()
        f.project.audioCrossfades[1].incomingClipID = f.b.id
        if (try? f.project.validate()) != nil {
            XCTAssertTrue(try OTIOExporter.export(project: f.project).warnings.contains { $0.contains("different tracks") })
        }
    }

    func testOfficialOTIOCoreReadsTransitionsAndTimeWarps() throws {
        guard let python = ProcessInfo.processInfo.environment["OTIO_PYTHON"] else {
            throw XCTSkip("Set OTIO_PYTHON to Python with official opentimelineio bindings for core qualification")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("otio-transitions-\(UUID().uuidString).otio")
        defer { try? FileManager.default.removeItem(at: file) }
        try OTIOExporter.export(project: fixture().project).json.write(to: file, atomically: true, encoding: .utf8)
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

    // MARK: CMX3600

    func testEDLWritesCentredDissolvesSpeedAndFadesToBlack() throws {
        var f = try fixture()
        f.project.tracks[0].clips[2].fadeOut = AudioFade(duration: try RationalTime(2), curve: .linear)
        let asset = f.project.assets[0]
        let timing = [asset.id: CMX3600SourceTiming(frameRate: f.project.settings.frameRate, startTimecode: .init(), reelName: "SHOT1",
                                                     streamIndex: 0, constantFrameRate: true)]
        let result = try CMX3600Exporter.export(project: f.project, trackID: f.project.tracks[0].id, projectName: "Cut", sourceTiming: timing)
        XCTAssertEqual(result.edl, """
        TITLE: Cut
        FCM: NON-DROP FRAME

        001  SHOT1    V  C        00:00:02:00 00:00:06:00 00:00:00:00 00:00:04:00
        * FROM CLIP NAME: Shot

        002  SHOT1    V  C        00:00:06:00 00:00:06:00 00:00:04:00 00:00:04:00
        002  SHOT1    V  D    050 00:00:09:00 00:00:15:00 00:00:04:00 00:00:10:00
        * FROM CLIP NAME: Shot
        * TO CLIP NAME: Shot

        003  SHOT1    V  C        00:00:20:00 00:00:21:00 00:00:10:00 00:00:12:00
        M2   SHOT1          012.5                00:00:20:00
        * FROM CLIP NAME: Shot

        004  SHOT1    V  C        00:00:21:00 00:00:21:00 00:00:12:00 00:00:12:00
        004  BL       V  D    050 00:00:00:00 00:00:02:00 00:00:12:00 00:00:14:00
        M2   SHOT1          012.5                00:00:21:00
        * FROM CLIP NAME: Shot

        """)
        // The linked sound crossfades the same way on its own track.
        let soundTiming = [asset.id: CMX3600SourceTiming(frameRate: f.project.settings.frameRate, startTimecode: .init(), reelName: "SHOT1", streamIndex: 1)]
        let sound = try CMX3600Exporter.export(project: f.project, trackID: f.project.tracks[1].id, sourceTiming: soundTiming)
        XCTAssertTrue(sound.edl.contains("002  SHOT1    AA  D    050 00:00:09:00 00:00:15:00 00:00:04:00 00:00:10:00"), sound.edl)
    }

    func testEDLLeavesOutSpeedsOffTheTenthAndSourceFramesOffTheGrid() throws {
        var f = try fixture()
        let timing = [f.project.assets[0].id: CMX3600SourceTiming(frameRate: f.project.settings.frameRate, startTimecode: .init(), reelName: "SHOT1",
                                                                   streamIndex: 0, constantFrameRate: true)]
        f.project.tracks[0].clips[2].speed = try RationalTime(1, 3)
        // The retimed clip is left out and the rest of the track exported.
        func reasons() -> [String] {
            do {
                let result = try CMX3600Exporter.export(project: f.project, trackID: f.project.tracks[0].id, sourceTiming: timing)
                XCTAssertEqual(result.report.clipCount, 2)
                XCTAssertFalse(result.edl.contains("M2"))
                return result.report.warnings
            } catch { return ["\(error)"] }
        }
        XCTAssertTrue(reasons().contains { $0.contains("tenth") }, "\(reasons())")
        // 50% over an odd number of frames ends between source frames.
        f.project.tracks[0].clips[2].speed = try RationalTime(1, 2)
        f.project.tracks[0].clips[2].fadeOut = AudioFade(duration: try RationalTime(1), curve: .linear)
        XCTAssertTrue(reasons().contains { $0.contains("whole source frames") }, "\(reasons())")
    }

    // MARK: FCPXML

    func testFCPXMLWritesStorylinesWithTransitionsAndTimeMaps() throws {
        let f = try fixture()
        let xml = try FCPXMLExporter.export(project: f.project).xml
        // Linked picture and sound share their dissolve, so they stay one A/V clip per shot.
        XCTAssertFalse(xml.contains("lane=\"-1\""), xml)
        XCTAssertTrue(xml.contains("<spine lane=\"1\" offset=\"0s\" name=\"Video\">"), xml)
        XCTAssertTrue(xml.contains("<transition name=\"Cross Dissolve\" offset=\"4s\" duration=\"2s\">"), xml)
        XCTAssertTrue(xml.contains("<filter-audio ref=\"r4\" name=\"Audio Crossfade\"/>"), xml)
        XCTAssertTrue(xml.contains("<effect id=\"r3\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>"), xml)
        // Editorial cut-point ranges; the slow clip starts at its retimed local time.
        XCTAssertTrue(xml.contains("offset=\"5s\" start=\"10s\" duration=\"5s\""), xml)
        XCTAssertTrue(xml.contains("offset=\"10s\" start=\"40s\" duration=\"4s\""), xml)
        XCTAssertTrue(xml.contains("<timept time=\"60s\" value=\"30s\" interp=\"linear\"/>"), xml)
    }

    func testFCPXMLKeepsBothSidesOfACrossfadeTogether() throws {
        var f = try fixture()
        // B's sound is slipped, so it can't merge with B's picture. A's sound must then stay
        // separate too, or the sound crossfade would lose its outgoing side.
        f.project.tracks[1].clips[1].sourceRange.start = try RationalTime(11)
        let xml = try FCPXMLExporter.export(project: f.project).xml
        XCTAssertTrue(xml.contains("<spine lane=\"-1\" offset=\"0s\" name=\"Audio\">"), xml)
        XCTAssertTrue(xml.contains("<transition name=\"Audio Crossfade\" offset=\"4s\" duration=\"2s\">"), xml)
        XCTAssertEqual(xml.components(separatedBy: "srcEnable=\"audio\"").count - 1, 2, xml)
    }

    func testFCPXMLValidatesAgainstAppleDTD() throws {
        let path = ProcessInfo.processInfo.environment["FCPXML_DTD"]
            ?? "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_10.dtd"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Set FCPXML_DTD to Apple's FCPXML 1.10 DTD") }
        var f = try fixture()
        var projects = [f.project]
        // Unlinked sound keeps its own crossfaded storyline below the picture.
        f.project.tracks[1].clips[1].sourceRange.start = try RationalTime(11)
        f.project.tracks[1].clips[1].linkGroupID = nil
        projects.append(f.project)
        for project in projects {
            let document = try XMLDocument(xmlString: FCPXMLExporter.export(project: project).xml)
            let dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: path))
            dtd.name = "fcpxml"
            document.dtd = dtd
            try document.validate()
        }
    }
}
