import Foundation
import XCTest
@testable import EditorCore

final class PictureTransformTests: XCTestCase {
    /// Blue movie on the lower track, red movie on the upper track.
    private func fixture(directory: URL = URL(fileURLWithPath: "/private/tmp")) throws -> (Project, UUID) {
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let blue = MediaAsset(name: "blue", originalURL: directory.appendingPathComponent("blue.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let red = MediaAsset(name: "red", originalURL: directory.appendingPathComponent("red.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let range = try TimeRange(start: .zero, duration: RationalTime(2))
        let top = TimelineClip(assetID: red.id, sourceRange: range, selection: .video(streamIndex: 0))
        let project = Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [blue, red], families: [family],
                              tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [top]),
                                       TimelineTrack(familyID: family.id, template: family.template, clips: [
                                        TimelineClip(assetID: blue.id, sourceRange: range, selection: .video(streamIndex: 0))])])
        return (project, top.id)
    }

    func testTransformsValidatePersistAndRevealLowerLayers() throws {
        let (project, top) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        let pip = PictureTransform(scale: 0.5, offsetX: 0.25, offsetY: 0.25, opacity: 0.5)
        try engine.apply(.setTransform(clipID: top, transform: pip))
        for invalid in [PictureTransform(scale: 0), PictureTransform(offsetX: 3), PictureTransform(opacity: 1.5), PictureTransform(scale: .nan)] {
            XCTAssertThrowsError(try engine.apply(.setTransform(clipID: top, transform: invalid)))
        }
        let data = try JSONEncoder().encode(engine.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), engine.project)

        let plan = try TimelineRenderPlan(project: engine.project)
        XCTAssertEqual(try VideoCompositionPlan(plan).instructions.map(\.componentIndices.count), [2], "The lower picture shows around the inset")
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/pip.mov"))
        XCTAssertTrue(command.filterGraph.contains(":color=black@0"))
        XCTAssertTrue(command.filterGraph.contains("scale=w='max(1,round(iw*0.5))'"))
        XCTAssertTrue(command.filterGraph.contains("lut=a='val*0.5'"))
        XCTAssertTrue(command.filterGraph.contains("x='(main_w-overlay_w)/2+0.25*main_w'"))
        XCTAssertThrowsError(try FCPXMLExporter.export(project: engine.project))
        try engine.apply(.split(clipID: top, at: RationalTime(1)))
        XCTAssertTrue(engine.project.tracks[0].clips.allSatisfy { $0.transform == pip }, "Both halves keep the transform")
    }

    func testRenderedPictureInPictureDecodedPixels() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else {
            throw XCTSkip("Set AFC_FFMPEG to an FFmpeg executable to render transforms")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        for color in ["blue", "red"] {
            _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=25:d=4", "-vf", "scale=out_color_matrix=bt709",
                         "-c:v", "prores_ks", "-colorspace", "bt709", directory.appendingPathComponent("\(color).mov").path])
        }
        var (project, top) = try fixture(directory: directory)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setTransform(clipID: top, transform: PictureTransform(scale: 0.5, offsetX: 0.25, offsetY: 0.25, opacity: 0.5)))
        project = engine.project
        let output = directory.appendingPathComponent("pip.mov")
        _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
        func pixel(_ x: Int, _ y: Int) throws -> [Int] {
            try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,10),crop=2:2:\(x):\(y)", "-frames:v", "1",
                     "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]).prefix(3).map(Int.init)
        }
        // The inset is 80×46 centred at (120, 67): half red over blue there, blue elsewhere.
        let inset = try pixel(118, 66), outside = try pixel(20, 20), corner = try pixel(40, 46)
        XCTAssertEqual(Double(inset[0]), 127, accuracy: 16); XCTAssertEqual(Double(inset[2]), 127, accuracy: 16)
        XCTAssertLessThan(outside[0], 16); XCTAssertGreaterThan(outside[2], 230)
        XCTAssertLessThan(corner[0], 16, "Upper-left of the inset's former frame stays blue")
    }
}
