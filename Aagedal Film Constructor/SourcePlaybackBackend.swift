import AVFoundation

/// Source coordinates and transport are independent of the rendering engine.
/// Proxy/original selection prepares the media before installing a backend.
@MainActor
protocol SourcePlaybackBackend: AnyObject {
    var currentTime: CMTime { get }
    var isPlaying: Bool { get }
    var surface: SourcePlaybackSurface { get }
    func seek(to time: CMTime) async
    func play()
    func pause()
    /// Cancel pending seeks and release media before security-scoped access ends.
    func close()
}

@MainActor
enum SourcePlaybackSurface {
    case avFoundation(AVPlayer)
}

@MainActor
final class AVFoundationSourceBackend: SourcePlaybackBackend {
    let player: AVPlayer
    private var closed = false

    init(player: AVPlayer) { self.player = player }

    var currentTime: CMTime { player.currentTime() }
    var isPlaying: Bool { player.rate > 0 }
    var surface: SourcePlaybackSurface { .avFoundation(player) }

    func seek(to time: CMTime) async {
        guard !closed else { return }
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() { if !closed { player.play() } }
    func pause() { player.pause() }

    func close() {
        guard !closed else { return }
        closed = true
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }
}
