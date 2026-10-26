import AVFoundation
import Combine
import MediaToolbox
import os
import EditorCore

/// Peak level of one preview audio track, written on the audio thread and read on the main thread.
final class MeterReading: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    func record(_ peak: Float) { lock.withLock { $0 = max($0, peak) } }
    /// Returns the peak since the last read and resets it.
    func take() -> Float { lock.withLock { value in defer { value = 0 }; return value } }
}

/// What a preview audio tap does: optional EQ, then metering of the result.
final class TapContext: @unchecked Sendable {
    let reading: MeterReading
    let eq: AudioEQ
    private var filters: [Biquad] = []
    /// Per channel, per band: the last two inputs and outputs.
    private var state: [[(x1: Double, x2: Double, y1: Double, y2: Double)]] = []
    init(reading: MeterReading, eq: AudioEQ) { self.reading = reading; self.eq = eq }

    func prepare(sampleRate: Double, channels: Int) {
        filters = eq.biquads(sampleRate: sampleRate)
        state = Array(repeating: Array(repeating: (0, 0, 0, 0), count: filters.count), count: max(1, channels))
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>) {
        var peak: Float = 0
        var channel = 0
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let interleaved = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / interleaved
            for lane in 0..<interleaved where !filters.isEmpty {
                let index = min(channel + lane, state.count - 1)
                for frame in 0..<frames {
                    var sample = Double(data[frame * interleaved + lane])
                    for (band, f) in filters.enumerated() {
                        let s = state[index][band]
                        let output = f.b0 * sample + f.b1 * s.x1 + f.b2 * s.x2 - f.a1 * s.y1 - f.a2 * s.y2
                        state[index][band] = (sample, s.x1, output, s.y1)
                        sample = output
                    }
                    data[frame * interleaved + lane] = Float(sample)
                }
            }
            for index in 0..<(frames * interleaved) { peak = max(peak, abs(data[index])) }
            channel += interleaved
        }
        reading.record(peak)
    }
}

/// Post-fader taps on preview audio tracks. Each tap applies the clip's EQ and measures
/// the samples the mix plays, after volume ramps, for the mixer's meter.
enum MeterTap {
    static func make(for reading: MeterReading, eq: AudioEQ = .flat) -> MTAudioProcessingTap? {
        let context = TapContext(reading: reading, eq: eq)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(buffers)
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
