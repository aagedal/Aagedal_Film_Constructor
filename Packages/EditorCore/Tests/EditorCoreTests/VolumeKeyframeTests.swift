import Foundation
import XCTest
@testable import EditorCore

final class VolumeKeyframeTests: XCTestCase {
    private let keyframes = [VolumeKeyframe(time: try! RationalTime(1), gain: 1), VolumeKeyframe(time: try! RationalTime(2), gain: 0.25)]

    func testEnvelopeInterpolatesHoldsAndValidates() throws {
        XCTAssertEqual(VolumeEnvelope.gain(atSourceSeconds: 0.5, keyframes: keyframes), 1)
        XCTAssertEqual(VolumeEnvelope.gain(atSourceSeconds: 1.5, keyframes: keyframes), 0.625, accuracy: 1e-12)
        XCTAssertEqual(VolumeEnvelope.gain(atSourceSeconds: 9, keyframes: keyframes), 0.25)
        XCTAssertEqual(VolumeEnvelope.gain(atSourceSeconds: 3, keyframes: []), 1)
        XCTAssertThrowsError(try VolumeEnvelope.validate(keyframes.reversed()))
        XCTAssertThrowsError(try VolumeEnvelope.validate([VolumeKeyframe(time: .zero, gain: 20)]))
    }

    func testKeyframesFollowTheSourceThroughSplitsAndPersist() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/keyframes.wav")
        let id = project.tracks[0].clips[0].id
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setVolumeKeyframes(clipIDs: [id], keyframes: keyframes))
        try engine.apply(.split(clipID: id, at: RationalTime(3)))
        XCTAssertTrue(engine.project.tracks[0].clips.filter { $0.assetID == project.assets[0].id && $0.timelineStart.seconds < 5 }
                        .allSatisfy { $0.volumeKeyframes == keyframes }, "Both halves keep the source-anchored automation")
        let data = try JSONEncoder().encode(engine.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), engine.project)
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: URL(fileURLWithPath: "/private/tmp/keyframes.mov"))
        XCTAssertTrue(command.filterGraph.contains("if(lt(n,"))
        XCTAssertTrue(try FCPXMLExporter.export(project: engine.project).xml.contains("<param name=\"amount\">"))
    }

    func testRenderedAutomationDecodedLevels() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else {
            throw XCTSkip("Set AFC_FFMPEG to an FFmpeg executable to render volume keyframes")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        let tone = directory.appendingPathComponent("tone.mov")
        _ = try run(["-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=4", "-af", "volume=0.5", "-c:a", "pcm_s24le", tone.path])
        let settings = try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25), audioLayout: .mono)
        let template = TrackTemplate(kind: .audio, audioLayout: .mono)
        let family = TrackFamily(baseName: "Audio", template: template)
        let asset = MediaAsset(name: "Tone", originalURL: tone, duration: try RationalTime(4), streams: [.init(index: 0, kind: .audio, audioLayout: .mono)])
        // Source starts at 0.5 s: timeline t plays source t + 0.5.
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1, 2), duration: RationalTime(3)),
                                selection: .audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0)], layout: .mono)), volumeKeyframes: keyframes)
        let project = Project(settings: settings, assets: [asset], families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
        let output = directory.appendingPathComponent("render.mov")
        _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
        let samples = try run(["-v", "error", "-i", output.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "-"]).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func rms(at seconds: Double) -> Double {
            let start = Int(seconds * 48000) - 480
            let window = samples[start..<(start + 960)]
            return (window.reduce(0) { $0 + Double($1 * $1) } / Double(window.count)).squareRoot()
        }
        // FFmpeg's sine source has amplitude 1/8; the fixture halves it.
        let full = 0.125 * 0.5 / 2.0.squareRoot()
        XCTAssertEqual(rms(at: 0.2), full, accuracy: 0.002, "Held at the first keyframe's volume")
        XCTAssertEqual(rms(at: 1.0), full * 0.625, accuracy: 0.002, "Halfway between keyframes")
        XCTAssertEqual(rms(at: 2.2), full * 0.25, accuracy: 0.002, "Held at the last keyframe's volume")
    }
}
