import AppKit
import AVFoundation
import EditorCore
import NativePlaybackRuntime

enum SourceSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { message } else { "" } }
}

/// The app's Source viewer with the native runtime: AVFoundation for what it plays,
/// libmpv for unconverted FFmpeg imports and for proxy picture with their sound.
/// Fixture frames encode FFmpeg's frame index n in their luma (Y = 16 + 4n).
@main struct SourceViewerNativeSmoke {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw SourceSmokeFailure.failed(message()) }
        print("ok - \(message())")
    }

    static func waitUntil(_ what: String, timeout: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SourceSmokeFailure.failed("Timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func mpv(_ store: EditorStore) -> MPVSourceBackend? { store.sourcePlayback as? MPVSourceBackend }

    /// The frame index on screen, from the centre pixel's luma.
    @MainActor static func shownFrame(_ player: NativeSourcePlayer) throws -> Int {
        guard let image = player.frame else { throw SourceSmokeFailure.failed("No MPV frame rendered") }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { throw SourceSmokeFailure.failed("Cannot read MPV frame") }
        return Int(((Double(pixel[1]) * 219 / 255) / 4).rounded())
    }

    /// Waits for the transport to settle at `seconds` and its frame to reach the screen.
    @MainActor static func settle(_ store: EditorStore, at seconds: Double, frame: Int, _ what: String) async throws {
        guard let backend = mpv(store) else { throw SourceSmokeFailure.failed("\(what): MPV backend not installed") }
        try await waitUntil("\(what) position") { abs((store.sourcePlayback?.currentTime.seconds ?? -1) - seconds) < 1e-6 }
        try await waitUntil("\(what) frame \(frame)") { (try? shownFrame(backend.player)) == frame }
        try check(true, "\(what): frame \(frame) on screen at \(seconds) s")
    }

    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        let ffprobe = URL(fileURLWithPath: CommandLine.arguments[3])
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        let converter = MediaConversionService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe, outputDirectory: file("converted"))
        func importUnconverted(_ name: String) async throws -> ImportedMedia {
            var converted = false
            let imported = try await MediaImporter.inspectOrConvert(url: file(name), using: converter) { converted = true }
            try check(!converted, "\(name) imports unconverted")
            return imported
        }

        let store = EditorStore()
        defer { store.close() }

        // 1. AVFoundation keeps everything it plays.
        let movie = try await importUnconverted("h264.mov")
        try store.registerImportedMedia(movie)
        try await waitUntil("AVFoundation backend") { store.sourcePlayback != nil }
        try check(store.sourcePlayback is AVFoundationSourceBackend && store.sourcePlayer != nil, "H.264 MOV uses AVPlayer")

        // 2. NUT and MXF originals play through libmpv on FFmpeg's frame grid.
        for (name, rate) in [("ffv1-pcm.nut", 25.0), ("dnxhr-pcm.mxf", 25.0), ("ffv1-2398.nut", 24000.0 / 1001)] {
            let imported = try await importUnconverted(name)
            try store.registerImportedMedia(imported)
            try await waitUntil("\(name) MPV backend") { mpv(store) != nil }
            let backend = mpv(store)!
            try check(store.sourcePlayer == nil && store.previewImage == nil, "\(name): libmpv replaces the single native frame")
            try check(store.proxyPlaybackMessage == "HiRes source · native playback", "\(name): \(store.proxyPlaybackMessage)")
            let audio = imported.asset.streams.first { $0.kind == .audio }?.index
            try check(backend.player.media.audioStreamIndex == audio && backend.player.selectedTracks?.audio == 1,
                      "\(name): sound is FFmpeg stream \(String(describing: audio))")
            try await settle(store, at: 0, frame: 0, "\(name) opens")
            let frame = 1 / rate
            store.seekSource(toSeconds: 13.6 * frame)
            try await settle(store, at: 13 * frame, frame: 13, "\(name) scrub mid-frame")
            store.markSource(inPoint: true)
            store.stepSource(frames: 10)
            try await settle(store, at: 23 * frame, frame: 23, "\(name) step 10 frames")
            store.markSource(inPoint: false)
            let range = store.sourceRanges[imported.asset.id]
            guard let rateValue = imported.asset.streams.first(where: { $0.kind == .video })?.videoFormat?.frameRate.value else {
                throw SourceSmokeFailure.failed("\(name): no proven frame rate")
            }
            try check(range?.start == (try RationalTime(13).divided(by: rateValue))
                      && (try? range?.end()) == (try RationalTime(23).divided(by: rateValue)),
                      "\(name): marks are source frames 13..<23 (\(String(describing: range)))")
            store.stepSource(frames: -1)
            try await settle(store, at: 22 * frame, frame: 22, "\(name) step back")
            store.playSourceForwards()
            try await waitUntil("\(name) plays") { (store.sourcePlayback?.currentTime.seconds ?? 0) > 22 * frame + 0.15 }
            store.pauseSource()
            try await Task.sleep(for: .milliseconds(200))
            let paused = store.sourcePlayback!.currentTime.seconds
            try check(!store.sourcePlayback!.isPlaying && (try shownFrame(backend.player)) == Int((paused * rate).rounded()),
                      "\(name): paused time \(paused) names the frame on screen")
            store.playSourceBackwards()
            try await Task.sleep(for: .milliseconds(250))
            store.pauseSource()
            try await Task.sleep(for: .milliseconds(150))
            try check(store.sourcePlayback!.currentTime.seconds < paused, "\(name): reverse transport moves back")
            store.seekSource(toSeconds: imported.asset.duration.seconds)
            try await waitUntil("\(name) end") { abs((store.sourcePlayback?.currentTime.seconds ?? 0) - imported.asset.duration.seconds) < 1e-6 }
            store.markSource(inPoint: false)
            try check((try? store.sourceRanges[imported.asset.id]?.end()) == imported.asset.duration, "\(name): Out at the end is the asset end")
        }

        // 3. Switching assets closes the previous libmpv player.
        let previous = mpv(store)!
        store.selectAsset(movie.asset.id)
        try await waitUntil("switch back to AVFoundation") { store.sourcePlayback is AVFoundationSourceBackend }
        do { try await previous.player.seek(toSeconds: 0); throw SourceSmokeFailure.failed("Replaced player still seeks") }
        catch NativeSourcePlayer.Failure.closed { try check(true, "Replaced libmpv player is closed") }

        // 4. Proxy picture with the original's sound, and back to the original.
        guard let nut = store.project.assets.first(where: { $0.name == "ffv1-pcm.nut" }) else { throw SourceSmokeFailure.failed("NUT asset") }
        store.selectAsset(nut.id)
        try await waitUntil("NUT reselected") { mpv(store) != nil }
        let service = ProxyGenerationService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe)
        let proxy = try await service.generate(asset: nut, preset: .proResProxy, scaleDivisor: 2, to: file("nut-proxy.mov"))
        try store.registerProxy(proxy, for: nut, epoch: store.mediaEpoch, sourceRevision: nil)
        try await waitUntil("original after proxy registration") { mpv(store)?.player.media.url == nut.originalURL }
        store.seekSource(toSeconds: 31.2 / 25)
        try await settle(store, at: 31 / 25, frame: 31, "NUT before proxy switch")
        store.setPlaybackRepresentation(.proxy)
        try await waitUntil("proxy MPV backend") { mpv(store)?.player.media.url == proxy.url }
        let proxyPlayer = mpv(store)!.player
        try check(proxyPlayer.media.externalAudioURL == nut.originalURL && proxyPlayer.media.audioStreamIndex == 1
                  && proxyPlayer.selectedTracks?.audio == 1,
                  "Proxy picture plays with the original's FFmpeg audio stream 1")
        try check(store.proxyPlaybackMessage == "Proxy picture · original audio · native playback", store.proxyPlaybackMessage)
        try await settle(store, at: 31 / 25, frame: 31, "Proxy switch preserves the paused frame")
        try check(proxyPlayer.frame?.width == proxy.width, "Proxy picture is the proxy raster (\(proxy.width) wide)")
        store.stepSource(frames: 5)
        try await settle(store, at: 36 / 25, frame: 36, "Proxy steps on the original frame grid")
        store.setPlaybackRepresentation(.original)
        try await waitUntil("original MPV backend") { mpv(store)?.player.media.url == nut.originalURL }
        try await settle(store, at: 36 / 25, frame: 36, "HiRes switch preserves the frame")

        store.close()
        try check(store.sourcePlayback == nil, "Closing releases the source player")
        await proxyPlayer.closeAndWait()
    }
}
