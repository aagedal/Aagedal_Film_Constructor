import Foundation
import Testing
import EditorCore
@testable import NativePlaybackRuntime

private func fixture() throws -> Project {
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

/// Deterministic barrier: a worker signals entry and awaits release. All counts
/// are locked since tests inspect them from outside the decoder's serial queue.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    let block: Bool
    init(block: Bool = false) { self.block = block }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() {
        lock.lock(); reads += 1; entered = true
        let continuation = waiting; waiting = nil; lock.unlock()
        continuation?.resume()
        if block { _ = release.wait(timeout: .now() + 10) }
    }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered { lock.unlock(); continuation.resume() }
            else { waiting = continuation; lock.unlock() }
        }
    }
}
private final class FakeDecoder: PlaybackDecoder {
    let probe: Probe
    let sourceOffset: UInt8
    init(probe: Probe, project: Project) {
        self.probe = probe
        sourceOffset = UInt8(project.tracks[0].clips[0].sourceRange.start.numerator)
    }
    func video(frame: Int64) throws -> Data {
        probe.read()
        return Data(repeating: UInt8(frame) + sourceOffset, count: 12)
    }
    func audio(start: Int64, count: Int) throws -> [Float] {
        probe.read()
        return [Float](repeating: Float(start), count: count * 2)
    }
}
private func session(_ probe: Probe, cache: Int = 24, pending: Int = 2) throws -> NativePlaybackSession {
    try NativePlaybackSession(project: fixture(), maximumPendingRequests: pending, maximumCacheBytes: cache,
        worker: SerialDecodeWorker(factory: { FakeDecoder(probe: probe, project: $0) }))
}

struct PlaybackSessionTests {
    @Test func mixedCacheEvictsLeastRecentlyUsedWithinByteBudget() async throws {
        let probe = Probe()
        let monitor = try session(probe)
        _ = try await monitor.video(frame: 0)
        _ = try await monitor.video(frame: 1)
        _ = try await monitor.video(frame: 0) // touch zero; one is now oldest
        _ = try await monitor.audio(start: 10, count: 1) // eight bytes evicts frame one
        #expect(probe.count == 3)
        #expect(await monitor.statistics().cachedBytes == 20)
        _ = try await monitor.video(frame: 0)
        #expect(probe.count == 3)
        _ = try await monitor.video(frame: 1)
        #expect(probe.count == 4)
        #expect(await monitor.statistics().cachedBytes <= 24)
    }

    @Test func oversizedPayloadAndDisabledCacheAreNotRetained() async throws {
        for budget in [0, 11] {
            let probe = Probe()
            let monitor = try session(probe, cache: budget)
            _ = try await monitor.video(frame: 0)
            _ = try await monitor.video(frame: 0)
            #expect(probe.count == 2)
            #expect(await monitor.statistics().cachedBytes == 0)
        }
    }

    @Test func seekDiscardsAnInFlightResultAndCanReuseCachedFrames() async throws {
        let probe = Probe(block: true)
        let monitor = try session(probe)
        let task = Task { try await monitor.video(frame: 0) }
        await probe.waitForEntry()
        let old = await monitor.epoch
        await monitor.invalidate()
        #expect(await monitor.accepts(old) == false)
        probe.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await monitor.statistics().cachedBytes == 0)
        #expect(await monitor.statistics().pendingRequests == 0)
        probe.release.signal()
        let next = try await monitor.video(frame: 0)
        #expect(await monitor.accepts(next.epoch))
        await monitor.invalidate()
        #expect(await monitor.accepts(next.epoch) == false)
        let cached = try await monitor.video(frame: 0)
        #expect(await monitor.accepts(cached.epoch))
        #expect(probe.count == 2)
    }

    @Test func cancellationDiscardsRunningDecodeAndReleasesAdmission() async throws {
        let probe = Probe(block: true)
        let monitor = try session(probe, pending: 1)
        let task = Task { try await monitor.audio(start: 0, count: 1) }
        await probe.waitForEntry()
        await #expect(throws: PlaybackSessionError.busy) { try await monitor.video(frame: 0) }
        #expect(await monitor.statistics().pendingRequests == 1)
        task.cancel(); probe.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await monitor.statistics().pendingRequests == 0)
        #expect(await monitor.statistics().cacheEntries == 0)
    }

    @Test func replacementClearsCacheAndRejectedReplacementPreservesEpoch() async throws {
        let probe = Probe()
        let monitor = try session(probe)
        let first = try await monitor.video(frame: 0)
        var invalid = try fixture(); invalid.settings.width = 0
        await #expect(throws: (any Error).self) { try await monitor.replace(project: invalid) }
        #expect(await monitor.accepts(first.epoch))
        #expect(await monitor.statistics().cachedBytes == 12)
        var edited = try fixture()
        edited.tracks[0].clips[0].sourceRange.start = try RationalTime(1)
        try await monitor.replace(project: edited)
        #expect(await monitor.accepts(first.epoch) == false)
        #expect(await monitor.statistics().cachedBytes == 0)
        #expect(try await monitor.video(frame: 0).value == Data(repeating: 1, count: 12))
    }

    @Test func closeInvalidatesInFlightAndRejectsFutureRequests() async throws {
        let probe = Probe(block: true)
        let monitor = try session(probe)
        let task = Task { try await monitor.video(frame: 0) }
        await probe.waitForEntry()
        await monitor.close(); probe.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: PlaybackSessionError.closed) { try await monitor.video(frame: 0) }
        #expect(await monitor.statistics().cacheEntries == 0)
    }

    @Test func invalidRequestsDoNotReachDecoder() async throws {
        let probe = Probe()
        let monitor = try session(probe)
        await #expect(throws: (any Error).self) { try await monitor.video(frame: -1) }
        await #expect(throws: (any Error).self) { try await monitor.audio(start: 0, count: 65537) }
        await #expect(throws: (any Error).self) { try await monitor.audio(start: 288000, count: 1) }
        #expect(probe.count == 0)
        #expect(await monitor.statistics().pendingRequests == 0)
    }

    @Test func replacementInvalidatesRunningAndQueuedReads() async throws {
        let probe = Probe(block: true)
        let monitor = try session(probe, pending: 2)
        let running = Task { try await monitor.video(frame: 0) }
        await probe.waitForEntry()
        let queued = Task { try await monitor.video(frame: 1) }
        // Yield until both actor admissions have happened, without a timing sleep.
        while await monitor.statistics().pendingRequests < 2 { await Task.yield() }
        var edited = try fixture()
        edited.tracks[0].clips[0].sourceRange.start = try RationalTime(1)
        for _ in 0..<100 { try await monitor.replace(project: edited) }
        probe.release.signal()
        await #expect(throws: CancellationError.self) { try await running.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(probe.count == 1) // obsolete queued read never reaches the backend
        #expect(await monitor.statistics().pendingRequests == 0)
        probe.release.signal()
        #expect(try await monitor.video(frame: 0).value == Data(repeating: 1, count: 12))
        await monitor.close()
        let closedEpoch = await monitor.epoch
        await monitor.close()
        #expect(await monitor.epoch == closedEpoch)
    }

    @Test func cancellingDuringInitializationDoesNotStartDecode() async throws {
        let initialization = Probe(block: true)
        let decoding = Probe()
        let monitor = try NativePlaybackSession(project: fixture(), maximumPendingRequests: 1, maximumCacheBytes: 24,
            worker: SerialDecodeWorker(factory: { project in
                initialization.read()
                return FakeDecoder(probe: decoding, project: project)
            }))
        let task = Task { try await monitor.video(frame: 0) }
        await initialization.waitForEntry()
        task.cancel(); initialization.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(decoding.count == 0)
        #expect(await monitor.statistics().pendingRequests == 0)
    }
}
