import AVFoundation
import Combine
import MediaToolbox
import os
import EditorCore

/// Peak level of one preview audio track, written on the audio thread and read on the main thread.
nonisolated final class MeterReading: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    func record(_ peak: Float) { lock.withLock { $0 = max($0, peak) } }
    /// Returns the peak since the last read and resets it.
    func take() -> Float { lock.withLock { value in defer { value = 0 }; return value } }
}

/// One selected source channel and the output channel it plays on.
nonisolated struct TapRoute: Equatable, Sendable {
    let input: Int
    let output: Int
}

/// What a preview audio tap does: makeup gain, optional EQ and dynamics per selected channel,
/// channel routing, then metering of the result.
nonisolated final class TapContext: @unchecked Sendable {
    let reading: MeterReading
    let eq: AudioEQ
    let dynamics: AudioDynamics?
    /// Gain the system volume (capped at unity) cannot apply: volume ramps are scaled down
    /// by it and the tap restores it before EQ and dynamics, as export applies volume first.
    let makeup: Double
    /// Selected channels and their outputs, as export's `pan` maps them; nil plays every
    /// delivered channel on itself.
    private let requestedRoutes: [TapRoute]?
    private var routes: [TapRoute] = []
    /// Per route, the compressor stages in order.
    private var compressors: [[Compressor]] = []
    /// The system mixer hands taps stereo audio 3 dB down (measured: a known tone meters
    /// 3.01 dB low). Compressors and meters work on the restored level so thresholds and
    /// readings match the export.
    private var levelScale = 1.0
    private var filters: [Biquad] = []
    /// Per route, per band: the last two inputs and outputs.
    private var state: [[(x1: Double, x2: Double, y1: Double, y2: Double)]] = []
    /// Input samples per delivered channel, copied before outputs are written in place.
    private var scratch: [[Float]] = []
    /// Where each delivered channel lives; reused so the audio thread does not allocate.
    private var lanes: [(data: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
    init(reading: MeterReading, eq: AudioEQ, dynamics: AudioDynamics?, makeup: Double = 1, routes: [TapRoute]? = nil) {
        self.reading = reading; self.eq = eq; self.dynamics = dynamics; self.makeup = makeup; requestedRoutes = routes
    }

    func prepare(sampleRate: Double, channels: Int, maxFrames: Int) {
        let channels = max(1, channels)
        routes = (requestedRoutes ?? (0..<channels).map { TapRoute(input: $0, output: $0) })
            .filter { $0.input < channels && $0.output < channels }
        filters = eq.biquads(sampleRate: sampleRate)
        state = Array(repeating: Array(repeating: (0, 0, 0, 0), count: filters.count), count: routes.count)
        levelScale = channels == 2 ? 2.0.squareRoot() : 1
        let stages = dynamics?.stages ?? []
        compressors = Array(repeating: stages.map { Compressor($0, sampleRate: sampleRate) }, count: routes.count)
        scratch = Array(repeating: Array(repeating: 0, count: max(1, maxFrames)), count: channels)
        lanes = []
        lanes.reserveCapacity(channels)
    }

    /// `frames` is the count the tap delivered; buffers may be larger.
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames delivered: Int) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        // Channel n lives in some buffer at a lane of its interleaving.
        lanes.removeAll(keepingCapacity: true)
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let interleaved = max(1, Int(buffer.mNumberChannels))
            let frames = min(delivered, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / interleaved)
            for lane in 0..<interleaved { lanes.append((data + lane, interleaved, frames)) }
        }
        let identity = makeup == 1 && filters.isEmpty && compressors.allSatisfy(\.isEmpty)
            && routes.count == lanes.count && routes.enumerated().allSatisfy { $0.element.input == $0.offset && $0.element.output == $0.offset }
        if !identity, lanes.count <= scratch.count {
            for (channel, lane) in lanes.enumerated() {
                let frames = min(lane.frames, scratch[channel].count)
                for frame in 0..<frames {
                    scratch[channel][frame] = lane.data[frame * lane.stride]
                    lane.data[frame * lane.stride] = 0
                }
            }
            for (index, route) in routes.enumerated() where route.input < lanes.count && route.output < lanes.count {
                let source = lanes[route.input], target = lanes[route.output]
                for frame in 0..<min(source.frames, target.frames, scratch[route.input].count) {
                    var sample = Double(scratch[route.input][frame]) * makeup
                    for (band, f) in filters.enumerated() {
                        let s = state[index][band]
                        let output = f.b0 * sample + f.b1 * s.x1 + f.b2 * s.x2 - f.a1 * s.y1 - f.a2 * s.y2
                        state[index][band] = (sample, s.x1, output, s.y1)
                        sample = output
                    }
                    // Each selected channel is compressed on its own, as each export channel chain is.
                    if !compressors[index].isEmpty {
                        sample *= levelScale
                        for stage in compressors[index].indices { sample = compressors[index][stage].process(sample) }
                        sample /= levelScale
                    }
                    target.data[frame * target.stride] += Float(sample)
                }
            }
        }
        var peak: Float = 0
        for lane in lanes {
            for frame in 0..<lane.frames { peak = max(peak, abs(lane.data[frame * lane.stride]) * Float(levelScale)) }
        }
        reading.record(peak)
    }
}

/// Post-fader taps on preview audio tracks. Each tap applies the clip's makeup gain, EQ,
/// dynamics and routing, and measures the samples the mix plays, after volume ramps, for
/// the mixer's meter.
nonisolated enum MeterTap {
    static func make(for reading: MeterReading, eq: AudioEQ = .flat, dynamics: AudioDynamics? = nil,
                     makeup: Double = 1, routes: [TapRoute]? = nil) -> MTAudioProcessingTap? {
        let context = TapContext(reading: reading, eq: eq, dynamics: dynamics, makeup: makeup, routes: routes)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame), maxFrames: Int(maxFrames))
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(buffers, frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            // Creation failed, so finalize will never release the retained context.
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}

/// Levels per editorial audio track for the mixer, in dBFS with a falling peak hold.
@MainActor
final class AudioMeters: ObservableObject {
    static let shared = AudioMeters()
    @Published private(set) var levels: [UUID: Float] = [:]
    private var readings: [UUID: [MeterReading]] = [:]
    private var timer: Timer?

    /// Replaces the readings for a newly prepared preview.
    func attach(_ readings: [UUID: [MeterReading]]) {
        self.readings = readings
        levels = [:]
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { AudioMeters.shared.poll() }
        }
    }
    func detach() { readings = [:]; levels = [:] }

    func poll() {
        var next = levels
        for (track, sources) in readings {
            let peak = sources.map { $0.take() }.max() ?? 0
            let decibels = peak > 0 ? 20 * log10(peak) : -120
            // Fall back by 1.5 dB per poll (30 dB per second) unless the new peak is higher.
            next[track] = max(decibels, (levels[track] ?? -120) - 1.5)
        }
        if next != levels { levels = next }
    }
}
