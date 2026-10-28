import Foundation
import XCTest
@testable import EditorCore

final class StabilizationTests: XCTestCase {
    /// A slow pan with fast jitter: the correction cancels the jitter and keeps the pan.
    private func shaky(frames: Int = 250, rate: Double = 25) -> MotionAnalysis {
        let times = (0..<frames).map { Double($0) / rate }
        return MotionAnalysis(times: times, x: times.map { 0.01 * $0 + 0.02 * sin(2 * .pi * 6 * $0) },
                              y: times.map { 0.015 * sin(2 * .pi * 4 * $0 + 1) })
    }

    func testCorrectionsCancelJitterAndClamp() throws {
        let stabilization = Stabilization(analysis: shaky(), smoothing: 1)
        try stabilization.validate()
        let corrections = stabilization.corrections()
        let times = stabilization.analysis.times
        // Away from the edges, the stabilised path (measured + correction) follows the pan only.
        for i in 50..<200 {
            XCTAssertEqual(stabilization.analysis.x[i] + corrections.x[i], 0.01 * times[i], accuracy: 0.002)
            XCTAssertEqual(stabilization.analysis.y[i] + corrections.y[i], 0, accuracy: 0.002)
        }
        let resolved = stabilization.resolved()
        XCTAssertGreaterThan(resolved.zoom, 1.03); XCTAssertLessThan(resolved.zoom, 1.06)
        let fixed = Stabilization(analysis: shaky(), smoothing: 1, zoom: 1.01).resolved()
        for t in stride(from: 0.0, to: 10, by: 0.013) {
            let c = fixed.correction(atSourceSeconds: t)
            XCTAssertLessThanOrEqual(max(abs(c.x), abs(c.y)), fixed.limit + 1e-12, "Edges never show")
        }
        XCTAssertThrowsError(try Stabilization(analysis: MotionAnalysis(times: [0], x: [0], y: [0])).validate())
        XCTAssertThrowsError(try Stabilization(analysis: shaky(), smoothing: 0).validate())
    }

    private func project(directory: URL) throws -> (Project, UUID) {
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let asset = MediaAsset(name: "shaky", originalURL: directory.appendingPathComponent("shaky.mov"), duration: try RationalTime(4),
                               streams: [.init(index: 0, kind: .video)])
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(4)), selection: .video(streamIndex: 0))
        return (Project(settings: try SequenceSettings(width: 320, height: 180, frameRate: FrameRate(25)), assets: [asset], families: [family],
                        tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [clip])]), clip.id)
    }

    func testEditPersistenceAndCompile() throws {
        var (project, clip) = try project(directory: URL(fileURLWithPath: "/private/tmp"))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setStabilization(clipID: clip, stabilization: Stabilization(analysis: shaky(frames: 100))))
        try engine.apply(.split(clipID: clip, at: RationalTime(2)))
        XCTAssertTrue(engine.project.tracks[0].clips.allSatisfy { $0.stabilization != nil }, "Halves keep the source-anchored analysis")
        project = engine.project
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/stable.mov"))
        XCTAssertEqual(command.sidecars.count, 2)
        XCTAssertTrue(command.filterGraph.contains("crop@stab"))
        XCTAssertEqual(command.sidecars[0].contents.split(separator: "\n").count, 50, "One command line per frame")
        XCTAssertTrue(try FCPXMLExporter.export(project: project).report.warnings.contains { $0.hasPrefix("Stabilisation") })
    }

    /// A white box jitters horizontally; with its measured path as the analysis the export
    /// holds it nearly still.
    func testRenderedStabilisationHoldsContentStill() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render stabilisation") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stabilise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data { try runFFmpeg(ffmpeg, arguments) }
        // Box x = 140 + 12·sin(n·2.2) pixels on a 320-wide frame.
        _ = try run(["-v", "error", "-filter_complex", "color=black:s=320x180:r=25:d=4[b];color=white:s=40x40:r=25:d=4[w];[b][w]overlay=x='140+12*sin(t*55)':y=70:eval=frame",
                     "-c:v", "prores_ks", directory.appendingPathComponent("shaky.mov").path])
        let times = (0..<100).map { Double($0) / 25 }
        let analysis = MotionAnalysis(times: times, x: (0..<100).map { 12 * sin(Double($0) * 2.2) / 320 }, y: times.map { _ in 0 })
        var (project, clip) = try project(directory: directory)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setStabilization(clipID: clip, stabilization: Stabilization(analysis: analysis, smoothing: 1, zoom: 1.2)))
        project = engine.project
        let output = directory.appendingPathComponent("stable.mov")
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output, sidecarDirectory: directory)
        for sidecar in command.sidecars { try sidecar.contents.write(to: sidecar.url, atomically: true, encoding: .utf8) }
        _ = try run(command.arguments)
        func centres(_ url: URL) throws -> [Double] {
            let data = try run(["-v", "error", "-i", url.path, "-vf", "crop=320:1:0:90", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
            return stride(from: 0, to: data.count, by: 320).map { start in
                let row = data[start..<min(data.count, start + 320)]
                let lit = row.indices.filter { row[$0] > 128 }.map { $0 - start }
                return lit.isEmpty ? 0 : Double(lit.reduce(0, +)) / Double(lit.count)
            }
        }
        let before = try centres(directory.appendingPathComponent("shaky.mov"))[25..<75]
        let after = try centres(output)[25..<75]
        func spread(_ values: ArraySlice<Double>) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        XCTAssertGreaterThan(spread(before), 20)
        XCTAssertLessThan(spread(after), 5, "Stabilised box centres \(Array(after))")
    }
}
