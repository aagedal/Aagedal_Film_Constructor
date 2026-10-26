import Foundation
import XCTest
@testable import EditorCore

final class TransformKeyframeTests: XCTestCase {
    private let keyframes = [TransformKeyframe(time: .zero, scale: 0.25, offsetX: -0.25),
                             TransformKeyframe(time: try! RationalTime(1), scale: 0.5, offsetX: 0.25)]

    private func project(directory: URL) throws -> (Project, UUID) {
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let blue = MediaAsset(name: "blue", originalURL: directory.appendingPathComponent("blue.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let red = MediaAsset(name: "red", originalURL: directory.appendingPathComponent("red.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let range = try TimeRange(start: .zero, duration: RationalTime(2))
        let top = TimelineClip(assetID: red.id, sourceRange: range, selection: .video(streamIndex: 0), transformKeyframes: keyframes)
        return (Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [blue, red], families: [family],
                        tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [top]),
                                 TimelineTrack(familyID: family.id, template: family.template, clips: [
                                    TimelineClip(assetID: blue.id, sourceRange: range, selection: .video(streamIndex: 0))])]), top.id)
    }

    func testInterpolationValidationAndPersistence() throws {
        let base = PictureTransform(opacity: 0.7)
        let middle = PictureAnimation.transform(atSourceSeconds: 0.5, base: base, keyframes: keyframes)
        XCTAssertEqual(middle.scale, 0.375, accuracy: 1e-12); XCTAssertEqual(middle.offsetX, 0, accuracy: 1e-12); XCTAssertEqual(middle.opacity, 0.7)
        XCTAssertEqual(PictureAnimation.transform(atSourceSeconds: 5, base: base, keyframes: keyframes).scale, 0.5)
        XCTAssertThrowsError(try PictureAnimation.validate(keyframes.reversed()))
        XCTAssertThrowsError(try PictureAnimation.validate([TransformKeyframe(time: .zero, scale: 0)]))
        var (project, top) = try project(directory: URL(fileURLWithPath: "/private/tmp"))
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        XCTAssertTrue(try FCPXMLExporter.export(project: project).xml.contains("<keyframeAnimation>"))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.split(clipID: top, at: RationalTime(1, 2)))
        XCTAssertTrue(engine.project.tracks[0].clips.allSatisfy { $0.transformKeyframes == keyframes }, "Halves keep source-anchored animation")
        project = engine.project
        let plan = try TimelineRenderPlan(project: project)
        XCTAssertTrue(try VideoCompositionPlan(plan).instructions.allSatisfy { $0.componentIndices.count == 2 }, "An animated picture reveals the lower layer")
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/private/tmp/animated.mov"))
        XCTAssertTrue(command.filterGraph.contains(":eval=frame"))
        XCTAssertTrue(command.filterGraph.contains("if(lt(t,"))
    }

    func testRenderedAnimationDecodedPositionAndSize() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render keyframes") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        for color in ["blue", "red"] {
            _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=25:d=4", "-c:v", "prores_ks", directory.appendingPathComponent("\(color).mov").path])
        }
        let (project, _) = try project(directory: directory)
        let output = directory.appendingPathComponent("animated.mov")
        _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
        /// Red pixels' horizontal centre and width on the middle row, in frame fractions.
        func inset(_ frame: Int) throws -> (centre: Double, width: Double) {
            let row = try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,\(frame)),crop=160:1:0:45", "-frames:v", "1",
                               "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            let red = stride(from: 0, to: row.count, by: 3).map { $0 / 3 }.filter { row[$0 * 3] > 128 && row[$0 * 3 + 2] < 128 }
            guard let first = red.first, let last = red.last else { return (0, 0) }
            return ((Double(first + last) / 2 + 0.5) / 160, Double(last - first + 1) / 160)
        }
        let start = try inset(0), middle = try inset(12), end = try inset(25)
        XCTAssertEqual(start.width, 0.25, accuracy: 0.02); XCTAssertEqual(start.centre, 0.25, accuracy: 0.02)
        XCTAssertEqual(middle.width, 0.37, accuracy: 0.03); XCTAssertEqual(middle.centre, 0.49, accuracy: 0.03)
        XCTAssertEqual(end.width, 0.5, accuracy: 0.02); XCTAssertEqual(end.centre, 0.75, accuracy: 0.02)
    }
}

final class OpacityKeyframeTests: XCTestCase {
    func testOpacityKeyframesInterpolateAndRenderAlpha() throws {
        let keyframes = [TransformKeyframe(time: .zero, opacity: 0), TransformKeyframe(time: try RationalTime(1), opacity: 1)]
        XCTAssertEqual(PictureAnimation.transform(atSourceSeconds: 0.25, base: PictureTransform(opacity: 0.8), keyframes: keyframes).opacity, 0.2, accuracy: 1e-12)
        let legacy = try JSONDecoder().decode(TransformKeyframe.self, from: Data(#"{"time":{"numerator":0,"denominator":1},"scale":1,"offsetX":0,"offsetY":0}"#.utf8))
        XCTAssertEqual(legacy.opacity, 1)
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render opacity keyframes") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        for color in ["blue", "red"] {
            _ = try run(["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=25:d=4", "-c:v", "prores_ks", directory.appendingPathComponent("\(color).mov").path])
        }
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let blue = MediaAsset(name: "blue", originalURL: directory.appendingPathComponent("blue.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let red = MediaAsset(name: "red", originalURL: directory.appendingPathComponent("red.mov"), duration: try RationalTime(4), streams: [.init(index: 0, kind: .video)])
        let range = try TimeRange(start: .zero, duration: RationalTime(2))
        let top = TimelineClip(assetID: red.id, sourceRange: range, selection: .video(streamIndex: 0), transformKeyframes: keyframes)
        let project = Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25)), assets: [blue, red], families: [family],
                              tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [top]),
                                       TimelineTrack(familyID: family.id, template: family.template, clips: [TimelineClip(assetID: blue.id, sourceRange: range, selection: .video(streamIndex: 0))])])
        let output = directory.appendingPathComponent("opacity.mov")
        _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
        func redLevel(_ frame: Int) throws -> Double {
            Double(try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:80:44", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])[0])
        }
        XCTAssertLessThan(try redLevel(0), 12)
        XCTAssertEqual(try redLevel(12), 255 * 0.48, accuracy: 14, "Half way up the opacity ramp")
        XCTAssertGreaterThan(try redLevel(30), 240)
    }
}
