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
                    space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
            // Read in the frame's own colour space, ramps and solid colours agree closely.
            try require(difference <= 8, "Preview frame \(frame) differs from export: \(actual) vs \(expected)")
        }
        let middle = try reference(36)
        try require(abs(middle[0] - middle[2]) < 30 && middle[0] > 90, "Dissolve midpoint must blend red and blue: \(middle)")
        await backend.close()
        print("PASS system transition preview matches export")

        // Picture in picture: half-size red inset, offset right and down, at 60% opacity over blue.
        let inset = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)),
                                 selection: .video(streamIndex: vi), transform: PictureTransform(scale: 0.5, offsetX: 0.25, offsetY: 0.25, opacity: 0.6))
        let below = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(3), duration: RationalTime(1)), selection: .video(streamIndex: vi))
        let pip = Project(settings: base.settings, assets: [asset], families: [family], tracks: [
            TimelineTrack(familyID: family.id, template: template, clips: [inset]),
            TimelineTrack(familyID: family.id, template: template, clips: [below])])
        let pipOutput = directory.appendingPathComponent("pip.mov")
        _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: pip), outputURL: pipOutput).arguments)
        let pipBackend = try AVFoundationSequenceBackend(project: pip, videoProxies: [:])
        pipBackend.display = { displayed, _ in image = displayed }
        try await pipBackend.seek(toFrame: 12)
        for (x, y) in [(60, 36), (10, 10), (30, 18), (78, 46)] {
            let data = try run(ffmpeg, ["-hide_banner", "-i", pipOutput.path, "-vf", "select=eq(n\\,12),crop=2:2:\(x):\(y)",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            let expected = data.prefix(3).map(Int.init)
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { pointer in
                let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: image!.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .none
                context.draw(image!, in: CGRect(x: -x, y: -(image!.height - 1 - y), width: image!.width, height: image!.height))
            }
            let actual = bytes.prefix(3).map(Int.init)
            print("pip (\(x),\(y)): export \(expected) preview \(actual)")
            try require(zip(expected, actual).allSatisfy { abs($0 - $1) <= 8 }, "Picture in picture preview differs at (\(x),\(y))")
        }
        await pipBackend.close()
        print("PASS picture in picture preview matches export")

        // Colour correction switches the preview to the CoreImage compositor: repeat the dissolve
        // and fades with a brighter, half-saturated first shot, and a greyed picture in picture.
        var coloured = engine.project
        coloured.tracks[0].clips[coloured.tracks[0].clips.firstIndex { $0.id == a.id }!].color = ColorAdjustment(brightness: 0.1, saturation: 0.5)
        var colouredPip = pip
        colouredPip.tracks[0].clips[0].color = ColorAdjustment(brightness: 0.2, contrast: 1.2, saturation: 0)
        for (name, candidate, frames, points) in [("dissolve", coloured, [0, 6, 12, 30, 36, 42, 60, 71], [(40, 24)]),
                                                  ("pip", colouredPip, [12], [(60, 36), (10, 10), (78, 46)])] {
            let colourOutput = directory.appendingPathComponent("colour-\(name).mov")
            _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: candidate), outputURL: colourOutput).arguments)
            let colourBackend = try AVFoundationSequenceBackend(project: candidate, videoProxies: [:])
            colourBackend.display = { displayed, _ in image = displayed }
            for frame in frames {
                try await colourBackend.seek(toFrame: Int64(frame))
                for (x, y) in points {
                    let data = try run(ffmpeg, ["-hide_banner", "-i", colourOutput.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:\(x):\(y)",
                                                "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
                    let expected = data.prefix(3).map(Int.init)
                    var bytes = [UInt8](repeating: 0, count: 4)
                    bytes.withUnsafeMutableBytes { pointer in
                        let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: image!.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.interpolationQuality = .none
                        context.draw(image!, in: CGRect(x: -x, y: -(image!.height - 1 - y), width: image!.width, height: image!.height))
                    }
                    let actual = bytes.prefix(3).map(Int.init)
                    print("colour \(name) frame \(frame) (\(x),\(y)): export \(expected) preview \(actual)")
                    try require(zip(expected, actual).allSatisfy { abs($0 - $1) <= 8 }, "Colour preview differs: \(name) frame \(frame)")
                }
            }
            await colourBackend.close()
        }
        print("PASS colour correction preview matches export")

        // Speed: a 50% clip of a ramp whose frame n has luma 16 + 3n shows the same source
        // frame in preview and export.
        let ramp = directory.appendingPathComponent("ramp.mov")
        _ = try run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "nullsrc=s=80x48:r=24:d=4,geq=lum='16+3*N':cb=128:cr=128,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709",
                             "-c:v", "prores_ks", "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", ramp.path])
        let rampTracks = try await AVURLAsset(url: ramp).load(.tracks)
        let rampAsset = MediaAsset(name: "Ramp", originalURL: ramp, duration: try RationalTime(4),
                                   streams: [MediaStream(index: rampTracks.firstIndex { $0.mediaType == .video }!, kind: .video)])
        var slow = Project(settings: base.settings, assets: [rampAsset])
        let slowIDs = try slow.appendAsset(rampAsset.id, at: .zero, sourceRange: TimeRange(start: RationalTime(1, 2), duration: RationalTime(1)))
        var slowEngine = try TimelineEditEngine(project: slow)
        try slowEngine.apply(.setSpeed(clipID: slowIDs[0], speed: RationalTime(1, 2)))
        slow = slowEngine.project
        let slowOutput = directory.appendingPathComponent("slow.mov")
        _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: slow), outputURL: slowOutput).arguments)
        let slowBackend = try AVFoundationSequenceBackend(project: slow, videoProxies: [:])
        slowBackend.display = { displayed, _ in image = displayed }
        for frame in [0, 1, 2, 3, 6, 12, 24, 36, 47] {
            try await slowBackend.seek(toFrame: Int64(frame))
            let data = try run(ffmpeg, ["-hide_banner", "-i", slowOutput.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:40:24",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            let expected = Int(data[0])
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { pointer in
                // Read the frame in its own colour space, without a display conversion.
                let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: image!.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image!, in: CGRect(x: -40, y: -23, width: image!.width, height: image!.height))
            }
            print("speed 50% frame \(frame): export \(expected) preview \(bytes[0])")
            // One source frame is about 3.5 levels.
            try require(abs(expected - Int(bytes[0])) <= 8, "Retimed preview shows another source frame at \(frame)")
        }
        await slowBackend.close()
        print("PASS speed preview matches export")

        // Animated picture in picture: red grows from 25% on the left to 50% on the right over
        // one second, through the system compositor and (with colour) the CoreImage compositor.
        var animated = pip
        animated.tracks[0].clips[0].transform = .identity
        animated.tracks[0].clips[0].transformKeyframes = [TransformKeyframe(time: .zero, scale: 0.25, offsetX: -0.25),
                                                          TransformKeyframe(time: try RationalTime(1), scale: 0.5, offsetX: 0.25)]
        var animatedColour = animated
        animatedColour.tracks[0].clips[0].color = ColorAdjustment(brightness: 0.01)
        for (name, candidate) in [("system", animated), ("coreimage", animatedColour)] {
            let animatedOutput = directory.appendingPathComponent("animated-\(name).mov")
            _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: candidate), outputURL: animatedOutput).arguments)
            let animatedBackend = try AVFoundationSequenceBackend(project: candidate, videoProxies: [:])
            animatedBackend.display = { displayed, _ in image = displayed }
            /// Centre and width of red on the middle row, in frame fractions.
            func span(_ row: [(Int, Int, Int)]) -> (Double, Double) {
                let red = row.indices.filter { row[$0].0 > 128 && row[$0].2 < 128 }
                guard let first = red.first, let last = red.last else { return (0, 0) }
                return ((Double(first + last) / 2 + 0.5) / Double(row.count), Double(last - first + 1) / Double(row.count))
            }
            for frame in [0, 12, 23] {
                let data = try run(ffmpeg, ["-hide_banner", "-i", animatedOutput.path, "-vf", "select=eq(n\\,\(frame)),crop=80:1:0:24",
                                            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
                let exported = span(stride(from: 0, to: data.count, by: 3).map { (Int(data[$0]), Int(data[$0 + 1]), Int(data[$0 + 2])) })
                try await animatedBackend.seek(toFrame: Int64(frame))
                var bytes = [UInt8](repeating: 0, count: 80 * 4)
                bytes.withUnsafeMutableBytes { pointer in
                    let context = CGContext(data: pointer.baseAddress, width: 80, height: 1, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                        space: image!.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.interpolationQuality = .none
                    context.draw(image!, in: CGRect(x: 0, y: -23, width: image!.width, height: image!.height))
                }
                let previewed = span(stride(from: 0, to: bytes.count, by: 4).map { (Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2])) })
                print("animated \(name) frame \(frame): export \(exported) preview \(previewed)")
                try require(abs(exported.0 - previewed.0) < 0.04 && abs(exported.1 - previewed.1) < 0.04, "Animated placement differs at \(frame)")
            }
            await animatedBackend.close()
        }
        print("PASS animated placement preview matches export")

        // A push: halfway through, the red shot fills the left half and the blue shot the right.
        var pushEngine = try TimelineEditEngine(project: base)
        try pushEngine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .linear, style: .pushLeft))
        let pushed = pushEngine.project
        let pushOutput = directory.appendingPathComponent("push.mov")
        _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: pushed), outputURL: pushOutput).arguments)
        let pushBackend = try AVFoundationSequenceBackend(project: pushed, videoProxies: [:])
        pushBackend.display = { displayed, _ in image = displayed }
        func redShare(_ row: [(Int, Int, Int)]) -> Double { Double(row.filter { $0.0 > 128 && $0.2 < 128 }.count) / Double(row.count) }
        for frame in [30, 36, 42] {
            let data = try run(ffmpeg, ["-hide_banner", "-i", pushOutput.path, "-vf", "select=eq(n\\,\(frame)),crop=80:1:0:24",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            let exported = redShare(stride(from: 0, to: data.count, by: 3).map { (Int(data[$0]), Int(data[$0 + 1]), Int(data[$0 + 2])) })
            try await pushBackend.seek(toFrame: Int64(frame))
            var bytes = [UInt8](repeating: 0, count: 80 * 4)
            bytes.withUnsafeMutableBytes { pointer in
                let context = CGContext(data: pointer.baseAddress, width: 80, height: 1, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                    space: image!.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image!, in: CGRect(x: 0, y: -23, width: image!.width, height: image!.height))
            }
            let previewed = redShare(stride(from: 0, to: bytes.count, by: 4).map { (Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2])) })
            print("push frame \(frame): red share export \(exported) preview \(previewed)")
            try require(abs(exported - previewed) < 0.05, "Push preview differs at \(frame)")
            if frame == 36 { try require(abs(exported - 0.5) < 0.05, "Halfway through the push") }
        }
        await pushBackend.close()
        print("PASS push transition preview matches export")

        // Volume keyframes: full level until source 1 s, then down to a quarter by source 2 s.
        let tone = directory.appendingPathComponent("tone.mov")
        _ = try run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=4",
                             "-ac", "2", "-c:a", "pcm_s24le", tone.path])
        let toneTracks = try await AVURLAsset(url: tone).load(.tracks)
        let ai = toneTracks.firstIndex { $0.mediaType == .audio }!
        let toneAsset = MediaAsset(name: "Tone", originalURL: tone, duration: try RationalTime(4), streams: [MediaStream(index: ai, kind: .audio, audioLayout: .stereo)])
        let audioTemplate = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let audioFamily = TrackFamily(baseName: "Audio", template: audioTemplate)
        let sound = TimelineClip(assetID: toneAsset.id, sourceRange: try TimeRange(start: RationalTime(1, 2), duration: RationalTime(3)),
                                 selection: .audio(.init(channels: [.init(streamIndex: ai, channelIndex: 0), .init(streamIndex: ai, channelIndex: 1)], layout: .stereo)),
                                 volumeKeyframes: [VolumeKeyframe(time: try RationalTime(1), gain: 1), VolumeKeyframe(time: try RationalTime(2), gain: 0.25)])
        let automated = Project(settings: base.settings, assets: [toneAsset], families: [audioFamily],
                                tracks: [TimelineTrack(familyID: audioFamily.id, template: audioTemplate, clips: [sound])])
        let audioBackend = try AVFoundationSequenceBackend(project: automated, videoProxies: [:])
        let item = try await audioBackend.makePlayerItem()
        let reader = try AVAssetReader(asset: item.asset)
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: try await item.asset.loadTracks(withMediaType: .audio),
            audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
        mixOutput.audioMix = item.audioMix
        reader.add(mixOutput); reader.startReading()
        var mixed: [Float] = []
        while let buffer = mixOutput.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0; var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer!.withMemoryRebound(to: Float.self, capacity: length / 4) { mixed += UnsafeBufferPointer(start: $0, count: length / 4) }
        }
        func level(_ seconds: Double) -> Double {
            let start = (Int(seconds * 48000) - 480) * 2
            let window = mixed[start..<(start + 1920)]
            return (window.reduce(0) { $0 + Double($1 * $1) } / Double(window.count)).squareRoot()
        }
        let reference = level(0.2)
        print("automation levels: \(level(0.2)) \(level(1.0)) \(level(2.2))")
        try require(abs(level(1.0) / reference - 0.625) < 0.03 && abs(level(2.2) / reference - 0.25) < 0.03,
                    "Preview follows volume keyframes")
        // The mixer's post-fader meter heard the tone on its track (1/8 amplitude ≈ −18 dBFS).
        AudioMeters.shared.poll()
        let meter = AudioMeters.shared.levels[automated.tracks[0].id] ?? -120
        print("meter level: \(meter) dBFS")
        try require(meter > -30 && meter < -10, "The track meter reports the tone")
        await audioBackend.close()
        print("PASS volume keyframes in preview and track meter")
    }
}
