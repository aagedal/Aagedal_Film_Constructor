import Foundation
import Darwin
import EditorCore

/// Generates a separate, verified video rendition. Originals and existing proxies are never replaced.
actor ProxyGenerationService {
    static let shared = ProxyGenerationService()
    private let ffmpegURL: URL?
    private let ffprobeURL: URL?
    private var activeJobs = 0
    init() {
        let helpers = Bundle.main.resourceURL?.appendingPathComponent("Helpers", isDirectory: true)
        ffmpegURL = helpers?.appendingPathComponent("ffmpeg")
        ffprobeURL = helpers?.appendingPathComponent("ffprobe")
    }
    init(ffmpegURL: URL, ffprobeURL: URL) {
        self.ffmpegURL = ffmpegURL; self.ffprobeURL = ffprobeURL
    }
    nonisolated static func fingerprint(for url: URL) throws -> MediaSourceFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
            throw SequenceExportError.verification("Proxy source must be a regular local file.")
        }
        return .init(fileSize: size.int64Value, modificationTime: date.timeIntervalSince1970)
    }
    func generate(asset: MediaAsset, preset: ProxyPreset, scaleDivisor: Int, to outputURL: URL,
                  progress: @escaping @Sendable (SequenceExportProgress) -> Void = { _ in }) async throws -> MediaProxy {
        guard let ffmpegURL, let ffprobeURL,
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path),
              FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { throw SequenceExportError.unavailable }
        guard activeJobs < 2 else {
            throw SequenceExportError.process("Two proxy jobs are already running. Wait for a job to finish, then retry.")
        }
        activeJobs += 1
        defer { activeJobs -= 1 }
        return try await Self.render(asset: asset, preset: preset, divisor: scaleDivisor, output: outputURL,
                                     ffmpeg: ffmpegURL, ffprobe: ffprobeURL, progress: progress)
    }
    @concurrent private static func render(asset: MediaAsset, preset: ProxyPreset, divisor: Int, output: URL,
                                           ffmpeg: URL, ffprobe: URL,
                                           progress: @escaping @Sendable (SequenceExportProgress) -> Void) async throws -> MediaProxy {
        try Task.checkCancellation()
        guard let source = asset.originalURL, source.isFileURL,
              let selected = asset.streams.first(where: { $0.kind == .video }), selected.timeOffset == .zero else {
            throw SequenceExportError.verification("Proxy generation requires a video source with zero stream offset.")
        }
        guard output.isFileURL, output.pathExtension.lowercased() == "mov", [1, 2, 4].contains(divisor) else {
            throw SequenceExportError.destination("Choose a new local MOV filename and full, half, or quarter resolution.")
        }
        let scoped = [source, output.deletingLastPathComponent()].filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard source.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw SequenceExportError.destination("Proxy destination already exists or aliases the original. Choose a new filename.")
        }
        let fingerprint = try fingerprint(for: source)
        progress(.init(fraction: 0, renderedSeconds: 0, stage: "Checking source"))
        let original = try await probe(source, index: selected.index, ffprobe: ffprobe)
        let width = original.width / divisor, height = original.height / divisor
        guard original.width % divisor == 0, original.height % divisor == 0,
              width >= 2, height >= 2, width % 2 == 0, height % 2 == 0 else {
            throw SequenceExportError.verification("Proxy scaling must preserve aspect ratio exactly and produce an even raster.")
        }
        let count = try await verifyFrames(source, index: selected.index, rate: original.rate, timeBase: original.timeBase, ffprobe: ffprobe)
        let duration = Double(count) / original.rate.seconds
        let directory = output.deletingLastPathComponent().appendingPathComponent(".afc-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("proxy.mov")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-progress", "pipe:1", "-nostats",
                         "-noautorotate", "-i", source.path, "-map", "0:\(selected.index)", "-an", "-sn", "-dn",
                         "-map_metadata", "-1", "-vf", "scale=\(width):\(height):flags=lanczos,setsar=1",
                         "-fps_mode", "passthrough", "-enc_time_base", "\(original.rate.denominator)/\(original.rate.numerator)",
                         "-video_track_timescale", "\(original.rate.numerator)"]
        switch preset {
        case .proResProxy: arguments += ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le"]
        case .h264: arguments += ["-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        for key in original.color.keys.sorted() { arguments += ["-\(key)", original.color[key]!] }
        if let timecode = original.timecode { arguments += ["-timecode", timecode] }
        arguments += ["-f", "mov", staged.path]
        _ = try await ExportProcess.run(executable: ffmpeg, arguments: arguments, progress: { seconds in
            progress(.init(fraction: min(0.95, max(0, seconds / duration)), renderedSeconds: seconds, stage: "Generating proxy"))
        })
        try Task.checkCancellation()
        progress(.init(fraction: 0.95, renderedSeconds: duration, stage: "Verifying proxy"))
        let rendition = try await probe(staged, index: 0, ffprobe: ffprobe)
        let expectedCodec = preset == .proResProxy ? "prores" : "h264"
        guard rendition.codec == expectedCodec, rendition.profile == (preset == .proResProxy ? "Proxy" : "High"),
              rendition.width == width, rendition.height == height, rendition.rate == original.rate,
              rendition.timecode == original.timecode, rendition.color == original.color,
              !rendition.hasAudio, rendition.videoStreamCount == 1 else {
            throw SequenceExportError.verification("Proxy codec, profile, raster, rate, timecode, or video-only verification failed.")
        }
        let outputCount = try await verifyFrames(staged, index: 0, rate: rendition.rate, timeBase: rendition.timeBase, ffprobe: ffprobe)
        guard outputCount == count, try Self.fingerprint(for: source) == fingerprint else {
            throw SequenceExportError.verification("Proxy frame count differs or the original changed during generation.")
        }
        let result = MediaProxy(url: output, preset: preset, sourceFingerprint: fingerprint, videoStreamIndex: selected.index,
                                width: width, height: height, frameRate: original.rate, frameCount: count)
        try result.validate()
        try Task.checkCancellation()
        guard Darwin.link(staged.path, output.path) == 0 else {
            throw SequenceExportError.destination("Could not publish proxy: \(String(cString: strerror(errno)))")
        }
        progress(.init(fraction: 1, renderedSeconds: duration, stage: "Complete"))
        return result
    }
    nonisolated private struct Probed: Sendable {
        let width: Int, height: Int
        let rate: RationalTime, timeBase: RationalTime
        let codec: String, profile: String?, timecode: String?
        let hasAudio: Bool
        let videoStreamCount: Int
        let color: [String: String]
    }
    nonisolated private static func rational(_ value: Any?) throws -> RationalTime {
        guard let value = value as? String else { throw SequenceExportError.verification("Missing source frame rate/time base.") }
        let parts = value.split(separator: "/")
        guard parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]), n > 0, d > 0 else {
            throw SequenceExportError.verification("Invalid source frame rate/time base.")
        }
        return try RationalTime(n, d)
    }
    @concurrent private static func probe(_ url: URL, index: Int, ffprobe: URL) async throws -> Probed {
        let data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let video = streams.first(where: { ($0["index"] as? NSNumber)?.intValue == index }),
              video["codec_type"] as? String == "video", let width = video["width"] as? Int, let height = video["height"] as? Int else {
            throw SequenceExportError.verification("Selected video stream is missing or invalid.")
        }
        func number(_ value: Any?) -> Double? {
            if let string = value as? String { return Double(string) }
            return (value as? NSNumber)?.doubleValue
        }
        let tags = video["tags"] as? [String: Any]
        let sides = video["side_data_list"] as? [[String: Any]] ?? []
        let sar = video["sample_aspect_ratio"] as? String ?? "1:1"
        let transfer = video["color_transfer"] as? String ?? "unknown"
        guard width > 0, height > 0, ["1:1", "N/A", "0:1"].contains(sar),
              (number(video["start_time"]) ?? 0) == 0, (number(tags?["rotate"]) ?? 0) == 0,
              sides.allSatisfy({ (number($0["rotation"]) ?? 0) == 0 && !["Mastering display metadata", "Content light level metadata", "DOVI configuration record"].contains($0["side_data_type"] as? String ?? "") }),
              !["smpte2084", "arib-std-b67", "bt2020-10", "bt2020-12"].contains(transfer),
              video["color_primaries"] as? String != "bt2020" else {
            throw SequenceExportError.verification("Rotated, anamorphic, HDR, or offset video is not qualified for proxies.")
        }
        let rate = try rational(video["r_frame_rate"])
        guard try rational(video["avg_frame_rate"]) == rate else {
            throw SequenceExportError.verification("Variable frame rate sources are not qualified for proxies.")
        }
        let formatTags = (root["format"] as? [String: Any])?["tags"] as? [String: Any]
        var color: [String: String] = ["color_range": "tv"]
        for key in ["color_range", "color_space", "color_transfer", "color_primaries"] {
            if let value = video[key] as? String, value != "unknown", value != "unspecified" {
                color[key == "color_space" ? "colorspace" : key == "color_transfer" ? "color_trc" : key] = value
            }
        }
        // H264 omits the VUI range flag for its specified default (limited/tv).
        // ProRes also decodes as limited range; full-range sources need separate qualification.
        guard color["color_range"] == "tv", !(video["pix_fmt"] as? String ?? "").hasPrefix("yuvj") else {
            throw SequenceExportError.verification("Full-range video is not yet qualified for proxy conversion.")
        }
        return .init(width: width, height: height, rate: rate, timeBase: try rational(video["time_base"]),
                     codec: video["codec_name"] as? String ?? "", profile: video["profile"] as? String,
                     timecode: tags?["timecode"] as? String ?? formatTags?["timecode"] as? String,
                     hasAudio: streams.contains { $0["codec_type"] as? String == "audio" },
                     videoStreamCount: streams.filter { $0["codec_type"] as? String == "video" }.count,
                     color: color)
    }
    /// Every decoded timestamp must identify the same consecutive source frame. The shared runner bounds output to 2 MB.
    @concurrent private static func verifyFrames(_ url: URL, index: Int, rate: RationalTime, timeBase: RationalTime, ffprobe: URL) async throws -> Int64 {
        let data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-select_streams", "\(index)", "-show_frames",
            "-show_entries", "frame=best_effort_timestamp,best_effort_timestamp_time", "-of", "json", url.path])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = root["frames"] as? [[String: Any]], !frames.isEmpty else {
            throw SequenceExportError.verification("Could not verify decoded video frames.")
        }
        for (index, frame) in frames.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let timestamp = frame["best_effort_timestamp"] as? NSNumber,
                  let text = frame["best_effort_timestamp_time"] as? String, let seconds = Double(text), seconds.isFinite else {
                throw SequenceExportError.verification("Video frame has no qualified timestamp.")
            }
            let expected = try RationalTime(Int64(index)).divided(by: rate)
            let actual = try timeBase.multiplied(by: timestamp.int64Value)
            guard actual == expected, abs(seconds - expected.seconds) <= 0.000001 else {
                throw SequenceExportError.verification("Variable, missing, or offset frame timestamps are not qualified for proxies.")
            }
        }
        return Int64(frames.count)
    }
}
