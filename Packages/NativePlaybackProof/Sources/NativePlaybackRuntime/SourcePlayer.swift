import CoreGraphics
import Dispatch
import EditorCore
import Foundation
import CNativeDecoder

/// What the Source viewer loads through libmpv. Stream indices are FFmpeg's
/// (container `ff-index`), the same ones export maps by; enumeration order is never used.
public struct NativeSourceMedia: Sendable, Equatable {
    /// The picture file: the original, or a generated proxy.
    public var url: URL
    /// The picture stream in `url`; nil plays sound only.
    public var videoStreamIndex: Int?
    /// The sound stream, in `externalAudioURL` when present, else in `url`.
    public var audioStreamIndex: Int?
    /// The original, when `url` is a proxy (proxy picture with original sound).
    public var externalAudioURL: URL?
    /// Picture frames per second and the picture stream's start in asset time.
    /// Seeks land on whole frames of this grid; nil seeks to the exact time.
    public var frameRate: RationalTime?
    public var videoOffset: RationalTime
    public var duration: RationalTime

    public init(url: URL, videoStreamIndex: Int?, audioStreamIndex: Int?, externalAudioURL: URL? = nil,
                frameRate: RationalTime?, videoOffset: RationalTime = .zero, duration: RationalTime) {
        self.url = url; self.videoStreamIndex = videoStreamIndex; self.audioStreamIndex = audioStreamIndex
        self.externalAudioURL = externalAudioURL; self.frameRate = frameRate; self.videoOffset = videoOffset
        self.duration = duration
    }

    /// A generated proxy's picture (its own first video stream, which starts at
    /// asset zero), with the original's sound stream when it has one.
    public static func proxy(url: URL, frameRate: RationalTime, duration: RationalTime,
                             original: URL?, audioStreamIndex: Int?) throws -> NativeSourceMedia {
        var error = [CChar](repeating: 0, count: 512)
        var numerator: Int64 = 0, denominator: Int64 = 1, video: Int32 = -1
        guard url.path.withCString({ afc_source_media_origin($0, &numerator, &denominator, &video, &error, error.count) }) == 0,
              video >= 0 else { throw ProofFailure("The proxy has no readable picture: \(message(error))") }
        let sound = original != nil ? audioStreamIndex : nil
        return NativeSourceMedia(url: url, videoStreamIndex: Int(video), audioStreamIndex: sound,
                                 externalAudioURL: sound == nil ? nil : original, frameRate: frameRate, duration: duration)
    }
}

/// Asset time ↔ MPV's raw container time. Asset zero is the earliest stream start,
/// as the import probe and export define it. A seek inside the picture lands on
/// the frame covering the requested time, at that frame's own timestamp, so the
/// reported time (and a mark taken from it) names the frame on screen. Past the
/// last frame (an audio tail) the time is used as given.
struct NativeSourceClock: Equatable {
    let origin: Double
    let offset: Double
    let rate: RationalTime?
    let duration: Double

    private var frameCount: Int64? {
        guard let rate, rate.numerator > 0 else { return nil }
        let frames = ((duration - offset) * rate.seconds - 1e-6).rounded(.up)
        return frames.isFinite && frames >= 1 && frames < 1e15 ? Int64(frames) : nil
    }

    func frameStart(_ frame: Int64) -> Double {
        guard let rate else { return offset }
        return offset + Double(frame) * Double(rate.denominator) / Double(rate.numerator)
    }

    struct Target: Equatable { let raw: Double; let asset: Double; let frame: Int64? }

    /// The raw seek target and the asset time it shows; `frame` is nil off the picture.
    func target(forAsset seconds: Double) -> Target {
        var t = max(0, min(duration, seconds.isFinite ? seconds : 0))
        // Callers' clocks (CMTime at 1/60000 s) cannot hold every 1001/24000 boundary;
        // a request within 1/1000 frame before a boundary means that boundary.
        let slack = rate.map { 1e-3 / $0.seconds } ?? 0
        if t >= duration - slack { t = duration }
        // The asset end (an exclusive Out) and audio past the last frame keep their own time.
        guard let rate, let count = frameCount, t < duration, t < frameStart(count) - slack else {
            return Target(raw: origin + t, asset: t, frame: nil)
        }
        let frame = max(0, min(count - 1, Int64(((t - offset) * rate.seconds + 1e-3).rounded(.down))))
        let start = frameStart(frame)
        return Target(raw: origin + start, asset: start, frame: frame)
    }

    func asset(forRaw seconds: Double) -> Double { max(0, min(duration, seconds - origin)) }
}

enum NativeSourceUpdate: Sendable {
    case opened(video: Int?, audio: Int?)
    case failed(String)
    case position(Double)
    case paused(Bool, Double?)
    case reply(UInt64, Int32, String)
    case restart(Double?)
    case ended
}

/// The C player and its two serial callers. Control owns everything but rendering;
/// render owns the software surface and never waits on control.
private final class NativeSourceCore: @unchecked Sendable {
    let control = DispatchQueue(label: "film-constructor.mpv-source.control")
    let render = DispatchQueue(label: "film-constructor.mpv-source.render")
    // Control state.
    private var player: OpaquePointer?
    private var pump: DispatchSourceTimer?
    // Render state.
    private var renderTimer: DispatchSourceTimer?
    private var surface: UnsafeMutableRawPointer?
    private var surfaceSize = (width: 0, height: 0, stride: 0)
    private var forceRender = false

    deinit {
        // Normally released by shutdown(); never leave the core running.
        renderTimer?.cancel()
        if let player { afc_source_release_render(player) }
        var handle = player
        afc_source_destroy(&handle)
        surface.map { free($0) }
    }

    /// Control caller. Starts event polling; updates reach `deliver` in order.
    func open(_ media: NativeSourceMedia, audioOutput: Bool, frames: @escaping @Sendable (CGImage) -> Void,
              deliver: @escaping @Sendable ([NativeSourceUpdate]) -> Void) throws -> (origin: Double, audioDelay: Double) {
        dispatchPrecondition(condition: .onQueue(control))
        render.sync { self.frames = frames }
        var error = [CChar](repeating: 0, count: 512)
        var numerator: Int64 = 0, denominator: Int64 = 1, ignored: Int32 = -1
        guard media.url.path.withCString({ afc_source_media_origin($0, &numerator, &denominator, &ignored, &error, error.count) }) == 0,
              denominator > 0 else { throw ProofFailure("Cannot read source timing: \(message(error))") }
        let origin = Double(numerator) / Double(denominator)
        var delay = 0.0
        if let audioURL = media.externalAudioURL {
            var audioNumerator: Int64 = 0, audioDenominator: Int64 = 1
            guard audioURL.path.withCString({ afc_source_media_origin($0, &audioNumerator, &audioDenominator, &ignored, &error, error.count) }) == 0,
                  audioDenominator > 0 else { throw ProofFailure("Cannot read original timing: \(message(error))") }
            // Proxy time is asset time from the proxy's own start; original sound is
            // asset time from the original's start. Shift the sound onto the picture.
            delay = origin - Double(audioNumerator) / Double(audioDenominator)
        }
        let video = media.videoStreamIndex ?? -1
        var handle: OpaquePointer?
        let created = afc_source_create(&handle, audioOutput ? 1 : 0, &error, error.count)
        guard created >= 0, let handle else { throw ProofFailure("Cannot start the source player: \(message(error))") }
        player = handle
        let rc = media.url.path.withCString { path in
            if let audioURL = media.externalAudioURL {
                return audioURL.path.withCString { audio in
                    afc_source_open(handle, path, Int32(video), Int32(media.audioStreamIndex ?? -1), audio, delay, 1)
                }
            }
            return afc_source_open(handle, path, Int32(video), Int32(media.audioStreamIndex ?? -1), nil, 0, 1)
        }
        guard rc >= 0 else { throw ProofFailure("Cannot open the source: \(Self.describe(rc))") }
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll(deliver) }
        pump = timer
        timer.resume()
        return (origin, delay)
    }

    private func poll(_ deliver: @Sendable ([NativeSourceUpdate]) -> Void) {
        guard let player else { return }
        var events = [AFCSourceEvent](repeating: AFCSourceEvent(), count: 64)
        let count = afc_source_poll(player, &events, events.count, 256)
        guard count > 0 else {
            if count < 0, count != Int32(AFC_SOURCE_STATE) { deliver([.failed(Self.describe(count))]) }
            return
        }
        var updates: [NativeSourceUpdate] = []
        for event in events.prefix(Int(count)) {
            switch event.type {
            case AFC_SOURCE_OPENED:
                updates.append(.opened(video: event.video_track_id > 0 ? Int(event.video_track_id) : nil,
                                       audio: event.audio_track_id > 0 ? Int(event.audio_track_id) : nil))
                startRendering()
            case AFC_SOURCE_ERROR, AFC_SOURCE_SHUTDOWN:
                updates.append(.failed(Self.text(event)))
            case AFC_SOURCE_POSITION: updates.append(.position(event.seconds))
            case AFC_SOURCE_PAUSE:
                var seconds = 0.0
                let paused = event.paused != 0
                updates.append(.paused(paused, paused && afc_source_time_pos(player, &seconds) == 0 ? seconds : nil))
            case AFC_SOURCE_COMMAND_REPLY: updates.append(.reply(event.request_id, event.status, Self.text(event)))
            case AFC_SOURCE_PLAYBACK_RESTART:
                // Read the decoded position directly; observations can lag or coalesce.
                var seconds = 0.0
                updates.append(.restart(afc_source_time_pos(player, &seconds) == 0 ? seconds : nil))
            case AFC_SOURCE_END_FILE: updates.append(.ended)
            default: break
            }
        }
        deliver(updates)
    }

    func seek(raw seconds: Double, id: UInt64) -> Int32 {
        guard let player else { return Int32(AFC_SOURCE_STATE) }
        return afc_source_seek(player, seconds, id)
    }

    func setPaused(_ paused: Bool, id: UInt64) -> Int32 {
        guard let player else { return Int32(AFC_SOURCE_STATE) }
        return afc_source_set_paused(player, paused ? 1 : 0, id)
    }

    /// Fit the display size within 1920×1080; the layer scales the rest.
    private func startRendering() {
        guard let player else { return }
        var width: Int32 = 0, height: Int32 = 0
        guard afc_source_video_size(player, &width, &height) == 0 else { return }
        let scale = min(1, 1920 / Double(width), 1080 / Double(height))
        let w = max(2, Int((Double(width) * scale).rounded())), h = max(2, Int((Double(height) * scale).rounded()))
        render.async { [self] in configureSurface(player: player, width: w, height: h) }
    }

    private var frames: (@Sendable (CGImage) -> Void)?

    private func configureSurface(player: OpaquePointer, width: Int, height: Int) {
        dispatchPrecondition(condition: .onQueue(render))
        let stride = (width * 4 + 63) / 64 * 64
        var memory: UnsafeMutableRawPointer?
        guard posix_memalign(&memory, 64, stride * height) == 0, let memory else { return }
        surface.map { free($0) }
        surface = memory
        surfaceSize = (width, height, stride)
        forceRender = true
        renderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: render)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.draw(player) }
        renderTimer = timer
        timer.resume()
    }

    private func draw(_ player: OpaquePointer) {
        guard let surface else { return }
        let size = surfaceSize
        let force = forceRender
        forceRender = false
        guard afc_source_render(player, Int32(size.width), Int32(size.height),
                                surface.assumingMemoryBound(to: UInt8.self), size.stride, force ? 1 : 0) == 1 else { return }
        let data = Data(bytes: surface, count: size.stride * size.height) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size.stride, space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        frames?(image)
    }

    /// Stops rendering, frees the render context on its own caller, then joins
    /// MPV's threads. Idempotent; runs on the control caller.
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(control))
        pump?.cancel(); pump = nil
        let player = self.player
        render.sync {
            renderTimer?.cancel(); renderTimer = nil
            if let player { afc_source_release_render(player) }
            surface.map { free($0) }; surface = nil
            frames = nil
        }
        var handle = player
        afc_source_destroy(&handle)
        self.player = nil
    }

    private static func text(_ event: AFCSourceEvent) -> String {
        var event = event
        let text = withUnsafeBytes(of: &event.message) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return text.isEmpty ? describe(event.status) : text
    }

    static func describe(_ status: Int32) -> String {
        switch status {
        case Int32(AFC_SOURCE_INVALID): "invalid request"
        case Int32(AFC_SOURCE_STATE): "player not ready"
        case Int32(AFC_SOURCE_BUSY): "too many pending requests"
        case Int32(AFC_SOURCE_TRACK): "the selected FFmpeg stream was not found"
        default: "libmpv error \(status)"
        }
    }
}

/// libmpv Source viewer transport. Main-actor API; libmpv runs on private queues.
/// Times are asset seconds. Picture seeks land on the FFmpeg frame grid of the
/// selected stream (including its start offset), so marks match export frames.
@MainActor
public final class NativeSourcePlayer {
    public enum Failure: Error, Equatable { case closed, superseded, failed(String) }

    public let media: NativeSourceMedia
    /// Asset seconds of the frame on screen (or the requested time past the picture).
    public private(set) var currentSeconds: Double = 0
    public private(set) var isPlaying = false
    /// Latest rendered picture; also delivered to `onFrame`.
    public private(set) var frame: CGImage?
    public var onFrame: ((CGImage) -> Void)?
    /// MPV track IDs resolved from the requested FFmpeg streams.
    public struct Tracks: Equatable, Sendable {
        public let video: Int?, audio: Int?
        public init(video: Int?, audio: Int?) { self.video = video; self.audio = audio }
    }
    public private(set) var selectedTracks: Tracks?
    /// Seconds the original's sound is shifted to line up with a proxy picture.
    public private(set) var audioDelay: Double = 0

    private let core = NativeSourceCore()
    private let audioOutput: Bool
    private var clock: NativeSourceClock?
    private var closed = false
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var nextRequest: UInt64 = 2
    private struct Seek { let id: UInt64; let target: NativeSourceClock.Target; var replied = false; let continuation: CheckedContinuation<Void, Error> }
    private var pendingSeek: Seek?
    /// A seek past the picture's end reports its own time rather than the last frame's.
    private var reportedOverride: Double?
    private var settlingPause = false

    public init(media: NativeSourceMedia, audioOutput: Bool = true) {
        self.media = media
        self.audioOutput = audioOutput
    }

    /// Loads the media paused at its start and resolves the explicit FFmpeg streams.
    public func open() async throws {
        guard !closed, clock == nil, openWaiter == nil else { throw Failure.closed }
        let media = self.media, core = self.core, audioOutput = self.audioOutput
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openWaiter = continuation
            core.control.async { [weak self] in
                do {
                    let timing = try core.open(media, audioOutput: audioOutput, frames: { image in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(image) } }
                    }, deliver: { updates in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(updates) } }
                    })
                    // Enqueued before the first poll can deliver OPENED, so the clock is set first.
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        self?.audioDelay = timing.audioDelay
                        self?.clock = NativeSourceClock(origin: timing.origin, offset: media.videoOffset.seconds,
                            rate: media.frameRate, duration: media.duration.seconds)
                    } }
                } catch {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishOpen(error) } }
                }
            }
        }
    }

    private func finishOpen(_ error: Error?) {
        guard let waiter = openWaiter else { return }
        openWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    private func present(_ image: CGImage) {
        guard !closed else { return }
        frame = image
        onFrame?(image)
    }

    private func apply(_ updates: [NativeSourceUpdate]) {
        guard !closed else { return }
        for update in updates {
            switch update {
            case .opened(let video, let audio):
                selectedTracks = Tracks(video: video, audio: audio)
                finishOpen(nil)
            case .failed(let text):
                finishOpen(Failure.failed(text))
                failSeek(.failed(text))
                isPlaying = false
            case .position(let raw):
                // Only playback moves the clock; paused times come from seeks and pauses.
                guard let clock, pendingSeek == nil, isPlaying else { continue }
                reportedOverride = nil
                currentSeconds = clock.asset(forRaw: raw)
            case .paused(let paused, let raw):
                // The core's position once stopped is the frame on screen.
                if paused, isPlaying || settlingPause, pendingSeek == nil, let raw, let clock {
                    currentSeconds = clock.asset(forRaw: raw)
                }
                if paused { settlingPause = false }
                isPlaying = !paused
            case .reply(let id, let status, let text):
                guard var seek = pendingSeek, seek.id == id else { continue }
                if status < 0 { failSeek(.failed(text)) } else { seek.replied = true; pendingSeek = seek }
            case .restart(let raw):
                guard let seek = pendingSeek, seek.replied, let clock else { continue }
                pendingSeek = nil
                // A frame-grid seek shows exactly that frame (the first at or after its own
                // timestamp). Its time is reported as such: on the last frame MPV can read
                // back the picture's end instead. Other seeks report what MPV reads back.
                let shown = seek.target.frame != nil ? seek.target.asset : raw.map(clock.asset(forRaw:)) ?? seek.target.asset
                currentSeconds = reportedOverride ?? shown
                seek.continuation.resume()
            case .ended:
                isPlaying = false
            }
        }
    }

    private func failSeek(_ failure: Failure) {
        guard let seek = pendingSeek else { return }
        pendingSeek = nil
        seek.continuation.resume(throwing: failure)
    }

    /// Exact seek; returns once the frame is decoded and the position read back.
    /// A newer seek or close makes an unfinished one throw.
    public func seek(toSeconds seconds: Double) async throws {
        guard !closed else { throw Failure.closed }
        guard let clock else { throw Failure.failed("The source player is not open") }
        try Task.checkCancellation()
        let target = clock.target(forAsset: seconds)
        failSeek(.superseded)
        let id = nextRequest; nextRequest += 1
        let core = self.core
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingSeek = Seek(id: id, target: target, continuation: continuation)
                settlingPause = false
                // Past the last frame MPV holds that frame; keep the requested coordinate.
                reportedOverride = media.frameRate != nil && media.videoStreamIndex != nil && target.frame == nil ? target.asset : nil
                core.control.async {
                    let rc = core.seek(raw: target.raw, id: id)
                    if rc < 0 {
                        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                            guard let self, self.pendingSeek?.id == id else { return }
                            self.failSeek(.failed(NativeSourceCore.describe(rc)))
                        } }
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.pendingSeek?.id == id else { return }
                self.failSeek(.superseded)
            } }
        }
        guard !closed else { throw Failure.closed }
    }

    public func play() {
        guard !closed, clock != nil else { return }
        isPlaying = true
        reportedOverride = nil
        send(paused: false)
    }

    public func pause() {
        guard !closed else { return }
        if isPlaying { settlingPause = true }
        isPlaying = false
        failSeek(.superseded)
        send(paused: true)
    }

    private func send(paused: Bool) {
        let id = nextRequest; nextRequest += 1
        let core = self.core
        core.control.async { _ = core.setPaused(paused, id: id) }
    }

    /// Stops playback and pending work at once; libmpv shuts down on its own queue.
    public func close() {
        guard !closed else { return }
        closed = true
        isPlaying = false
        onFrame = nil
        failSeek(.closed)
        finishOpen(Failure.closed)
        let core = self.core
        core.control.async { core.shutdown() }
    }

    /// close(), then wait until libmpv has released the media.
    public func closeAndWait() async {
        close()
        let core = self.core
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            core.control.async { continuation.resume() }
        }
    }
}
