import AVFoundation
import AppKit
import EditorCore
import ImageIO
import UniformTypeIdentifiers

@main struct SystemStillSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SystemStillSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let videoURL = directory.appendingPathComponent("fixture.mov")
        func fixture(_ name: String, alpha: CGFloat = 1, orientation: Int = 1, width: Int = 40, height: Int = 20) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, alpha])!)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 1, 0, alpha])!)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
            let type = name.hasSuffix("jpg") ? UTType.jpeg : .png
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "Create still fixture")
            return url
        }
        let png = try fixture("opaque.png")
        let transparent = try fixture("alpha.png", alpha: 0.5)
        let jpeg = try fixture("oriented.jpg", orientation: 6)
        let video = AVURLAsset(url: videoURL)
        let vi = try await video.load(.tracks).firstIndex { $0.mediaType == .video }!
        let family = TrackFamily(baseName: "Picture", template: TrackTemplate(kind: .video))
        let template = family.template
        let settings = try SequenceSettings(width: 80, height: 48, frameRate: FrameRate(24))
        let picture = MediaAsset(name: "Video", originalURL: videoURL, duration: try RationalTime(2), streams: [MediaStream(index: vi, kind: .video)])
        let base = TimelineClip(assetID: picture.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)), selection: .video(streamIndex: vi))
        func project(url: URL, mode: ScalingMode, lower: Bool = false) throws -> Project {
            let still = MediaAsset(name: url.lastPathComponent, originalURL: url, duration: try RationalTime(5), streams: [])
            // Synthetic source In is intentionally nonzero; it must not seek into the short prepared movie.
            let clip = TimelineClip(assetID: still.id, sourceRange: try TimeRange(start: RationalTime(3), duration: RationalTime(1, 2)),
                timelineStart: try RationalTime(1, 2), selection: .still, scalingMode: mode)
            var tracks = [TimelineTrack(familyID: family.id, template: template, clips: [clip])]
            if lower { tracks.append(TimelineTrack(familyID: family.id, template: template, clips: [base])) }
            return Project(settings: settings, assets: [still, picture], families: [family], tracks: tracks)
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
            var bytes = [UInt8](repeating: 0, count: 80 * 48 * 4)
            bytes.withUnsafeMutableBytes { ptr in
                let context = CGContext(data: ptr.baseAddress, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 320,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 48))
            }
            return (0..<3).map { Int(bytes[(y * 80 + x) * 4 + $0]) }
        }
        var decoded = 0
        for mode: ScalingMode in [.fit, .fill, .none] {
            let backend = try AVFoundationSequenceBackend(project: project(url: png, mode: mode), videoProxies: [:])
            var image: CGImage?
            var displayed: Int64?
            backend.display = { image = $0; displayed = $1 }
            for frame: Int64 in [0, 12, 23, 11, 18, 12] {
                try await backend.seek(toFrame: frame)
                try require(displayed == frame && image != nil, "Still seek publishes exact frame")
                let p = pixel(image!, 30, 24)
                if frame < 12 { try require(p.allSatisfy { $0 < 8 }, "Leading gap is black: \(p)") }
                else {
                    try require(p[0] > 230 && p[1] < 20 && p[2] < 20, "Still hold is red at \(mode) / \(frame): \(p)")
                    let edge = pixel(image!, 5, 24)
                    if mode == .none { try require(edge.allSatisfy { $0 < 8 }, "No scaling centers native raster") }
                    else { try require(edge[0] > 230, "Fit/fill fills horizontal extent") }
                    let top = pixel(image!, 30, 1)
                    if mode == .fill { try require(top[0] > 230, "Fill crops to canvas") }
                    else { try require(top.allSatisfy { $0 < 8 }, "Fit/none retains black padding") }
                }
                decoded += 1
            }
            try await backend.seek(toFrame: 10)
            try await backend.play()
            try await Task.sleep(for: .milliseconds(350))
            backend.pause()
            try require(backend.position > 0.5 && image != nil, "Live playback crosses into a still")
            await backend.close()
        }
        // Transparent PNG and fit bars must reveal lower video, then disappear at the half-open cut.
        let layered = try AVFoundationSequenceBackend(project: project(url: transparent, mode: .fit, lower: true), videoProxies: [:])
        var layeredImage: CGImage?
        layered.display = { image, _ in layeredImage = image }
        for frame: Int64 in [23, 24, 18, 12] {
            try await layered.seek(toFrame: frame)
            let p = pixel(layeredImage!, 60, 24)
            if frame < 24 {
                // Underlying video is red before frame 24; half-green over red gives yellow.
                try require(abs(p[0] - 127) < 18 && abs(p[1] - 128) < 18 && p[2] < 15, "Alpha reveals lower video: \(p)")
                let bar = pixel(layeredImage!, 40, 1)
                try require(bar[0] > 230 && bar[1] < 20, "Still fit bars reveal lower video: \(bar)")
            } else { try require(p[2] > 230 && p[0] < 20 && p[1] < 20, "Still stops at exact cut: \(p)") }
            decoded += 1
        }
        // Two independently placed transparent still clips must both contribute.
        var stackedProject = try project(url: transparent, mode: .fill, lower: true)
        var secondStillTrack = stackedProject.tracks[0]
        secondStillTrack.id = UUID()
        secondStillTrack.clips[0].id = UUID()
        stackedProject.tracks.insert(secondStillTrack, at: 1)
        let stacked = try AVFoundationSequenceBackend(project: stackedProject, videoProxies: [:])
        var stackedImage: CGImage?
        stacked.display = { image, _ in stackedImage = image }
        for frame: Int64 in [12, 23, 18] {
            try await stacked.seek(toFrame: frame)
            let p = pixel(stackedImage!, 60, 24)
            // Half-green over half-green over red: 75% green and 25% red.
            try require(abs(p[0] - 64) < 18 && abs(p[1] - 191) < 18 && p[2] < 15,
                "Both transparent still layers reveal the opaque lower picture: \(p)")
            decoded += 1
        }
        await stacked.close()
        let cachedItem = try await layered.makePlayerItem()
        let cachedTracks = try await cachedItem.asset.load(.tracks)
        var preparedURLs = Set<URL>()
        for track in cachedTracks {
            for segment in try await track.load(.segments) {
                if let url = (segment as? AVCompositionTrackSegment)?.sourceURL, url != videoURL { preparedURLs.insert(url) }
            }
        }
        try require(preparedURLs.count == 1, "Repeated seeks/builds reuse one prepared movie")
        try require(preparedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Prepared movie remains available during playback")
        await layered.close()
        try require(preparedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Close removes prepared movie")
        let oriented = try AVFoundationSequenceBackend(project: project(url: jpeg, mode: .fit), videoProxies: [:])
        var orientedImage: CGImage?
        oriented.display = { image, _ in orientedImage = image }
        try await oriented.seek(toFrame: 12)
        try require(pixel(orientedImage!, 20, 24).allSatisfy { $0 < 8 }, "Rotated JPEG has portrait fit bounds")
        let a = pixel(orientedImage!, 40, 10), b = pixel(orientedImage!, 40, 38)
        // EXIF orientation 6 rotates clockwise: source left/red becomes top/red.
        try require(a[0] > 220 && a[1] < 20 && b[1] > 220 && b[0] < 20,
            "EXIF 6 rotates clockwise, with red above green: \(a), \(b)")
        await oriented.close()
        decoded += 1
        // Still holds share a lane, with a separate lane for motion video.
        // Stretching a single frame must leave later holds/trims in place.
        var holds = try project(url: png, mode: .fit)
        let orientedAsset = MediaAsset(name: "Oriented", originalURL: jpeg, duration: try RationalTime(5))
        holds.assets.append(orientedAsset)
        holds.tracks[0].clips = []
        var nextFrame: Int64 = 0
        var holdChecks: [(Int64, Bool)] = []
        for index in 0..<16 {
            let rotated = index % 2 == 1
            let frames: Int64 = rotated ? 6 : 3
            holds.tracks[0].clips.append(TimelineClip(assetID: rotated ? orientedAsset.id : holds.assets[0].id,
                sourceRange: try TimeRange(start: RationalTime(3), duration: holds.settings.frameRate.time(forFrames: frames)),
                timelineStart: try holds.settings.frameRate.time(forFrames: nextFrame), selection: .still))
            holdChecks.append((nextFrame, rotated)); holdChecks.append((nextFrame + frames - 1, rotated))
            nextFrame += frames
        }
        var ending = base
        ending.id = UUID()
        ending.sourceRange = try TimeRange(start: RationalTime(1), duration: holds.settings.frameRate.time(forFrames: 3))
        ending.timelineStart = try holds.settings.frameRate.time(forFrames: nextFrame)
        holds.tracks[0].clips.append(ending)
        let holdsBackend = try AVFoundationSequenceBackend(project: holds, videoProxies: [:])
        let holdsItem = try await holdsBackend.makePlayerItem()
        let holdsTracks = try await holdsItem.asset.loadTracks(withMediaType: .video)
        try require(holdsTracks.count == 2, "Adjacent still holds reuse one composition track, separate from motion video")
        var holdImage: CGImage?
        var holdFrame: Int64?
        holdsBackend.display = { holdImage = $0; holdFrame = $1 }
        for (frame, rotated) in holdChecks.reversed() {
            try await holdsBackend.seek(toFrame: frame)
            try require(holdFrame == frame && holdImage != nil, "Reused still track preserves exact cut frames")
            let top = pixel(holdImage!, 40, 10), bottom = pixel(holdImage!, 40, 38)
            if rotated {
                try require(top[0] > 220 && top[1] < 20 && bottom[1] > 220 && bottom[0] < 20,
                    "Reused track applies each JPEG orientation")
            } else {
                let topBar = pixel(holdImage!, 40, 1), bottomBar = pixel(holdImage!, 40, 46)
                try require(topBar.allSatisfy { $0 < 8 } && bottomBar.allSatisfy { $0 < 8 }, "Reused track applies PNG fit padding: \(topBar), \(bottomBar)")
            }
            decoded += 1
        }
        try await holdsBackend.seek(toFrame: nextFrame)
        let endPixel = pixel(holdImage!, 40, 24)
        try require(endPixel[2] > 230 && endPixel[0] < 20, "Still scaling preserves the following movie's timeline and source trim")
        decoded += 1
        await holdsBackend.close()
        // Reusing a movie lane for a prepared still changes AVFoundation's color
        // output. Separate pools must retain alpha and color across these cuts.
        var staggered = try project(url: transparent, mode: .fit, lower: true)
        staggered.tracks[0].clips[0].sourceRange.duration = try RationalTime(1)
        staggered.tracks[1].clips[0].sourceRange.duration = try RationalTime(1, 2)
        var lateLower = base
        lateLower.id = UUID()
        lateLower.timelineStart = try RationalTime(1)
        lateLower.sourceRange = try TimeRange(start: RationalTime(1), duration: RationalTime(1))
        staggered.tracks[1].clips.append(lateLower)
        let staggeredBackend = try AVFoundationSequenceBackend(project: staggered, videoProxies: [:])
        var staggeredImage: CGImage?
        staggeredBackend.display = { image, _ in staggeredImage = image }
        for frame: Int64 in [30, 18, 30, 12] {
            try await staggeredBackend.seek(toFrame: frame)
            let bar = pixel(staggeredImage!, 40, 1), center = pixel(staggeredImage!, 60, 24)
            if frame >= 24 {
                try require(bar[2] > 230 && bar[0] < 20 && bar[1] < 20, "Reused mixed-format lane preserves lower blue padding: \(bar)")
                try require(center[0] < 20 && abs(center[1] - 128) < 18 && abs(center[2] - 127) < 18,
                    "Reused mixed-format lane preserves alpha over blue: \(center)")
            } else {
                try require(bar.allSatisfy { $0 < 8 }, "Reused mixed-format lane preserves empty padding")
                try require(center[0] < 20 && abs(center[1] - 128) < 18 && center[2] < 20,
                    "Reused mixed-format lane preserves alpha over black: \(center)")
            }
            decoded += 1
        }
        await staggeredBackend.close()
        for (width, height) in [(81, 53), (41, 21)] {
            let url = try fixture("odd-\(width).png", width: width, height: height)
            let backend = try AVFoundationSequenceBackend(project: project(url: url, mode: .none), videoProxies: [:])
            var image: CGImage?
            backend.display = { value, _ in image = value }
            try await backend.seek(toFrame: 12)
            let split = (80 - width) / 2 + width / 2
            try require(pixel(image!, split - 1, 24)[0] > 220 && pixel(image!, split, 24)[1] > 220,
                "Odd no-scaling pad/crop keeps integer pixel boundary: \(pixel(image!, split - 1, 24)) \(pixel(image!, split, 24))")
            await backend.close()
            decoded += 1
        }
        for rate in [try FrameRate(24000, 1001), try FrameRate(30000, 1001), try FrameRate(60000, 1001)] {
            var fractional = try project(url: png, mode: .fit)
            fractional.settings.frameRate = rate
            fractional.tracks[0].clips[0].timelineStart = try rate.time(forFrames: 12)
            fractional.tracks[0].clips[0].sourceRange.duration = try rate.time(forFrames: 12)
            let backend = try AVFoundationSequenceBackend(project: fractional, videoProxies: [:])
            var image: CGImage?
            var displayed: Int64?
            backend.display = { image = $0; displayed = $1 }
            for frame: Int64 in [23, 11, 12, 18] {
                try await backend.seek(toFrame: frame)
                try require(displayed == frame, "Fractional still seek preserves frame index")
                let p = pixel(image!, 30, 24)
                try require(frame < 12 ? p.allSatisfy { $0 < 8 } : p[0] > 230, "Fractional hold preserves exact cut")
                decoded += 1
            }
            await backend.close()
        }
        // A one-frame hold can be shorter than the prepared movie's 1/24 second.
        let shortRate = try FrameRate(60000, 1001)
        var shortProject = try project(url: png, mode: .fill, lower: true)
        shortProject.settings.frameRate = shortRate
        shortProject.tracks[0].clips[0].timelineStart = try shortRate.time(forFrames: 12)
        shortProject.tracks[0].clips[0].sourceRange.duration = try shortRate.time(forFrames: 1)
        let short = try AVFoundationSequenceBackend(project: shortProject, videoProxies: [:])
        var shortImage: CGImage?
        short.display = { image, _ in shortImage = image }
        for frame: Int64 in [13, 11, 12, 13] {
            try await short.seek(toFrame: frame)
            let p = pixel(shortImage!, 60, 24)
            try require(frame == 12 ? p[1] > 230 && p[0] < 20 : p[0] > 230 && p[1] < 20,
                "One-frame 60000/1001 still hold has exact half-open visibility: \(p)")
            decoded += 1
        }
        await short.close()
        // File validation and cancellation must leave no partially prepared files.
        let invalid = directory.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: invalid)
        let scratch = directory.appendingPathComponent("cancelled-preparation")
        do {
            _ = try await SystemStillPreview.prepare(url: invalid, directory: scratch)
            throw NSError(domain: "Expected invalid image rejection", code: 1)
        } catch { try require(!error.localizedDescription.contains("Expected invalid"), "Invalid images must fail") }
        let oversized = try fixture("oversized.png", width: 4097, height: 1)
        do {
            _ = try await SystemStillPreview.prepare(url: oversized, directory: scratch)
            throw NSError(domain: "Expected oversized image rejection", code: 1)
        } catch SystemStillPreview.PreparationError.imageTooLarge { }
        let gif = directory.appendingPathComponent("unsupported.gif")
        let gifSource = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let gifImage = CGImageSourceCreateImageAtIndex(gifSource, 0, nil)!
        let gifDestination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        for _ in 0..<2 { CGImageDestinationAddImage(gifDestination, gifImage, nil) }
        try require(CGImageDestinationFinalize(gifDestination), "Create unsupported animated GIF fixture")
        try require(CGImageSourceGetCount(CGImageSourceCreateWithURL(gif as CFURL, nil)!) == 2,
            "Unsupported fixture contains multiple frames")
        do {
            _ = try await SystemStillPreview.prepare(url: gif, directory: scratch)
            throw NSError(domain: "Expected unsupported image rejection", code: 1)
        } catch SystemStillPreview.PreparationError.unsupportedImage { }
        let cancelled = Task { try await SystemStillPreview.prepare(url: png, directory: scratch) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "Expected cancellation", code: 1) }
        catch is CancellationError { }
        try require((try? FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty) != false, "Failed/cancelled preparation cleans files")
        print("System still smoke passed: \(decoded) decoded seeks, fit/fill/none, synthetic source trims, stacked alpha/lower layers, exact cuts, EXIF orientation, live playback, malformed/oversized/animated unsupported input and cancellation.")
    }
}
