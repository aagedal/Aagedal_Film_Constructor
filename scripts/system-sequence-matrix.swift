import AVFoundation
import AppKit
import EditorCore

/// Barcode fixtures let us check decoded content independently of reported seek time.
@main struct SystemSequenceMatrix {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "SystemSequenceMatrix", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() async {
        do { try await qualify() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func qualify() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let rate = try FrameRate(Int64(CommandLine.arguments[2])!, Int64(CommandLine.arguments[3])!)
        func t(_ frames: Int64) throws -> RationalTime { try rate.time(forFrames: frames) }
        let tracks = try await AVURLAsset(url: url).load(.tracks)
        let vi = tracks.firstIndex { $0.mediaType == .video }!
        let ai = tracks.firstIndex { $0.mediaType == .audio }!
        let asset = MediaAsset(name: url.lastPathComponent, originalURL: url, duration: try t(96), streams: [
            MediaStream(index: vi, kind: .video), MediaStream(index: ai, kind: .audio, audioLayout: .stereo)])
        let vt = TrackTemplate(kind: .video), at = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let vf = TrackFamily(baseName: "Video", template: vt), af = TrackFamily(baseName: "Audio", template: at)
        let lower = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: t(7), duration: t(48)), timelineStart: try t(2), selection: .video(streamIndex: vi))
        // Frame 1 at 24000/1001 cannot be represented by the old 600000 timebase.
        let upper = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: t(60), duration: t(16)), timelineStart: try t(1), selection: .video(streamIndex: vi))
        let audio = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: t(52)), selection: .audio(.init(channels: [
            .init(streamIndex: ai, channelIndex: 0), .init(streamIndex: ai, channelIndex: 1)], layout: .stereo)))
        let project = Project(settings: try SequenceSettings(width: 128, height: 64, frameRate: rate), assets: [asset], families: [vf, af], tracks: [
            TimelineTrack(familyID: vf.id, template: vt, clips: [upper]),
            TimelineTrack(familyID: vf.id, template: vt, clips: [lower]),
            TimelineTrack(familyID: af.id, template: at, clips: [audio])])
        let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
        var image: CGImage?, displayed: Int64?
        var errors: [String] = []
        backend.display = { image = $0; displayed = $1 }
        backend.failure = { errors.append($0.localizedDescription) }
        let frames: [Int64] = Array(0..<52) + Array((0..<52).reversed()) + [1, 17, 2, 49, 50, 0, 51, 1]
        for frame in frames {
            try await backend.seek(toFrame: frame)
            try require(displayed == frame && image != nil, "Missing requested frame \(frame)")
            let expected: Int64? = (1..<17).contains(frame) ? frame + 59 : ((2..<50).contains(frame) ? frame + 5 : nil)
            var pixels = [UInt8](repeating: 0, count: 128 * 64 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 128 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image!, in: CGRect(x: 0, y: 0, width: 128, height: 64))
            }
            var decoded: Int64 = 0
            for bit in 0..<8 {
                let offset = (32 * 128 + bit * 16 + 8) * 4
                let level = Int(pixels[offset])
                if let expected {
                    let target = expected & (1 << bit) == 0 ? 32 : 224
                    try require(abs(level - target) <= 24, "\(url.lastPathComponent) frame \(frame), stripe \(bit): \(level), expected \(target)")
                    if level > 128 { decoded |= 1 << bit }
                } else { try require(level < 10, "Gap frame \(frame) must be black") }
            }
            if let expected { try require(decoded == expected, "Wrong source frame \(decoded), expected \(expected)") }
        }
        // Seek beyond the end must clamp without losing the fractional final frame.
        try await backend.seek(toFrame: Int64.max)
        try require(displayed == 51, "End clamp must publish last frame")
        try await backend.seek(toFrame: 0)
        try await backend.play()
        try await Task.sleep(for: .milliseconds(250))
        backend.pause()
        try require(backend.position > 0 && !backend.isPlaying && errors.isEmpty, "Live codec transport failed: \(errors)")
        await backend.close()
        print("PASS \(url.lastPathComponent): \(frames.count) decoded seeks, end clamp and live transport at \(rate.value.numerator)/\(rate.value.denominator)")
    }
}
