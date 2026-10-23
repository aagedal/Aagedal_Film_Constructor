import Foundation
import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import EditorCore

final class FCPXMLExporterTests: XCTestCase {
    private func fixture(rate: FrameRate = try! FrameRate(24)) throws -> Project {
        let settings = try SequenceSettings(frameRate: rate, startTimecode: Timecode(frameCount: Int64(rate.nominalFramesPerSecond) * 3600))
        let videoTemplate = TrackTemplate(kind: .video)
        let videoFamily = TrackFamily(baseName: "Video", template: videoTemplate)
        let audioTemplate = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let audioFamily = TrackFamily(baseName: "Audio", template: audioTemplate)
        let asset = MediaAsset(name: "Source & \"quoted\"\nfilm", originalURL: URL(fileURLWithPath: "/tmp/Original & film.mov"), duration: try RationalTime(30), streams: [MediaStream(index: 0, kind: .video), MediaStream(index: 1, kind: .audio, audioLayout: .stereo)])
        let duration = try rate.time(forFrames: 48)
        let foreground = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(10), duration: duration), timelineStart: duration, selection: .video(streamIndex: 0), scalingMode: .fill)
        let background = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(2), duration: duration.multiplied(by: 2)), selection: .video(streamIndex: 0))
        let audio = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1, 48000), duration: duration), timelineStart: duration, selection: .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: 0), SourceChannel(streamIndex: 1, channelIndex: 1)], layout: .stereo)))
        return Project(settings: settings, assets: [asset], families: [videoFamily, audioFamily], tracks: [
            TimelineTrack(familyID: videoFamily.id, template: videoTemplate, clips: [foreground]),
            TimelineTrack(familyID: videoFamily.id, template: videoTemplate, clips: [background]),
            TimelineTrack(familyID: audioFamily.id, template: audioTemplate, clips: [audio])
        ])
    }

    private func reasons(_ project: Project) throws -> [String] {
        do {
            _ = try FCPXMLExporter.export(project: project)
            XCTFail("Unsupported project was exported")
            return []
        } catch FCPXMLExportError.unsupported(let reasons) { return reasons }
    }

    func testLinkedPictureAndSoundBecomeOneAVClip() throws {
        // The fixture's audio starts one sample later, so it stays a separate audio-only clip.
        var project = try fixture()
        let unmatched = try FCPXMLExporter.export(project: project).xml
        XCTAssertEqual(unmatched.components(separatedBy: "srcEnable=\"audio\"").count - 1, 1)
        // Give the audio the foreground's exact source and timeline range: one A/V clip results.
        project.tracks[2].clips[0].sourceRange = project.tracks[0].clips[0].sourceRange
        let merged = try FCPXMLExporter.export(project: project)
        let document = try XMLDocument(xmlString: merged.xml)
        let clips = try document.nodes(forXPath: "//asset-clip")
        XCTAssertEqual(clips.count, 2)
        XCTAssertFalse(merged.xml.contains("srcEnable=\"audio\""))
        let foreground = try document.nodes(forXPath: "//asset-clip[not(@srcEnable)]")
        XCTAssertEqual(foreground.count, 1)
        XCTAssertEqual(try (foreground.first as? XMLElement)?.attribute(forName: "audioRole")?.stringValue, "dialogue")
    }

    func testSourceTimecodeOriginOffsetsAssetAndClipStarts() throws {
        var project = try fixture(rate: FrameRate(25))
        project.assets[0].sourceTimecodeStart = try RationalTime(3600)  // 01:00:00:00
        let document = try XMLDocument(xmlString: FCPXMLExporter.export(project: project).xml)
        XCTAssertEqual(try document.nodes(forXPath: "//asset/@start").first?.stringValue, "3600s")
        let starts = try document.nodes(forXPath: "//asset-clip/@start").compactMap(\.stringValue)
        XCTAssertTrue(starts.contains("3610s") && starts.contains("3602s"), "\(starts)")
    }

    func testExactTimingMediaReferencesAndLayerOrder() throws {
        let project = try fixture(rate: FrameRate(24000, 1001))
        let result = try FCPXMLExporter.export(project: project, projectName: "Film & \"edit\"\nOne")
        let document = try XMLDocument(xmlString: result.xml)
        func value(_ xpath: String) throws -> String? { try document.nodes(forXPath: xpath).first?.stringValue }
        XCTAssertEqual(try value("//format/@frameDuration"), "1001/24000s")
        XCTAssertEqual(try value("//sequence/@tcStart"), "18018/5s")
        XCTAssertEqual(try value("//sequence/@duration"), "1001/250s")
        XCTAssertEqual(try value("//gap/@offset"), "18018/5s")
        XCTAssertEqual(try value("//gap/@start"), "0s")
        XCTAssertEqual(try value("//asset-clip[1]/@lane"), "2")
        XCTAssertEqual(try value("//asset-clip[2]/@lane"), "1")
        XCTAssertEqual(try value("//asset-clip[3]/@lane"), "-1")
        XCTAssertEqual(try value("//asset-clip[1]/@offset"), "1001/500s")
        XCTAssertEqual(try value("//asset-clip[1]/@start"), "10s")
        XCTAssertEqual(try value("//asset-clip[3]/@start"), "1/48000s")
        XCTAssertEqual(try value("//asset-clip[1]/@srcEnable"), "video")
        XCTAssertEqual(try value("//asset-clip[3]/@srcEnable"), "audio")
        XCTAssertEqual(try value("//asset-clip[1]/adjust-conform/@type"), "fill")
        XCTAssertEqual(try value("//asset-clip[2]/adjust-conform/@type"), "fit")
        XCTAssertEqual(try value("//project/@name"), "Film & \"edit\"\nOne")
        XCTAssertEqual(try value("//asset/@name"), project.assets[0].name)
        XCTAssertEqual(try value("//media-rep/@src"), project.assets[0].originalURL?.absoluteString)
        XCTAssertEqual(try document.nodes(forXPath: "//asset").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "//asset/@format").count, 0, "Never invent source geometry or frame rate")
        XCTAssertEqual(result.report.clipCount, 3)
        XCTAssertEqual(result.report.assetCount, 1)
        XCTAssertTrue(result.report.notes.contains { $0.contains("not been verified") })
        XCTAssertEqual(try FCPXMLExporter.export(project: project, projectName: "Film & \"edit\"\nOne"), result)
    }

    func testDropFrameAndWholeFrameRatesStayExact() throws {
        for (n, d): (Int64, Int64) in [(24, 1), (25, 1), (24000, 1001), (30000, 1001), (60000, 1001)] {
            var project = try fixture(rate: FrameRate(n, d))
            if project.settings.frameRate.supportsDropFrame { project.settings.startTimecode.mode = .dropFrame }
            let xml = try FCPXMLExporter.export(project: project).xml
            let document = try XMLDocument(xmlString: xml)
            let mode = try document.nodes(forXPath: "//sequence/@tcFormat").first?.stringValue
            XCTAssertEqual(mode, project.settings.frameRate.supportsDropFrame ? "DF" : "NDF")
            XCTAssertTrue(xml.contains("frameDuration=\"\(d == 1 ? "1/\(n)" : "\(d)/\(n)")s\""))
        }
    }

    func testRejectsFadesCrossfadesAndGainInsteadOfDroppingThem() throws {
        var project = try fixture()
        project.tracks[2].clips[0].fadeIn = .init(duration: try RationalTime(1))
        project.tracks[2].template.gain = 0.5
        let errors = try reasons(project)
        XCTAssertTrue(errors.contains { $0.contains("fades") })
        XCTAssertTrue(errors.contains { $0.contains("gain") })
        var audio = try DemoProjectFactory.musicCollision()
        audio.assets[0].originalURL = URL(fileURLWithPath: "/tmp/audio.wav")
        audio.tracks[0].template.gain = 1
        audio.audioCrossfades = [AudioCrossfade(outgoingClipID: audio.tracks[0].clips[0].id, incomingClipID: audio.tracks[0].clips[1].id, duration: try RationalTime(2))]
        XCTAssertTrue(try reasons(audio).contains { $0.contains("crossfades") })
    }

    func testExpressesChannelSelectionsAndRejectsRouting() throws {
        var project = try fixture()
        let stream = project.assets[0].streams[1]
        // A second stereo stream: the first stream's channels are 1 and 2 across the asset.
        project.assets[0].streams.append(MediaStream(index: 2, kind: .audio, audioLayout: .stereo))
        XCTAssertTrue(try FCPXMLExporter.export(project: project).xml.contains("<audio-channel-source srcCh=\"1, 2\" role=\"dialogue\"/>"))
        // Selecting the second stream maps to channels 3 and 4.
        project.tracks[2].clips[0].selection = .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 2, channelIndex: 0), SourceChannel(streamIndex: 2, channelIndex: 1)], layout: .stereo))
        XCTAssertTrue(try FCPXMLExporter.export(project: project).xml.contains("srcCh=\"3, 4\""))
        project.assets[0].streams.removeLast()
        // Reordered channels are expressible; nonidentity output routing is not.
        project.tracks[2].clips[0].selection = .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: stream.index, channelIndex: 1), SourceChannel(streamIndex: stream.index, channelIndex: 0)], layout: .stereo))
        XCTAssertTrue(try FCPXMLExporter.export(project: project).xml.contains("srcCh=\"2, 1\""))
        project.tracks[2].template.routing = .init(outputChannels: [1, 0])
        XCTAssertTrue(try reasons(project).contains { $0.contains("routing") })
        // Dual mono (one mono channel on both outputs) references the single source channel.
        project = try fixture()
        project.assets[0].streams[1] = MediaStream(index: 1, kind: .audio, audioLayout: .mono)
        project.tracks[2].clips[0].selection = .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: 0), SourceChannel(streamIndex: 1, channelIndex: 0)], layout: .stereo))
        XCTAssertTrue(try FCPXMLExporter.export(project: project).xml.contains("srcCh=\"1\""))
        project = try fixture()
        project.assets[0].streams.append(MediaStream(index: 3, kind: .video))
        XCTAssertTrue(try reasons(project).contains { $0.contains("multiple video streams") })
    }

    func testRejectsMissingOriginalAndUnsupportedGeometry() throws {
        var project = try fixture()
        project.assets[0].originalURL = nil
        project.tracks[0].clips[0].scalingMode = .none
        let errors = try reasons(project)
        XCTAssertTrue(errors.contains { $0.contains("original local file") })
        XCTAssertTrue(errors.contains { $0.contains("geometry") })
        project.assets[0].originalURL = URL(string: "https://example.com/film.mov")
        XCTAssertTrue(try reasons(project).contains { $0.contains("original local file") })
        project = try fixture()
        project.assets[0].streams[0].timeOffset = try RationalTime(1, 2)
        project.assets[0].sourceTimecode = Timecode(frameCount: 100)
        let otherErrors = try reasons(project)
        XCTAssertTrue(otherErrors.contains { $0.contains("source stream offsets") })
        XCTAssertTrue(otherErrors.contains { $0.contains("source timecode") })
    }

    func testRejectsTimingRoundingInvalidXMLAndEmptySequences() throws {
        var project = try fixture()
        project.tracks[0].clips[0].timelineStart = try RationalTime(1, 1000)
        XCTAssertTrue(try reasons(project).contains { $0.contains("frame boundaries") })
        project = try fixture()
        project.assets[0].name = "Control\u{1}"
        XCTAssertTrue(try reasons(project).contains { $0.contains("XML 1.0") })
        project = try fixture()
        project.tracks = []
        XCTAssertTrue(try reasons(project).contains { $0.contains("no clips") })
        project = try fixture()
        project.settings.audioSampleRate = 12345
        XCTAssertTrue(try reasons(project).contains { $0.contains("sample rate") })
        project = try fixture()
        project.tracks[2].clips[0].sourceRange.start = try RationalTime(1, Int64(Int32.max) + 1)
        XCTAssertTrue(try reasons(project).contains { $0.contains("32-bit") })
    }

    func testCompleteMonoAudioAndUnusedAssets() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.settings.audioLayout = .mono
        project.assets[0].originalURL = URL(fileURLWithPath: "/tmp/music.wav")
        project.assets[0].streams[0].audioLayout = .mono
        project.tracks[0].template.audioLayout = .mono
        project.tracks[0].template.gain = 1
        project.families[0].template = project.tracks[0].template
        for index in project.tracks[0].clips.indices {
            project.tracks[0].clips[index].selection = .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0)], layout: .mono))
        }
        project.assets.append(MediaAsset(name: "Unused", duration: try RationalTime(1)))
        let result = try FCPXMLExporter.export(project: project)
        XCTAssertEqual(result.report.assetCount, 1)
        XCTAssertTrue(result.xml.contains("audioLayout=\"mono\""))
        XCTAssertFalse(result.xml.contains("Unused"))
    }

    /// Opt in with a locally downloaded Apple DTD. The DTD is intentionally not bundled
    /// or fetched by tests, and passing this check does not establish native import support.
    func testAgainstLocalAppleDTDWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["FCPXML_DTD"] else { throw XCTSkip("Set FCPXML_DTD to Apple's FCPXML 1.10 DTD for schema validation") }
        var channels = try fixture()
        channels.assets[0].streams.append(MediaStream(index: 2, kind: .audio, audioLayout: .stereo))
        channels.tracks[2].clips[0].selection = .audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 2, channelIndex: 1), SourceChannel(streamIndex: 2, channelIndex: 0)], layout: .stereo))
        var projects = try [FrameRate(24), FrameRate(24000, 1001), FrameRate(30000, 1001), FrameRate(60000, 1001)].map { try fixture(rate: $0) }
        projects.append(channels)  // audio-channel-source selection
        for project in projects {
            let result = try FCPXMLExporter.export(project: project)
            let document = try XMLDocument(xmlString: result.xml)
            let dtd = try XMLDTD(contentsOf: URL(fileURLWithPath: path))
            dtd.name = "fcpxml"
            document.dtd = dtd
            try document.validate()
        }
    }
}
