import Foundation
import CNativeDecoder
import EditorCore

public struct ProofFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

private func message(_ chars: [CChar]) -> String {
    String(decoding: chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Serial ownership of one exact container stream. No decoder crosses threads.
final class SourceDecoder {
    private let handle: OpaquePointer
    let width: Int
    let height: Int
    let channels: Int
    let sampleRate: Int

    init(url: URL, streamIndex: Int, isStill: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              let index = Int32(exactly: streamIndex) else {
            throw ProofFailure("Decoder requires a local file and valid stream index")
        }
        var error = [CChar](repeating: 0, count: 1024)
        guard let pointer = url.path.withCString({ path in
            isStill ? afc_decoder_open_still(path, index, &error, error.count)
                : afc_decoder_open(path, index, &error, error.count)
        }) else { throw ProofFailure(message(error)) }
        handle = pointer
        width = Int(afc_decoder_width(pointer))
        height = Int(afc_decoder_height(pointer))
        channels = Int(afc_decoder_channels(pointer))
        sampleRate = Int(afc_decoder_sample_rate(pointer))
    }

    deinit { afc_decoder_close(handle) }

    var retainedBytes: Int { Int(clamping: afc_decoder_retained_bytes(handle)) }

    public func video(frame: Int64, rate: FrameRate, width: Int, height: Int,
                      scalingMode: ScalingMode, originalFormat: VideoSourceFormat? = nil) throws -> Data {
        let geometry = try NativeVideoGeometry(sourceWidth: originalFormat?.width ?? self.width, sourceHeight: originalFormat?.height ?? self.height,
                                               width: width, height: height, mode: scalingMode)
        var bytes = [UInt8](repeating: 0, count: geometry.scaledWidth * geometry.scaledHeight * 3)
        var error = [CChar](repeating: 0, count: 1024)
        let result = afc_decoder_scaled_video(handle, Int32(geometry.scaledWidth), Int32(geometry.scaledHeight),
            frame, rate.value.numerator, rate.value.denominator, &bytes, bytes.count, &error, error.count)
        guard result == 0 else { throw ProofFailure(message(error)) }
        return geometry.compose(Data(bytes))
    }

    func still(width: Int, height: Int, scalingMode: ScalingMode) throws -> Data {
        let geometry = try NativeVideoGeometry(sourceWidth: self.width, sourceHeight: self.height,
                                               width: width, height: height, mode: scalingMode)
        var bytes = [UInt8](repeating: 0, count: geometry.scaledWidth * geometry.scaledHeight * 4)
        var error = [CChar](repeating: 0, count: 1024)
        let result = afc_decoder_scaled_still(handle, Int32(geometry.scaledWidth), Int32(geometry.scaledHeight),
                                             &bytes, bytes.count, &error, error.count)
        guard result == 0 else { throw ProofFailure(message(error)) }
        return geometry.compose(Data(bytes), channels: 4)
    }

    public func audio(start: Int64, count: Int, sampleRate: Int) throws -> [Float] {
        guard self.sampleRate == sampleRate, channels > 0, channels <= 64,
              count > 0, count <= 65536, let cCount = Int32(exactly: count),
              let cRate = Int32(exactly: sampleRate) else {
            throw ProofFailure("Proof requires matching source sample rate and bounded PCM blocks")
        }
        var samples = [Float](repeating: 0, count: count * channels)
        var error = [CChar](repeating: 0, count: 1024)
        let result = afc_decoder_audio(handle, start, cCount, cRate, &samples, samples.count,
                                       &error, error.count)
        guard result == 0 else { throw ProofFailure(message(error)) }
        return samples
    }
}

struct SourceKey: Hashable {
    let url: URL
    let streamIndex: Int
    let isStill: Bool
}

/// Retention bounds, separate from the session's cache of returned RGB/PCM.
/// These bound idle source frames and conversion buffers, not total FFmpeg RSS.
public struct NativeDecoderLimits: Sendable {
    public let maximumActiveDecoders: Int
    public let retainedSourceByteLimit: Int

    public init(maximumActiveDecoders: Int = 16, retainedSourceByteLimit: Int = 128 * 1024 * 1024) {
        self.maximumActiveDecoders = maximumActiveDecoders
        self.retainedSourceByteLimit = retainedSourceByteLimit
    }

    func validate() throws {
        guard maximumActiveDecoders > 0, maximumActiveDecoders <= 64,
              retainedSourceByteLimit >= 0 else {
            throw ProofFailure("Decoder limits require 1...64 active streams and a nonnegative byte budget")
        }
    }
}

/// Serial access only. The operation's local reference pins a source until it
/// finishes; trimming then releases complete decoders, preserving exact reopen
/// qualification/seek semantics instead of clearing frames behind the C bridge.
final class SourceDecoderCache {
    private let limits: NativeDecoderLimits
    private var entries: [SourceKey: SourceDecoder] = [:]
    private var recency: [SourceKey] = [] // oldest first; small bounded array

    init(limits: NativeDecoderLimits) throws {
        try limits.validate()
        self.limits = limits
    }

    var count: Int { entries.count }
    var retainedBytes: Int {
        entries.values.reduce(0) { total, source in
            let (sum, overflow) = total.addingReportingOverflow(source.retainedBytes)
            return overflow ? Int.max : sum
        }
    }

    func reset() { entries.removeAll(); recency.removeAll() }

    private func evictOldest() {
        guard !recency.isEmpty else { return }
        entries.removeValue(forKey: recency.removeFirst())
    }

    func withDecoder<Value>(key: SourceKey, operation: (SourceDecoder) throws -> Value) throws -> Value {
        let source: SourceDecoder
        if let existing = entries[key] {
            source = existing
            recency.removeAll { $0 == key }
        } else {
            // Close an idle decoder before opening the next one so opening does
            // not temporarily exceed the active-context bound.
            while entries.count >= limits.maximumActiveDecoders { evictOldest() }
            source = try SourceDecoder(url: key.url, streamIndex: key.streamIndex, isStill: key.isStill)
            entries[key] = source
        }
        recency.append(key)
        defer {
            while !entries.isEmpty && (limits.retainedSourceByteLimit == 0 || retainedBytes > limits.retainedSourceByteLimit) {
                evictOldest()
            }
        }
        return try operation(source)
    }
}

/// Buffers are bounded by a frame or audio block, never the duration of a source.
public final class NativeMonitor {
    public private(set) var plan: NativePlaybackPlan
    private let decoders: SourceDecoderCache
    private var proxySelections: [UUID: NativeProxySelection]

    /// Video proxies must be integrity-verified by the caller for these asset IDs.
    /// No attached rendition is selected implicitly; audio always uses originals.
    public init(project: Project, videoProxies: [UUID: MediaProxy] = [:], decoderLimits: NativeDecoderLimits = NativeDecoderLimits()) throws {
        decoders = try SourceDecoderCache(limits: decoderLimits)
        plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        proxySelections = try NativeProxySelection.compile(project: project, videoProxies: videoProxies)
        guard plan.settings.width <= 4096, plan.settings.height <= 4096 else {
            throw ProofFailure("Proof limits sequence raster to 4096²")
        }
    }

    /// Compile and validate before swapping; a failed edit keeps the prior plan
    /// and decoders. Successful replacement invalidates all decoded source state.
    public func replace(project: Project, videoProxies: [UUID: MediaProxy] = [:]) throws {
        let replacement = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        guard replacement.settings.width <= 4096, replacement.settings.height <= 4096 else {
            throw ProofFailure("Proof limits sequence raster to 4096²")
        }
        let selections = try NativeProxySelection.compile(project: project, videoProxies: videoProxies)
        plan = replacement
        proxySelections = selections
        resetDecoders()
    }

    public func resetDecoders() { decoders.reset() }

    public func video(frame: Int64) throws -> Data {
        let layers = try plan.videoLayers(at: frame)
        var output = Data(repeating: 0, count: plan.settings.width * plan.settings.height * 3)
        for request in layers.reversed() {
            let proxy = proxySelections[request.clipID]
            try decoders.withDecoder(key: SourceKey(url: proxy?.proxy.url ?? request.url,
                                                    streamIndex: proxy == nil ? request.streamIndex : 0, isStill: request.isStill)) { source in
                if let proxy {
                    guard source.width == proxy.proxy.width, source.height == proxy.proxy.height else {
                        throw ProofFailure("Decoded proxy raster differs from verified metadata")
                    }
                }
                if request.isStill {
                    let rgba = try source.still(width: plan.settings.width, height: plan.settings.height,
                                                scalingMode: request.scalingMode)
                    NativeStillComposition.over(rgba, onto: &output)
                } else {
                    output = try source.video(frame: request.sourceFrame, rate: plan.settings.frameRate,
                        width: plan.settings.width, height: plan.settings.height, scalingMode: request.scalingMode,
                        originalFormat: proxy?.originalFormat)
                }
            }
        }
        return output
    }

    /// Float mixing preserves explicit routing, static gain and sample-timed fades without a limiter.
    public func audio(start: Int64, count: Int) throws -> [Float] {
        let requests = try plan.audioBlock(startSample: start, sampleCount: count)
        let channels = plan.settings.audioLayout.channels.count
        var output = [Float](repeating: 0, count: count * channels)
        for request in requests {
            try decoders.withDecoder(key: SourceKey(url: request.url, streamIndex: request.streamIndex, isStill: false)) { source in
                guard request.sourceChannel < source.channels else { throw ProofFailure("Missing decoded channel") }
                let samples = try source.audio(start: request.sourceStartSample, count: request.sampleCount,
                                               sampleRate: plan.settings.audioSampleRate)
                for frame in 0..<request.sampleCount {
                    let envelope = try AudioFadeEnvelope.gain(sampleIndex: request.clipSampleOffset + Int64(frame),
                        sampleRate: request.sampleRate, duration: request.clipDuration,
                        fadeIn: request.fadeIn, fadeOut: request.fadeOut)
                    let value = samples[frame * source.channels + request.sourceChannel] * Float(request.gain * envelope)
                    let destination = (request.destinationOffset + frame) * channels + request.destinationChannel
                    output[destination] += value
                    guard output[destination].isFinite else { throw ProofFailure("Nonfinite mixed sample") }
                }
            }
        }
        return output
    }
}

/// Integer-centered spatial conform for qualified square-pixel sources. RGB
/// centering rounds toward the top/left when the spare dimension is odd. Color
/// conversion and subsampled export edge equivalence remain independently tested.
struct NativeVideoGeometry {
    let width: Int
    let height: Int
    let scaledWidth: Int
    let scaledHeight: Int
    let x: Int
    let y: Int

    init(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int, mode: ScalingMode) throws {
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 4096, sourceHeight <= 4096,
              width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw ProofFailure("Proof limits source and sequence raster to 4096²")
        }
        self.width = width; self.height = height
        // Nearest positive integer, matching FFmpeg scale aspect-ratio rounding.
        func rounded(_ numerator: Int, _ denominator: Int) -> Int {
            (numerator + denominator / 2) / denominator
        }
        let aspectWidth = rounded(height * sourceWidth, sourceHeight)
        let aspectHeight = rounded(width * sourceHeight, sourceWidth)
        switch mode {
        case .fit: scaledWidth = min(width, aspectWidth); scaledHeight = min(height, aspectHeight)
        case .fill: scaledWidth = max(width, aspectWidth); scaledHeight = max(height, aspectHeight)
        case .none: scaledWidth = sourceWidth; scaledHeight = sourceHeight
        }
        guard scaledWidth > 0, scaledHeight > 0, scaledWidth <= 4096, scaledHeight <= 4096 else {
            throw ProofFailure("Spatial conform intermediate raster exceeds development limit")
        }
        let dx = width - scaledWidth, dy = height - scaledHeight
        x = dx / 2; y = dy / 2
    }

    func compose(_ rgb: Data, channels: Int = 3) -> Data {
        precondition(channels == 3 || channels == 4)
        precondition(rgb.count == scaledWidth * scaledHeight * channels)
        if width == scaledWidth && height == scaledHeight { return rgb }
        var output = Data(repeating: 0, count: width * height * channels)
        let sourceX = max(0, -x), sourceY = max(0, -y)
        let destinationX = max(0, x), destinationY = max(0, y)
        let rowBytes = min(width, scaledWidth) * channels
        let rows = min(height, scaledHeight)
        output.withUnsafeMutableBytes { destination in
            rgb.withUnsafeBytes { source in
                for row in 0..<rows {
                    destination.baseAddress!.advanced(by: ((destinationY + row) * width + destinationX) * channels)
                        .copyMemory(from: source.baseAddress!.advanced(by: ((sourceY + row) * scaledWidth + sourceX) * channels),
                                    byteCount: rowBytes)
                }
            }
        }
        return output
    }
}

/// Straight alpha over an opaque RGB background, with nearest integer rounding.
/// This development SDR composition does not claim linear-light color management.
enum NativeStillComposition {
    static func over(_ rgba: Data, onto rgb: inout Data) {
        precondition(rgba.count % 4 == 0 && rgb.count == rgba.count / 4 * 3)
        rgb.withUnsafeMutableBytes { destination in
            rgba.withUnsafeBytes { source in
                let input = source.bindMemory(to: UInt8.self)
                let output = destination.bindMemory(to: UInt8.self)
                for pixel in 0..<(rgba.count / 4) {
                    let alpha = Int(input[pixel * 4 + 3])
                    for channel in 0..<3 {
                        let foreground = Int(input[pixel * 4 + channel])
                        let background = Int(output[pixel * 3 + channel])
                        output[pixel * 3 + channel] = UInt8((foreground * alpha + background * (255 - alpha) + 127) / 255)
                    }
                }
            }
        }
    }
}
