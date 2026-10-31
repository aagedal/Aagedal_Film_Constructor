import Foundation
import UniformTypeIdentifiers

nonisolated enum MediaConversionError: LocalizedError {
    case unavailable, noStreams, probe(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This format needs conversion, but this build does not include the bundled FFmpeg helpers."
        case .noStreams: return "FFmpeg found no video or audio streams to convert."
        case .probe(let message): return message
        }
    }
}

/// Converts media that AVFoundation cannot open (MXF, MKV, WebM, AVI, MPEG-TS, 4:2:2 10-bit
/// H.264, …) into an edit-friendly MOV in the app's Converted Media folder. Compatible
/// H.264/HEVC/ProRes picture is rewrapped; everything else becomes ProRes. All audio
/// streams become 24-bit PCM, and container timecode is preserved.
actor MediaConversionService {
    static let shared = MediaConversionService()
    /// Extensions offered in the import panel in addition to system movie/audio types.
    nonisolated static let additionalExtensions = ["mxf", "mkv", "webm", "nut", "avi", "ts", "mts", "m2ts", "m2t", "flv", "wmv", "ogg", "opus", "vob", "mpg", "mpeg", "m2p", "mod", "tod"]
    /// MPEG program and transport streams are always converted, even when AVFoundation opens
    /// them: it can omit their AAC/LPCM audio and number their streams differently from FFmpeg,
    /// which renders the export.
    nonisolated static let alwaysConvertedExtensions: Set<String> = ["ts", "mts", "m2ts", "m2t", "vob", "mpg", "mpeg", "m2p", "mod", "tod"]
    private let ffmpegURL: URL?
    private let ffprobeURL: URL?
    /// Where converted files are written; nil uses the app's Converted Media folder.
    private let defaultDirectory: URL?

    init(bundle: Bundle = .main) {
        let helpers = bundle.resourceURL?.appendingPathComponent("Helpers", isDirectory: true)
        ffmpegURL = helpers?.appendingPathComponent("ffmpeg")
        ffprobeURL = helpers?.appendingPathComponent("ffprobe")
        defaultDirectory = nil
    }
    init(ffmpegURL: URL, ffprobeURL: URL, outputDirectory: URL? = nil) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        defaultDirectory = outputDirectory
    }

    nonisolated static var importContentTypes: [UTType] {
        [.movie, .audio, .image] + additionalExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Converted media lives with the app's support files; originals are never modified.
    nonisolated static func outputDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Converted Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func convert(_ source: URL, into directory: URL? = nil) async throws -> URL {
        guard let ffmpegURL, let ffprobeURL,
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path),
              FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { throw MediaConversionError.unavailable }
        let directory = try directory ?? defaultDirectory ?? Self.outputDirectory()
        return try await Self.run(source: source, directory: directory, ffmpeg: ffmpegURL, ffprobe: ffprobeURL)
    }

    @concurrent private static func run(source: URL, directory: URL, ffmpeg: URL, ffprobe: URL) async throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-show_streams", "-of", "json", source.path], timeout: 60)
        } catch {
            throw MediaConversionError.probe("\(source.lastPathComponent) is not a readable media file.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { throw MediaConversionError.noStreams }
        let arguments = try conversionArguments(streams: streams)
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let destination = directory.appendingPathComponent("\(stem)-\(suffix).mov")
        let partial = directory.appendingPathComponent(".partial-\(suffix).mov")
        defer { try? FileManager.default.removeItem(at: partial) }
        _ = try await ExportProcess.run(executable: ffmpeg, arguments: ["-hide_banner", "-nostdin", "-n", "-i", source.path]
                                        + arguments + [partial.path])
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// Pure argument selection, separated for testing.
    nonisolated static func conversionArguments(streams: [[String: Any]]) throws -> [String] {
        func index(_ stream: [String: Any]) -> Int? { (stream["index"] as? NSNumber)?.intValue }
        let video = streams.first { stream in
            stream["codec_type"] as? String == "video" &&
                ((stream["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.intValue != 1
        }
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }
        guard video != nil || !audio.isEmpty else { throw MediaConversionError.noStreams }
        var arguments: [String] = []
        if let video, let videoIndex = index(video) {
            arguments += ["-map", "0:\(videoIndex)"]
            let codec = video["codec_name"] as? String ?? ""
            let pixelFormat = video["pix_fmt"] as? String ?? ""
            let alpha = pixelFormat.hasPrefix("yuva") || pixelFormat.hasPrefix("gbrap") || pixelFormat.hasPrefix("ya")
                || ["rgba", "bgra", "argb", "abgr"].contains { pixelFormat.hasPrefix($0) }
            switch (codec, pixelFormat) {
            case ("h264", "yuv420p"), ("h264", "yuvj420p"):
                arguments += ["-c:v", "copy"]
            case ("hevc", "yuv420p"), ("hevc", "yuv420p10le"):
                arguments += ["-c:v", "copy", "-tag:v", "hvc1"]
            case ("prores", _):
                arguments += ["-c:v", "copy"]
            default:
                arguments += alpha
                    ? ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le"]
                    : ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"]
            }
        }
        for stream in audio { if let audioIndex = index(stream) { arguments += ["-map", "0:\(audioIndex)"] } }
        if !audio.isEmpty { arguments += ["-c:a", "pcm_s24le"] }
        return arguments + ["-map_metadata", "0", "-dn", "-sn"]
    }
}
