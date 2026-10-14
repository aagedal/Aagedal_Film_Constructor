import AVFoundation
import AppKit
import EditorCore

@main struct SystemSequenceSmoke {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SystemSequenceSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = AVURLAsset(url: url)
        let tracks = try await source.load(.tracks)
        let vi = tracks.firstIndex { $0.mediaType == .video }!
        let ai = tracks.firstIndex { $0.mediaType == .audio }!
        let asset = MediaAsset(name: "Fixture", originalURL: url, duration: try RationalTime(2), streams: [
            MediaStream(index: vi, kind: .video), MediaStream(index: ai, kind: .audio, audioLayout: .stereo)])
        let videoTemplate = TrackTemplate(kind: .video)
        let audioTemplate = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.5)
        let vf = TrackFamily(baseName: "Video", template: videoTemplate)
        let af = TrackFamily(baseName: "Audio", template: audioTemplate)
        let range = try TimeRange(start: .zero, duration: RationalTime(2))
        let lower = TimelineClip(assetID: asset.id, sourceRange: range, selection: .video(streamIndex: vi))
        let upper = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1), duration: RationalTime(1, 2)),
            timelineStart: try RationalTime(1, 2), selection: .video(streamIndex: vi))
        let audio = TimelineClip(assetID: asset.id, sourceRange: range, timelineStart: try RationalTime(1, 2),
            selection: .audio(.init(channels: [.init(streamIndex: ai, channelIndex: 0), .init(streamIndex: ai, channelIndex: 1)], layout: .stereo)),
            fadeIn: .init(duration: try RationalTime(1, 2), curve: .equalPower), fadeOut: .init(duration: try RationalTime(1, 2), curve: .equalPower))
        let project = Project(settings: try SequenceSettings(width: 80, height: 48, frameRate: FrameRate(24)), assets: [asset], families: [vf, af], tracks: [
            TimelineTrack(familyID: vf.id, template: videoTemplate, clips: [upper]),
            TimelineTrack(familyID: vf.id, template: videoTemplate, clips: [lower]),
            TimelineTrack(familyID: af.id, template: audioTemplate, clips: [audio])])
        let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
        var image: CGImage?
        var displayed: Int64?
        backend.display = { image = $0; displayed = $1 }
        var errors: [String] = []
        backend.failure = { errors.append($0.localizedDescription) }
        func pixel(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { ptr in
                let context = CGContext(data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        for (frame, color) in [(0, "red"), (18, "blue"), (6, "red"), (24, "blue"), (54, "black"), (18, "blue")] {
            do { try await backend.seek(toFrame: Int64(frame)) }
            catch { throw NSError(domain: "Seek frame \(frame): \(error)", code: 1) }
            try require(displayed == Int64(frame) && image != nil, "Seek must publish requested frame")
            let p = pixel(image!)
            if color == "red" { try require(p[0] > 180 && p[2] < 40, "Wrong trimmed/layered red frame: \(p)") }
            if color == "blue" { try require(p[2] > 180 && p[0] < 40, "Wrong trimmed/layered blue frame: \(p)") }
            if color == "black" { try require(p[0] < 10 && p[1] < 10 && p[2] < 10, "Video gap must be black: \(p)") }
        }
        try require(backend.previewQualificationNotice == "Curved or overlapping audio fades are approximate in system preview.",
            "PCM nonlinear fades must retain one qualification notice across repeated seeks")
        try await backend.seek(toFrame: 0)
        try await backend.play()
        try await Task.sleep(for: .milliseconds(350))
        backend.pause()
        try require(backend.position > 0 && !backend.isPlaying && errors.isEmpty, "Live play/pause must advance the player clock without errors: \(errors)")
        let paused = backend.position
        try await Task.sleep(for: .milliseconds(80))
        try require(abs(backend.position - paused) < 0.001, "Pause must hold position")
        await backend.close()
        try require(!backend.isPlaying, "Close must stop output")
        var fractional = project
        fractional.settings = try SequenceSettings(width: 80, height: 48, frameRate: FrameRate(30000, 1001))
        let fractionalBackend = try AVFoundationSequenceBackend(project: fractional, videoProxies: [:])
        var fractionalFrame: Int64?
        fractionalBackend.display = { _, frame in fractionalFrame = frame }
        for frame: Int64 in [1, 2, 29, 1] {
            try await fractionalBackend.seek(toFrame: frame)
            try require(fractionalFrame == frame, "Fractional seek must preserve frame identity")
        }
        await fractionalBackend.close()
        // Nine 24000/1001 frames round to slightly more than nine in Double.
        // End clamping must still select frame eight, not an out-of-range frame nine.
        var short = project
        short.settings.frameRate = try FrameRate(24000, 1001)
        short.tracks = [project.tracks[2]]
        short.tracks[0].clips[0].timelineStart = .zero
        short.tracks[0].clips[0].sourceRange = try TimeRange(start: .zero, duration: short.settings.frameRate.time(forFrames: 9))
        short.tracks[0].clips[0].fadeIn = .init(); short.tracks[0].clips[0].fadeOut = .init()
        let shortBackend = try AVFoundationSequenceBackend(project: short, videoProxies: [:])
        var shortFrame: Int64?
        shortBackend.display = { _, frame in shortFrame = frame }
        try await shortBackend.seek(toFrame: Int64.max)
        try require(shortFrame == 8, "Exact fractional end clamp must not invent a tenth frame")
        try require(shortBackend.previewQualificationNotice == nil, "Unaffected PCM media must clear the fade notice")
        await shortBackend.close()
        short.tracks[0].clips[0].fadeIn = .init(duration: try RationalTime(47, 48_000), curve: .equalPower)
        let tinyFadeBackend = try AVFoundationSequenceBackend(project: short, videoProxies: [:])
        _ = try await tinyFadeBackend.makePlayerItem()
        try require(tinyFadeBackend.previewQualificationNotice?.contains("Very short audio fades") == true,
            "Sub-5-ms fades must disclose the measured system rendering limitation")
        await tinyFadeBackend.close()
        var unsupported = project
        unsupported.tracks[2].template.routing.outputChannels = [1, 0]
        let rejected = try AVFoundationSequenceBackend(project: unsupported, videoProxies: [:])
        do { try await rejected.seek(toFrame: 0); throw NSError(domain: "Expected routing rejection", code: 1) }
        catch { try require(error.localizedDescription.contains("routing"), "Unsupported channel mapping must fail visibly") }
        await rejected.close()
        let controller = SequencePlaybackController()
        try require(controller.available, "Normal builds must enable system sequence preview")
        controller.activate(project: project, seconds: 100)
        for _ in 0..<1000 {
            if !controller.isPreparing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(controller.image != nil && controller.displayedFrameIndex == 59,
            "Scrubbing beyond the sequence end must display the clamped last frame: \(controller.message)")
        controller.deactivate()
        print("System sequence smoke passed: decoded trims, overlap precedence, reverse/fractional seeks, black gaps, live transport, end scrub/exact fractional end clamp, cleanup and routing rejection.")
    }
}
