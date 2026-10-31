import CoreGraphics
import Foundation
import CNativeDecoder
import EditorCore

/// libavformat's reading of a local file in the app's media model, for media that
/// AVFoundation cannot open. Stream indices are FFmpeg's, which export maps by.
/// Durations, offsets and cadence are exact fractions from packet timing; a video
/// format is present only when every packet proves one constant square-pixel cadence.
public struct NativeMediaProbe: Sendable {
    public let formatName: String
    /// Latest stream end, measured from the earliest stream start (asset zero).
    public let duration: RationalTime
    public let streams: [MediaStream]
    /// FFmpeg codec names by stream index.
    public let codecs: [Int: String]
    /// First-frame embedded timecode as exact seconds (frames × timecode frame duration).
    public let sourceTimecodeStart: RationalTime?
    /// Audio streams whose packets tile the sample grid exactly and contiguously.
    public let sampleExactAudio: Set<Int>

    public init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProofFailure("Probe requires a local file") }
        var error = [CChar](repeating: 0, count: 1024)
        guard let probe = url.path.withCString({ afc_probe_open($0, &error, error.count) }) else {
            throw ProofFailure(message(error))
        }
        defer { afc_probe_close(probe) }
        formatName = String(cString: afc_probe_format_name(probe))
        var numerator: Int64 = 0, denominator: Int64 = 0
        guard afc_probe_duration(probe, &numerator, &denominator) == 0 else { throw ProofFailure("Probe has no duration") }
        duration = try RationalTime(numerator, denominator)
        var streams: [MediaStream] = []
        var codecs: [Int: String] = [:]
        var sampleExact: Set<Int> = []
        for position in 0..<afc_probe_stream_count(probe) {
            var stream = AFCProbeStream()
            guard afc_probe_stream(probe, position, &stream) == 0 else { throw ProofFailure("Probe stream is absent") }
            let index = Int(stream.index)
            let offset = try RationalTime(stream.offset_num, stream.offset_den)
            codecs[index] = withUnsafeBytes(of: stream.codec) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if stream.kind == Int32(AFC_PROBE_VIDEO) {
                var format: VideoSourceFormat?
                if stream.square_untransformed != 0, stream.frame_duration > 0 {
                    format = try? VideoSourceFormat(width: Int(stream.width), height: Int(stream.height),
                        frameRate: FrameRate(Int64(stream.time_base_den), stream.frame_duration * Int64(stream.time_base_num)))
                }
                streams.append(MediaStream(index: index, kind: .video, label: "Video \(index + 1)", timeOffset: offset, videoFormat: format))
            } else {
                if stream.sample_exact != 0 { sampleExact.insert(index) }
                let layout: ChannelLayout
                switch Int(stream.layout) {
                case Int(AFC_PROBE_LAYOUT_MONO): layout = .mono
                case Int(AFC_PROBE_LAYOUT_STEREO): layout = .stereo
                case Int(AFC_PROBE_LAYOUT_SURROUND51): layout = .surround51
                default: layout = ChannelLayout(channels: Array(repeating: nil, count: Int(stream.channels)))
                }
                streams.append(MediaStream(index: index, kind: .audio, label: "Audio \(index + 1)", audioLayout: layout, timeOffset: offset))
            }
        }
        guard !streams.isEmpty else { throw ProofFailure("This file has no supported video or audio tracks.") }
        self.streams = streams
        self.codecs = codecs
        sampleExactAudio = sampleExact
        var frames: Int64 = 0
        if afc_probe_timecode(probe, &frames, &numerator, &denominator) == 0 {
            sourceTimecodeStart = try? RationalTime(frames).multiplied(by: RationalTime(numerator, denominator))
        } else {
            sourceTimecodeStart = nil
        }
    }

    /// Whether the sequence monitor can play every stream: packet timing proves a constant
    /// video cadence and sample-exact contiguous audio (the grids its decoder qualifies),
    /// and each stream opens in that decoder, which applies its codec, zero-origin, geometry
    /// and first-frame checks. Media that fails should be converted instead. Decoded-frame
    /// qualification still runs when playback first reads a stream.
    public func verifyNativePlayback(url: URL) throws {
        for stream in streams {
            let name = "\(stream.label ?? "Stream \(stream.index)") (\(codecs[stream.index] ?? "unknown"))"
            if stream.kind == .video, stream.videoFormat == nil {
                throw ProofFailure("\(name): no proven constant square-pixel cadence")
            }
            if stream.kind == .audio, !sampleExactAudio.contains(stream.index) {
                throw ProofFailure("\(name): packet timing is not sample-exact")
            }
            do { _ = try SourceDecoder(url: url, streamIndex: stream.index) } catch {
                throw ProofFailure("\(name): \(error)")
            }
        }
    }
}

/// Approximate timeline thumbnails and waveforms through FFmpeg, for originals
/// that AVFoundation cannot read. Times are asset seconds, as the probe defines them.
public enum NativeMediaPreview {
    public static func thumbnails(url: URL, streamIndex: Int, times: [Double],
                                  maximumWidth: Int, maximumHeight: Int) throws -> [CGImage] {
        guard (1...4096).contains(maximumWidth), (1...4096).contains(maximumHeight) else {
            throw ProofFailure("Thumbnail size must be 1...4096")
        }
        let preview = try open(url: url, streamIndex: streamIndex)
        defer { afc_preview_close(preview) }
        var images: [CGImage] = []
        var rgba = [UInt8](repeating: 0, count: maximumWidth * maximumHeight * 4)
        var error = [CChar](repeating: 0, count: 1024)
        for time in times {
            try Task.checkCancellation()
            var width: Int32 = 0, height: Int32 = 0
            guard afc_preview_frame(preview, time, Int32(maximumWidth), Int32(maximumHeight),
                                    &rgba, rgba.count, &width, &height, &error, error.count) == 0 else {
                throw ProofFailure(message(error))
            }
            let bytes = Data(rgba.prefix(Int(width) * Int(height) * 4))
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw ProofFailure("Create thumbnail image")
            }
            images.append(image)
        }
        return images
    }

    /// Per requested source channel (FFmpeg order), `bins` absolute peaks clamped to 1.
    public static func peaks(url: URL, streamIndex: Int, channels: [Int], start: Double,
                             duration: Double, bins: Int) throws -> [[Float]] {
        guard !channels.isEmpty, channels.count <= 64, (1...100_000).contains(bins) else {
            throw ProofFailure("Invalid waveform request")
        }
        let preview = try open(url: url, streamIndex: streamIndex)
        defer { afc_preview_close(preview) }
        let indices = channels.map { Int32(clamping: $0) }
        var peaks = [Float](repeating: 0, count: channels.count * bins)
        var error = [CChar](repeating: 0, count: 1024)
        guard afc_preview_peaks(preview, start, duration, Int32(bins), indices, Int32(indices.count),
                                &peaks, peaks.count, &error, error.count) == 0 else {
            throw ProofFailure(message(error))
        }
        return (0..<channels.count).map { Array(peaks[($0 * bins)..<(($0 + 1) * bins)]) }
    }

    private static func open(url: URL, streamIndex: Int) throws -> OpaquePointer {
        guard url.isFileURL, url.path.hasPrefix("/"), let index = Int32(exactly: streamIndex) else {
            throw ProofFailure("Preview requires a local file and valid stream index")
        }
        var error = [CChar](repeating: 0, count: 1024)
        guard let preview = url.path.withCString({ afc_preview_open($0, index, &error, error.count) }) else {
            throw ProofFailure(message(error))
        }
        return preview
    }
}
