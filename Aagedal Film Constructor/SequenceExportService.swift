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
    let warnings: [String]
}
/// Strict qualification refuses any source outside the decoded-parity subset.
/// The default renders conformable sources and reports approximations as warnings.
nonisolated struct SequenceExportOptions: Sendable {
    var format: RenderOutputFormat = .proRes422HQ
    var strictQualification = false
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
        return .init(isAvailable: ready, message: ready ? "Export available" : SequenceExportError.unavailable.localizedDescription)
    }
    /// Probe sources without rendering; returns approximations the export would make.
    func assess(plan: TimelineRenderPlan, options: SequenceExportOptions = .init()) async throws -> [String] {
        guard let ffprobeURL, FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { throw SequenceExportError.unavailable }
        let urls = Set(plan.components.compactMap(\.originalURL))
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(options.format.fileExtension)
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: probeURL, format: options.format)
        return try await Self.preflight(plan: plan, command: command, ffprobe: ffprobeURL, strict: options.strictQualification).warnings
    }
    func export(plan: TimelineRenderPlan, to outputURL: URL, options: SequenceExportOptions = .init(),
                progress: @escaping @Sendable (SequenceExportProgress) -> Void = { _ in }) async throws -> SequenceExportResult {
        guard let ffmpegURL, let ffprobeURL,
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path),
              FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { throw SequenceExportError.unavailable }
        return try await Self.render(plan: plan, output: outputURL, options: options, ffmpeg: ffmpegURL, ffprobe: ffprobeURL, progress: progress)
    }
    @concurrent private static func render(plan: TimelineRenderPlan, output: URL, options: SequenceExportOptions, ffmpeg: URL, ffprobe: URL,
                                           progress: @escaping @Sendable (SequenceExportProgress) -> Void) async throws -> SequenceExportResult {
        try Task.checkCancellation()
        let format = options.format
        guard output.isFileURL, output.pathExtension.lowercased() == format.fileExtension else {
            throw SequenceExportError.destination("Choose a local \(format.fileExtension.uppercased()) destination.")
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
        let staged = stageDirectory.appendingPathComponent("render." + format.fileExtension)
        var command = try FFmpegRenderCompiler.compile(plan, outputURL: staged, format: format)
        progress(.init(fraction: 0, renderedSeconds: 0, stage: "Checking sources"))
        let (warnings, hdrSources) = try await preflight(plan: plan, command: command, ffprobe: ffprobe, strict: options.strictQualification)
        if !hdrSources.isEmpty {
            command = try FFmpegRenderCompiler.compile(plan, outputURL: staged, format: format, toneMappedSources: hdrSources)
        }
        let duration = Double(command.videoFrames) / plan.settings.frameRate.value.seconds
        var arguments = command.arguments
        arguments.insert(contentsOf: ["-progress", "pipe:1", "-nostats"], at: 0)
        progress(.init(fraction: 0, renderedSeconds: 0, stage: "Rendering"))
        _ = try await ExportProcess.run(executable: ffmpeg, arguments: arguments, progress: { seconds in
            progress(.init(fraction: min(0.99, max(0, seconds / duration)), renderedSeconds: seconds, stage: "Rendering"))
        })
        try Task.checkCancellation()
        progress(.init(fraction: 0.99, renderedSeconds: duration, stage: "Verifying"))
        // Packet counts equal frame counts for these intra/progressive encoders and avoid a
        // second full decode; strict qualification still decodes every rendered frame.
        let counting = options.strictQualification ? "-count_frames" : "-count_packets"
        let probe = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", counting, "-show_streams", "-show_format", "-of", "json", staged.path])
        try verify(probe, plan: plan, command: command, format: format, counted: options.strictQualification ? "nb_read_frames" : "nb_read_packets")
        try Task.checkCancellation()
        // link(2) atomically creates a new name and cannot overwrite a destination created during rendering.
        guard Darwin.link(staged.path, output.path) == 0 else {
            throw SequenceExportError.destination("Could not publish export: \(String(cString: strerror(errno)))")
        }
        progress(.init(fraction: 1, renderedSeconds: duration, stage: "Complete"))
        return .init(outputURL: output, videoFrames: command.videoFrames, audioSamples: command.audioSamples, warnings: warnings)
    }
    @concurrent private static func preflight(plan: TimelineRenderPlan, command: FFmpegRenderCommand, ffprobe: URL,
                                              strict: Bool) async throws -> (warnings: [String], hdrSources: [URL: Int]) {
        var warnings: [String] = []
        var hdrSources: [URL: Int] = [:]
        for url in Set(command.inputs.map(\.url)).sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-show_streams", "-of", "json", url.path], timeout: 30)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = root["streams"] as? [[String: Any]] else {
                throw SequenceExportError.verification("Cannot qualify source streams for \(url.lastPathComponent).")
            }
            func reject(_ reason: String) -> SequenceExportError {
                .verification("Export source \(url.lastPathComponent): \(reason)")
            }
            /// Strict mode refuses; otherwise the render proceeds and reports the approximation once.
            func qualify(_ strictReason: String, warning: String?) throws {
                if strict { throw reject(strictReason) }
                if let warning {
                    let message = "\(url.lastPathComponent): \(warning)"
                    if !warnings.contains(message) { warnings.append(message) }
                }
            }
            func numeric(_ value: Any?) -> Double? {
                if let string = value as? String { return Double(string) }
                return (value as? NSNumber)?.doubleValue
            }
            func rational(_ value: Any?) -> RationalTime? {
                guard let value = value as? String else { return nil }
                let parts = value.split(separator: "/")
                guard parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]), d > 0, n > 0 else { return nil }
                return try? RationalTime(n, d)
            }
            for input in Set(command.inputs.filter { $0.url == url }.map { "\($0.streamIndex):\($0.kind.rawValue)" }) {
                let parts = input.split(separator: ":")
                let index = Int(parts[0])!
                let kind = String(parts[1])
                guard let stream = streams.first(where: { numeric($0["index"]) == Double(index) }),
                      stream["codec_type"] as? String == kind else {
                    throw reject("Selected stream index/kind does not match FFprobe. Reimport or select a qualified source.")
                }
                if let offset = numeric(stream["start_time"]), !offset.isFinite || abs(offset) > 0.000001 {
                    try qualify("Nonzero source stream start offsets are not qualified.", warning: nil)
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
                    guard let sampleRate = numeric(stream["sample_rate"]), sampleRate.isFinite,
                          sampleRate >= 1, sampleRate <= 768000, sampleRate.rounded() == sampleRate else {
                        throw reject("Selected audio sample rate is missing or invalid.")
                    }
                    guard let channels = numeric(stream["channels"]), channels.isFinite, channels >= 1, channels <= 64, channels.rounded() == channels, components.allSatisfy({ component in
                        component.sourceStreams.first(where: { $0.index == index })?.audioLayout?.channels.count == Int(channels)
                    }) else { throw reject("Selected audio channel count does not match FFprobe.") }
                } else {
                    guard let width = numeric(stream["width"]), let height = numeric(stream["height"]),
                          width.isFinite, height.isFinite, width >= 1, height >= 1,
                          width <= 16384, height <= 16384, width.rounded() == width, height.rounded() == height else {
                        throw reject("Selected source raster is missing, invalid, or exceeds the 16384-pixel limit.")
                    }
                    if let sar = stream["sample_aspect_ratio"] as? String, !["1:1", "N/A", "0:1"].contains(sar) {
                        try qualify("Non-square source pixels are not qualified.", warning: nil)
                    }
                    let rotation = numeric((stream["tags"] as? [String: Any])?["rotate"]) ?? 0
                    let sides = stream["side_data_list"] as? [[String: Any]] ?? []
                    if rotation != 0 || !sides.allSatisfy({ (numeric($0["rotation"]) ?? 0) == 0 }) {
                        try qualify("Rotated sources are not qualified.", warning: nil)
                    }
                    let transfer = stream["color_transfer"] as? String ?? "unknown"
                    let primaries = stream["color_primaries"] as? String ?? "unknown"
                    if ["smpte2084", "arib-std-b67", "bt2020-10", "bt2020-12"].contains(transfer) || primaries == "bt2020" {
                        try qualify("HDR/wide-gamut sources are not qualified.", warning: "HDR picture is tone mapped to SDR (Rec. 709).")
                        if components.contains(where: { $0.selection != .still }) {
                            hdrSources[url] = Int(sides.compactMap { numeric($0["rotation"]) }.first(where: { $0 != 0 }) ?? -rotation)
                        }
                    }
                    if strict, components.contains(where: { $0.selection != .still }) {
                        guard let average = rational(stream["avg_frame_rate"]), let nominal = rational(stream["r_frame_rate"]),
                              average == nominal, nominal.seconds <= 1000,
                              let timeBase = rational(stream["time_base"]), timeBase.seconds <= 1 / nominal.seconds else {
                            throw reject("Missing, variable, or invalid source frame rate/time base is not qualified.")
                        }
                        let frameCount = try await verifySourceFrames(url, index: index, rate: nominal, timeBase: timeBase, width: Int(width), height: Int(height), ffprobe: ffprobe)
                        for component in components where component.selection != .still {
                            guard try component.sourceRange.end().compared(to: RationalTime(Int64(frameCount)).divided(by: nominal)) != .orderedDescending else {
                                throw reject("Selected source range exceeds the decoded frame coverage.")
                            }
                        }
                    }
                }
                if !strict, kind == "video", components.contains(where: { $0.selection != .still }),
                   let average = stream["avg_frame_rate"] as? String, let nominal = stream["r_frame_rate"] as? String, average != nominal {
                    try qualify("", warning: "variable frame rate is conformed to the sequence frame rate.")
                }
                if let duration = numeric(stream["duration"]), duration.isFinite {
                    for component in components where component.selection != .still {
                        let end = try component.sourceRange.end().seconds
                        if strict {
                            guard end <= duration + 0.000021 else { throw reject("Selected source range exceeds the probed stream duration.") }
                        } else if end > duration + 0.1 {
                            // Containers often end one stream slightly early; the mix pads silence/holds picture.
                            try qualify("", warning: "selected range extends \(String(format: "%.2f", end - duration)) s past the end of the \(kind) stream; it is padded.")
                        }
                    }
                }
            }
        }
        return (warnings, hdrSources)
    }
    /// Full selected-stream scan, never a sampling claim. Output, elapsed time and frame
    /// count are bounded; larger/slow sources refuse qualification instead of guessing CFR.
    @concurrent private static func verifySourceFrames(_ url: URL, index: Int, rate: RationalTime,
                                                        timeBase: RationalTime, width: Int, height: Int, ffprobe: URL) async throws -> Int {
        let data = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-select_streams", "\(index)",
            "-show_frames", "-show_entries", "frame=best_effort_timestamp,width,height,sample_aspect_ratio,color_transfer,color_primaries:frame_side_data=side_data_type,rotation", "-of", "json", url.path], timeout: 30)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = root["frames"] as? [[String: Any]], !frames.isEmpty, frames.count <= 100000 else {
            throw SequenceExportError.verification("Export source \(url.lastPathComponent): full timestamp qualification is limited to 100000 frames and 2 MB of probe output.")
        }
        let tolerance = try timeBase.divided(by: RationalTime(2))
        let lowerBound = try RationalTime(-tolerance.numerator, tolerance.denominator)
        for (position, frame) in frames.enumerated() {
            if position % 256 == 0 { try Task.checkCancellation() }
            guard let timestamp = frame["best_effort_timestamp"] as? NSNumber, let ticks = Int64(timestamp.stringValue),
                  frame["width"] as? Int == width, frame["height"] as? Int == height else {
                throw SequenceExportError.verification("Export source \(url.lastPathComponent): missing timestamps or changing decoded raster are not qualified.")
            }
            let actual = try timeBase.multiplied(by: ticks)
            let expected = try RationalTime(Int64(position)).divided(by: rate)
            let difference = try actual.subtracting(expected)
            let sar = frame["sample_aspect_ratio"] as? String ?? "1:1"
            let transfer = frame["color_transfer"] as? String ?? "unknown"
            let primaries = frame["color_primaries"] as? String ?? "unknown"
            let sides = frame["side_data_list"] as? [[String: Any]] ?? []
            guard ["1:1", "N/A", "0:1"].contains(sar),
                  !["smpte2084", "arib-std-b67", "bt2020-10", "bt2020-12"].contains(transfer), primaries != "bt2020",
                  sides.allSatisfy({ !["Mastering display metadata", "Content light level metadata", "DOVI configuration record"].contains($0["side_data_type"] as? String ?? "") && (($0["rotation"] as? NSNumber)?.doubleValue ?? 0) == 0 }) else {
                throw SequenceExportError.verification("Export source \(url.lastPathComponent): decoded non-square pixels, rotation, or HDR metadata are not qualified.")
            }
            // Containers may quantize rational CFR timestamps to their time base.
            // The first decoded frame must still start exactly at zero.
            guard (position != 0 || ticks == 0),
                  try difference.compared(to: tolerance) != .orderedDescending,
                  try difference.compared(to: lowerBound) != .orderedAscending else {
                throw SequenceExportError.verification("Export source \(url.lastPathComponent): variable, missing, or offset decoded frame timestamps are not qualified.")
            }
        }
        return frames.count
    }
    nonisolated private static func verify(_ data: Data, plan: TimelineRenderPlan, command: FFmpegRenderCommand,
                                           format: RenderOutputFormat, counted: String) throws {
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
        let checks: [(String, Bool)] = [
            ("video codec", video["codec_name"] as? String == format.videoCodecName),
            ("video profile", video["profile"] as? String == format.videoProfileName),
            ("pixel format", video["pix_fmt"] as? String == format.pixelFormat),
            ("raster", integer(video["width"]) == Int64(plan.settings.width) && integer(video["height"]) == Int64(plan.settings.height)),
            ("frame rate", video["r_frame_rate"] as? String == "\(rate.numerator)/\(rate.denominator)"),
            ("frame count \(integer(video[counted]).map(String.init) ?? "missing") ≠ \(command.videoFrames)", integer(video[counted]) == command.videoFrames),
            ("audio codec", audio["codec_name"] as? String == format.audioCodecName),
            ("audio bit depth", !format.isProRes || integer(audio["bits_per_raw_sample"]) == 24),
            ("audio sample rate", integer(audio["sample_rate"]) == Int64(plan.settings.audioSampleRate)),
            ("audio channels", integer(audio["channels"]) == Int64(plan.settings.audioLayout.channels.count)),
            ("audio sample count \(integer(audio["duration_ts"]).map(String.init) ?? "missing") ≠ \(command.audioSamples)", integer(audio["duration_ts"]) == command.audioSamples),
            ("audio time base", audio["time_base"] as? String == "1/\(plan.settings.audioSampleRate)"),
            ("timecode", (tags?["timecode"] as? String ?? formatTags?["timecode"] as? String) == timecode),
        ]
        let failed = checks.filter { !$0.1 }.map(\.0)
        guard failed.isEmpty else {
            throw SequenceExportError.verification("Rendered \(format.fileExtension.uppercased()) failed verification: \(failed.joined(separator: ", ")).")
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
    @concurrent static func run(executable: URL, arguments: [String], progress: (@Sendable (Double) -> Void)? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        if let timeout, !timeout.isFinite || timeout <= 0 {
            throw SequenceExportError.verification("Probe qualification timeout must be finite and positive.")
        }
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
            let started = Date()
            var cancellationStart: Date?
            var timedOut = false
            while runner.process.isRunning {
                if let timeout, Date().timeIntervalSince(started) >= timeout { timedOut = true }
                if Task.isCancelled || timedOut || runner.didOverflow() {
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
            guard !timedOut else { throw SequenceExportError.verification("Probe exceeded its \(String(format: "%g", timeout ?? 0))-second qualification limit.") }
            guard !runner.overflow else { throw SequenceExportError.verification("Probe output exceeded its 2 MB qualification limit.") }
            guard runner.process.terminationStatus == 0 else {
                throw SequenceExportError.process("Export helper failed (\(runner.process.terminationStatus)): \(String(decoding: runner.stderr, as: UTF8.self))")
            }
            return runner.stdout
        } onCancel: { runner.cancel() }
    }
    private func didOverflow() -> Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    private func remainingReaders() -> Int { lock.lock(); defer { lock.unlock() }; return readers }
}
