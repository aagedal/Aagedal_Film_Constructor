import AVFAudio
import CoreGraphics
import EditorCore
import Foundation

enum LivePlaybackClockError: Error, Equatable {
    case underrun
}

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
        guard clock <= scheduled || scheduled == total else { throw LivePlaybackClockError.underrun }
        let next = min(clock, total)
        if next == scheduled, scheduled < total { throw LivePlaybackClockError.underrun }
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
    /// AVAudioFormat permits an absent layout for mono/stereo. When hardware
    /// supplies speaker metadata, require a canonical tag or exact named channel
    /// order rather than guessing a map. No automatic downmix/upmix is qualified.
    static func validate(route: AVAudioFormat, expected: AVAudioFormat) throws {
        guard (1...2).contains(route.channelCount), route.channelCount == expected.channelCount,
              route.sampleRate.isFinite, route.sampleRate > 0 else {
            throw ProofFailure("Live hardware output must match the sequence's mono/stereo channel count; choose a compatible route")
        }
        if let layout = route.channelLayout {
            let tag = route.channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            guard layout.layoutTag == tag || canonicalDescriptions(layout, channels: route.channelCount) else {
                throw ProofFailure("Live hardware output has an unsupported speaker layout; choose a canonical mono/stereo route")
            }
        }
        // Hardware sample-rate conversion is AVAudioEngine's responsibility;
        // timeline progress still uses the separately validated player clock.
    }
    private static func canonicalDescriptions(_ layout: AVAudioChannelLayout, channels: AVAudioChannelCount) -> Bool {
        guard layout.layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions,
              layout.layout.pointee.mNumberChannelDescriptions == channels,
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return false }
        let descriptions = UnsafeRawPointer(layout.layout).advanced(by: offset)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        if channels == 1 {
            return descriptions[0].mChannelLabel == kAudioChannelLabel_Mono ||
                descriptions[0].mChannelLabel == kAudioChannelLabel_Center
        }
        return channels == 2 && descriptions[0].mChannelLabel == kAudioChannelLabel_Left &&
            descriptions[1].mChannelLabel == kAudioChannelLabel_Right
    }
    static func clock(sample: Int64, rate: Double, expectedRate: Double) throws -> Int64 {
        guard rate == expectedRate else { throw ProofFailure("Player clock sample rate differs from sequence") }
        guard sample >= 0 else { throw ProofFailure("Invalid player clock sample") }
        return sample
    }
}

/// Player nodes can report a negative sample time during device startup pre-roll.
/// It is unavailable time, not timeline progress. Once a clock is established,
/// negative samples are invalid rather than another startup interval.
struct LivePlayerClock {
    private(set) var initialized = false

    mutating func observe(sample: Int64, rate: Double, expectedRate: Double) throws -> Int64? {
        guard rate == expectedRate else {
            throw ProofFailure("Player clock sample rate differs from sequence")
        }
        if sample < 0, !initialized { return nil }
        let value = try LiveOutputQualification.clock(sample: sample, rate: rate, expectedRate: expectedRate)
        initialized = true
        return value
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
    public internal(set) var underruns: Int = 0
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

/// The hardware boundary also permits deterministic starvation and lifecycle
/// exercises without opening an audio device or consulting wall-clock progress.
@MainActor protocol LivePlaybackOutput: AnyObject {
    var isRunning: Bool { get }
    var isPlaying: Bool { get }
    var configurationObject: AnyObject { get }
    func validateRoute(format: AVAudioFormat) throws
    func start() throws
    func stop()
    func reset()
    func clock() -> (sample: Int64, rate: Double)?
    func schedule(_ buffer: AVAudioPCMBuffer, at sample: Int64)
}

@MainActor private final class LiveAudioEngineOutput: LivePlaybackOutput {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format: AVAudioFormat
    var isRunning: Bool { engine.isRunning }
    var isPlaying: Bool { player.isPlaying }
    var configurationObject: AnyObject { engine }

    init(format: AVAudioFormat) {
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }
    func validateRoute(format: AVAudioFormat) throws {
        try LiveOutputQualification.validate(route: engine.outputNode.outputFormat(forBus: 0), expected: format)
    }
    func start() throws {
        try validateRoute(format: format)
        try engine.start()
        do { try validateRoute(format: format) }
        catch { engine.stop(); throw error }
        player.play()
    }
    func stop() { player.stop(); engine.stop() }
    func reset() { engine.reset() }
    func clock() -> (sample: Int64, rate: Double)? {
        guard let render = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: render), time.isSampleTimeValid else { return nil }
        return (time.sampleTime, time.sampleRate)
    }
    func schedule(_ buffer: AVAudioPCMBuffer, at sample: Int64) {
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: sample, atRate: format.sampleRate),
                              completionHandler: nil)
    }
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
    private let output: any LivePlaybackOutput
    private let format: AVAudioFormat
    private var queue: LiveAudioQueue?
    private var startSample: Int64 = 0
    private var playerClock = LivePlayerClock()
    private var operation = UUID()
    private var pump: Task<Void, Never>?
    private var priming: Task<Void, any Error>?
    private var video: Task<Void, Never>?
    private var requestedFrame: Int64?
    private var closed = false
    private var replacing = false
    private var configurationObserver: LiveAudioConfigurationObserver?

    public convenience init(project: Project) throws {
        try self.init(project: project, session: nil, output: nil)
    }

    init(project: Project, session injectedSession: NativePlaybackSession?,
         output injectedOutput: (any LivePlaybackOutput)?) throws {
        let plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        try LiveOutputQualification.validate(layout: plan.settings.audioLayout)
        transport = try NativePlaybackTransport(plan: plan)
        session = try injectedSession ?? NativePlaybackSession(project: project, maximumPendingRequests: 2,
                                             maximumCacheBytes: 8 * 1024 * 1024)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(plan.settings.audioSampleRate),
            channels: AVAudioChannelCount(plan.settings.audioLayout.channels.count)) else {
            throw ProofFailure("Cannot create live audio format")
        }
        self.format = format
        output = injectedOutput ?? LiveAudioEngineOutput(format: format)
        configurationObserver = LiveAudioConfigurationObserver(object: output.configurationObject) { [weak self] in
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
        try output.validateRoute(format: format)
        video?.cancel(); video = nil; requestedFrame = nil
        let token = UUID(); operation = token
        guard transport.plan.audioSamples > 0 else { throw ProofFailure("Cannot play an empty sequence") }
        _ = try transport.play()
        startSample = transport.sampleIndex
        playerClock = .init()
        statistics = .init()
        queue = try LiveAudioQueue(total: transport.plan.audioSamples - startSample)
        do {
            let preparation = Task { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.fill(token: token)
            }
            priming = preparation
            try await withTaskCancellationHandler {
                try await preparation.value
                try Task.checkCancellation()
            } onCancel: { preparation.cancel() }
            guard token == operation else { throw CancellationError() }
            priming = nil
            try output.validateRoute(format: format)
            try output.start()
            let generation = transport.generation
            pump = Task { [weak self] in
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                do {
                    // Keep ownership scoped to a tick, releasing the monitor
                    // during polling sleeps so an abandoned player can deinit.
                    while try await self?.tick(token: token, generation: generation, deadline: deadline) == true {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    if self?.operation == token { self?.pause() }
                } catch {
                    if self?.operation == token { self?.fail(error) }
                }
            }
        } catch {
            if token == operation { stop(observeFinalClock: false) }
            throw error
        }
    }

    private func tick(token: UUID, generation: UUID, deadline: ContinuousClock.Instant) async throws -> Bool {
        guard token == operation, transport.isPlaying else { return false }
        guard output.isRunning else {
            statistics.unexpectedEngineStops += 1
            fail(ProofFailure("Live audio engine stopped unexpectedly; playback is paused. Play explicitly to restart"))
            return false
        }
        if let clock = try outputClock() {
            try advance(clock: clock, generation: generation)
            guard transport.isPlaying else { return false }
            requestVideo(token: token)
            try await fill(token: token)
        } else if ContinuousClock.now > deadline {
            throw ProofFailure("Live audio device did not produce a sample clock")
        }
        return token == operation && transport.isPlaying
    }

    /// Final observed player clock is submitted before flushing scheduled audio.
    public func pause() {
        stop(observeFinalClock: true)
    }

    private func stop(observeFinalClock: Bool) {
        if observeFinalClock, transport.isPlaying, let clock = try? outputClock() {
            // Apply the same admission validation as a pump tick. A starved or
            // regressed final reading must preserve the last accepted position.
            try? advance(clock: clock, generation: transport.generation)
        }
        operation = UUID(); priming?.cancel(); priming = nil; pump?.cancel(); pump = nil
        video?.cancel(); video = nil; requestedFrame = nil
        output.stop(); transport.pause(); queue = nil
    }

    private func fail(_ error: any Error) {
        if error as? LivePlaybackClockError == .underrun { statistics.underruns += 1 }
        stop(observeFinalClock: false)
        output.reset()
        if error as? LivePlaybackClockError == .underrun {
            failure?(ProofFailure("Live audio underrun; playback is paused at its last accepted position. Play explicitly to restart"))
        } else { failure?(error) }
    }

    func audioConfigurationChanged() {
        guard !closed else { return }
        statistics.configurationChanges += 1
        let wasPlaying = transport.isPlaying
        // The old node's sample-time epoch is no longer trustworthy. Preserve the
        // last accepted transport position, cancel all work, and flush the graph.
        stop(observeFinalClock: false)
        output.reset()
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
        guard let time = output.clock() else { return nil }
        return try playerClock.observe(sample: time.sample, rate: time.rate,
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
            if output.isPlaying, let clock = try outputClock() {
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
            output.schedule(buffer, at: queue.scheduled)
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
                if token == self.operation { self.fail(error) }
            }
        }
    }
}
