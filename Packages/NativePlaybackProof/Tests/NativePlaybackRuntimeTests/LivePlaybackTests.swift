import Foundation
import AVFAudio
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

struct LivePlaybackTests {
    @Test func playerStartupPrerollDoesNotEstablishOrAdvanceClock() throws {
        var clock = LivePlayerClock()
        var queue = try LiveAudioQueue(total: 10000)
        try queue.commit(count: 1024)
        for sample: Int64 in [-2048, -512, -1] {
            if let value = try clock.observe(sample: sample, rate: 48000, expectedRate: 48000) {
                try queue.update(clock: value)
            }
            #expect(!clock.initialized)
            #expect(queue.clock == 0)
        }
        #expect(try clock.observe(sample: 0, rate: 48000, expectedRate: 48000) == 0)
        #expect(clock.initialized)
        #expect(try clock.observe(sample: 256, rate: 48000, expectedRate: 48000) == 256)
        #expect(throws: (any Error).self) {
            try clock.observe(sample: -1, rate: 48000, expectedRate: 48000)
        }
        #expect(clock.initialized)
        clock = .init() // A new explicit play starts a new node clock epoch.
        #expect(try clock.observe(sample: -512, rate: 48000, expectedRate: 48000) == nil)
        #expect(!clock.initialized)
    }

    @Test func prerollStillRejectsChangedSampleRate() throws {
        var clock = LivePlayerClock()
        #expect(throws: (any Error).self) {
            try clock.observe(sample: -512, rate: 44100, expectedRate: 48000)
        }
        #expect(!clock.initialized)
        #expect(try clock.observe(sample: 0, rate: 48000, expectedRate: 48000) == 0)
        #expect(throws: (any Error).self) {
            try clock.observe(sample: 128, rate: 44100, expectedRate: 48000)
        }
    }

    @Test func configurationObserverIsScopedAndRemovedOnRelease() {
        let center = NotificationCenter()
        let engine = NSObject()
        let unrelated = NSObject()
        let counter = NotificationCounter()
        var observer: LiveAudioConfigurationObserver? = LiveAudioConfigurationObserver(
            object: engine, center: center, changed: { counter.increment() })
        #expect(observer != nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: unrelated)
        center.post(name: Notification.Name("unrelated"), object: engine)
        #expect(counter.count == 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(counter.count == 1)
        observer = nil
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(counter.count == 1)
    }

    @Test func removingConfigurationObserverReleasesCallbackCaptures() {
        let center = NotificationCenter()
        let engine = NSObject()
        weak var retained: NotificationCounter?
        var observer: LiveAudioConfigurationObserver?
        do {
            let counter = NotificationCounter()
            retained = counter
            observer = LiveAudioConfigurationObserver(object: engine, center: center,
                                                      changed: { counter.increment() })
        }
        #expect(observer != nil)
        #expect(retained != nil)
        observer = nil
        #expect(retained == nil)
    }

    @Test func liveStatisticsEncodeLifecycleFailures() throws {
        var statistics = LivePlaybackStatistics()
        statistics.configurationChanges = 2
        statistics.unexpectedEngineStops = 1
        statistics.underruns = 3
        let decoded = try JSONDecoder().decode(LivePlaybackStatistics.self,
                                               from: JSONEncoder().encode(statistics))
        #expect(decoded.configurationChanges == 2)
        #expect(decoded.unexpectedEngineStops == 1)
        #expect(decoded.underruns == 3)
    }

    @Test func scheduleIsBoundedAndClockCreatesAdmission() throws {
        var queue = try LiveAudioQueue(total: 20000)
        for _ in 0..<4 { try queue.commit(count: 1024) }
        #expect(queue.scheduled == 4096)
        #expect(queue.nextCount == nil)
        #expect(throws: (any Error).self) { try queue.commit(count: 1) }
        try queue.update(clock: 100)
        #expect(queue.nextCount == nil)
        try queue.update(clock: 1024)
        #expect(queue.nextCount == 1024)
        try queue.commit(count: 1024)
        #expect(queue.scheduled - queue.clock <= 4096)
    }

    @Test func starvationAndRegressingClocksFailWithoutAdvancing() throws {
        var queue = try LiveAudioQueue(total: 10000)
        try queue.commit(count: 1024)
        try queue.update(clock: 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 99) }
        #expect(queue.clock == 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 1025) }
        #expect(queue.clock == 100)
        #expect(throws: (any Error).self) { try queue.update(clock: 1024) }
        #expect(queue.clock == 100)
    }

    @Test func finalPartialBlockAcceptsDeviceOvershoot() throws {
        var queue = try LiveAudioQueue(total: 1500)
        try queue.commit(count: 1024)
        #expect(queue.nextCount == 476)
        try queue.commit(count: 476)
        try queue.update(clock: 1600)
        #expect(queue.clock == 1500)
        #expect(queue.nextCount == nil)
    }

    @Test func liveOutputRejectsSurroundAndChangedSampleGrid() throws {
        try LiveOutputQualification.validate(layout: .mono)
        try LiveOutputQualification.validate(layout: .stereo)
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.validate(layout: ChannelLayout(channels: [.left, .right, .mono]))
        }
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.clock(sample: 10, rate: 44100, expectedRate: 48000)
        }
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.clock(sample: -1, rate: 48000, expectedRate: 48000)
        }
        #expect(try LiveOutputQualification.clock(sample: 1024, rate: 48000, expectedRate: 48000) == 1024)
    }

    @Test func hardwareRouteRequiresMatchingCanonicalChannels() throws {
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        try LiveOutputQualification.validate(route: mono, expected: mono)
        try LiveOutputQualification.validate(route: stereo, expected: stereo)
        let converted = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        try LiveOutputQualification.validate(route: converted, expected: stereo)
        #expect(throws: (any Error).self) { try LiveOutputQualification.validate(route: mono, expected: stereo) }
        #expect(throws: (any Error).self) { try LiveOutputQualification.validate(route: stereo, expected: mono) }
        for tag in [kAudioChannelLayoutTag_MPEG_5_1_A, kAudioChannelLayoutTag_DiscreteInOrder | 2] {
            let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
            let route = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            #expect(throws: (any Error).self) { try LiveOutputQualification.validate(route: route, expected: stereo) }
        }
    }

    @Test func hardwareRouteAcceptsOnlyCanonicalNamedDescriptions() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try LiveOutputQualification.validate(route: describedLiveRoute([kAudioChannelLabel_Left, kAudioChannelLabel_Right]), expected: stereo)
        for label in [kAudioChannelLabel_Mono, kAudioChannelLabel_Center] {
            try LiveOutputQualification.validate(route: describedLiveRoute([label]), expected: mono)
        }
        for labels in [[kAudioChannelLabel_Right, kAudioChannelLabel_Left],
                       [kAudioChannelLabel_Unknown, kAudioChannelLabel_Unknown],
                       [kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Discrete_1],
                       [kAudioChannelLabel_Left, kAudioChannelLabel_Center]] {
            #expect(throws: (any Error).self) {
                try LiveOutputQualification.validate(route: describedLiveRoute(labels), expected: stereo)
            }
        }
        #expect(throws: (any Error).self) {
            try LiveOutputQualification.validate(route: describedLiveRoute([kAudioChannelLabel_Left]), expected: mono)
        }
    }

    @Test func invalidLimitsAndMalformedImagesAreRejected() throws {
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 0) }
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 100, blockSize: 65537) }
        #expect(throws: (any Error).self) { try LiveAudioQueue(total: 100, maximumBlocks: 1) }
        #expect(throws: (any Error).self) { try nativeImage(rgb: Data(count: 11), width: 2, height: 2) }
        #expect(try nativeImage(rgb: Data(count: 12), width: 2, height: 2).width == 2)
    }
}

private func describedLiveRoute(_ labels: [AudioChannelLabel]) throws -> AVAudioFormat {
    let offset = try #require(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
    let bytes = offset + MemoryLayout<AudioChannelDescription>.stride * labels.count
    let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
    let descriptions = raw.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
    for (index, label) in labels.enumerated() { descriptions[index].mChannelLabel = label }
    let copied = AVAudioChannelLayout(layout: layout)
    return AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: copied)
}

private func liveFixture() throws -> Project {
    let rate = try FrameRate(30)
    let settings = try SequenceSettings(width: 2, height: 2, frameRate: rate)
    let template = TrackTemplate(kind: .video)
    let family = TrackFamily(baseName: "Video", template: template)
    let asset = MediaAsset(name: "A", originalURL: URL(fileURLWithPath: "/private/tmp/unused.mov"),
        duration: try rate.time(forFrames: 300), streams: [.init(index: 0, kind: .video)])
    let clip = TimelineClip(assetID: asset.id,
        sourceRange: try TimeRange(start: .zero, duration: rate.time(forFrames: 180)), selection: .video(streamIndex: 0))
    return Project(settings: settings, assets: [asset], families: [family],
        tracks: [.init(familyID: family.id, template: template, clips: [clip])])
}

private final class LiveFakeDecoder: PlaybackDecoder {
    func video(frame: Int64) throws -> Data { Data(count: 12) }
    func audio(start: Int64, count: Int) throws -> [Float] { Array(repeating: 0, count: count * 2) }
}

@MainActor private final class LiveFakeOutput: LivePlaybackOutput {
    var isRunning = false
    var isPlaying = false
    let configurationObject: AnyObject = NSObject()
    var samples: [Int64] = []
    var current: Int64 = 0
    var scheduled: [Int64] = []
    var starts = 0
    var stops = 0
    var resets = 0
    var onStart: (() -> Void)?
    var route = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    func validateRoute(format: AVAudioFormat) throws {
        try LiveOutputQualification.validate(route: route, expected: format)
    }
    func start() { starts += 1; isRunning = true; isPlaying = true; onStart?() }
    func stop() { stops += 1; isRunning = false; isPlaying = false }
    func reset() { resets += 1 }
    func clock() -> (sample: Int64, rate: Double)? {
        if !samples.isEmpty { current = samples.removeFirst() }
        return (current, 48000)
    }
    func schedule(_ buffer: AVAudioPCMBuffer, at sample: Int64) { scheduled.append(sample) }
}

@MainActor private func liveMonitor(_ output: LiveFakeOutput) throws -> NativeLivePlayback {
    let project = try liveFixture()
    let session = try NativePlaybackSession(project: project, maximumPendingRequests: 2, maximumCacheBytes: 8192,
        worker: SerialDecodeWorker(factory: { _ in LiveFakeDecoder() }))
    return try NativeLivePlayback(project: project, session: session, output: output)
}

struct LiveRecoveryTests {
    @Test @MainActor func incompatibleHardwareRouteDoesNotStartOrDiscardPausedPosition() async throws {
        let output = LiveFakeOutput()
        let monitor = try liveMonitor(output)
        try await monitor.seek(toFrame: 30)
        let sample = monitor.transport.sampleIndex
        output.route = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        await #expect(throws: (any Error).self) { try await monitor.play() }
        #expect(output.starts == 0)
        #expect(output.scheduled.isEmpty)
        #expect(!monitor.transport.isPlaying)
        #expect(monitor.transport.sampleIndex == sample)
        output.route = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        try await monitor.play()
        #expect(output.starts == 1)
        #expect(monitor.transport.sampleIndex == sample)
        await monitor.close()
    }
    @Test(arguments: [Int64(100), Int64(1024)]) @MainActor func starvationPausesAtLastAcceptedSampleAndExplicitPlayRestartsClock(acceptedSample: Int64) async throws {
        let output = LiveFakeOutput()
        // First pump tick is accepted; the next reading starves at the exact
        // schedule boundary. At 1024 this also crosses an awaited refill decode;
        // at 100 it starves on the next polling tick. Neither admits late audio.
        output.samples = [acceptedSample, 4096]
        let monitor = try liveMonitor(output)
        let failure = Task { @MainActor in
            await withCheckedContinuation { continuation in
                monitor.failure = { error in continuation.resume(returning: String(describing: error)) }
            }
        }
        await Task.yield()
        try await monitor.play()
        let message = await failure.value
        monitor.failure = nil
        #expect(message.contains("Play explicitly to restart"))
        #expect(!monitor.transport.isPlaying)
        #expect(monitor.transport.sampleIndex == acceptedSample)
        #expect(monitor.statistics.clockSamples == acceptedSample)
        #expect(monitor.statistics.underruns == 1)
        #expect(output.scheduled == [0, 1024, 2048, 3072])
        #expect(output.resets == 1)
        output.samples = []; output.current = 0
        try await monitor.play()
        #expect(monitor.transport.isPlaying)
        #expect(monitor.transport.sampleIndex == acceptedSample)
        #expect(output.starts == 2)
        #expect(output.scheduled.suffix(4) == [0, 1024, 2048, 3072])
        #expect(monitor.statistics.underruns == 0)
        await monitor.close()
    }

    @Test @MainActor func manualPauseRejectsStarvedFinalReading() async throws {
        let output = LiveFakeOutput()
        let monitor = try liveMonitor(output)
        try await monitor.play()
        // play returns before the pump task starts, so this is a deterministic
        // final-clock-only observation with no accepted progress.
        output.current = 4096
        monitor.pause()
        #expect(monitor.transport.sampleIndex == 0)
        #expect(monitor.statistics.clockSamples == 0)
        #expect(!monitor.transport.isPlaying)
        await monitor.close()
    }

    @Test @MainActor func manualPauseAcceptsQualifiedFinalReading() async throws {
        let output = LiveFakeOutput()
        let monitor = try liveMonitor(output)
        try await monitor.play()
        output.current = 512
        monitor.pause()
        #expect(monitor.transport.sampleIndex == 512)
        #expect(monitor.statistics.clockSamples == 512)
        await monitor.close()
    }

    @Test @MainActor func engineStopPreservesPositionAndClosePreventsRestart() async throws {
        let output = LiveFakeOutput()
        output.onStart = { output.isRunning = false }
        let monitor = try liveMonitor(output)
        let failure = Task { @MainActor in
            await withCheckedContinuation { continuation in
                monitor.failure = { _ in continuation.resume() }
            }
        }
        await Task.yield()
        try await monitor.play()
        await failure.value
        monitor.failure = nil
        #expect(monitor.statistics.unexpectedEngineStops == 1)
        #expect(monitor.transport.sampleIndex == 0)
        #expect(!monitor.transport.isPlaying)
        await monitor.close()
        await #expect(throws: PlaybackSessionError.closed) { try await monitor.play() }
        #expect(output.starts == 1)
    }
}

/// Hold the first audio decode until a transport mutation has cancelled priming.
private final class LiveDecodeBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    let release = DispatchSemaphore(value: 0)
    func block() {
        lock.lock(); entered = true
        let waiting = waiter; waiter = nil; lock.unlock()
        waiting?.resume()
        _ = release.wait(timeout: .now() + 10)
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered { lock.unlock(); continuation.resume() }
            else { waiter = continuation; lock.unlock() }
        }
    }
}
private final class LiveBlockedDecoder: PlaybackDecoder {
    let barrier: LiveDecodeBarrier
    init(_ barrier: LiveDecodeBarrier) { self.barrier = barrier }
    func video(frame: Int64) throws -> Data { Data(count: 12) }
    func audio(start: Int64, count: Int) throws -> [Float] {
        barrier.block()
        return Array(repeating: 0, count: count * 2)
    }
}

struct LiveCancellationTests {
    @Test @MainActor func routeChangeDuringPrimingFailsBeforeOutputStarts() async throws {
        let project = try liveFixture()
        let barrier = LiveDecodeBarrier()
        let session = try NativePlaybackSession(project: project, maximumPendingRequests: 2, maximumCacheBytes: 0,
            worker: SerialDecodeWorker(factory: { _ in LiveBlockedDecoder(barrier) }))
        let output = LiveFakeOutput()
        let monitor = try NativeLivePlayback(project: project, session: session, output: output)
        let priming = Task { try await monitor.play() }
        await barrier.wait()
        output.route = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        for _ in 0..<4 { barrier.release.signal() }
        await #expect(throws: (any Error).self) { try await priming.value }
        #expect(output.starts == 0)
        // Failed admission flushes the player through stop; an engine reset is
        // reserved for an actual configuration notification or output failure.
        #expect(output.stops == 1)
        #expect(!output.isRunning)
        #expect(!monitor.transport.isPlaying)
        #expect(monitor.transport.sampleIndex == 0)
        output.route = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        for _ in 0..<4 { barrier.release.signal() }
        try await monitor.play()
        #expect(output.starts == 1)
        #expect(monitor.transport.sampleIndex == 0)
        await monitor.close()
    }

    @Test @MainActor func pauseSeekReplaceAndCloseRejectBlockedPriming() async throws {
        for action in ["pause", "seek", "replace", "close", "cancel"] {
            let project = try liveFixture()
            let barrier = LiveDecodeBarrier()
            let session = try NativePlaybackSession(project: project, maximumPendingRequests: 2, maximumCacheBytes: 0,
                worker: SerialDecodeWorker(factory: { _ in LiveBlockedDecoder(barrier) }))
            let output = LiveFakeOutput()
            let monitor = try NativeLivePlayback(project: project, session: session, output: output)
            let priming = Task { try await monitor.play() }
            await barrier.wait()
            switch action {
            case "pause": monitor.pause()
            case "seek": try await monitor.seek(toFrame: monitor.transport.plan.videoFrames)
            case "replace": try await monitor.replace(project: project)
            case "close":
                let epoch = await session.epoch
                var firstFinished = false
                let closing = Task { await monitor.close(); firstFinished = true }
                while await session.accepts(epoch) { await Task.yield() }
                var secondStarted = false
                var secondFinished = false
                let secondClose = Task {
                    secondStarted = true
                    await monitor.close()
                    secondFinished = true
                }
                while !secondStarted { await Task.yield() }
                _ = await session.statistics()
                await Task.yield()
                #expect(!firstFinished && !secondFinished)
                barrier.release.signal()
                await closing.value; await secondClose.value
                #expect(firstFinished && secondFinished)
            default: priming.cancel()
            }
            barrier.release.signal()
            await #expect(throws: (any Error).self) { try await priming.value }
            #expect(output.starts == 0)
            #expect(output.scheduled.isEmpty)
            #expect(!monitor.transport.isPlaying)
            await monitor.close()
        }
    }

    @Test @MainActor func configurationChangeStopsWithoutSamplingNewDeviceEpoch() async throws {
        let output = LiveFakeOutput()
        let monitor = try liveMonitor(output)
        let failure = Task { @MainActor in
            await withCheckedContinuation { continuation in
                monitor.failure = { _ in continuation.resume() }
            }
        }
        await Task.yield()
        try await monitor.play()
        output.current = 100000
        monitor.audioConfigurationChanged()
        await failure.value
        monitor.failure = nil
        #expect(!monitor.transport.isPlaying)
        #expect(monitor.transport.sampleIndex == 0)
        #expect(monitor.statistics.configurationChanges == 1)
        #expect(output.resets == 1)
        await monitor.close()
    }

    @Test @MainActor func activePollingTaskDoesNotRetainAbandonedMonitor() async throws {
        let output = LiveFakeOutput()
        var monitor: NativeLivePlayback? = try liveMonitor(output)
        weak var retained: NativeLivePlayback?
        retained = monitor
        let displayed = Task { @MainActor in
            await withCheckedContinuation { continuation in
                monitor?.display = { _, _ in continuation.resume() }
            }
        }
        await Task.yield()
        try await monitor?.play()
        await displayed.value
        monitor?.display = nil
        monitor = nil
        // At least one pump tick and video decode completed. A polling task
        // must release ownership during its sleep rather than retain forever.
        #expect(retained == nil)
    }
}
