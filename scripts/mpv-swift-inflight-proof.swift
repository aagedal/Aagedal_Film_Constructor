import Foundation
import EditorCore
@testable import NativePlaybackRuntime

/// Hold a real decoded payload on the serial worker before it can cross the
/// session's cancellation/epoch checks. This does not interrupt libavcodec.
private final class DecodeBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var arrived = false
    private var used = false
    private var reads = 0
    private var constructed = 0
    private var destroyed = 0
    var entered: Bool { lock.withLock { arrived } }
    var count: Int { lock.withLock { reads } }
    var releasedDecoder: Bool { lock.withLock { constructed > 0 && destroyed == constructed } }
    var decoderCount: Int { lock.withLock { constructed } }
    func decoderConstructed() { lock.withLock { constructed += 1 } }
    func decoderDestroyed() { lock.withLock { destroyed += 1 } }
    func holdOnce() throws {
        let hold = lock.withLock { () -> Bool in
            reads += 1
            if used { return false }
            used = true; arrived = true
            return true
        }
        if hold, release.wait(timeout: .now() + 20) != .success {
            throw ProofFailure("decode barrier timed out")
        }
    }
    func resume() { release.signal() }
}

private final class BarrierDecoder: PlaybackDecoder {
    let monitor: NativeMonitor
    let barrier: DecodeBarrier
    init(_ project: Project, _ barrier: DecodeBarrier) throws {
        monitor = try NativeMonitor(project: project); self.barrier = barrier
        barrier.decoderConstructed()
    }
    deinit { barrier.decoderDestroyed() }
    func video(frame: Int64) throws -> Data {
        let value = try monitor.video(frame: frame)
        try barrier.holdOnce()
        return value
    }
    func audio(start: Int64, count: Int) throws -> [Float] {
        let value = try monitor.audio(start: start, count: count)
        try barrier.holdOnce()
        return value
    }
}

@MainActor private func until(_ condition: () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while !(await condition()) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProofFailure("in-flight admission timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor func qualifyInFlight(_ path: String, output: URL, concurrent: Bool) async throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for operation in ["replace", "cancel", "close"] {
        for kind in ["video", "audio"] {
            let barrier = DecodeBarrier()
            let session = try NativePlaybackSession(project: project(path, offset: 0),
                maximumPendingRequests: 2, maximumCacheBytes: 1024 * 1024,
                worker: SerialDecodeWorker(factory: { try BarrierDecoder($0, barrier) }))
            let client = concurrent ? try Client() : nil
            let running = Task { @MainActor in
                if kind == "video" { _ = try await session.video(frame: 36) }
                else { _ = try await session.audio(start: 72000, count: 1024) }
            }
            var queued: Task<Void, Error>?
            var closing: Task<Void, Never>?
            do {
                if let client { _ = try await client.open(path, video: 0, audio: 2) }
                try await until { barrier.entered }
                let epoch = await session.epoch
                queued = Task { _ = try await session.video(frame: 12) }
                try await until { await session.statistics().pendingRequests == 2 }
                if let client { try await client.seek(1.5) }
                var closeFinished = false
                switch operation {
                case "replace": try await session.replace(project: project(path, offset: 6))
                case "cancel": running.cancel(); queued!.cancel()
                default:
                    closing = Task { await session.close(); closeFinished = true }
                    try await until { !(await session.accepts(epoch)) }
                    _ = await session.statistics()
                    guard !closeFinished, !barrier.releasedDecoder else { throw ProofFailure("close bypassed worker drain") }
                }
                // MPV must still complete transport while the native worker is held.
                if let client { try await client.seek(0.25); try await client.paused(false); try await client.paused(true) }
                barrier.resume()
                for task in [running, queued!] {
                    do { try await task.value; throw ProofFailure("obsolete in-flight request succeeded") }
                    catch is CancellationError {}
                }
                if let closing { await closing.value }
                let stats = await session.statistics()
                guard stats.pendingRequests == 0, stats.cachedBytes == 0, barrier.count == 1 else {
                    throw ProofFailure("obsolete request decoded or populated cache")
                }
                if operation == "close" {
                    guard closeFinished, barrier.releasedDecoder else { throw ProofFailure("close retained decoder") }
                    do { _ = try await session.video(frame: 0); throw ProofFailure("closed request admitted") }
                    catch PlaybackSessionError.closed {}
                } else {
                    let picture = try await session.video(frame: 0)
                    let audio = try await session.audio(start: 0, count: 1024)
                    guard await session.accepts(picture.epoch), await session.accepts(audio.epoch) else {
                        throw ProofFailure("recovery returned stale epoch")
                    }
                    let stem = "recovery-\(operation)-\(kind)"
                    try picture.value.write(to: output.appendingPathComponent(stem + ".rgb"))
                    try audio.value.withUnsafeBytes { try Data($0).write(to: output.appendingPathComponent(stem + ".f32")) }
                }
                try client?.close()
                await session.close()
                rows.append(["operation": operation, "kind": kind, "rejected": 2,
                             "queuedDecodeSkipped": true, "cacheEmptyAfterRejection": true,
                             "mpvTransportWhileHeld": concurrent,
                             "sourceFrame": operation == "replace" ? 6 : 0,
                             "decoderReleased": barrier.releasedDecoder, "decoderCount": barrier.decoderCount])
            } catch {
                barrier.resume(); running.cancel(); queued?.cancel()
                _ = await running.result
                if let queued { _ = await queued.result }
                if let closing { await closing.value }
                try? client?.close(); await session.close()
                throw error
            }
        }
    }
    return rows
}
