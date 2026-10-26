import Foundation

/// Makes a stabilised copy of part of a movie with FFmpeg's deshake filter. The copy covers
/// the requested source range and is used for both preview and export, so they always agree.
enum StabilisationService {
    /// Stabilised copies live with the app's support files; originals are never modified.
    nonisolated static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Stabilised", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `start` and `duration` are source seconds; the copy's time zero is `start` in the source.
    @concurrent static func stabilise(source: URL, start: Double, duration: Double, ffmpeg: URL, into directory: URL) async throws -> URL {
        let name = source.deletingPathExtension().lastPathComponent + "-stabilised-" + UUID().uuidString.prefix(8) + ".mov"
        let output = directory.appendingPathComponent(String(name))
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await ExportProcess.run(executable: ffmpeg, arguments: [
                "-hide_banner", "-nostdin", "-n", "-ss", String(format: "%.6f", start), "-i", source.path, "-t", String(format: "%.6f", duration),
                "-map", "0:v:0", "-an", "-vf", "deshake=rx=64:ry=64:edge=mirror",
                "-c:v", "hevc_videotoolbox", "-q:v", "70", "-tag:v", "hvc1",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", output.path])
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
