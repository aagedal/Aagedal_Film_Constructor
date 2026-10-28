import Foundation
import XCTest
@testable import EditorCore

final class AudioDynamicsTests: XCTestCase {
    func testValidationAndPersistence() throws {
        let dynamics = AudioDynamics(threshold: -20, ratio: 4, makeup: 6, limiterCeiling: -1)
        XCTAssertEqual(try JSONDecoder().decode(AudioDynamics.self, from: JSONEncoder().encode(dynamics)), dynamics)
        XCTAssertThrowsError(try AudioDynamics(ratio: 40).validate())
        XCTAssertEqual(dynamics.stages.count, 2)
    }

    /// The Swift compressor matches FFmpeg's acompressor on a tone that steps from quiet to loud.
    func testCompressorMatchesFFmpegSampleForSample() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to compare with acompressor") }
        let rate = 48000.0
        var input: [Float] = []
        for (seconds, amplitude) in [(0.5, 0.05), (1.0, 0.8), (1.0, 0.2)] {
            for n in 0..<Int(seconds * rate) { input.append(Float(amplitude * sin(2 * .pi * 440 * Double(input.count + n) / rate))) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compressor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("in.f32")
        try input.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: raw)
        let dynamics = AudioDynamics(threshold: -20, ratio: 4, makeup: 6, limiterCeiling: -3)
        let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", raw.path, "-af", dynamics.ffmpegFilters, "-f", "f32le", "-"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var stages = dynamics.stages.map { Compressor($0, sampleRate: rate) }
        let actual = input.map { sample -> Float in
            var value = Double(sample)
            for index in stages.indices { value = stages[index].process(value) }
            return Float(value)
        }
        XCTAssertEqual(expected.count, actual.count)
        let worst = zip(expected, actual).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4, "Largest sample difference \(worst)")
        // The loud section is compressed: well below 0.8 × makeup.
        let loud = actual[Int(1.2 * rate)..<Int(1.4 * rate)].map(abs).max() ?? 0
        XCTAssertLessThan(loud, 0.8)
    }
}

final class AudioDynamicsRenderTests: XCTestCase {
    func testClipDynamicsCompileAfterVolumeAndPersist() throws {
        var project = try DemoProjectFactory.musicCollision()
        project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/dynamics.wav")
        let id = project.tracks[0].clips[0].id
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setDynamics(clipIDs: [id], dynamics: AudioDynamics(threshold: -24, ratio: 4, makeup: 6, limiterCeiling: -1)))
        XCTAssertThrowsError(try engine.apply(.setDynamics(clipIDs: [id], dynamics: AudioDynamics(threshold: -90))))
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(engine.project)), engine.project)
        let graph = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: URL(fileURLWithPath: "/private/tmp/dynamics.mov")).filterGraph
        let volume = try XCTUnwrap(graph.range(of: "volume=0.8")), compressor = try XCTUnwrap(graph.range(of: "acompressor="))
        XCTAssertLessThan(volume.lowerBound, compressor.lowerBound, "Compression follows volume, as in the post-fader preview tap")
        XCTAssertTrue(try FCPXMLExporter.export(project: engine.project).report.warnings.contains { $0.hasPrefix("Compression") })
    }
}
