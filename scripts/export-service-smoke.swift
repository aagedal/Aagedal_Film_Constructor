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
        func videoProject(_ name: String) throws -> Project {
            let asset = MediaAsset(name: name, originalURL: directory.appendingPathComponent(name), duration: try RationalTime(1), streams: [MediaStream(index: 0, kind: .video)])
            let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1)), selection: .video(streamIndex: 0))
            return Project(settings: project.settings, assets: [asset], families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [clip])])
        }
        let cfr = try videoProject("cfr.mov")
        let cfrResult = try await service.export(plan: TimelineRenderPlan(project: cfr), to: directory.appendingPathComponent("cfr-output.mov"))
        try check(cfrResult.videoFrames == 24, "CFR source at different raster remains qualified")
        let fractionalResult = try await service.export(plan: TimelineRenderPlan(project: videoProject("fractional-cfr.mov")), to: directory.appendingPathComponent("fractional-output.mov"))
        try check(fractionalResult.videoFrames == 24, "Mixed fractional CFR source rate remains qualified")
        let vfrProbe = try await ExportProcess.run(executable: ffprobe, arguments: ["-v", "error", "-show_streams", "-of", "json", directory.appendingPathComponent("equal-rate-vfr.mov").path])
        let vfrRoot = try JSONSerialization.jsonObject(with: vfrProbe) as! [String: Any]
        let vfrStream = (vfrRoot["streams"] as! [[String: Any]])[0]
        try check(vfrStream["avg_frame_rate"] as? String == "24/1" && vfrStream["r_frame_rate"] as? String == "24/1", "VFR fixture must defeat metadata-only checks")
        for name in ["equal-rate-vfr.mov", "offset.mov"] {
            let destination = directory.appendingPathComponent("rejected-" + name)
            do {
                _ = try await service.export(plan: TimelineRenderPlan(project: videoProject(name)), to: destination)
                throw ExportSmokeFailure.failed("Irregular/offset source accepted: " + name)
            } catch let error as SequenceExportError {
                try check(error.localizedDescription.contains("timestamp") || error.localizedDescription.contains("offset"), "Timestamp qualification refusal: " + error.localizedDescription)
            }
            try check(!FileManager.default.fileExists(atPath: destination.path), "Unqualified timestamp source never publishes")
        }
        var resampled = project
        resampled.assets[0].originalURL = directory.appendingPathComponent("resample.wav")
        let resampleResult = try await service.export(plan: TimelineRenderPlan(project: resampled), to: directory.appendingPathComponent("resample-output.mov"))
        try check(resampleResult.audioSamples == 480000, "Different source sample rate remains qualified for explicit resampling")
        // Corrupt only reported metadata around a real FFprobe. The decoded raster
        // still comes from the original, exercising stale probe contract rejection.
        let alteredProbe = directory.appendingPathComponent("altered-probe")
        let probeScript = """
        #!/usr/bin/python3
        import json, subprocess, sys
        result = subprocess.run([\(String(reflecting: ffprobe.path))] + sys.argv[1:], capture_output=True)
        if result.returncode:
            sys.stderr.buffer.write(result.stderr)
            sys.exit(result.returncode)
        data = json.loads(result.stdout)
        if '-show_streams' in sys.argv:
            for stream in data['streams']:
                if stream['codec_type'] == 'video': stream['width'] += 1
                if stream['codec_type'] == 'audio': stream['sample_rate'] = '0'
        print(json.dumps(data))
        """
        try probeScript.write(to: alteredProbe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: alteredProbe.path)
        let alteredService = SequenceExportService(ffmpegURL: ffmpeg, ffprobeURL: alteredProbe)
        for (source, name, expected) in [(cfr, "stale-raster.mov", "raster"), (project, "invalid-rate.mov", "sample rate")] {
            let destination = directory.appendingPathComponent(name)
            do {
                _ = try await alteredService.export(plan: TimelineRenderPlan(project: source), to: destination)
                throw ExportSmokeFailure.failed("Invalid raster/rate metadata accepted")
            } catch let error as SequenceExportError {
                try check(error.localizedDescription.contains(expected), "Raster/rate qualification refusal: " + error.localizedDescription)
            }
            try check(!FileManager.default.fileExists(atPath: destination.path), "Invalid raster/rate never publishes")
        }
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
        let overflowStart = Date()
        do {
            _ = try await ExportProcess.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 5)
            throw ExportSmokeFailure.failed("Unbounded probe output accepted")
        } catch let error as SequenceExportError {
            try check(error.localizedDescription.contains("2 MB"), "Probe output overflow refuses qualification")
        }
        try check(Date().timeIntervalSince(overflowStart) < 5, "Overflow terminates the producer promptly")
        let timeoutStart = Date()
        do {
            _ = try await ExportProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1)
            throw ExportSmokeFailure.failed("Probe timeout accepted")
        } catch let error as SequenceExportError {
            try check(error.localizedDescription.contains("qualification limit"), "Slow probe refuses qualification")
        }
        try check(Date().timeIntervalSince(timeoutStart) < 5, "Probe timeout terminates and reaps promptly")
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
        print("Export service smoke passed: verified MOV, protected destination, actual CFR/VFR/offset and raster/rate qualification, resampling, bounded diagnostics, helper failures, cancellation cleanup with no orphan")
    }
}
