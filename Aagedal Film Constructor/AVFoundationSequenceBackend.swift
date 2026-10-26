import AVFoundation
import AppKit
import CoreImage
import EditorCore

/// System-codec preview for video, bounded PNG/JPEG stills and whole mono/stereo audio streams.
/// The canonical plan supplies trims, ordering, routing, gain and fade geometry.
@MainActor
final class AVFoundationSequenceBackend: SequencePlaybackBackend {
    var display: ((CGImage, Int64) -> Void)?
    var failure: ((any Error) -> Void)?
    private(set) var previewQualificationNotice: String?
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
    private let stillDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("afc-system-stills-" + UUID().uuidString)
    private var stillMovies: [URL: URL] = [:]
    private var stillMovieBytes = 0

    deinit { try? FileManager.default.removeItem(at: stillDirectory) }

    init(project: Project, videoProxies: [UUID: MediaProxy]) throws {
        plan = try TimelineRenderPlan(project: project)
        proxies = videoProxies
        guard plan.duration.numerator > 0 else { throw Self.unsupported("Append media to preview the sequence.") }
        guard plan.settings.width <= 4096, plan.settings.height <= 4096,
              plan.duration.seconds < Double(Int64.max) / 600_000,
              plan.duration.seconds * plan.settings.frameRate.value.seconds < Double(Int64.max) else {
            throw Self.unsupported("Sequence dimensions or duration exceed system preview limits.")
        }
        guard [ChannelLayout.mono, .stereo, .surround51].contains(plan.settings.audioLayout) else {
            throw Self.unsupported("System preview requires mono, stereo or 5.1 sequence output.")
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
    private func rampTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    private func addQualificationNotice(_ notice: String) {
        guard let existing = previewQualificationNotice else {
            previewQualificationNotice = notice
            return
        }
        if !existing.contains(notice) { previewQualificationNotice = existing + " " + notice }
    }

    /// Shared construction path for live playback and offline decoded-mix qualification.
    func makePlayerItem() async throws -> AVPlayerItem {
        guard !closed else { throw CancellationError() }
        let composition = AVMutableComposition()
        let duration = try time(plan.duration)
        // Establish full duration, including leading/trailing gaps and audio-only edits.
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: duration))
        hasVideo = false
        previewQualificationNotice = nil
        if plan.settings.audioLayout == .surround51 {
            addQualificationNotice("5.1 sequences preview as the system's stereo downmix; export writes all six channels.")
        }
        let picturePlan = try VideoCompositionPlan(plan)
        var pictureTracks: [Int: AVMutableCompositionTrack] = [:]
        // Preserve editorial priority when creating tracks. AVFoundation can
        // derive its working color format from the first composition track.
        // Insertion within each reused lane still follows chronological order.
        for placement in picturePlan.placements.sorted(by: { $0.componentIndex < $1.componentIndex }) {
            guard pictureTracks[placement.trackIndex] == nil else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Self.unsupported("Could not create a sequence preview track.")
            }
            pictureTracks[placement.trackIndex] = track
        }
        let pictureLanes = Dictionary(uniqueKeysWithValues: picturePlan.placements.map { ($0.componentIndex, $0.trackIndex) })
        let componentIndices = picturePlan.placements.map(\.componentIndex) + plan.components.indices.filter {
            if case .audio = plan.components[$0].selection { return true }
            return false
        }
        var layers: [Int: AVMutableVideoCompositionLayerInstruction] = [:]
        var placements: [Int: (track: CMPersistentTrackID, placement: LayerPlacement)] = [:]
        var mixes: [AVAudioMixInputParameters] = []
        var meterReadings: [UUID: [MeterReading]] = [:]
        var assets: [URL: AVURLAsset] = [:]
        defer {
            withExtendedLifetime(assets) {}
            if closed { try? FileManager.default.removeItem(at: stillDirectory) }
        }
        var sourceTracks: [URL: [AVAssetTrack]] = [:]
        for componentIndex in componentIndices {
            try Task.checkCancellation()
            let component = plan.components[componentIndex]
            guard let original = component.originalURL else { throw Self.unsupported("Relink missing originals before sequence preview.") }
            var url = original
            var streamIndex: Int
            switch component.selection {
            case .still:
                if let prepared = stillMovies[original] { url = prepared }
                else {
                    guard stillMovies.count < 512 else {
                        throw Self.unsupported("System preview supports up to 512 distinct still images per sequence. Use the native runtime for larger sequences.")
                    }
                    url = try await SystemStillPreview.prepare(url: original, directory: stillDirectory)
                    do {
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 256 * 1024 * 1024 - stillMovieBytes else {
                            throw Self.unsupported("Still-image preparation exceeds the 256 MB system preview limit. Use the native runtime.")
                        }
                        stillMovieBytes += size
                        stillMovies[original] = url
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                }
                streamIndex = 0
            case .video(let index):
                streamIndex = index
                if let proxy = proxies[component.assetID] { url = proxy.url; streamIndex = 0 }
            case .audio(let selection):
                // In 5.1 sequences, stereo on front left/right and mono on centre monitor faithfully
                // through the system downmix, like identity routes do in stereo sequences.
                let frontRoute = plan.settings.audioLayout == .surround51
                    && ((selection.layout == .stereo && component.routing.outputChannels == [0, 1])
                        || (selection.layout == .mono && component.routing.outputChannels == [2]))
                guard let first = selection.channels.first,
                      selection.channels.allSatisfy({ $0.streamIndex == first.streamIndex }),
                      frontRoute || selection.layout == plan.settings.audioLayout,
                      frontRoute || component.routing.outputChannels.isEmpty || component.routing.outputChannels == Array(selection.channels.indices),
                      let stream = component.sourceStreams.first(where: { $0.index == first.streamIndex }) else {
                    // Keep the rest of the sequence playable; export still renders this routing.
                    addQualificationNotice("Audio with custom channel routing is silent in preview; export includes it.")
                    continue
                }
                let wholeStream = selection.channels.map(\.channelIndex) == Array(selection.channels.indices) && stream.audioLayout == selection.layout
                // The system mixer plays a mono track on every output channel, matching dual mono.
                let dualMono = stream.audioLayout?.channels.count == 1 && selection.channels.allSatisfy { $0.channelIndex == 0 }
                guard wholeStream || dualMono else {
                    addQualificationNotice("Audio with custom channel routing is silent in preview; export includes it.")
                    continue
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
            switch component.selection {
            case .video, .still: expectedType = .video
            case .audio: expectedType = .audio
            }
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
                    addQualificationNotice("MP3 cut points are approximate in preview; export trims exactly.")
                }
                // Interior AAC fixtures agree, but source edges and even one-packet
                // insets do not. No measured margin establishes a faithful general
                // subset. Preserve useful playback while making that limit visible.
                let aacFormats: Set<AudioFormatID> = [kAudioFormatMPEG4AAC,
                    kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                    kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
                    kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2,
                    kAudioFormatMPEG4AAC_Spatial]
                if descriptions.contains(where: { description in
                    guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return false }
                    return aacFormats.contains(format.pointee.mFormatID)
                }) {
                    addQualificationNotice("AAC source-edge audio is approximate. Normalize to PCM or ALAC for faithful trims.")
                }
                guard !descriptions.isEmpty else {
                    throw Self.unsupported("\(url.lastPathComponent) has no readable audio format.")
                }
                if !descriptions.allSatisfy({ description in
                    guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return false }
                    return format.pointee.mSampleRate == Double(plan.settings.audioSampleRate)
                }) {
                    addQualificationNotice("Audio not at \(plan.settings.audioSampleRate) Hz is resampled approximately in preview; export resamples exactly.")
                }
            }
            let destination = pictureLanes[componentIndex].flatMap { pictureTracks[$0] }
                ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            guard let track = destination else {
                throw Self.unsupported("Could not create a sequence preview track.")
            }
            let range: CMTimeRange
            if component.selection == .still {
                // Still source In/Out values describe a synthetic hold, not movie frames.
                range = try await source.load(.timeRange)
                guard range.duration.isNumeric, CMTimeCompare(range.duration, .zero) > 0 else {
                    throw Self.unsupported("Could not prepare still-image sequence preview.")
                }
            } else {
                // A retimed clip inserts the source it consumes, then scales to its timeline length.
                range = try CMTimeRange(start: time(component.sourceRange.start), duration: time(component.sourceExtent()))
            }
            do {
                let start = try time(component.timelineRange.start)
                try track.insertTimeRange(range, of: source, at: start)
                if component.selection == .still || component.speed != .one {
                    track.scaleTimeRange(CMTimeRange(start: start, duration: range.duration),
                        toDuration: try time(component.timelineRange.duration))
                }
            }
            catch { throw Self.unsupported("Could not preview \(url.lastPathComponent) stream \(streamIndex): \(error.localizedDescription)") }
            if video {
                hasVideo = true
                // naturalSize already applies pixel aspect, so anamorphic media presents widened.
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
                var offsetX = (canvas.width - bounds.width * factor) / 2
                var offsetY = (canvas.height - bounds.height * factor) / 2
                if component.selection == .still && component.scalingMode == .none {
                    // Canonical integer pad/crop centers toward zero at odd dimensions.
                    offsetX = offsetX.rounded(.towardZero)
                    offsetY = offsetY.rounded(.towardZero)
                }
                // The clip's own scale is about the frame centre, then offset in frame fractions;
                // keyframes animate them between their timeline times.
                let fit = orientation
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                    .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
                let static_ = component.transform
                let points: [LayerPlacement.Point] = component.transformKeyframes.isEmpty
                    ? (static_.isIdentity ? [] : [.init(time: 0, scale: static_.scale, offsetX: static_.offsetX, offsetY: static_.offsetY)])
                    : component.transformKeyframes.map {
                        .init(time: component.timelineSeconds(ofSource: $0.time), scale: $0.scale, offsetX: $0.offsetX, offsetY: $0.offsetY)
                    }
                let placement = LayerPlacement(base: fit, canvas: canvas, points: points)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                let start = component.timelineRange.start.seconds, end = try component.timelineRange.end().seconds
                layer.setTransform(placement.transform(at: start), at: .zero)
                // Linear matrix ramps equal linear scale and offset ramps for this placement.
                let times = ([start] + points.map(\.time).filter { $0 > start && $0 < end } + [end])
                for (a, b) in zip(times, times.dropFirst()) where points.count > 1 && b > a {
                    layer.setTransformRamp(fromStart: placement.transform(at: a), toEnd: placement.transform(at: b),
                                           timeRange: CMTimeRange(start: rampTime(a), end: rampTime(b)))
                }
                if let reveal = component.reveal {
                    // Wipe: the crop (in the source's own coordinates) widens from one edge.
                    let start = rampTime(reveal.start.seconds), finish = rampTime(try reveal.start.adding(reveal.duration).seconds)
                    let hidden = CGRect(x: reveal.fromLeft ? 0 : size.width, y: 0, width: 0, height: size.height)
                    layer.setCropRectangle(hidden, at: .zero)
                    layer.setCropRectangleRamp(fromStartCropRectangle: hidden, toEndCropRectangle: CGRect(origin: .zero, size: size),
                                               timeRange: CMTimeRange(start: start, end: finish))
                }
                try applyOpacityFades(component, to: layer)
                layers[componentIndex] = layer
                placements[componentIndex] = (track.trackID, placement)
            } else {
                if component.gain > 1 {
                    addQualificationNotice("Gain above 0 dB plays at 0 dB in preview; export applies the full gain.")
                }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                // A post-fader tap feeds the mixer's meter for this editorial track.
                let reading = MeterReading()
                if let tap = MeterTap.make(for: reading, eq: component.eq) {
                    parameters.audioTapProcessor = tap
                    meterReadings[component.trackID, default: []].append(reading)
                }
                let start = component.timelineRange.start.seconds
                let ramps = try AudioFadeRampPlan(duration: component.timelineRange.duration,
                    fadeIn: component.fadeIn, fadeOut: component.fadeOut, gain: min(component.gain, 1))
                if component.gain > 0 && [component.fadeIn, component.fadeOut].contains(where: {
                    $0.duration.numerator > 0 && $0.duration.seconds <= 0.005
                }) {
                    addQualificationNotice("Very short audio fades can differ substantially from export in system preview.")
                }
                if ramps.isNonlinear {
                    addQualificationNotice("Curved or overlapping audio fades are approximate in system preview.")
                }
                // Volume keyframes multiply the fade ramps at their own times.
                var points = ramps.points.map { (seconds: $0.seconds, volume: $0.volume) }
                if !component.volumeKeyframes.isEmpty {
                    let sourceStart = component.sourceRange.start.seconds, length = component.timelineRange.duration.seconds
                    let speed = component.speed.seconds
                    func fade(at t: Double) -> Double {
                        guard let next = points.firstIndex(where: { $0.seconds >= t }) else { return points.last?.volume ?? 1 }
                        guard next > 0 else { return points[0].volume }
                        let a = points[next - 1], b = points[next]
                        return b.seconds > a.seconds ? a.volume + (b.volume - a.volume) * (t - a.seconds) / (b.seconds - a.seconds) : b.volume
                    }
                    let times = Set(points.map(\.seconds) + component.volumeKeyframes.map { ($0.time.seconds - sourceStart) / speed }
                        .filter { $0 > 0 && $0 < length }).sorted()
                    points = times.map { t in
                        let automation = VolumeEnvelope.gain(atSourceSeconds: sourceStart + t * speed, keyframes: component.volumeKeyframes)
                        if automation * min(component.gain, 1) > 1 {
                            addQualificationNotice("Gain above 0 dB plays at 0 dB in preview; export applies the full gain.")
                        }
                        return (t, min(1, fade(at: t) * automation))
                    }
                }
                // Establish initial gain before delayed media begins; otherwise the
                // system can smooth from its default unity volume at the cut.
                parameters.setVolume(Float(points[0].volume), at: .zero)
                for (a, b) in zip(points, points.dropFirst()) {
                    let rampStart = rampTime(start + a.seconds)
                    let rampEnd = rampTime(start + b.seconds)
                    guard rampStart.isNumeric, rampEnd.isNumeric, CMTimeCompare(rampEnd, rampStart) > 0 else {
                        throw Self.unsupported("Audio fade timing exceeds system preview precision. Use the native runtime.")
                    }
                    parameters.setVolumeRamp(fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume),
                        timeRange: CMTimeRange(start: rampStart, duration: CMTimeSubtract(rampEnd, rampStart)))
                }
                mixes.append(parameters)
            }
        }
        let item = AVPlayerItem(asset: composition)
        // Retimed sound keeps its pitch, as in export.
        if plan.components.contains(where: { $0.speed != .one }) { item.audioTimePitchAlgorithm = .spectral }
        let mix = AVMutableAudioMix(); mix.inputParameters = mixes; item.audioMix = mix
        AudioMeters.shared.attach(meterReadings)
        if hasVideo {
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = CGSize(width: plan.settings.width, height: plan.settings.height)
            let rate = plan.settings.frameRate.value
            guard let timescale = Int32(exactly: rate.numerator) else { throw Self.unsupported("Sequence frame rate exceeds the system preview timebase.") }
            videoComposition.frameDuration = CMTime(value: rate.denominator, timescale: timescale)
            videoComposition.instructions = try picturePlan.instructions.map { segment in
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = try CMTimeRange(start: time(segment.timeRange.start), duration: time(segment.timeRange.duration))
                instruction.backgroundColor = NSColor.black.cgColor
                instruction.layerInstructions = try segment.componentIndices.map {
                    guard let layer = layers[$0] else { throw Self.unsupported("Missing sequence preview layer.") }
                    return layer
                }
                return instruction
            }
            // Colour correction needs per-layer filters, which only a custom compositor can apply.
            if plan.components.contains(where: { !$0.color.isNeutral }) {
                let canvas = videoComposition.renderSize
                videoComposition.customVideoCompositorClass = CoreImageCompositor.self
                videoComposition.instructions = try picturePlan.instructions.map { segment in
                    try CoreImageInstruction(
                        timeRange: CMTimeRange(start: time(segment.timeRange.start), duration: time(segment.timeRange.duration)),
                        layers: segment.componentIndices.map { index in
                            guard let placement = placements[index] else { throw Self.unsupported("Missing sequence preview layer.") }
                            let component = plan.components[index]
                            return .init(trackID: placement.track, placement: placement.placement,
                                         opacity: Self.opacityCurve(component), brightness: component.color.brightness,
                                         contrast: component.color.contrast, saturation: component.color.saturation,
                                         blur: component.color.blur * Double(plan.settings.height),
                                         reveal: component.reveal.map { ($0.start.seconds, $0.duration.seconds, $0.fromLeft) })
                        }, canvas: canvas)
                }
            }
            item.videoComposition = videoComposition
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return item
    }

    /// Linear opacity ramps for picture fades and dissolves, matching the export's alpha fades.
    /// Overlapping fade in and fade out multiply; that product is followed with short segments.
    /// Opacity at a sequence time in seconds: fades times the clip's own opacity.
    static func opacityCurve(_ component: TimelineRenderPlan.Component) -> @Sendable (Double) -> Double {
        let fadeIn = component.fadeIn.duration.seconds, fadeOut = component.fadeOut.duration.seconds
        let start = component.timelineRange.start.seconds, duration = component.timelineRange.duration.seconds
        let level = component.transform.opacity
        return { time in
            let t = time - start
            let rising = fadeIn > 0 ? min(1, max(0, t / fadeIn)) : 1
            let falling = fadeOut > 0 ? min(1, max(0, (duration - t) / fadeOut)) : 1
            return rising * falling * level
        }
    }

    private func applyOpacityFades(_ component: TimelineRenderPlan.Component, to layer: AVMutableVideoCompositionLayerInstruction) throws {
        let fadeIn = component.fadeIn.duration.seconds, fadeOut = component.fadeOut.duration.seconds
        let level = component.transform.opacity
        guard fadeIn > 0 || fadeOut > 0 else {
            if level != 1 { layer.setOpacity(Float(level), at: .zero) }
            return
        }
        let start = component.timelineRange.start.seconds, duration = component.timelineRange.duration.seconds
        func opacity(_ t: Double) -> Double {
            let rising = fadeIn > 0 ? min(1, max(0, t / fadeIn)) : 1
            let falling = fadeOut > 0 ? min(1, max(0, (duration - t) / fadeOut)) : 1
            return rising * falling * level
        }
        var times = Set([0, duration, min(fadeIn, duration), max(0, duration - fadeOut)])
        if fadeIn + fadeOut > duration {
            let from = max(0, duration - fadeOut), to = min(fadeIn, duration)
            for step in 1..<16 { times.insert(from + (to - from) * Double(step) / 16) }
        }
        let points = times.sorted()
        layer.setOpacity(Float(opacity(0)), at: rampTime(start))
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let from = opacity(a), to = opacity(b)
            guard from != level || to != level else { continue }
            let rampStart = rampTime(start + a), rampEnd = rampTime(start + b)
            guard rampStart.isNumeric, rampEnd.isNumeric, CMTimeCompare(rampEnd, rampStart) > 0 else {
                throw Self.unsupported("Picture fade timing exceeds system preview precision.")
            }
            layer.setOpacityRamp(fromStartOpacity: Float(from), toEndOpacity: Float(to),
                                 timeRange: CMTimeRange(start: rampStart, duration: CMTimeSubtract(rampEnd, rampStart)))
        }
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
        AudioMeters.shared.detach()
        closed = true; pause(); polling?.cancel(); polling = nil
        player?.replaceCurrentItem(with: nil); player = nil; output = nil
        stillMovies.removeAll(); stillMovieBytes = 0
        try? FileManager.default.removeItem(at: stillDirectory)
    }
}
