import Foundation
import EditorCore

public enum PlaybackSessionError: Error, Equatable {
    case busy
    case staleRequest
    case closed
    case invalidLimits
}

/// A decoded value carries its epoch so a UI can reject it if a seek occurs
/// between completion of the await and presentation of the returned value.
public struct PlaybackValue<Value: Sendable>: Sendable {
    public let epoch: UUID
    public let value: Value
}

public struct PlaybackSessionStatistics: Sendable {
    public let pendingRequests: Int
    public let cachedBytes: Int
    public let cacheEntries: Int
}

/// Lock protects cancellation across the actor and the serial decoder queue.
/// It cannot interrupt a libavcodec call already in progress.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

protocol PlaybackDecoder: AnyObject {
    func video(frame: Int64) throws -> Data
    func audio(start: Int64, count: Int) throws -> [Float]
}
extension NativeMonitor: PlaybackDecoder {}

/// Ownership transfer only: the decoder is never called through this box.
private final class DecoderRelease: @unchecked Sendable {
    let monitor: (any PlaybackDecoder)?
    init(_ monitor: (any PlaybackDecoder)?) { self.monitor = monitor }
}

/// All mutable decoder state is used exclusively inside this queue. The actor
/// controls admission; this worker never calls back synchronously into the actor.
final class SerialDecodeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "film-constructor.native-decode", qos: .userInitiated)
    private let factory: @Sendable (Project, [UUID: MediaProxy]) throws -> any PlaybackDecoder
    private var monitor: (any PlaybackDecoder)?
    private var planID: UUID?
    private let releaseLock = NSLock()
    private var releaseQueued = false

    init(factory: @escaping @Sendable (Project) throws -> any PlaybackDecoder = { try NativeMonitor(project: $0) }) {
        self.factory = { project, _ in try factory(project) }
    }

    init(proxyFactory: @escaping @Sendable (Project, [UUID: MediaProxy]) throws -> any PlaybackDecoder) {
        self.factory = proxyFactory
    }

    deinit {
        // Queued jobs retain this worker, so no job can be running at deinit.
        // Transfer the final ownership to the queue for libavcodec teardown.
        let retained = DecoderRelease(monitor)
        queue.async { withExtendedLifetime(retained) {} }
    }

    func read<Value: Sendable>(project: Project, videoProxies: [UUID: MediaProxy] = [:], planID: UUID, epoch: CancellationFlag,
                              operation: @escaping @Sendable (any PlaybackDecoder) throws -> Value) async throws -> Value {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check(); try epoch.check()
                        if self.planID != planID {
                            let replacement = try self.factory(project, videoProxies)
                            self.monitor = replacement
                            self.planID = planID
                        }
                        try cancellation.check(); try epoch.check()
                        guard let monitor = self.monitor else { throw PlaybackSessionError.closed }
                        let result = try operation(monitor)
                        try cancellation.check(); try epoch.check()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Complete only after admitted jobs finish and decoder teardown runs on its queue.
    /// Cancellation of the caller cannot shorten this resource-lifetime barrier.
    func drainAndRelease() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.monitor = nil; self.planID = nil
                continuation.resume()
            }
        }
    }

    func release() {
        releaseLock.lock()
        guard !releaseQueued else { releaseLock.unlock(); return }
        releaseQueued = true
        queue.async {
            self.monitor = nil; self.planID = nil
            self.releaseLock.lock(); self.releaseQueued = false; self.releaseLock.unlock()
        }
        releaseLock.unlock()
    }
}

/// Development asynchronous sequence monitor. FFmpeg work stays off the actor
/// executor and UI thread. Admission and a shared video/audio LRU bound queued
/// work and retained decoded payloads independently of sequence duration.
public actor NativePlaybackSession {
    public private(set) var plan: NativePlaybackPlan
    public private(set) var epoch = UUID()
    private var project: Project
    private var videoProxies: [UUID: MediaProxy]
    private var planID = UUID()
    private var epochCancellation = CancellationFlag()
    private let worker: SerialDecodeWorker
    private let maximumPendingRequests: Int
    private let maximumCacheBytes: Int
    private var pending = 0
    private var closed = false
    private var closing: Task<Void, Never>?
    private enum Key: Hashable { case video(Int64), audio(Int64, Int) }
    private enum Payload {
        case video(Data), audio([Float])
        var bytes: Int {
            switch self { case .video(let value): value.count; case .audio(let value): value.count * MemoryLayout<Float>.stride }
        }
    }
    private var cache: [Key: Payload] = [:]
    private var recency: [Key] = []
    private var cachedBytes = 0

    public init(project: Project, videoProxies: [UUID: MediaProxy] = [:], maximumPendingRequests: Int = 4, maximumCacheBytes: Int = 8 * 1024 * 1024,
                decoderLimits: NativeDecoderLimits = NativeDecoderLimits()) throws {
        try decoderLimits.validate()
        try self.init(project: project, videoProxies: videoProxies, maximumPendingRequests: maximumPendingRequests,
                      maximumCacheBytes: maximumCacheBytes,
                      worker: SerialDecodeWorker(proxyFactory: { try NativeMonitor(project: $0, videoProxies: $1, decoderLimits: decoderLimits) }))
    }

    init(project: Project, videoProxies: [UUID: MediaProxy] = [:], maximumPendingRequests: Int, maximumCacheBytes: Int, worker: SerialDecodeWorker) throws {
        guard (1...64).contains(maximumPendingRequests), maximumCacheBytes >= 0 else {
            throw PlaybackSessionError.invalidLimits
        }
        let plan = try Self.compile(project, videoProxies: videoProxies)
        self.plan = plan; self.project = project; self.videoProxies = videoProxies; self.worker = worker
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumCacheBytes = maximumCacheBytes
    }

    private static func compile(_ project: Project, videoProxies: [UUID: MediaProxy]) throws -> NativePlaybackPlan {
        let plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        guard plan.settings.width <= 4096, plan.settings.height <= 4096 else {
            throw ProofFailure("Proof limits sequence raster to 4096²")
        }
        _ = try NativeProxySelection.compile(project: project, videoProxies: videoProxies)
        return plan
    }

    /// Validate before invalidating. A rejected edit retains the old epoch/cache.
    public func replace(project: Project, videoProxies: [UUID: MediaProxy] = [:]) throws {
        guard !closed else { throw PlaybackSessionError.closed }
        let replacement = try Self.compile(project, videoProxies: videoProxies)
        invalidate()
        self.project = project; self.videoProxies = videoProxies; plan = replacement; planID = UUID()
        clearCache()
        worker.release()
    }

    /// Call before requests for a new seek/scrub. Decoders retain their exact
    /// seek indexes; queued work and values from the prior epoch are invalid.
    @discardableResult public func invalidate() -> UUID {
        epochCancellation.cancel()
        epochCancellation = CancellationFlag()
        epoch = UUID()
        return epoch
    }

    public func accepts(_ valueEpoch: UUID) -> Bool { !closed && valueEpoch == epoch }

    /// Concurrent callers share the same decoder-drain barrier. Security-scoped
    /// media access may be released only after this await completes.
    public func close() async {
        if let closing { await closing.value; return }
        invalidate(); closed = true; clearCache()
        let worker = self.worker
        let closing = Task { await worker.drainAndRelease() }
        self.closing = closing
        await closing.value
    }

    public func statistics() -> PlaybackSessionStatistics {
        .init(pendingRequests: pending, cachedBytes: cachedBytes, cacheEntries: cache.count)
    }

    public func video(frame: Int64) async throws -> PlaybackValue<Data> {
        try Task.checkCancellation()
        guard !closed else { throw PlaybackSessionError.closed }
        _ = try plan.videoFrame(at: frame)
        let key = Key.video(frame)
        if case .video(let value) = cached(key) { return .init(epoch: epoch, value: value) }
        let generation = try admit()
        defer { pending -= 1 }
        let value = try await worker.read(project: project, videoProxies: videoProxies, planID: planID, epoch: epochCancellation) {
            try $0.video(frame: frame)
        }
        try validateCompletion(generation)
        store(.video(value), for: key)
        return .init(epoch: generation, value: value)
    }

    public func audio(start: Int64, count: Int) async throws -> PlaybackValue<[Float]> {
        try Task.checkCancellation()
        guard !closed else { throw PlaybackSessionError.closed }
        guard count > 0, count <= 65536 else { throw ProofFailure("Audio block must contain 1...65536 samples") }
        _ = try plan.audioBlock(startSample: start, sampleCount: count)
        let key = Key.audio(start, count)
        if case .audio(let value) = cached(key) { return .init(epoch: epoch, value: value) }
        let generation = try admit()
        defer { pending -= 1 }
        let value = try await worker.read(project: project, videoProxies: videoProxies, planID: planID, epoch: epochCancellation) {
            try $0.audio(start: start, count: count)
        }
        try validateCompletion(generation)
        store(.audio(value), for: key)
        return .init(epoch: generation, value: value)
    }

    private func admit() throws -> UUID {
        guard pending < maximumPendingRequests else { throw PlaybackSessionError.busy }
        pending += 1
        return epoch
    }
    private func validateCompletion(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard !closed, generation == epoch else { throw PlaybackSessionError.staleRequest }
    }
    private func cached(_ key: Key) -> Payload? {
        guard let value = cache[key] else { return nil }
        recency.removeAll { $0 == key }; recency.append(key)
        return value
    }
    private func store(_ value: Payload, for key: Key) {
        guard value.bytes <= maximumCacheBytes else { return }
        if let prior = cache.removeValue(forKey: key) { cachedBytes -= prior.bytes }
        recency.removeAll { $0 == key }
        while cachedBytes > maximumCacheBytes - value.bytes, !recency.isEmpty {
            let oldest = recency.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cachedBytes -= removed.bytes }
        }
        cache[key] = value; recency.append(key); cachedBytes += value.bytes
    }
    private func clearCache() { cache.removeAll(); recency.removeAll(); cachedBytes = 0 }
}
