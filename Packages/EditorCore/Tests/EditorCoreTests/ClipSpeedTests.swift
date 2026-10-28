import Foundation
import XCTest
@testable import EditorCore

final class ClipSpeedTests: XCTestCase {
    private func linked() throws -> (Project, [UUID]) {
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/speed.mov"), duration: try RationalTime(20),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(25)), assets: [movie])
        let ids = try project.appendAsset(movie.id, at: .zero, sourceRange: TimeRange(start: RationalTime(2), duration: RationalTime(4)))
        try project.appendAsset(movie.id, at: RationalTime(4), sourceRange: TimeRange(start: RationalTime(10), duration: RationalTime(2)))
        return (project, ids)
    }
    private func clip(_ id: UUID, _ project: Project) -> TimelineClip { project.tracks.flatMap(\.clips).first { $0.id == id }! }

    func testSlowingKeepsSourceAndLengthensTheLinkedGroupWithoutOverwriting() throws {
        let (project, ids) = try linked()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setSpeed(clipID: ids[0], speed: RationalTime(1, 2)))
        for id in ids {
            let c = clip(id, engine.project)
            XCTAssertEqual(c.speed, try RationalTime(1, 2))
            XCTAssertEqual(c.sourceRange, try TimeRange(start: RationalTime(2), duration: RationalTime(8)), "Same 4 s of source over 8 s")
            XCTAssertEqual(try c.sourceEnd(), try RationalTime(6))
        }
        XCTAssertGreaterThan(engine.project.tracks.count, project.tracks.count, "The longer clip stacks over the next one instead of overwriting it")
        XCTAssertThrowsError(try engine.apply(.setSpeed(clipID: ids[0], speed: RationalTime(1, 20))), "Below 10%")

        // Splitting halfway lands halfway through the source.
        try engine.apply(.split(clipID: ids[0], at: RationalTime(4)))
        let right = try XCTUnwrap(engine.project.tracks.flatMap(\.clips).first { $0.timelineStart == (try! RationalTime(4)) && $0.speed != .one })
        XCTAssertEqual(right.sourceRange.start, try RationalTime(4))
        XCTAssertNoThrow(try engine.project.validate())
        // Speeding up past the media end is refused: 4 s at 1000% would need 40 s.
        var fast = try TimelineEditEngine(project: project)
        try fast.apply(.setSpeed(clipID: ids[0], speed: RationalTime(4)))
        XCTAssertEqual(clip(ids[0], fast.project).sourceRange.duration, try RationalTime(1))
        XCTAssertEqual(try TimelineGesture.trimDelta(10, edge: .trailing, clip: clip(ids[0], fast.project), project: fast.project, quantum: 0.04), 3.48, accuracy: 1e-9,
                       "14 s of source remain: 3.5 s of timeline at 400%, floored to whole frames")
        // Interchange writes the speed as a time map.
        XCTAssertTrue(try FCPXMLExporter.export(project: fast.project).xml.contains("<timeMap>"))
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: fast.project), outputURL: URL(fileURLWithPath: "/private/tmp/speed-out.mov"))
        XCTAssertTrue(command.filterGraph.contains("atempo=4.0"))
    }

    func testRenderedSpeedDecodedFramesAndPitch() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else { throw XCTSkip("Set AFC_FFMPEG to render speed changes") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); return data
        }
        // Source frame n has luma 16 + 3n; audio is a 1 kHz tone.
        let source = directory.appendingPathComponent("ramp.mov")
        _ = try run(["-v", "error", "-f", "lavfi", "-i", "nullsrc=s=64x36:r=25:d=4,geq=lum='16+3*N':cb=128:cr=128", "-f", "lavfi",
                     "-i", "sine=frequency=1000:sample_rate=48000:duration=4", "-ac", "2", "-c:v", "prores_ks", "-c:a", "pcm_s24le", "-shortest", source.path])
        let asset = MediaAsset(name: "ramp", originalURL: source, duration: try RationalTime(4),
                               streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        for (speed, frames) in [(try RationalTime(1, 2), [0, 10, 20, 39]), (try RationalTime(2), [0, 5, 10, 19])] {
            var project = Project(settings: try SequenceSettings(width: 64, height: 36, frameRate: FrameRate(25)), assets: [asset])
            let ids = try project.appendAsset(asset.id, at: .zero, sourceRange: TimeRange(start: .zero, duration: RationalTime(8, 5)))
            var engine = try TimelineEditEngine(project: project)
            try engine.apply(.setSpeed(clipID: ids[0], speed: speed))
            let output = directory.appendingPathComponent("out-\(speed.seconds).mov")
            _ = try run(try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: output).arguments)
            for frame in frames {
                let luma = try run(["-v", "error", "-i", output.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:30:16,format=gray", "-frames:v", "1",
                                    "-f", "rawvideo", "-"])[0]
                // Grey output expands video range: frame = luma × 219/255 / 3.
                let sourceFrame = Double(luma) * 219 / 255 / 3
                XCTAssertEqual(sourceFrame, Double(frame) * speed.seconds, accuracy: 1.01, "Speed \(speed.seconds) frame \(frame)")
            }
            let samples = try run(["-v", "error", "-i", output.path, "-map", "0:a", "-f", "f32le", "-ac", "1", "-"]).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let expected = Int(engine.project.tracks.flatMap(\.clips)[0].sourceRange.duration.seconds * 48000)
            XCTAssertEqual(samples.count, expected, accuracy: 2, "Exact timeline length")
            let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
            let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            XCTAssertEqual(Double(crossings) / (Double(middle.count) / 48000), 1000, accuracy: 30, "Pitch is preserved at speed \(speed.seconds)")
        }
    }
}
