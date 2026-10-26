import Foundation
import XCTest
@testable import EditorCore

final class ChromaKeyTests: XCTestCase {
    func testKeyFormulaValidationAndRenderedComposite() throws {
        let key = ChromaKey(color: "#00FF00", similarity: 0.12, blend: 0.08)
        XCTAssertEqual(key.alpha(red: 0, green: 1, blue: 0), 0, "Pure key green is transparent")
        XCTAssertEqual(key.alpha(red: 1, green: 0, blue: 0), 1, "Red is kept")
        XCTAssertThrowsError(try ChromaKey(color: "green").validate())
        XCTAssertEqual(try JSONDecoder().decode(ChromaKey.self, from: JSONEncoder().encode(key)), key)
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render a key") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        let screen = directory.appendingPathComponent("screen.mov"), blue = directory.appendingPathComponent("blue.mov")
        _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=0x00FF00:s=160x90:r=25:d=2", "-f", "lavfi", "-i", "color=red:s=40x40:r=25:d=2",
                     "-filter_complex", "[0][1]overlay=x=60:y=25,scale=out_color_matrix=bt709", "-c:v", "prores_ks", "-colorspace", "bt709", screen.path])
        _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=blue:s=160x90:r=25:d=2", "-c:v", "prores_ks", blue.path])
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let screenAsset = MediaAsset(name: "screen", originalURL: screen, duration: try RationalTime(2), streams: [.init(index: 0, kind: .video)])
        let blueAsset = MediaAsset(name: "blue", originalURL: blue, duration: try RationalTime(2), streams: [.init(index: 0, kind: .video)])
        let range = try TimeRange(start: .zero, duration: RationalTime(1))
        let project = Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [screenAsset, blueAsset], families: [family],
                              tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [
                                        TimelineClip(assetID: screenAsset.id, sourceRange: range, selection: .video(streamIndex: 0), key: key)]),
                                       TimelineTrack(familyID: family.id, template: family.template, clips: [
                                        TimelineClip(assetID: blueAsset.id, sourceRange: range, selection: .video(streamIndex: 0))])])
        let plan = try TimelineRenderPlan(project: project)
        XCTAssertEqual(try VideoCompositionPlan(plan).instructions.first?.componentIndices.count, 2, "A keyed picture reveals the layer below")
        XCTAssertThrowsError(try FCPXMLExporter.export(project: project))
        let output = directory.appendingPathComponent("keyed.mov")
        _ = try run(try FFmpegRenderCompiler.compile(plan, outputURL: output).arguments)
        func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
            Array(try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,5),crop=2:2:\(x):\(y)", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]).prefix(3))
        }
        let background = try pixel(10, 10), square = try pixel(78, 44)
        XCTAssertGreaterThan(background[2], 230); XCTAssertLessThan(background[1], 30)
        XCTAssertGreaterThan(square[0], 230); XCTAssertLessThan(square[2], 30)
    }
}
