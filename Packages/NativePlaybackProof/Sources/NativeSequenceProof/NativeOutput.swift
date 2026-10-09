import AVFAudio
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Construct a native image from the selected decoded pixels. ImageIO's PNG is
/// an inspectable capture, not evidence of a display refresh or Metal rendering.
func writeNativeImage(rgb: Data, width: Int, height: Int, to url: URL) throws {
    guard let provider = CGDataProvider(data: rgb as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 24, bytesPerRow: width * 3,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [],
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL,
              UTType.png.identifier as CFString, 1, nil) else {
        throw ProofFailure("Cannot construct native image capture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ProofFailure("Cannot write native PNG") }
}

/// Schedule bounded mixed buffers against AVAudioPlayerNode's sample clock.
/// Offline mode exercises the actual native scheduling path without assuming an
/// audio device is available; live CoreAudio latency and A/V sync remain untested.
func renderNativeAudio(monitor: NativeMonitor, start: Int64, count: Int64,
                       consume: ([Float]) throws -> Void) throws {
    guard start >= 0, count > 0, start <= monitor.plan.audioSamples,
          count <= monitor.plan.audioSamples - start else { throw ProofFailure("Invalid native audio span") }
    let sampleRate = Double(monitor.plan.settings.audioSampleRate)
    let channels = monitor.plan.settings.audioLayout.channels.count
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                     channels: AVAudioChannelCount(channels)) else {
        throw ProofFailure("Cannot create native audio format")
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let block: Int64 = 1024
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: UInt32(block))
    defer {
        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
    }
    guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: UInt32(block)) else {
        throw ProofFailure("Cannot allocate native output buffer")
    }
    var scheduled: Int64 = 0
    // Four blocks of look-ahead keep retained buffers bounded. Absolute times
    // are relative to the requested seek position, never wall-clock estimates.
    func fillQueue(renderedThrough: Int64) throws {
        while scheduled < count, scheduled - renderedThrough < block * 4 {
            let length = Int(min(block, count - scheduled))
            let samples = try monitor.audio(start: start + scheduled, count: length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(length)),
                  let data = buffer.floatChannelData else { throw ProofFailure("Cannot allocate scheduled buffer") }
            buffer.frameLength = UInt32(length)
            for channel in 0..<channels {
                for frame in 0..<length { data[channel][frame] = samples[frame * channels + channel] }
            }
            player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: scheduled, atRate: sampleRate))
            scheduled += Int64(length)
        }
    }
    try fillQueue(renderedThrough: 0)
    try engine.start()
    player.play()
    var position: Int64 = 0
    var retries = 0
    while position < count {
        let length = UInt32(min(block, count - position))
        let status = try engine.renderOffline(length, to: rendered)
        if status == .cannotDoInCurrentContext {
            retries += 1
            guard retries <= 8 else { throw ProofFailure("Native offline render failed to advance") }
            continue
        }
        guard status == .success, rendered.frameLength == length,
              let data = rendered.floatChannelData else {
            throw ProofFailure("Native offline render status \(status.rawValue), frames \(rendered.frameLength)")
        }
        retries = 0
        var interleaved = [Float](repeating: 0, count: Int(length) * channels)
        for frame in 0..<Int(length) {
            for channel in 0..<channels { interleaved[frame * channels + channel] = data[channel][frame] }
        }
        try consume(interleaved)
        position += Int64(length)
        guard engine.manualRenderingSampleTime == position else {
            throw ProofFailure("Native sample clock differs from emitted frame count")
        }
        try fillQueue(renderedThrough: position)
    }
}
