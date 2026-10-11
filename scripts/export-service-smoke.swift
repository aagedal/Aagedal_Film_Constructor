import Foundation
import Darwin
import EditorCore

enum ExportSmokeFailure: Error { case failed(String) }
@main struct ExportServiceSmoke {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ExportSmokeFailure.failed(message) }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        let ffprobe = URL(fileURLWithPath: CommandLine.arguments[3])
        var project = try DemoProjectFactory.musicCollision()
        project.settings = try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(24), startTimecode: .init(frameCount: 24 * 3600))
        project.assets[0].originalURL = directory.appendingPathComponent("source.wav")
        let plan = try TimelineRenderPlan(project: project)
        let service = SequenceExportService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe)
        let output = directory.appendingPathComponent("output.mov")
        let result = try await service.export(plan: plan, to: output)
        try check(result.videoFrames == 240 && result.audioSamples == 480000, "Verified export counts")
        let original = try Data(contentsOf: output)
        do {
            _ = try await service.export(plan: plan, to: output)
            throw ExportSmokeFailure.failed("Existing destination accepted")
        } catch is SequenceExportError { }
        try check(try Data(contentsOf: output) == original, "Existing output preserved")
        let missing = SequenceExportService(ffmpegURL: directory.appendingPathComponent("missing"), ffprobeURL: ffprobe)
        do {
            _ = try await missing.export(plan: plan, to: directory.appendingPathComponent("missing.mov"))
            throw ExportSmokeFailure.failed("Missing helper accepted")
        } catch is SequenceExportError { }
        let geometryURL = directory.appendingPathComponent("anamorphic.mov")
        var mismatched = project
        mismatched.assets[0].originalURL = geometryURL
        do {
            _ = try await service.export(plan: TimelineRenderPlan(project: mismatched), to: directory.appendingPathComponent("mismatched.mov"))
            throw ExportSmokeFailure.failed("Mismatched source stream kind accepted")
        } catch is SequenceExportError { }
        let template = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Video", template: template)
        let asset = MediaAsset(name: "Anamorphic", originalURL: geometryURL, duration: try RationalTime(1), streams: [MediaStream(index: 0, kind: .video)])
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), selection: .video(streamIndex: 0))
        let geometryProject = Project(settings: project.settings, assets: [asset], families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
        do {
            _ = try await service.export(plan: TimelineRenderPlan(project: geometryProject), to: directory.appendingPathComponent("geometry.mov"))
            throw ExportSmokeFailure.failed("Unsupported source pixel geometry accepted")
        } catch is SequenceExportError { }
        let cancelled = directory.appendingPathComponent("cancelled.mov")
        let task = Task { try await service.export(plan: plan, to: cancelled) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            throw ExportSmokeFailure.failed("Cancelled export succeeded")
        } catch is CancellationError { }
        try check(!FileManager.default.fileExists(atPath: cancelled.path), "Cancellation never publishes")
        let failedService = SequenceExportService(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"), ffprobeURL: ffprobe)
        do {
            _ = try await failedService.export(plan: plan, to: directory.appendingPathComponent("failed.mov"))
            throw ExportSmokeFailure.failed("Failed helper accepted")
        } catch is SequenceExportError { }
        let noisyHelper = directory.appendingPathComponent("noisy-helper")
        try "#!/bin/bash\n/bin/dd if=/dev/zero bs=8192 count=16 >&2 2>/dev/null\nexit 1\n".write(to: noisyHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noisyHelper.path)
        let noisyService = SequenceExportService(ffmpegURL: noisyHelper, ffprobeURL: ffprobe)
        do {
            _ = try await noisyService.export(plan: plan, to: directory.appendingPathComponent("noisy.mov"))
            throw ExportSmokeFailure.failed("Noisy failed helper succeeded")
        } catch let error as SequenceExportError {
            try check(error.localizedDescription.utf8.count <= 33000, "Helper diagnostics bounded without pipe deadlock")
        }
        let invalidProbeService = SequenceExportService(ffmpegURL: ffmpeg, ffprobeURL: URL(fileURLWithPath: "/usr/bin/true"))
        let unverified = directory.appendingPathComponent("unverified.mov")
        do {
            _ = try await invalidProbeService.export(plan: plan, to: unverified)
            throw ExportSmokeFailure.failed("Malformed verification accepted")
        } catch let error as ExportSmokeFailure { throw error } catch { }
        try check(!FileManager.default.fileExists(atPath: unverified.path), "Failed verification never publishes")
        let stubbornHelper = directory.appendingPathComponent("stubborn-helper")
        let pidFile = directory.appendingPathComponent("helper.pid")
        try "#!/bin/bash\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: stubbornHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stubbornHelper.path)
        let stubborn = SequenceExportService(ffmpegURL: stubbornHelper, ffprobeURL: ffprobe)
        let stubbornOutput = directory.appendingPathComponent("stubborn.mov")
        let stubbornTask = Task { try await stubborn.export(plan: plan, to: stubbornOutput) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(pidText) else { throw ExportSmokeFailure.failed("Missing helper PID") }
        let cancellationStart = Date()
        stubbornTask.cancel()
        do {
            _ = try await stubbornTask.value
            throw ExportSmokeFailure.failed("Stubborn cancelled helper succeeded")
        } catch is CancellationError { }
        try check(Date().timeIntervalSince(cancellationStart) < 5, "Cancellation kills an unresponsive helper promptly")
        try check(Darwin.kill(pid, 0) != 0 && errno == ESRCH, "Cancelled helper reaped with no orphan")
        try check(!FileManager.default.fileExists(atPath: stubbornOutput.path), "Stubborn cancellation never publishes")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(!names.contains { $0.hasPrefix(".afc-export-") }, "All staging files removed")
        print("Export service smoke passed: verified MOV, protected destination, source qualification, bounded diagnostics, helper failures, cancellation cleanup with no orphan")
    }
}
