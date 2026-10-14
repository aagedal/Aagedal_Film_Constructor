import AVFoundation
import AppKit
import CoreImage
import EditorCore

/// System-codec preview for ordinary video and whole mono/stereo audio streams.
/// The canonical plan supplies trims, ordering, routing, gain and fade geometry.
@MainActor
final class AVFoundationSequenceBackend: SequencePlaybackBackend {
    var display: ((CGImage, Int64) -> Void)?
    var failure: ((any Error) -> Void)?
    var position: Double {
        let seconds = player?.currentTime().seconds ?? target.seconds
        return seconds.isFinite ? seconds : target.seconds
    }
    var isPlaying: Bool { player?.rate != 0 && player != nil }
    private let plan: TimelineRenderPlan
    private let proxies: [UUID: MediaProxy]
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var polling: Task<Void, Never>?
    private let context = CIContext()
    private var target = CMTime.zero
    private var closed = false
    private var hasVideo = false

    init(project: Project, videoProxies: [UUID: MediaProxy]) throws {
        plan = try TimelineRenderPlan(project: project)
        proxies = videoProxies
        guard plan.duration.numerator > 0 else { throw Self.unsupported("Append media to preview the sequence.") }
        guard plan.settings.width <= 4096, plan.settings.height <= 4096,
              plan.duration.seconds < Double(Int64.max) / 600_000,
              plan.duration.seconds * plan.settings.frameRate.value.seconds < Double(Int64.max) else {
            throw Self.unsupported("Sequence dimensions or duration exceed system preview limits.")
        }
        guard plan.settings.audioLayout == .mono || plan.settings.audioLayout == .stereo else {
            throw Self.unsupported("System preview requires mono or stereo sequence output.")
        }
    }

    private static func unsupported(_ message: String) -> NSError {
        NSError(domain: "SequencePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func time(_ exact: RationalTime) throws -> CMTime {
        guard let timescale = Int32(exactly: exact.denominator) else {
            throw Self.unsupported("Clip timing exceeds the system preview timebase. Use the native runtime.")
        }
        return CMTime(value: exact.numerator, timescale: timescale)
    }
    // Nonlinear audio envelopes are intentionally approximated by short ramps.
    private func rampTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }

    /// Shared construction path for live playback and offline decoded-mix qualification.
    func makePlayerItem() async throws -> AVPlayerItem {
        guard !closed else { throw CancellationError() }
        let composition = AVMutableComposition()
        let duration = try time(plan.duration)
        // Establish full duration, including leading/trailing gaps and audio-only edits.
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: duration))
        hasVideo = false
        var layers: [(TimelineRenderPlan.Component, AVMutableVideoCompositionLayerInstruction)] = []
        var mixes: [AVAudioMixInputParameters] = []
        var assets: [URL: AVURLAsset] = [:]
        defer { withExtendedLifetime(assets) {} }
        var sourceTracks: [URL: [AVAssetTrack]] = [:]
        for component in plan.components {
            try Task.checkCancellation()
            guard let original = component.originalURL else { throw Self.unsupported("Relink missing originals before sequence preview.") }
            var url = original
            var streamIndex: Int
            switch component.selection {
            case .still:
                throw Self.unsupported("Still-image sequence preview requires the native FFmpeg runtime. System preview currently supports video and audio.")
            case .video(let index):
                streamIndex = index
                if let proxy = proxies[component.assetID] { url = proxy.url; streamIndex = 0 }
            case .audio(let selection):
                guard let first = selection.channels.first,
                      selection.channels.allSatisfy({ $0.streamIndex == first.streamIndex }),
                      selection.channels.map(\.channelIndex) == Array(selection.channels.indices),
                      selection.layout == plan.settings.audioLayout,
                      component.routing.outputChannels.isEmpty || component.routing.outputChannels == Array(selection.channels.indices),
                      let stream = component.sourceStreams.first(where: { $0.index == first.streamIndex }),
                      stream.audioLayout == selection.layout else {
                    throw Self.unsupported("System preview supports whole mono/stereo streams with unchanged channel routing. This selection requires the native runtime.")
                }
                streamIndex = first.streamIndex
            }
            if assets[url] == nil {
                let asset = AVURLAsset(url: url)
                assets[url] = asset
                sourceTracks[url] = try await asset.load(.tracks)
            }
            // Import assigns container indices from this same AVFoundation track list.
            guard let tracks = sourceTracks[url], tracks.indices.contains(streamIndex) else {
                throw Self.unsupported("Selected stream is unavailable in system preview: \(url.lastPathComponent).")
            }
            let source = tracks[streamIndex]
            let video = source.mediaType == .video
            let expectedType: AVMediaType
            if case .video = component.selection { expectedType = .video } else { expectedType = .audio }
            guard source.mediaType == expectedType,
                  video || source.mediaType == .audio else { throw Self.unsupported("Selected stream type does not match the clip.") }
            if !video {
                let descriptions = try await source.load(.formatDescriptions)
                // AVFoundation's composition resampler shifts sample phase and
                // smooths cut boundaries differently from the canonical render.
                // Admit only the same-rate subset qualified against that render.
                // Generated gapless MP3 fixtures disagree with the canonical
                // renderer even at matching rates and interior cuts. Do not
                // present those decoded samples as an edited sequence preview.
                if descriptions.contains(where: { description in
                    CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID == kAudioFormatMPEGLayer3
                }) {
                    throw Self.unsupported("System preview cannot faithfully trim MP3 audio. Normalize \(url.lastPathComponent) to PCM or ALAC before editing.")
                }
                guard !descriptions.isEmpty, descriptions.allSatisfy({ description in
                    guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return false }
                    return format.pointee.mSampleRate == Double(plan.settings.audioSampleRate)
                }) else {
                    throw Self.unsupported("System preview requires audio at the sequence sample rate (\(plan.settings.audioSampleRate) Hz). \(url.lastPathComponent) uses a different or unknown sample rate. Match the sequence rate or use normalized media.")
                }
            }
            guard let track = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Self.unsupported("Could not create a sequence preview track.")
            }
            let range = try CMTimeRange(start: time(component.sourceRange.start), duration: time(component.sourceRange.duration))
            do { try track.insertTimeRange(range, of: source, at: time(component.timelineRange.start)) }
            catch { throw Self.unsupported("Could not preview \(url.lastPathComponent) stream \(streamIndex): \(error.localizedDescription)") }
            if video {
                hasVideo = true
                let size = try await source.load(.naturalSize)
                let orientation = try await source.load(.preferredTransform)
                let bounds = CGRect(origin: .zero, size: size).applying(orientation)
                let canvas = CGSize(width: plan.settings.width, height: plan.settings.height)
                guard bounds.width > 0, bounds.height > 0 else { throw Self.unsupported("Invalid video dimensions.") }
                let factor: CGFloat
                switch component.scalingMode {
                case .fit: factor = min(canvas.width / bounds.width, canvas.height / bounds.height)
                case .fill: factor = max(canvas.width / bounds.width, canvas.height / bounds.height)
                case .none:
                    // A smaller proxy is a representation of the original raster.
                    if proxies[component.assetID] != nil,
                       let format = component.sourceStreams.first(where: { $0.index == proxies[component.assetID]?.videoStreamIndex })?.videoFormat {
                        factor = CGFloat(format.width) / bounds.width
                    } else { factor = 1 }
                }
                let transform = orientation
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                    .concatenating(CGAffineTransform(translationX: (canvas.width - bounds.width * factor) / 2,
                                                    y: (canvas.height - bounds.height * factor) / 2))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(transform, at: .zero)
                layers.append((component, layer))
            } else {
                guard component.gain <= 1 else { throw Self.unsupported("System preview supports audio gain up to unity. Boosted tracks require the native runtime.") }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                let start = component.timelineRange.start.seconds
                let length = component.timelineRange.duration.seconds
                let fadeIn = component.fadeIn.duration.seconds, fadeOut = component.fadeOut.duration.seconds
                // Piecewise ramps target 5 ms intervals, capped at 4096 per edge.
                // Limit only fades; a long constant-gain clip needs no per-frame ramps.
                var knots: Set<Double> = [0, length]
                for (edge, incoming) in [(fadeIn, true), (fadeOut, false)] where edge > 0 {
                    let count = min(4096, max(1, Int(ceil(min(edge / 0.005, 4096)))))
                    for i in 0...count {
                        let offset = edge * Double(i) / Double(count)
                        knots.insert(incoming ? offset : length - edge + offset)
                    }
                }
                let points = knots.filter { $0 >= 0 && $0 <= length }.sorted()
                func volume(_ offset: Double) throws -> Float {
                    let elapsed = offset >= length ? component.timelineRange.duration
                        : try RationalTime(Int64((offset * 600_000).rounded()), 600_000)
                    return Float(component.gain * (try AudioFadeEnvelope.gain(at: elapsed, duration: component.timelineRange.duration,
                        fadeIn: component.fadeIn, fadeOut: component.fadeOut)))
                }
                // Establish the initial gain before delayed media begins. Otherwise
                // AVFoundation smooths from its default unity volume at the cut.
                parameters.setVolume(try volume(0), at: .zero)
                for (a, b) in zip(points, points.dropFirst()) {
                    parameters.setVolumeRamp(fromStartVolume: try volume(a), toEndVolume: try volume(b),
                        timeRange: CMTimeRange(start: rampTime(start + a), duration: rampTime(b - a)))
                }
                mixes.append(parameters)
            }
        }
        let item = AVPlayerItem(asset: composition)
        let mix = AVMutableAudioMix(); mix.inputParameters = mixes; item.audioMix = mix
        if hasVideo {
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = CGSize(width: plan.settings.width, height: plan.settings.height)
            let rate = plan.settings.frameRate.value
            guard let timescale = Int32(exactly: rate.numerator) else { throw Self.unsupported("Sequence frame rate exceeds the system preview timebase.") }
            videoComposition.frameDuration = CMTime(value: rate.denominator, timescale: timescale)
            let boundaries = try Set([.zero, plan.duration] + layers.flatMap {
                [$0.0.timelineRange.start, try $0.0.timelineRange.end()]
            }).sorted { try $0.compared(to: $1) == .orderedAscending }
            videoComposition.instructions = try zip(boundaries, boundaries.dropFirst()).map { start, end in
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = try CMTimeRange(start: time(start), duration: time(end.subtracting(start)))
                instruction.backgroundColor = NSColor.black.cgColor
                instruction.layerInstructions = try layers.filter {
                    try $0.0.timelineRange.start.compared(to: start) != .orderedDescending &&
                        $0.0.timelineRange.end().compared(to: start) == .orderedDescending
                }.sorted {
                    if $0.0.layerOrder != $1.0.layerOrder { return $0.0.layerOrder < $1.0.layerOrder }
                    return $0.0.clipID.uuidString < $1.0.clipID.uuidString
                }.prefix(1).map(\.1)
                return instruction
            }
            item.videoComposition = videoComposition
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return item
    }

    private func prepare() async throws {
        guard player == nil, !closed else { return }
        let item = try await makePlayerItem()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if item.videoComposition != nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output); self.output = output
        }
        player = AVPlayer(playerItem: item)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, let player = self.player else { return }
                if let error = player.currentItem?.error { self.pause(); self.failure?(error); return }
                let current = player.currentTime()
                guard current.isNumeric else { continue }
                var displayedTime = CMTime.invalid
                if let buffer = self.output?.copyPixelBuffer(forItemTime: current, itemTimeForDisplay: &displayedTime),
                   let image = self.context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))) {
                    self.display?(image, self.frame(at: displayedTime.isNumeric ? displayedTime : current))
                }
            }
        }
    }

    private func frame(at time: CMTime) -> Int64 {
        guard time.isNumeric, time.timescale > 0,
              let frames = try? RationalTime(time.value, Int64(time.timescale)).multiplied(by: plan.settings.frameRate.value) else { return 0 }
        return max(0, frames.numerator / frames.denominator)
    }
    func seek(toFrame frame: Int64) async throws {
        pause()
        try await prepare()
        let frameCount = try plan.duration.multiplied(by: plan.settings.frameRate.value)
        let last = max(0, frameCount.numerator / frameCount.denominator - (frameCount.numerator % frameCount.denominator == 0 ? 1 : 0))
        let selectedFrame = min(max(0, frame), last)
        let exact = try RationalTime(selectedFrame).divided(by: plan.settings.frameRate.value)
        target = try time(exact)
        guard let player else { throw CancellationError() }
        let finished = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard finished, !closed else { throw CancellationError() }
        if hasVideo, let item = player.currentItem {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = item.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            defer { generator.cancelAllCGImageGeneration() }
            let image = try await generator.image(at: target).image
            guard !closed else { throw CancellationError() }
            display?(image, selectedFrame)
        } else {
            let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: plan.settings.width, height: plan.settings.height))
            if let cg = context.createCGImage(image, from: image.extent) { display?(cg, selectedFrame) }
        }
    }
    func play() async throws {
        try await prepare()
        if position >= plan.duration.seconds - 0.000001 { try await seek(toFrame: 0) }
        if let error = player?.currentItem?.error { throw error }
        player?.play()
    }
    func pause() { player?.pause() }
    func close() async {
        closed = true; pause(); polling?.cancel(); polling = nil
        player?.replaceCurrentItem(with: nil); player = nil; output = nil
    }
}
