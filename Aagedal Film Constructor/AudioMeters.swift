import AVFoundation
import Combine
import MediaToolbox
import os

/// Peak level of one preview audio track, written on the audio thread and read on the main thread.
final class MeterReading: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    func record(_ peak: Float) { lock.withLock { $0 = max($0, peak) } }
    /// Returns the peak since the last read and resets it.
    func take() -> Float { lock.withLock { value in defer { value = 0 }; return value } }
}

/// Post-fader taps on preview audio tracks. Each tap measures the samples the mix plays,
/// after volume ramps, and reports the peak to its reading.
enum MeterTap {
    static func make(for reading: MeterReading) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(reading).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<MeterReading>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: nil, unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let reading = Unmanaged<MeterReading>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var peak: Float = 0
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { peak = max(peak, abs(data[index])) }
                }
                reading.record(peak)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            // Creation failed, so finalize will never release the retained reading.
            Unmanaged<MeterReading>.fromOpaque(callbacks.clientInfo!).release()
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
