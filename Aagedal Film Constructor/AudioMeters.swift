import AVFoundation
import Combine
import MediaToolbox
import os
import EditorCore

/// Peak levels per channel of one preview audio track, written on the audio thread and read
/// on the main thread.
nonisolated final class MeterReading: @unchecked Sendable {
    static let maxChannels = 8
    private let lock = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: MeterReading.maxChannels + 1))
    /// The last slot holds how many channels have been delivered.
    func record(_ peaks: UnsafeBufferPointer<Float>) {
        // Unchecked: the buffer is only read inside the lock, on the calling thread.
        lock.withLockUnchecked { state in
            for (channel, peak) in peaks.prefix(Self.maxChannels).enumerated() { state[channel] = max(state[channel], peak) }
            state[Self.maxChannels] = max(state[Self.maxChannels], Float(min(peaks.count, Self.maxChannels)))
        }
    }
    /// Returns each channel's peak since the last read and resets them.
    func take() -> [Float] {
        lock.withLock { state in
            let peaks = Array(state.prefix(Int(state[Self.maxChannels])))
            for channel in 0..<Self.maxChannels { state[channel] = 0 }
            return peaks
        }
    }
}

/// One selected source channel and the output channel it plays on.
nonisolated struct TapRoute: Equatable, Sendable {
    let input: Int
    let output: Int
}

/// One way a track's sound reaches a main bus in preview: the buses it passes, each with its
/// effects and fader gain.
nonisolated struct TapPath: Sendable {
    let main: UUID
    let stages: [(bus: UUID, effects: [AudioEffect], gain: Double)]
    var isTransparent: Bool { stages.allSatisfy { $0.effects.isEmpty && $0.gain == 1 } }
}

/// How a tap's track joins the mix: the track's insert effects, its routes to main buses,
/// the main bus being monitored and the hub that gathers bus meters.
nonisolated struct TapMix: Sendable {
    var trackEffects: [AudioEffect] = []
    var paths: [TapPath] = []
    var monitored: UUID?
    var hub: MixMeterHub?
}

/// What a preview audio tap does: makeup gain, optional EQ and dynamics per selected channel,
/// channel routing, the track's effects and its bus chain, then metering of the result.
/// Track and bus effects run on each clip's sound; for EQ and gain that equals processing
/// the sum, while compressors hear each clip on its own (export compresses the sum).
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
    private var peaks = [Float](repeating: 0, count: MeterReading.maxChannels)
    private let mix: TapMix
    private var sampleRate = 48000.0
    private var trackEffects: AudioEffectProcessor?
    /// Per path, per stage: a processor with its own state.
    private var pathProcessors: [[AudioEffectProcessor]] = []
    /// Which (path, stage) feeds each bus meter, so a submix shared by two paths meters once.
    private var meterOwners: Set<[Int]> = []
    private var frame: [Double] = [], work: [Double] = [], sum: [Double] = []
    /// Interleaved bus contributions for this callback, by bus.
    private var deposits: [UUID: [Float]] = [:]
    init(reading: MeterReading, eq: AudioEQ, dynamics: AudioDynamics?, makeup: Double = 1, routes: [TapRoute]? = nil, mix: TapMix = .init()) {
        self.reading = reading; self.eq = eq; self.dynamics = dynamics; self.makeup = makeup; requestedRoutes = routes; self.mix = mix
    }
    /// Whether the mix stage changes or meters anything.
    var rate: Double { sampleRate }
    private var mixes: Bool {
        mix.hub != nil || !mix.trackEffects.isEmpty || !(mix.paths.count == 1 && mix.paths[0].main == mix.monitored && mix.paths[0].isTransparent)
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
        self.sampleRate = sampleRate
        trackEffects = mix.trackEffects.isEmpty ? nil : AudioEffectProcessor(effects: mix.trackEffects, sampleRate: sampleRate, channels: channels)
        pathProcessors = mix.paths.map { path in path.stages.map { AudioEffectProcessor(effects: $0.effects, sampleRate: sampleRate, channels: channels) } }
        var metered = Set<UUID>(); meterOwners = []
        for (p, path) in mix.paths.enumerated() {
            for (s, stage) in path.stages.enumerated() where metered.insert(stage.bus).inserted { meterOwners.insert([p, s]) }
        }
        frame = Array(repeating: 0, count: channels); work = frame; sum = frame
        deposits = [:]
        if let hub = mix.hub {
            for bus in metered { deposits[bus] = Array(repeating: 0, count: max(1, maxFrames) * hub.channels) }
        }
    }

    /// `frames` is the count the tap delivered; buffers may be larger. `start` is the
    /// composition sample index of the first frame, for time-aligned bus meters.
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames delivered: Int, start: Int64? = nil) {
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
        let channels = min(lanes.count, peaks.count)
        if mixes, !lanes.isEmpty, lanes.count == frame.count {
            mixStage(start: start)
        } else {
            for (channel, lane) in lanes.prefix(channels).enumerated() {
                var peak: Float = 0
                for frame in 0..<lane.frames { peak = max(peak, abs(lane.data[frame * lane.stride]) * Float(levelScale)) }
                peaks[channel] = peak
            }
        }
        peaks.withUnsafeBufferPointer { reading.record(UnsafeBufferPointer(rebasing: $0.prefix(channels))) }
    }

    /// Track effects, the track meter, then every bus path: the monitored main's paths are
    /// what plays, and each bus's contribution goes to its meter.
    private func mixStage(start: Int64?) {
        let count = lanes.count
        let frames = lanes.map(\.frames).min() ?? 0
        let hubChannels = mix.hub?.channels ?? 0
        for c in 0..<min(count, peaks.count) { peaks[c] = 0 }
        for f in 0..<frames {
            for c in 0..<count { frame[c] = Double(lanes[c].data[f * lanes[c].stride]) * levelScale }
            frame.withUnsafeMutableBufferPointer { trackEffects?.process($0.baseAddress!) }
            for c in 0..<min(count, peaks.count) { peaks[c] = max(peaks[c], Float(abs(frame[c]))) }
            for c in 0..<count { sum[c] = 0 }
            for (p, path) in mix.paths.enumerated() {
                for c in 0..<count { work[c] = frame[c] }
                for (s, stage) in path.stages.enumerated() {
                    work.withUnsafeMutableBufferPointer { pathProcessors[p][s].process($0.baseAddress!) }
                    for c in 0..<count { work[c] *= stage.gain }
                    if hubChannels > 0, meterOwners.contains([p, s]), deposits[stage.bus] != nil {
                        // Mono taps play on every output, as the system mixer does.
                        for h in 0..<hubChannels { deposits[stage.bus]![f * hubChannels + h] = Float(work[count == 1 ? 0 : min(h, count - 1)]) }
                    }
                }
                if path.main == mix.monitored { for c in 0..<count { sum[c] += work[c] } }
            }
            for c in 0..<count { lanes[c].data[f * lanes[c].stride] = Float(sum[c] / levelScale) }
        }
        if let hub = mix.hub, let start {
            for (bus, buffer) in deposits {
                buffer.withUnsafeBufferPointer { hub.add(bus: bus, at: start, interleaved: $0.baseAddress!, frames: min(frames, $0.count / max(1, hubChannels))) }
            }
        }
    }
}

/// Post-fader taps on preview audio tracks. Each tap applies the clip's makeup gain, EQ,
/// dynamics and routing, and measures the samples the mix plays, after volume ramps, for
/// the mixer's meter.
nonisolated enum MeterTap {
    static func make(for reading: MeterReading, eq: AudioEQ = .flat, dynamics: AudioDynamics? = nil,
                     makeup: Double = 1, routes: [TapRoute]? = nil, mix: TapMix = .init()) -> MTAudioProcessingTap? {
        let context = TapContext(reading: reading, eq: eq, dynamics: dynamics, makeup: makeup, routes: routes, mix: mix)
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
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let start = range.start.isNumeric ? Int64((range.start.seconds * context.rate).rounded()) : nil
                context.process(buffers, frames: Int(framesOut.pointee), start: start)
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

/// Time-aligned sums of every tap's contribution to each bus. Taps add blocks at their
/// composition sample position; the meters read everything older than a short latency, by
/// which time all taps have delivered that stretch.
nonisolated final class MixMeterHub: @unchecked Sendable {
    let channels: Int
    let sampleRate: Double
    private let capacity: Int
    private let lock = NSLock()
    private var rings: [UUID: [Float]]
    private var readPosition: Int64?
    private var highWater: Int64 = 0

    init(buses: [UUID], channels: Int, sampleRate: Double) {
        self.channels = max(1, channels); self.sampleRate = sampleRate
        capacity = Int(sampleRate * 2)
        rings = Dictionary(uniqueKeysWithValues: buses.map { ($0, [Float](repeating: 0, count: Int(sampleRate * 2) * max(1, channels))) })
    }

    func add(bus: UUID, at start: Int64, interleaved: UnsafePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard rings[bus] != nil, frames > 0 else { return }
        // A seek or a long stall starts over at the new position.
        if let read = readPosition, start < read - Int64(capacity / 4) || start + Int64(frames) > read + Int64(capacity) { reset(at: start) }
        if readPosition == nil { reset(at: start) }
        let read = readPosition!
        rings[bus]!.withUnsafeMutableBufferPointer { ring in
            for f in 0..<frames {
                let position = start + Int64(f)
                guard position >= read else { continue }
                let slot = Int(position % Int64(capacity)) * channels
                for c in 0..<channels { ring[slot + c] += interleaved[f * channels + c] }
            }
        }
        highWater = max(highWater, start + Int64(frames))
    }

    private func reset(at start: Int64) {
        for key in rings.keys { rings[key] = [Float](repeating: 0, count: capacity * channels) }
        readPosition = start; highWater = start
    }

    /// Interleaved frames per bus up to `latency` seconds before the newest delivery.
    func drain(latency: Double = 0.15) -> [UUID: [Float]] {
        lock.lock(); defer { lock.unlock() }
        guard let read = readPosition else { return [:] }
        let end = highWater - Int64(latency * sampleRate)
        guard end > read else { return [:] }
        let count = Int(min(end - read, Int64(capacity)))
        var result: [UUID: [Float]] = [:]
        for key in rings.keys {
            var out = [Float](repeating: 0, count: count * channels)
            rings[key]!.withUnsafeMutableBufferPointer { ring in
                for f in 0..<count {
                    let slot = Int((read + Int64(f)) % Int64(capacity)) * channels
                    for c in 0..<channels { out[f * channels + c] = ring[slot + c]; ring[slot + c] = 0 }
                }
            }
            result[key] = out
        }
        readPosition = read + Int64(count)
        return result
    }
}

/// Levels per editorial audio track and per channel for the mixer, in dBFS with a falling
/// peak hold.
@MainActor
final class AudioMeters: ObservableObject {
    static let shared = AudioMeters()
    /// The loudest channel of each track.
    @Published private(set) var levels: [UUID: Float] = [:]
    /// Each channel the track plays on, in output order.
    @Published private(set) var channelLevels: [UUID: [Float]] = [:]
    /// Each bus's channels, post-fader, in dBFS with the same falling hold.
    @Published private(set) var busLevels: [UUID: [Float]] = [:]
    /// Loudness of each main bus while the sequence plays.
    @Published private(set) var loudness: [UUID: LoudnessMeter.Reading] = [:]
    private var readings: [UUID: [MeterReading]] = [:]
    private var hub: MixMeterHub?
    private var mainBuses: Set<UUID> = []
    private var loudnessMeters: [UUID: LoudnessMeter] = [:]
    private var timer: Timer?

    /// Replaces the readings for a newly prepared preview. Loudness keeps integrating across
    /// preview rebuilds of the same bus until it is reset.
    func attach(_ readings: [UUID: [MeterReading]], hub: MixMeterHub? = nil, mains: [UUID] = [], layout: ChannelLayout = .stereo) {
        self.readings = readings
        self.hub = hub; mainBuses = Set(mains)
        let meterLayout = hub?.channels == 1 ? ChannelLayout.mono : .stereo
        for main in mains where loudnessMeters[main]?.channels != meterLayout.channels.count {
            loudnessMeters[main] = LoudnessMeter(sampleRate: hub?.sampleRate ?? 48000, layout: meterLayout)
        }
        levels = [:]; channelLevels = [:]; busLevels = [:]
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { AudioMeters.shared.poll() }
        }
    }
    func detach() { readings = [:]; hub = nil; levels = [:]; channelLevels = [:]; busLevels = [:] }

    /// Starts loudness measurement over for every main bus.
    func resetLoudness() {
        loudnessMeters.values.forEach { $0.reset() }
        loudness = loudnessMeters.mapValues(\.reading)
    }

    func poll() {
        var next = channelLevels
        for (track, sources) in readings {
            // A track's clips each have their own tap; a channel shows the loudest of them.
            var peaks: [Float] = []
            for source in sources {
                for (channel, peak) in source.take().enumerated() {
                    if channel < peaks.count { peaks[channel] = max(peaks[channel], peak) } else { peaks.append(peak) }
                }
            }
            let previous = channelLevels[track] ?? []
            let count = max(peaks.count, previous.count)
            next[track] = (0..<count).map { channel in
                let peak = channel < peaks.count ? peaks[channel] : 0
                let decibels: Float = peak > 0 ? 20 * log10(peak) : -120
                // Fall back by 1.5 dB per poll (30 dB per second) unless the new peak is higher.
                return max(decibels, (channel < previous.count ? previous[channel] : -120) - 1.5)
            }
        }
        if next != channelLevels {
            channelLevels = next
            levels = next.mapValues { $0.max() ?? -120 }
        }
        guard let hub else { return }
        let blocks = hub.drain()
        var buses = busLevels
        for (bus, samples) in blocks {
            var peaks = [Float](repeating: 0, count: hub.channels)
            for (index, sample) in samples.enumerated() { peaks[index % hub.channels] = max(peaks[index % hub.channels], abs(sample)) }
            let previous = busLevels[bus] ?? []
            buses[bus] = peaks.enumerated().map { channel, peak in
                let decibels: Float = peak > 0 ? 20 * log10(peak) : -120
                return max(decibels, (channel < previous.count ? previous[channel] : -120) - 1.5)
            }
            if mainBuses.contains(bus), let meter = loudnessMeters[bus], meter.channels == hub.channels {
                meter.add(interleaved: samples)
            }
        }
        if blocks.isEmpty {
            // Silence or pause: let the bus meters fall.
            buses = buses.mapValues { $0.map { max(-120, $0 - 1.5) } }
        }
        if buses != busLevels { busLevels = buses }
        if !blocks.isEmpty {
            let readings = loudnessMeters.filter { mainBuses.contains($0.key) }.mapValues(\.reading)
            if readings != loudness { loudness = readings }
        }
    }
}
