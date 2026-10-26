import Foundation

/// Makes a noise-reduced copy of an audio component's selected channels with FFmpeg's afftdn
/// (FFT denoiser), its noise floor measured from the quietest half second. The copy is used for preview and export alike.
enum NoiseReductionService {
    nonisolated static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Noise Reduced", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `channels` are (container stream index, channel) pairs in output order. `amount` is the
    /// reduction in dB. The copy's time zero is `start` in the source.
    @concurrent static func reduce(source: URL, channels: [(stream: Int, channel: Int)], amount: Double,
                                   start: Double, duration: Double, ffmpeg: URL, into directory: URL) async throws -> URL {
        let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-clean-" + UUID().uuidString.prefix(8) + ".wav")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var graph = channels.enumerated().map { "[0:\($0.element.stream)]pan=mono|c0=c\($0.element.channel)[c\($0.offset)]" }
        let inputs = channels.indices.map { "[c\($0)]" }.joined()
        let merge = channels.count > 1 ? "amerge=inputs=\(channels.count)," : ""
        // The noise floor is the level of the quietest half second (a pause). afftdn needs it set
        // close to the real floor; its adaptive tracking (tn) barely reduces broadband hiss.
        let profile = try await quietestWindow(source: source, channel: channels[0], start: start, duration: duration, ffmpeg: ffmpeg)
        let floor = min(-20, max(-80, profile.level))
        graph.append(inputs + merge + "afftdn=nr=\(amount):nf=\(String(format: "%.1f", floor))[out]")
        do {
            _ = try await ExportProcess.run(executable: ffmpeg, arguments: [
                "-hide_banner", "-nostdin", "-n", "-ss", String(format: "%.6f", start), "-i", source.path, "-t", String(format: "%.6f", duration),
                "-filter_complex", graph.joined(separator: ";"), "-map", "[out]", "-c:a", "pcm_s24le", output.path])
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// Start (seconds into the range) and level (dBFS) of the quietest half second of one channel.
    @concurrent private static func quietestWindow(source: URL, channel: (stream: Int, channel: Int), start: Double, duration: Double,
                                                   ffmpeg: URL) async throws -> (time: Double, level: Double) {
        // Samples go to a scratch file: the process runner caps captured output at 2 MB.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("afc-noise-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try await ExportProcess.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-nostdin", "-ss", String(format: "%.6f", start), "-i", source.path, "-t", String(format: "%.6f", duration),
            // Full bandwidth: resampling would drop most of broadband hiss and understate the floor.
            "-filter_complex", "[0:\(channel.stream)]pan=mono|c0=c\(channel.channel),aresample=48000[a]", "-map", "[a]", "-f", "f32le", scratch.path])
        let samples = try Data(contentsOf: scratch).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let window = 24000, step = 2400
        guard samples.count > window else { return (0, -60) }
        var best = (time: 0.0, energy: Double.infinity)
        var offset = 0
        while offset + window <= samples.count {
            let energy = samples[offset..<(offset + window)].reduce(0) { $0 + Double($1 * $1) } / Double(window)
            if energy < best.energy { best = (Double(offset) / 48000, energy) }
            offset += step
        }
        return (best.time, best.energy > 0 ? 10 * log10(best.energy) : -80)
    }
}
