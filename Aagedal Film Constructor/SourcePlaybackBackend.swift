import AVFoundation

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
