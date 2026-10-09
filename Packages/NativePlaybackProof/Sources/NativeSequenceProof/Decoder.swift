import Foundation
import CNativeDecoder
import EditorCore

struct ProofFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
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

    init(url: URL, streamIndex: Int) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              let index = Int32(exactly: streamIndex) else {
            throw ProofFailure("Decoder requires a local file and valid stream index")
        }
        var error = [CChar](repeating: 0, count: 1024)
        guard let pointer = url.path.withCString({ path in
            afc_decoder_open(path, index, &error, error.count)
        }) else { throw ProofFailure(message(error)) }
        handle = pointer
        width = Int(afc_decoder_width(pointer))
        height = Int(afc_decoder_height(pointer))
        channels = Int(afc_decoder_channels(pointer))
        sampleRate = Int(afc_decoder_sample_rate(pointer))
    }

    deinit { afc_decoder_close(handle) }

    func video(frame: Int64, rate: FrameRate, width: Int, height: Int) throws -> Data {
        // Geometry is intentionally narrow until metadata and scaling are qualified.
        guard self.width == width, self.height == height, width <= 4096, height <= 4096 else {
            throw ProofFailure("Proof requires source raster equal to sequence raster (maximum 4096²)")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        var error = [CChar](repeating: 0, count: 1024)
        let result = afc_decoder_video(handle, frame, rate.value.numerator, rate.value.denominator,
                                       &bytes, bytes.count, &error, error.count)
        guard result == 0 else { throw ProofFailure(message(error)) }
        return Data(bytes)
    }

    func audio(start: Int64, count: Int, sampleRate: Int) throws -> [Float] {
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
}

/// Buffers are bounded by a frame or audio block, never the duration of a source.
final class NativeMonitor {
    private(set) var plan: NativePlaybackPlan
    private var decoders: [SourceKey: SourceDecoder] = [:]

    init(project: Project) throws {
        plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        guard plan.settings.width <= 4096, plan.settings.height <= 4096 else {
            throw ProofFailure("Proof limits sequence raster to 4096²")
        }
    }

    /// Compile and validate before swapping; a failed edit keeps the prior plan
    /// and decoders. Successful replacement invalidates all decoded source state.
    func replace(project: Project) throws {
        let replacement = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        guard replacement.settings.width <= 4096, replacement.settings.height <= 4096 else {
            throw ProofFailure("Proof limits sequence raster to 4096²")
        }
        plan = replacement
        resetDecoders()
    }

    func resetDecoders() { decoders.removeAll() }

    private func decoder(url: URL, streamIndex: Int) throws -> SourceDecoder {
        let key = SourceKey(url: url, streamIndex: streamIndex)
        if let decoder = decoders[key] { return decoder }
        guard decoders.count < 64 else { throw ProofFailure("Proof limits open stream decoders to 64") }
        let decoder = try SourceDecoder(url: url, streamIndex: streamIndex)
        decoders[key] = decoder
        return decoder
    }

    func video(frame: Int64) throws -> Data {
        guard let request = try plan.videoFrame(at: frame) else {
            return Data(repeating: 0, count: plan.settings.width * plan.settings.height * 3)
        }
        return try decoder(url: request.url, streamIndex: request.streamIndex).video(
            frame: request.sourceFrame, rate: plan.settings.frameRate,
            width: plan.settings.width, height: plan.settings.height)
    }

    /// Float mixing preserves explicit routing and static gain without a limiter.
    func audio(start: Int64, count: Int) throws -> [Float] {
        let requests = try plan.audioBlock(startSample: start, sampleCount: count)
        let channels = plan.settings.audioLayout.channels.count
        var output = [Float](repeating: 0, count: count * channels)
        for request in requests {
            let source = try decoder(url: request.url, streamIndex: request.streamIndex)
            guard request.sourceChannel < source.channels else { throw ProofFailure("Missing decoded channel") }
            let samples = try source.audio(start: request.sourceStartSample, count: request.sampleCount,
                                           sampleRate: plan.settings.audioSampleRate)
            for frame in 0..<request.sampleCount {
                let value = samples[frame * source.channels + request.sourceChannel] * Float(request.gain)
                let destination = (request.destinationOffset + frame) * channels + request.destinationChannel
                output[destination] += value
                guard output[destination].isFinite else { throw ProofFailure("Nonfinite mixed sample") }
            }
        }
        return output
    }
}
