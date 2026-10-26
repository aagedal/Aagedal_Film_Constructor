import Foundation
import XCTest
@testable import EditorCore

final class ColorAdjustmentTests: XCTestCase {
    private func project(_ url: URL) throws -> (Project, UUID) {
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let asset = MediaAsset(name: "src", originalURL: url, duration: try RationalTime(2), streams: [.init(index: 0, kind: .video)])
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), selection: .video(streamIndex: 0))
        return (Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [asset], families: [family],
                        tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [clip])]), clip.id)
    }

    func testColorValidatesPersistsAndIsRefusedByInterchange() throws {
        var (project, id) = try project(URL(fileURLWithPath: "/private/tmp/color.mov"))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setColor(clipID: id, color: ColorAdjustment(brightness: 0.1, contrast: 1.2, saturation: 0)))
        XCTAssertThrowsError(try engine.apply(.setColor(clipID: id, color: ColorAdjustment(brightness: 2))))
        XCTAssertThrowsError(try engine.apply(.setColor(clipID: id, color: ColorAdjustment(saturation: -1))))
        project = engine.project
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        XCTAssertThrowsError(try FCPXMLExporter.export(project: project))
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/color-out.mov"))
        XCTAssertTrue(command.filterGraph.contains("lutyuv=y="))
    }

    func testRenderedColorDecodedPixels() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render colour") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        func render(_ color: String, _ adjustment: ColorAdjustment, fade: Bool = false) throws -> [Int] {
            let source = directory.appendingPathComponent("\(color).mov")
            if !FileManager.default.fileExists(atPath: source.path) {
                _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=25:d=2", "-vf", "scale=out_color_matrix=bt709",
                             "-c:v", "prores_ks", "-colorspace", "bt709", source.path])
            }
            var (project, id) = try project(source)
            var engine = try TimelineEditEngine(project: project)
            try engine.apply(.setColor(clipID: id, color: adjustment))
            if fade { try engine.apply(.setFades(clipID: id, fadeIn: .init(), fadeOut: AudioFade(duration: try RationalTime(1, 5)))) }
            project = engine.project
            let output = directory.appendingPathComponent("out-\(UUID().uuidString).mov")
            _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
            return try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,5),crop=2:2:80:44", "-frames:v", "1",
                            "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]).prefix(3).map(Int.init)
        }
        let grey = try render("0x808080", .neutral)
        let brighter = try render("0x808080", ColorAdjustment(brightness: 0.2))
        XCTAssertEqual(Double(brighter[1] - grey[1]), 0.2 * 255, accuracy: 8, "Brightness adds a fifth of full scale")
        let red = try render("red", ColorAdjustment(saturation: 0))
        XCTAssertLessThan(abs(red[0] - red[2]), 6, "No saturation leaves grey: \(red)")
        let contrast = try render("0xC0C0C0", ColorAdjustment(contrast: 2))
        XCTAssertGreaterThan(contrast[0], 240, "Contrast pushes light grey towards white: \(contrast)")
        XCTAssertEqual(try render("0x808080", ColorAdjustment(brightness: 0.2), fade: true)[1], brighter[1], accuracy: 3, "Colour and alpha fades combine")
    }
}

final class BlurTests: XCTestCase {
    func testBlurValidatesPersistsAndSoftensAnEdge() throws {
        XCTAssertThrowsError(try ColorAdjustment(blur: 0.2).validate())
        let legacy = try JSONDecoder().decode(ColorAdjustment.self, from: Data(#"{"brightness":0,"contrast":1,"saturation":1}"#.utf8))
        XCTAssertEqual(legacy.blur, 0)
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render blur") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        // Black left half, white right half.
        let source = directory.appendingPathComponent("edge.mov")
        _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=black:s=160x90:r=25:d=2", "-f", "lavfi", "-i", "color=white:s=80x90:r=25:d=2",
                     "-filter_complex", "[0][1]overlay=x=80", "-c:v", "prores_ks", source.path])
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let asset = MediaAsset(name: "edge", originalURL: source, duration: try RationalTime(2), streams: [.init(index: 0, kind: .video)])
        func row(_ blur: Double) throws -> [UInt8] {
            let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), selection: .video(streamIndex: 0),
                                    color: ColorAdjustment(blur: blur))
            let project = Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [asset], families: [family],
                                  tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [clip])])
            let output = directory.appendingPathComponent("out-\(blur).mov")
            _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
            return Array(try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,5),crop=160:1:0:45,format=gray", "-frames:v", "1", "-f", "rawvideo", "-"]))
        }
        let sharp = try row(0), soft = try row(0.05)
        XCTAssertLessThan(sharp[76], 10); XCTAssertGreaterThan(sharp[84], 245)
        XCTAssertGreaterThan(soft[76], 25, "Blur spreads white into the black side"); XCTAssertLessThan(soft[84], 235)
    }
}
