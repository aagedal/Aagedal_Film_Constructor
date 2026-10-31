import AVFoundation
#if canImport(NativePlaybackRuntime)
import NativePlaybackRuntime
#endif

/// Source coordinates and transport are independent of the rendering engine.
/// Proxy/original selection prepares the media before installing a backend.
@MainActor
protocol SourcePlaybackBackend: AnyObject {
    var currentTime: CMTime { get }
    var isPlaying: Bool { get }
    var surface: SourcePlaybackSurface { get }
    func seek(to time: CMTime) async throws
    func play()
    func pause()
    /// Cancel pending seeks and release media before security-scoped access ends.
    func close()
}

@MainActor
enum SourcePlaybackSurface {
    case avFoundation(AVPlayer)
    #if canImport(NativePlaybackRuntime)
    /// libmpv picture rendered in software; sound plays through CoreAudio.
    case mpv(NativeSourcePlayer)
    #endif
}

enum SourcePlaybackError: LocalizedError {
    case closed
    case seekFailed

    var errorDescription: String? {
        switch self {
        case .closed: return "The source player has closed."
        case .seekFailed: return "The source player could not reach the requested position."
        }
    }
}

@MainActor
final class AVFoundationSourceBackend: SourcePlaybackBackend {
    let player: AVPlayer
    private var closed = false

    init(player: AVPlayer) { self.player = player }

    var currentTime: CMTime { player.currentTime() }
    var isPlaying: Bool { player.rate > 0 }
    var surface: SourcePlaybackSurface { .avFoundation(player) }

    func seek(to time: CMTime) async throws {
        try Task.checkCancellation()
        guard !closed else { throw SourcePlaybackError.closed }
        let completed = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard !closed else { throw SourcePlaybackError.closed }
        guard completed else { throw SourcePlaybackError.seekFailed }
    }

    func play() { if !closed { player.play() } }
    func pause() {
        player.pause()
        player.currentItem?.cancelPendingSeeks()
    }

    func close() {
        guard !closed else { return }
        closed = true
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }
}

#if canImport(NativePlaybackRuntime)
/// libmpv transport for originals AVFoundation cannot play (media imported unconverted
/// through FFmpeg, or MOVs it reads but cannot decode), and for proxy picture with
/// such an original's sound. Picture seeks land on the FFmpeg frame grid that export uses.
@MainActor
final class MPVSourceBackend: SourcePlaybackBackend {
    let player: NativeSourcePlayer
    private var closed = false

    init(player: NativeSourcePlayer) { self.player = player }

    // Flicks (1/705,600,000 s) hold 24000/1001, 25, 30000/1001 and 44.1/48 kHz grids exactly.
    var currentTime: CMTime { CMTime(seconds: player.currentSeconds, preferredTimescale: 705_600_000) }
    var isPlaying: Bool { player.isPlaying }
    var surface: SourcePlaybackSurface { .mpv(player) }

    func seek(to time: CMTime) async throws {
        try Task.checkCancellation()
        guard !closed else { throw SourcePlaybackError.closed }
        do {
            try await player.seek(toSeconds: time.seconds)
        } catch NativeSourcePlayer.Failure.closed {
            throw SourcePlaybackError.closed
        } catch {
            try Task.checkCancellation()
            throw closed ? SourcePlaybackError.closed : SourcePlaybackError.seekFailed
        }
        try Task.checkCancellation()
        guard !closed else { throw SourcePlaybackError.closed }
    }

    func play() { if !closed { player.play() } }
    func pause() { player.pause() }

    func close() {
        guard !closed else { return }
        closed = true
        player.close()
    }
}
#endif
