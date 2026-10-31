import CoreGraphics
import Foundation
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private let ffmpegPath = ProcessInfo.processInfo.environment["AFC_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"

/// Each fixture frame's luma encodes FFmpeg's own frame index n (Y = 16 + 4n), so a
/// rendered picture names the frame on screen. Frames are also compared with
/// FFmpeg's decode of the same index.
private let indexedPicture = "geq=lum='16+4*N':cb=128:cr=128"

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: ffmpegPath),
                             "Requires the local FFmpeg fixture generator (AFC_FFMPEG)."))
@MainActor
struct SourcePlayerTests {
    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProofFailure(String(decoding: details, as: UTF8.self)) }
        return data
    }

    private func fixture(_ name: String, _ arguments: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        _ = try run(arguments + [url.path])
        return url
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// FFmpeg's RGB24 decode of stream frame `index`, scaled like the render surface.
    private func reference(_ url: URL, stream: Int, index: Int, width: Int, height: Int) throws -> [UInt8] {
        [UInt8](try run(["-i", url.path, "-map", "0:\(stream)", "-vf",
            "select=eq(n\\,\(index)),scale=\(width):\(height):flags=bicubic", "-frames:v", "1",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]))
    }

    private func rgb(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw ProofFailure("Cannot read rendered frame") }
        return stride(from: 0, to: pixels.count, by: 4).flatMap { pixels[$0..<$0 + 3] }
    }

    private func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    /// The frame index the luma ramp encodes, read from the frame centre.
    private func shownIndex(_ pixels: [UInt8], width: Int, height: Int) -> Int {
        let centre = ((height / 2) * width + width / 2) * 3
        let gray = Double(pixels[centre + 1])
        return Int(((gray * 219 / 255) / 4).rounded())
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProofFailure("Timed out waiting for the source player") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Seek, then wait for the picture to settle on screen.
    private func settledFrame(_ player: NativeSourcePlayer, seconds: Double) async throws -> CGImage {
        try await player.seek(toSeconds: seconds)
        var last: CGImage?
        player.onFrame = { image in last = image }
        // The restart frame can be presented before or after the seek returns.
        try await Task.sleep(for: .milliseconds(80))
        if last == nil { last = player.frame }
        player.onFrame = nil
        guard let last else { throw ProofFailure("No frame rendered") }
        return last
    }

    private func open(_ media: NativeSourceMedia) async throws -> NativeSourcePlayer {
        let player = NativeSourcePlayer(media: media, audioOutput: false)
        try await player.open()
        try await waitUntil { player.frame != nil || media.videoStreamIndex == nil }
        return player
    }

    private func checkSeeks(_ url: URL, stream: Int, rate: RationalTime, offset: RationalTime = .zero,
                            duration: RationalTime, frames: [Int], audio: Int? = nil) async throws {
        let player = try await open(NativeSourceMedia(url: url, videoStreamIndex: stream, audioStreamIndex: audio,
            frameRate: rate, videoOffset: offset, duration: duration))
        defer { player.close() }
        let frameSeconds = Double(rate.denominator) / Double(rate.numerator)
        for index in frames {
            // Mid-frame targets show the frame covering them, at its own timestamp.
            let requested = offset.seconds + (Double(index) + 0.6) * frameSeconds
            let image = try await settledFrame(player, seconds: requested)
            let pixels = try rgb(image)
            #expect(shownIndex(pixels, width: image.width, height: image.height) == index, "frame \(index)")
            let expected = offset.seconds + Double(index) * frameSeconds
            #expect(abs(player.currentSeconds - expected) < 1e-6, "time of frame \(index): \(player.currentSeconds)")
            // A mark taken here lands on the frame export reads.
            #expect(((player.currentSeconds - offset.seconds) * rate.seconds).rounded() == Double(index))
            let error = meanError(pixels, try reference(url, stream: stream, index: index, width: image.width, height: image.height))
            #expect(error < 3, "frame \(index) mean RGB error \(error)")
        }
    }

    @Test func nutSeeksLandOnFFmpegFrameIndices() async throws {
        let url = try fixture("source.nut", ["-f", "lavfi", "-i", "nullsrc=s=64x36:r=24000/1001:d=2,\(indexedPicture)",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2", "-c:v", "ffv1", "-c:a", "pcm_s16le"])
        defer { remove(url) }
        try await checkSeeks(url, stream: 0, rate: try RationalTime(24000, 1001), duration: try RationalTime(2002, 1000),
                             frames: [0, 30, 7, 47, 12, 13, 12, 0, 46], audio: 1)
    }

    @Test func mxfDNxHRSeeksLandOnFFmpegFrameIndices() async throws {
        let url = try fixture("source.mxf", ["-f", "lavfi", "-i", "nullsrc=s=640x360:r=25:d=2,\(indexedPicture),format=yuv422p",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2",
            "-c:v", "dnxhd", "-profile:v", "dnxhr_lb", "-c:a", "pcm_s24le"])
        defer { remove(url) }
        try await checkSeeks(url, stream: 0, rate: try RationalTime(25), duration: try RationalTime(2),
                             frames: [0, 25, 3, 49, 24, 26, 1], audio: 1)
    }

    /// Video starting 0.5 s after the audio in a file whose clock begins at 10 s:
    /// asset zero is the audio start, and frame n sits at 0.5 + n/25 as in export.
    @Test func streamOffsetsAndContainerOriginMapToAssetTime() async throws {
        let url = try fixture("offset.nut", ["-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2.5",
            "-itsoffset", "0.5", "-f", "lavfi", "-i", "nullsrc=s=64x36:r=25:d=2,\(indexedPicture)",
            "-map", "0", "-map", "1", "-c:a", "pcm_s16le", "-c:v", "ffv1", "-output_ts_offset", "10"])
        defer { remove(url) }
        let probe = try NativeMediaProbe(url: url)
        let video = try #require(probe.streams.first { $0.kind == .video })
        // The muxer starts the picture on its own 1/25 grid after 0.5 s.
        #expect(video.index == 1 && video.timeOffset.seconds > 0.5)
        try await checkSeeks(url, stream: 1, rate: try RationalTime(25), offset: video.timeOffset,
                             duration: probe.duration, frames: [0, 10, 49, 3], audio: 0)
    }

    @Test func clockSnapsToFrameGridAndKeepsAudioTail() throws {
        let clock = NativeSourceClock(origin: 10, offset: 0.5, rate: try RationalTime(25), duration: 3)
        #expect(clock.target(forAsset: 0.5 + 3.9 / 25) == .init(raw: 10.5 + 3.0 / 25, asset: 0.5 + 3.0 / 25, frame: 3))
        // Before the picture starts: its first frame. Exactly on a frame: that frame.
        #expect(clock.target(forAsset: 0.1).frame == 0)
        #expect(clock.target(forAsset: 0.5 + 7.0 / 25).frame == 7)
        // A 1/60000 s clock rounds frame 23 of 24000/1001 half a tick early.
        let ntsc = NativeSourceClock(origin: 0, offset: 0, rate: try RationalTime(24000, 1001), duration: 2)
        #expect(ntsc.target(forAsset: 57557.0 / 60000).frame == 23)
        #expect(ntsc.target(forAsset: 57540.0 / 60000).frame == 22)
        // 2.5 s of picture is 63 frames (the last one partial); later times are audio tail.
        #expect(clock.target(forAsset: 2.99).frame == 62)
        #expect(clock.target(forAsset: 3) == .init(raw: 13, asset: 3, frame: nil))
        #expect(clock.asset(forRaw: 10.25) == 0.25)
        let audioOnly = NativeSourceClock(origin: 0, offset: 0, rate: nil, duration: 2)
        #expect(audioOnly.target(forAsset: 1.234567) == .init(raw: 1.234567, asset: 1.234567, frame: nil))
    }

    @Test func seekPastPictureEndReportsTheRequestedTime() async throws {
        let url = try fixture("tail.nut", ["-f", "lavfi", "-i", "nullsrc=s=64x36:r=25:d=1,\(indexedPicture)",
            "-c:v", "ffv1"])
        defer { remove(url) }
        let player = try await open(NativeSourceMedia(url: url, videoStreamIndex: 0, audioStreamIndex: nil,
            frameRate: try RationalTime(25), duration: try RationalTime(1)))
        defer { player.close() }
        // Out at the asset end is exclusive and stays at the end; the last frame stays on screen.
        let image = try await settledFrame(player, seconds: 1)
        #expect(player.currentSeconds == 1)
        #expect(shownIndex(try rgb(image), width: image.width, height: image.height) == 24)
    }

    /// Audio-first file: picture is ff-index 1, sound streams 0 and 2. Selection
    /// resolves by kind and ff-index, never by enumeration order.
    @Test func explicitStreamIdentityAndRejections() async throws {
        let url = try fixture("streams.nut", ["-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:duration=1",
            "-f", "lavfi", "-i", "nullsrc=s=64x36:r=25:d=1,\(indexedPicture)",
            "-f", "lavfi", "-i", "sine=f=880:sample_rate=48000:duration=1",
            "-map", "0", "-map", "1", "-map", "2", "-c:a", "pcm_s16le", "-c:v", "ffv1"])
        defer { remove(url) }
        let rate = try RationalTime(25), duration = try RationalTime(1)
        let player = try await open(NativeSourceMedia(url: url, videoStreamIndex: 1, audioStreamIndex: 2,
            frameRate: rate, duration: duration))
        #expect(player.selectedTracks == .init(video: 1, audio: 2))
        player.close()
        for (video, audio) in [(0, 2), (1, 1), (3, nil), (nil, 5)] as [(Int?, Int?)] {
            let rejected = NativeSourcePlayer(media: NativeSourceMedia(url: url, videoStreamIndex: video,
                audioStreamIndex: audio, frameRate: rate, duration: duration), audioOutput: false)
            await #expect(throws: NativeSourcePlayer.Failure.self) { try await rejected.open() }
            rejected.close()
        }
        // Sound only.
        let sound = try await open(NativeSourceMedia(url: url, videoStreamIndex: nil, audioStreamIndex: 0,
            frameRate: nil, duration: duration))
        #expect(sound.selectedTracks == .init(video: nil, audio: 1))
        try await sound.seek(toSeconds: 0.5)
        #expect(abs(sound.currentSeconds - 0.5) < 0.001)
        sound.close()
    }

    /// Proxy picture with the original's sound from its own ff-index, aligned by
    /// each file's asset zero although the original's clock starts at 10 s.
    @Test func proxyPictureWithOriginalAudio() async throws {
        let original = try fixture("original.nut", ["-f", "lavfi", "-i", "nullsrc=s=640x360:r=25:d=2,\(indexedPicture)",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2", "-f", "lavfi", "-i", "sine=f=880:sample_rate=48000:duration=2",
            "-map", "0", "-map", "1", "-map", "2", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-output_ts_offset", "10"])
        defer { remove(original) }
        let proxy = try fixture("proxy.mov", ["-i", original.path, "-map", "0:0", "-an",
            "-vf", "scale=320:180:flags=lanczos,setsar=1", "-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le"])
        defer { remove(proxy) }
        let media = try NativeSourceMedia.proxy(url: proxy, frameRate: try RationalTime(25), duration: try RationalTime(2),
                                                original: original, audioStreamIndex: 2)
        #expect(media.videoStreamIndex == 0 && media.externalAudioURL == original)
        let player = try await open(media)
        defer { player.close() }
        #expect(player.selectedTracks == .init(video: 1, audio: 2))
        for index in [0, 31, 5, 49] {
            let image = try await settledFrame(player, seconds: (Double(index) + 0.5) / 25)
            #expect(image.width == 320 && image.height == 180)
            #expect(shownIndex(try rgb(image), width: image.width, height: image.height) == index)
            #expect(abs(player.currentSeconds - Double(index) / 25) < 1e-6, "frame \(index): \(player.currentSeconds)")
        }
        #expect(player.audioDelay == -10)
    }

    /// Diagnostic, not a parity claim: MPV's software render of tagged BT.709 colour
    /// against FFmpeg's own RGB conversion of the same decoded frame.
    @Test func colourAgainstFFmpegConversion() async throws {
        for (name, filter, tags) in [
            ("bars709", "smptehdbars=s=1280x720:r=25:d=1", ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]),
            ("ramp709", "testsrc2=s=1280x720:r=25:d=1", ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]),
            ("bars601", "smptebars=s=640x480:r=25:d=1", ["-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m"])] {
            let url = try fixture("\(name).nut", ["-f", "lavfi", "-i", "\(filter),format=yuv422p", "-c:v", "ffv1"] + tags)
            defer { remove(url) }
            let player = try await open(NativeSourceMedia(url: url, videoStreamIndex: 0, audioStreamIndex: nil,
                frameRate: try RationalTime(25), duration: try RationalTime(1)))
            let image = try await settledFrame(player, seconds: 0.4)
            player.close()
            let actual = try rgb(image)
            let matrix = tags[1] == "bt709" ? "bt709" : "smpte170m"
            let expected = [UInt8](try run(["-i", url.path, "-vf",
                "select=eq(n\\,10),scale=\(image.width):\(image.height):in_color_matrix=\(matrix):in_range=tv:out_range=pc:flags=bicubic+accurate_rnd+full_chroma_int",
                "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]))
            let errors = zip(actual, expected).map { abs(Int($0) - Int($1)) }
            let mean = Double(errors.reduce(0, +)) / Double(max(1, errors.count))
            let peak = errors.max() ?? 0
            let over = errors.filter { $0 > 32 }.count
            // Pixels whose 5×5 reference neighbourhood is one colour: away from chroma edges.
            let w = image.width, h = image.height
            var flat: [Int] = []
            for y in stride(from: 2, to: h - 2, by: 3) { for px in stride(from: 2, to: w - 2, by: 3) {
                let centre = (y * w + px) * 3
                var uniform = true
                for dy in -2...2 where uniform { for dx in -2...2 where uniform {
                    let other = ((y + dy) * w + px + dx) * 3
                    for c in 0..<3 where expected[other + c] != expected[centre + c] { uniform = false }
                } }
                if uniform { flat.append(contentsOf: errors[centre..<centre + 3]) }
            } }
            let flatMean = Double(flat.reduce(0, +)) / Double(max(1, flat.count))
            print("colour \(name) \(w)x\(h): mean \(mean) peak \(peak) components>32 \(over) of \(errors.count); flat areas mean \(flatMean) peak \(flat.max() ?? 0) over \(flat.count / 3) pixels")
            #expect(actual.count == expected.count)
            // The matrix and range agree; differences sit on chroma edges (upsampling filter).
            #expect(mean < 3 && flatMean < 1.5 && (flat.max() ?? 0) <= 4, "\(name)")
        }
    }

    @Test func playPauseSupersedeAndRepeatedClose() async throws {
        let url = try fixture("play.nut", ["-f", "lavfi", "-i", "nullsrc=s=64x36:r=25:d=2,\(indexedPicture)",
            "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=2", "-c:v", "ffv1", "-c:a", "pcm_s16le"])
        defer { remove(url) }
        let media = NativeSourceMedia(url: url, videoStreamIndex: 0, audioStreamIndex: 1,
            frameRate: try RationalTime(25), duration: try RationalTime(2))
        let player = try await open(media)
        player.play()
        #expect(player.isPlaying)
        try await waitUntil { player.currentSeconds > 0.2 }
        player.pause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!player.isPlaying)
        // After a pause the reported time names the frame on screen.
        let paused = try #require(player.frame)
        #expect(shownIndex(try rgb(paused), width: paused.width, height: paused.height)
                == Int((player.currentSeconds * 25).rounded()), "paused at \(player.currentSeconds)")
        // A newer seek supersedes an unfinished one; only the last lands.
        let first = Task { try await player.seek(toSeconds: 0.3) }
        let second = Task { try await player.seek(toSeconds: 1.2) }
        _ = await first.result
        if case .failure(let error) = await second.result { Issue.record("Latest seek failed: \(error)") }
        #expect(abs(player.currentSeconds - 1.2) < 1e-6)
        // Playing to the end pauses on the last frame.
        try await player.seek(toSeconds: 1.8)
        player.play()
        try await waitUntil { !player.isPlaying }
        #expect(player.currentSeconds > 1.9)
        await player.closeAndWait()
        player.close()
        await #expect(throws: NativeSourcePlayer.Failure.closed) { try await player.seek(toSeconds: 0) }
        // Many quick open/close cycles release every core.
        for _ in 0..<6 {
            let cycle = NativeSourcePlayer(media: media, audioOutput: false)
            try await cycle.open()
            try await cycle.seek(toSeconds: 0.4)
            await cycle.closeAndWait()
        }
    }
}
