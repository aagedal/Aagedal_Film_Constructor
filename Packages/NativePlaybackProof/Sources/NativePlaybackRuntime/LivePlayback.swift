import AVFAudio
import CoreGraphics
import EditorCore
import Foundation

/// Bounded sample-time admission, independent of decoding and wall-clock time.
/// The live proof stops on starvation instead of silently advancing over gaps.
struct LiveAudioQueue {
    let total: Int64
    let blockSize: Int
    let maximumBlocks: Int
    private(set) var scheduled: Int64 = 0
    private(set) var clock: Int64 = 0

    init(total: Int64, blockSize: Int = 1024, maximumBlocks: Int = 4) throws {
        guard total > 0, (1...65536).contains(blockSize), (2...16).contains(maximumBlocks) else {
            throw ProofFailure("Invalid live audio queue limits")
        }
        self.total = total; self.blockSize = blockSize; self.maximumBlocks = maximumBlocks
    }

    var nextCount: Int? {
        let available = Int64(blockSize * maximumBlocks) - (scheduled - clock)
        let count = min(Int64(blockSize), total - scheduled)
        guard count > 0, available >= count else { return nil }
        return Int(count)
    }

    mutating func commit(count: Int) throws {
        guard let allowed = nextCount, count > 0, count <= allowed else { throw ProofFailure("Live schedule exceeds bounded admission") }
        scheduled += Int64(count)
    }

    mutating func update(clock: Int64) throws {
        guard clock >= self.clock, clock >= 0 else { throw ProofFailure("Live output clock regressed") }
        guard clock <= scheduled || scheduled == total else { throw ProofFailure("Live audio underrun") }
        let next = min(clock, total)
        if next == scheduled, scheduled < total { throw ProofFailure("Live audio underrun") }
        self.clock = next
    }
}

/// Fail explicitly rather than silently adapting surround or changing time grids.
enum LiveOutputQualification {
    static func validate(layout: ChannelLayout) throws {
        guard layout == .mono || layout == .stereo else {
            throw ProofFailure("Live proof supports canonical mono/stereo output only")
        }
    }
    static func clock(sample: Int64, rate: Double, expectedRate: Double) throws -> Int64 {
        guard rate == expectedRate else { throw ProofFailure("Player clock sample rate differs from sequence") }
        guard sample >= 0 else { throw ProofFailure("Invalid player clock sample") }
        return sample
    }
}

public struct LivePlaybackStatistics: Sendable, Codable {
    public internal(set) var clockSamples: Int64 = 0
    public internal(set) var scheduledSamples: Int64 = 0
    public internal(set) var displayedFrames: Int = 0
    public internal(set) var discardedFrames: Int = 0
    public internal(set) var maximumQueuedSamples: Int64 = 0
    public internal(set) var configurationChanges: Int = 0
    public internal(set) var unexpectedEngineStops: Int = 0
}

/// NotificationCenter retains block observers until explicitly removed. Keep the
/// token outside actor isolation so releasing a monitor also removes its observer.
/// The immutable token and NotificationCenter's thread-safe removal permit cleanup
/// on whichever thread releases the last reference.
final class LiveAudioConfigurationObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(object: AnyObject, center: NotificationCenter = .default,
         changed: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                   object: object, queue: nil) { _ in changed() }
    }

    deinit { center.removeObserver(token) }
}

/// Development hardware-output monitor. All AVAudioEngine and display mutation
/// is serialized on MainActor; decoder work runs on NativePlaybackSession's queue.
/// AVAudioPlayerNode's render clock is measured, not acoustic device presentation.
/// A polling display and fail-closed underrun policy are intentionally explicit.
@MainActor public final class NativeLivePlayback {
    public private(set) var transport: NativePlaybackTransport
    public private(set) var statistics = LivePlaybackStatistics()
    public var display: ((CGImage, Int64) -> Void)?
    public var failure: ((any Error) -> Void)?
    private let session: NativePlaybackSession
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var queue: LiveAudioQueue?
    private var startSample: Int64 = 0
    private var operation = UUID()
    private var pump: Task<Void, Never>?
    private var video: Task<Void, Never>?
    private var requestedFrame: Int64?
    private var closed = false
    private var replacing = false
    private var configurationObserver: LiveAudioConfigurationObserver?

    public init(project: Project) throws {
        let plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        try LiveOutputQualification.validate(layout: plan.settings.audioLayout)
        transport = try NativePlaybackTransport(plan: plan)
        session = try NativePlaybackSession(project: project, maximumPendingRequests: 2,
                                             maximumCacheBytes: 8 * 1024 * 1024)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(plan.settings.audioSampleRate),
            channels: AVAudioChannelCount(plan.settings.audioLayout.channels.count)) else {
            throw ProofFailure("Cannot create live audio format")
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configurationObserver = LiveAudioConfigurationObserver(object: engine) { [weak self] in
            // Engine notifications can originate on an audio thread. Never mutate
            // the graph there, and do not retain the monitor while dispatching.
            Task { @MainActor [weak self] in self?.audioConfigurationChanged() }
        }
    }

    /// Prime bounded audio before starting the device. First-use source indexing
    /// can be slow; play does not imply any startup-latency qualification.
    public func play() async throws {
        guard !closed else { throw PlaybackSessionError.closed }
        guard !replacing else { throw PlaybackSessionError.busy }
        guard pump == nil, !transport.isPlaying else { return }
        video?.cancel(); video = nil; requestedFrame = nil
        let token = UUID(); operation = token
        guard transport.plan.audioSamples > 0 else { throw ProofFailure("Cannot play an empty sequence") }
        _ = try transport.play()
        startSample = transport.sampleIndex
        statistics = .init()
        queue = try LiveAudioQueue(total: transport.plan.audioSamples - startSample)
        do {
            try await fill(token: token)
            guard token == operation else { throw CancellationError() }
            try engine.start()
            player.play()
            let generation = transport.generation
            pump = Task { [weak self] in
                guard let self else { return }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                do {
                    while token == self.operation, self.transport.isPlaying {
                        guard self.engine.isRunning else {
                            self.statistics.unexpectedEngineStops += 1
                            self.stop(observeFinalClock: false)
                            self.engine.reset()
                            self.failure?(ProofFailure("Live audio engine stopped unexpectedly; playback is paused. Play explicitly to restart"))
                            break
                        }
                        if let clock = try self.outputClock() {
                            try self.advance(clock: clock, generation: generation)
                            if !self.transport.isPlaying { break }
                            self.requestVideo(token: token)
                            try await self.fill(token: token)
                        } else if ContinuousClock.now > deadline {
                            throw ProofFailure("Live audio device did not produce a sample clock")
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    if token == self.operation { self.pause() }
                } catch {
                    if token == self.operation { self.pause(); self.failure?(error) }
                }
            }
        } catch {
            if token == operation { pause() }
            throw error
        }
    }

    /// Final observed player clock is submitted before flushing scheduled audio.
    public func pause() {
        stop(observeFinalClock: true)
    }

    private func stop(observeFinalClock: Bool) {
        if observeFinalClock, transport.isPlaying, let clock = try? outputClock(), let queue {
            // Never advance over unscheduled silence after a detected underrun.
            _ = try? transport.update(clockSample: min(clock, queue.scheduled), generation: transport.generation)
        }
        operation = UUID(); pump?.cancel(); pump = nil
        video?.cancel(); video = nil; requestedFrame = nil
        player.stop(); engine.stop(); transport.pause(); queue = nil
    }

    private func audioConfigurationChanged() {
        guard !closed else { return }
        statistics.configurationChanges += 1
        let wasPlaying = transport.isPlaying
        // The old node's sample-time epoch is no longer trustworthy. Preserve the
        // last accepted transport position, cancel all work, and flush the graph.
        stop(observeFinalClock: false)
        engine.reset()
        if wasPlaying {
            failure?(ProofFailure("Live audio configuration changed; playback is paused. Play explicitly to restart"))
        }
    }

    /// Seeks flush the audio node, cancel queued decodes, and reject values that
    /// finish after the seek. A running seek primes a new sample-clock epoch.
    public func seek(toFrame frame: Int64) async throws {
        guard !closed else { throw PlaybackSessionError.closed }
        guard !replacing else { throw PlaybackSessionError.busy }
        let resume = transport.isPlaying
        pause()
        let token = operation
        await session.invalidate()
        guard operation == token else { throw CancellationError() }
        try transport.seek(toFrame: frame)
        requestVideo(token: token)
        if resume, transport.frameIndex != nil { try await play() }
    }

    /// Clip/edit replacement retains the fixed output format. Validate before
    /// stopping the old plan; output-format changes require a new live monitor.
    public func replace(project: Project) async throws {
        guard !closed else { throw PlaybackSessionError.closed }
        guard !replacing else { throw PlaybackSessionError.busy }
        let plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        try LiveOutputQualification.validate(layout: plan.settings.audioLayout)
        guard plan.settings.width <= 4096, plan.settings.height <= 4096,
              plan.settings.audioSampleRate == transport.plan.settings.audioSampleRate,
              plan.settings.audioLayout == transport.plan.settings.audioLayout else {
            throw ProofFailure("Live replacement requires bounded raster and unchanged output audio format")
        }
        pause(); replacing = true
        let token = operation
        defer { replacing = false }
        try await session.replace(project: project)
        guard !closed else { throw CancellationError() }
        // The session has committed the plan. Keep transport coherent, but never
        // submit a display request from a replacement invalidated while awaiting.
        try transport.replacePlan(plan)
        guard token == operation else { throw CancellationError() }
        requestVideo(token: token)
    }

    public func close() async {
        guard !closed else { return }
        closed = true; configurationObserver = nil
        pause()
        await session.close()
    }

    private func outputClock() throws -> Int64? {
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render),
              time.isSampleTimeValid else { return nil }
        return try LiveOutputQualification.clock(sample: time.sampleTime, rate: time.sampleRate,
                                                  expectedRate: format.sampleRate)
    }

    private func advance(clock: Int64, generation: UUID) throws {
        guard var queue else { return }
        try queue.update(clock: clock)
        self.queue = queue
        statistics.clockSamples = queue.clock
        try transport.update(clockSample: clock, generation: generation)
    }

    private func fill(token: UUID) async throws {
        var filledBlocks = 0
        while token == operation, filledBlocks < 4, let current = queue, let count = current.nextCount {
            filledBlocks += 1
            let value = try await session.audio(start: startSample + current.scheduled, count: count)
            let accepted = await session.accepts(value.epoch)
            guard token == operation, accepted else { throw CancellationError() }
            // Decoding may have consumed the remaining look-ahead. Inspect the
            // actual clock before scheduling a buffer at its absolute time.
            if player.isPlaying, let clock = try outputClock() {
                try advance(clock: clock, generation: transport.generation)
            }
            guard var queue, queue.scheduled == current.scheduled,
                  value.value.count == count * Int(format.channelCount),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)),
                  let channels = buffer.floatChannelData else {
                throw ProofFailure("Cannot construct live output block")
            }
            buffer.frameLength = UInt32(count)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<count { channels[channel][frame] = value.value[frame * Int(format.channelCount) + channel] }
            }
            // Completion awaits playback; priming must use the nonblocking overload.
            player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: queue.scheduled, atRate: format.sampleRate),
                                  completionHandler: nil)
            try queue.commit(count: count)
            self.queue = queue
            statistics.scheduledSamples = queue.scheduled
            statistics.maximumQueuedSamples = max(statistics.maximumQueuedSamples, queue.scheduled - queue.clock)
        }
    }

    private func requestVideo(token: UUID) {
        guard video == nil, let frame = transport.frameIndex, frame != requestedFrame else { return }
        requestedFrame = frame
        video = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.operation { self.video = nil } }
            do {
                let value = try await self.session.video(frame: frame)
                let accepted = await self.session.accepts(value.epoch)
                // An obsolete play/seek must not mutate the new operation's counters.
                guard token == self.operation else { return }
                guard accepted, self.transport.frameIndex == frame else {
                    self.statistics.discardedFrames += 1
                    self.requestedFrame = nil
                    return
                }
                let image = try nativeImage(rgb: value.value, width: self.transport.plan.settings.width,
                                            height: self.transport.plan.settings.height)
                self.display?(image, frame)
                self.statistics.displayedFrames += 1
            } catch {
                if token == self.operation { self.pause(); self.failure?(error) }
            }
        }
    }
}
