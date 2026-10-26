import AVFoundation
import AppKit
import EditorCore

/// Red (0–2 s) then blue (2–4 s) source. Shot A is red, shot B is blue, joined at 1.5 s with a
/// one-second dissolve; A fades in from black over half a second and B fades out at the end.
@main struct SystemTransitionSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SystemTransitionSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("afc-transition-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: log) }
        process.standardError = errors
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = (try? String(contentsOf: log, encoding: .utf8))?.suffix(800) ?? ""
        try require(process.terminationStatus == 0, "\(executable) failed: \(message)")
        return data
    }
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let tracks = try await AVURLAsset(url: url).load(.tracks)
        let vi = tracks.firstIndex { $0.mediaType == .video }!
        let asset = MediaAsset(name: "Fixture", originalURL: url, duration: try RationalTime(4), streams: [MediaStream(index: vi, kind: .video)])
        let template = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Video", template: template)
        let a = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(3, 2)), selection: .video(streamIndex: vi))
        let b = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(5, 2), duration: RationalTime(3, 2)),
                             timelineStart: try RationalTime(3, 2), selection: .video(streamIndex: vi))
        let base = Project(settings: try SequenceSettings(width: 80, height: 48, frameRate: FrameRate(24)), assets: [asset], families: [family],
                           tracks: [TimelineTrack(familyID: family.id, template: template, clips: [a, b])])
        var engine = try TimelineEditEngine(project: base)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .linear))
        try engine.apply(.setFades(clipID: a.id, fadeIn: AudioFade(duration: try RationalTime(1, 2)), fadeOut: .init()))
        try engine.apply(.setFades(clipID: b.id, fadeIn: .init(), fadeOut: AudioFade(duration: try RationalTime(1, 2))))
        let project = engine.project

        let output = directory.appendingPathComponent("reference.mov")
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
        _ = try run(ffmpeg, command.arguments)
        func reference(_ frame: Int) throws -> [Int] {
            let data = try run(ffmpeg, ["-hide_banner", "-i", output.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:40:24",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            return data.prefix(3).map(Int.init)
        }

        let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
        var image: CGImage?
        backend.display = { displayed, _ in image = displayed }
        func preview(_ frame: Int) async throws -> [Int] {
            try await backend.seek(toFrame: Int64(frame))
            guard let image else { throw NSError(domain: "No preview frame", code: 1) }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { pointer in
                let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: -40, y: -23, width: image.width, height: image.height))
            }
            return bytes.prefix(3).map(Int.init)
        }
        // Fade in, solid red, dissolve start/middle/end, solid blue, fade out.
        for frame in [0, 6, 12, 20, 24, 30, 36, 42, 47, 50, 60, 66, 71] {
            let expected = try reference(frame), actual = try await preview(frame)
            let difference = zip(expected, actual).map { abs($0 - $1) }.max() ?? 255
            print("frame \(frame): export \(expected) preview \(actual)")
            // System and FFmpeg colour conversion of saturated primaries differ by up to ~26 levels.
            try require(difference <= 32, "Preview frame \(frame) differs from export: \(actual) vs \(expected)")
        }
        let middle = try reference(36)
        try require(abs(middle[0] - middle[2]) < 30 && middle[0] > 90, "Dissolve midpoint must blend red and blue: \(middle)")
        await backend.close()
        print("PASS system transition preview matches export")
    }
}
