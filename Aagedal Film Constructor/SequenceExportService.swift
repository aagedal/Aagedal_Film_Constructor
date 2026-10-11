import Foundation
import Darwin
import EditorCore

nonisolated struct SequenceExportHelperAvailability: Sendable {
    let isAvailable: Bool
    let message: String
}
nonisolated struct SequenceExportProgress: Sendable {
    let fraction: Double
    let renderedSeconds: Double
    let stage: String
}
nonisolated struct SequenceExportResult: Sendable {
    let outputURL: URL
    let videoFrames: Int64
    let audioSamples: Int64
}
nonisolated enum SequenceExportError: LocalizedError {
    case unavailable, destination(String), process(String), verification(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Export requires bundled Helpers/ffmpeg and Helpers/ffprobe. This build does not include executable helpers."
        case .destination(let message), .process(let message), .verification(let message): return message
        }
    }
}

/// Owns all access and subprocess lifetime for a value snapshot of the render plan.
actor SequenceExportService {
    static let shared = SequenceExportService()
    private let ffmpegURL: URL?
    private let ffprobeURL: URL?
    init() {
        ffmpegURL = Self.helper("ffmpeg", bundle: .main)
        ffprobeURL = Self.helper("ffprobe", bundle: .main)
    }
    init(ffmpegURL: URL, ffprobeURL: URL) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
    }
    nonisolated private static func helper(_ name: String, bundle: Bundle) -> URL? {
        bundle.resourceURL?.appendingPathComponent("Helpers", isDirectory: true).appendingPathComponent(name)
    }
    nonisolated static func helperAvailability(bundle: Bundle = .main) -> SequenceExportHelperAvailability {
        let ready = ["ffmpeg", "ffprobe"].allSatisfy { name in
            helper(name, bundle: bundle).map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        }
        return .init(isAvailable: ready, message: ready ? "MOV / ProRes export available" : SequenceExportError.unavailable.localizedDescription)
    }
    func export(plan: TimelineRenderPlan, to outputURL: URL,
                progress: @escaping @Sendable (SequenceExportProgress) -> Void = { _ in }) async throws -> SequenceExportResult {
        guard let ffmpegURL, let ffprobeURL,
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path),
              FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { throw SequenceExportError.unavailable }
        return try await Self.render(plan: plan, output: outputURL, ffmpeg: ffmpegURL, ffprobe: ffprobeURL, progress: progress)
    }
    @concurrent private static func render(plan: TimelineRenderPlan, output: URL, ffmpeg: URL, ffprobe: URL,
                                           progress: @escaping @Sendable (SequenceExportProgress) -> Void) async throws -> SequenceExportResult {
        try Task.checkCancellation()
        guard output.isFileURL, output.pathExtension.lowercased() == "mov" else {
            throw SequenceExportError.destination("Choose a local MOV destination.")
        }
        let urls = Set(plan.components.compactMap(\.originalURL) + [output, output.deletingLastPathComponent()])
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let destination = output.resolvingSymlinksInPath().standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path),
              !plan.components.compactMap(\.originalURL).contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == destination }) else {
            throw SequenceExportError.destination("Export destination already exists or aliases a source. Choose a new filename.")
        }
        // Same-filesystem private staging permits atomic publication of a verified file.
        let stageDirectory = output.deletingLastPathComponent().appendingPathComponent(".afc-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stageDirectory) }
        let staged = stageDirectory.appendingPathComponent("render.mov")
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: staged)
        progress(.init(fraction: 0, renderedSeconds: 0, stage: "Checking sources"))
        try await preflight(plan: plan, command: command, ffprobe: ffprobe)
        let duration = Double(command.videoFrames) / plan.settings.frameRate.value.seconds
        var arguments = command.arguments
        arguments.insert(contentsOf: ["-progress", "pipe:1", "-nostats"], at: 0)
        progress(.init(fraction: 0, renderedSeconds: 0, stage: "Rendering"))
        _ = try await ExportProcess.run(executable: ffmpeg, arguments: arguments, progress: { seconds in
            progress(.init(fraction: min(0.99, max(0, seconds / duration)), renderedSeconds: seconds, stage: "Rendering"))
        })
        try Task.checkCancellation()
        progress(.init(fraction: 0.99, renderedSeconds: duration, stage: "Verifying"))
        let probe = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", staged.path])
        try verify(probe, plan: plan, command: command)
        try Task.checkCancellation()
        // link(2) atomically creates a new name and cannot overwrite a destination created during rendering.
        guard Darwin.link(staged.path, output.path) == 0 else {
            throw SequenceExportError.destination("Could not publish export: \(String(cString: strerror(errno)))")
        }
        progress(.init(fraction: 1, renderedSeconds: duration, stage: "Complete"))
        return .init(outputURL: output, videoFrames: command.videoFrames, audioSamples: command.audioSamples)
    }
    @concurrent private static func preflight(plan: TimelineRenderPlan, command: FFmpegRenderCommand, ffprobe: URL) async throws {
        for url in Set(command.inputs.map(\.url)) {
            try Task.checkCancellation()
            let data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-show_streams", "-of", "json", url.path])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = root["streams"] as? [[String: Any]] else {
                throw SequenceExportError.verification("Cannot qualify source streams for \(url.lastPathComponent).")
            }
            func reject(_ reason: String) -> SequenceExportError {
                .verification("Export source \(url.lastPathComponent): \(reason)")
            }
            func numeric(_ value: Any?) -> Double? {
                if let string = value as? String { return Double(string) }
                return (value as? NSNumber)?.doubleValue
            }
            func rational(_ value: Any?) -> Double? {
                guard let value = value as? String else { return nil }
                let parts = value.split(separator: "/")
                guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 else { return nil }
                return n / d
            }
            for input in Set(command.inputs.filter { $0.url == url }.map { "\($0.streamIndex):\($0.kind.rawValue)" }) {
                let parts = input.split(separator: ":")
                let index = Int(parts[0])!
                let kind = String(parts[1])
                guard let stream = streams.first(where: { numeric($0["index"]) == Double(index) }),
                      stream["codec_type"] as? String == kind else {
                    throw reject("Selected stream index/kind does not match FFprobe. Reimport or select a qualified source.")
                }
                if let offset = numeric(stream["start_time"]), abs(offset) > 0.000001 {
                    throw reject("Nonzero source stream start offsets are not qualified.")
                }
                let components = plan.components.filter { component in
                    guard component.originalURL == url else { return false }
                    switch component.selection {
                    case .video(let selected): return kind == "video" && selected == index
                    case .audio(let selected): return kind == "audio" && selected.channels.contains { $0.streamIndex == index }
                    case .still: return kind == "video" && (component.sourceStreams.first?.index ?? 0) == index
                    }
                }
                if kind == "audio" {
                    guard let channels = numeric(stream["channels"]), channels.isFinite, channels >= 1, channels <= 64, channels.rounded() == channels, components.allSatisfy({ component in
                        component.sourceStreams.first(where: { $0.index == index })?.audioLayout?.channels.count == Int(channels)
                    }) else { throw reject("Selected audio channel count does not match FFprobe.") }
                } else {
                    if let sar = stream["sample_aspect_ratio"] as? String, !["1:1", "N/A", "0:1"].contains(sar) {
                        throw reject("Non-square source pixels are not qualified.")
                    }
                    let rotation = numeric((stream["tags"] as? [String: Any])?["rotate"]) ?? 0
                    let sides = stream["side_data_list"] as? [[String: Any]] ?? []
                    guard rotation == 0, sides.allSatisfy({ (numeric($0["rotation"]) ?? 0) == 0 }) else {
                        throw reject("Rotated sources are not qualified.")
                    }
                    let transfer = stream["color_transfer"] as? String ?? "unknown"
                    let primaries = stream["color_primaries"] as? String ?? "unknown"
                    guard !["smpte2084", "arib-std-b67", "bt2020-10", "bt2020-12"].contains(transfer), primaries != "bt2020" else {
                        throw reject("HDR/wide-gamut sources are not qualified.")
                    }
                    if components.contains(where: { $0.selection != .still }), let average = rational(stream["avg_frame_rate"]),
                       let nominal = rational(stream["r_frame_rate"]), abs(average - nominal) > 0.000001 {
                        throw reject("Variable frame rate sources are not qualified.")
                    }
                }
                if let duration = numeric(stream["duration"]), duration.isFinite {
                    for component in components where component.selection != .still {
                        guard try component.sourceRange.end().seconds <= duration + 0.000021 else {
                            throw reject("Selected source range exceeds the probed stream duration.")
                        }
                    }
                }
            }
        }
    }
    nonisolated private static func verify(_ data: Data, plan: TimelineRenderPlan, command: FFmpegRenderCommand) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw SequenceExportError.verification("Export verification found missing audio/video streams.")
        }
        func integer(_ value: Any?) -> Int64? {
            if let value = value as? String { return Int64(value) }
            return (value as? NSNumber)?.int64Value
        }
        let rate = plan.settings.frameRate.value
        let timecode = try plan.settings.startTimecode.formatted(rate: plan.settings.frameRate)
        let tags = video["tags"] as? [String: Any]
        let formatTags = (root["format"] as? [String: Any])?["tags"] as? [String: Any]
        guard video["codec_name"] as? String == "prores", video["profile"] as? String == "HQ",
              video["pix_fmt"] as? String == "yuv422p10le", integer(video["width"]) == Int64(plan.settings.width),
              integer(video["height"]) == Int64(plan.settings.height),
              video["r_frame_rate"] as? String == "\(rate.numerator)/\(rate.denominator)",
              integer(video["nb_read_frames"]) == command.videoFrames,
              audio["codec_name"] as? String == "pcm_s24le", integer(audio["bits_per_raw_sample"]) == 24,
              integer(audio["sample_rate"]) == Int64(plan.settings.audioSampleRate),
              integer(audio["channels"]) == Int64(plan.settings.audioLayout.channels.count),
              integer(audio["duration_ts"]) == command.audioSamples,
              audio["time_base"] as? String == "1/\(plan.settings.audioSampleRate)",
              (tags?["timecode"] as? String ?? formatTags?["timecode"] as? String) == timecode else {
            throw SequenceExportError.verification("Rendered MOV failed frame count, audio sample count, raster, rate, codec, or timecode verification.")
        }
    }
}

/// Pipes are drained concurrently; retained diagnostics and probe output have fixed limits.
nonisolated final class ExportProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var stdout = Data()
    private var stderr = Data()
    private var overflow = false
    private var readers = 2
    private var line = Data()
    private func read(_ handle: FileHandle, isError: Bool, progress: (@Sendable (Double) -> Void)?) {
        defer { lock.lock(); readers -= 1; lock.unlock(); try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            lock.lock()
            if isError {
                stderr.append(chunk)
                if stderr.count > 32768 { stderr.removeFirst(stderr.count - 32768) }
            } else if let progress {
                line.append(chunk)
                while let end = line.firstIndex(of: 10) {
                    let item = String(decoding: line[..<end], as: UTF8.self)
                    line.removeSubrange(...end)
                    if item.hasPrefix("out_time_us="), let microseconds = Double(item.dropFirst(12)), microseconds.isFinite {
                        lock.unlock(); progress(microseconds / 1_000_000); lock.lock()
                    }
                }
                if line.count > 8192 { line.removeAll() }
            } else {
                if stdout.count + chunk.count <= 2 * 1024 * 1024 { stdout.append(chunk) } else { overflow = true }
            }
            lock.unlock()
        }
    }
    private func cancel() {
        lock.lock(); cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
    }
    @concurrent static func run(executable: URL, arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        let runner = ExportProcess()
        return try await withTaskCancellationHandler {
            let output = Pipe(), errors = Pipe()
            runner.process.executableURL = executable
            runner.process.arguments = arguments
            runner.process.standardInput = FileHandle.nullDevice
            runner.process.standardOutput = output
            runner.process.standardError = errors
            try runner.lock.withLock {
                if runner.cancelled { throw CancellationError() }
                try runner.process.run()
            }
            // Close parent write ends so EOF remains reliable after child exit.
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            DispatchQueue.global().async { runner.read(output.fileHandleForReading, isError: false, progress: progress) }
            DispatchQueue.global().async { runner.read(errors.fileHandleForReading, isError: true, progress: nil) }
            var cancellationStart: Date?
            while runner.process.isRunning {
                if Task.isCancelled {
                    runner.cancel()
                    if cancellationStart == nil { cancellationStart = Date() }
                    if Date().timeIntervalSince(cancellationStart!) > 1 { _ = Darwin.kill(runner.process.processIdentifier, SIGKILL) }
                }
                // Cancellation must not skip process reaping or reader cleanup.
                await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            }
            // Foundation reaps the child before isRunning becomes false. Calling
            // waitUntilExit here can hang when an async task resumed on a different run loop.
            while runner.remainingReaders() > 0 { await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value }
            try Task.checkCancellation()
            guard runner.process.terminationStatus == 0 else {
                throw SequenceExportError.process("Export helper failed (\(runner.process.terminationStatus)): \(String(decoding: runner.stderr, as: UTF8.self))")
            }
            guard !runner.overflow else { throw SequenceExportError.verification("Probe output exceeded its 2 MB limit.") }
            return runner.stdout
        } onCancel: { runner.cancel() }
    }
    private func remainingReaders() -> Int { lock.lock(); defer { lock.unlock() }; return readers }
}
