import Foundation
import XCTest
@testable import EditorCore

final class AudioEQTests: XCTestCase {
    func testBandsHitTheirGainsAndLeaveOtherFrequencies() throws {
        let eq = AudioEQ(low: 12, mid: 6, high: -12)
        let rate = 48000.0
        func total(_ f: Double) -> Double { eq.biquads(sampleRate: rate).reduce(0) { $0 + $1.response(at: f, sampleRate: rate) } }
        XCTAssertEqual(total(30), 12, accuracy: 0.6, "Low shelf")
        XCTAssertEqual(total(1000), 6, accuracy: 0.6, "Mid peak")
        XCTAssertEqual(total(20000), -12, accuracy: 0.8, "High shelf")
        XCTAssertEqual(AudioEQ(mid: 6).biquads(sampleRate: rate)[0].response(at: 50, sampleRate: rate), 0, accuracy: 0.5)
        XCTAssertTrue(AudioEQ.flat.biquads(sampleRate: rate).isEmpty)
        XCTAssertThrowsError(try AudioEQ(low: 30).validate())
        XCTAssertEqual(try JSONDecoder().decode(AudioEQ.self, from: JSONEncoder().encode(eq)), eq)
    }

    func testRenderedEQChangesTonesByTheComputedResponse() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render EQ") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        let eq = AudioEQ(low: -12, mid: 6, high: 9)
        for frequency in [60.0, 1000, 12000] {
            let tone = directory.appendingPathComponent("tone-\(Int(frequency)).mov")
            _ = try run(["-v", "error", "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000:duration=2", "-c:a", "pcm_s24le", tone.path])
            func level(_ eq: AudioEQ) throws -> Double {
                let template = TrackTemplate(kind: .audio, audioLayout: .mono)
                let family = TrackFamily(baseName: "Audio", template: template)
                let asset = MediaAsset(name: "tone", originalURL: tone, duration: try RationalTime(2), streams: [.init(index: 0, kind: .audio, audioLayout: .mono)])
                let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)),
                                        selection: .audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0)], layout: .mono)), eq: eq)
                let project = Project(settings: try SequenceSettings(width: 64, height: 36, frameRate: FrameRate(25), audioLayout: .mono), assets: [asset],
                                      families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
                let output = directory.appendingPathComponent("out-\(UUID().uuidString).mov")
                _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
                let samples = try run(["-v", "error", "-i", output.path, "-map", "0:a", "-f", "f32le", "-"]).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
                return 10 * log10(middle.reduce(0) { $0 + Double($1 * $1) } / Double(middle.count))
            }
            let change = try level(eq) - level(.flat)
            let expected = eq.biquads(sampleRate: 48000).reduce(0) { $0 + $1.response(at: frequency, sampleRate: 48000) }
            XCTAssertEqual(change, expected, accuracy: 0.3, "\(frequency) Hz")
        }
    }
}
