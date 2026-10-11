import Foundation
import Darwin
import EditorCore

enum ProxySmokeFailure: Error { case failed(String) }
@main struct ProxyServiceSmoke {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProxySmokeFailure.failed(message) }
    }
    static func main() async throws {
        Task.detached {
            try? await Task.sleep(for: .seconds(45))
            print("Proxy service smoke timed out after 45 seconds")
            Darwin.exit(1)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        let ffprobe = URL(fileURLWithPath: CommandLine.arguments[3])
        func asset(_ name: String) throws -> MediaAsset {
            .init(name: name, originalURL: directory.appendingPathComponent(name), duration: try RationalTime(1), streams: [.init(index: 0, kind: .video)])
        }
        let source = try asset("source.mov")
        let before = try Data(contentsOf: source.originalURL!)
        let service = ProxyGenerationService(ffmpegURL: ffmpeg, ffprobeURL: ffprobe)
        let prores = directory.appendingPathComponent("prores.mov")
        let proxy = try await service.generate(asset: source, preset: .proResProxy, scaleDivisor: 2, to: prores)
        try check(proxy.width == 80 && proxy.height == 48 && proxy.frameCount == 24 && proxy.frameRate == RationalTime(24000, 1001), "Verified scaled proxy metadata")
        let h264 = try await service.generate(asset: source, preset: .h264, scaleDivisor: 4, to: directory.appendingPathComponent("h264.mov"))
        try check(h264.width == 40 && h264.height == 24 && h264.frameCount == proxy.frameCount, "Verified H264 proxy")
        let recorded = try await ProxyGenerationService.validateProxyFile(proxy)
        try check(recorded == proxy.outputIntegrity, "Generated proxy records verified output bytes")
        let relocated = directory.appendingPathComponent("relocated.mov")
        try FileManager.default.copyItem(at: prores, to: relocated)
        _ = try await ProxyGenerationService.validateProxyFile(proxy, at: relocated)
        let integrityBefore = try ProxyGenerationService.fingerprint(for: relocated)
        let relocatedHandle = try FileHandle(forUpdating: relocated)
        let firstByte = try relocatedHandle.read(upToCount: 1)![0]
        try relocatedHandle.seek(toOffset: 0)
        try relocatedHandle.write(contentsOf: Data([firstByte ^ 1]))
        try relocatedHandle.close()
        // Preserve size and timestamp to prove byte hashing catches metadata-preserving mutation.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: integrityBefore.modificationTime)], ofItemAtPath: relocated.path)
        do {
            _ = try await ProxyGenerationService.validateProxyFile(proxy, at: relocated)
            throw ProxySmokeFailure.failed("Tampered proxy accepted")
        } catch is SequenceExportError { }
        var legacy = proxy; legacy.outputIntegrity = nil
        do {
            _ = try await ProxyGenerationService.validateProxyFile(legacy)
            throw ProxySmokeFailure.failed("Unhashed legacy proxy relink accepted")
        } catch is SequenceExportError { }
        let originalProxy = try Data(contentsOf: prores)
        do {
            _ = try await service.generate(asset: source, preset: .h264, scaleDivisor: 1, to: prores)
            throw ProxySmokeFailure.failed("Existing destination accepted")
        } catch is SequenceExportError { }
        try check(try Data(contentsOf: prores) == originalProxy, "Previous proxy preserved")
        for name in ["vfr.mov", "sar.mov"] {
            let output = directory.appendingPathComponent("rejected-\(name)")
            do {
                _ = try await service.generate(asset: asset(name), preset: .proResProxy, scaleDivisor: 2, to: output)
                throw ProxySmokeFailure.failed("Unsupported source accepted: \(name)")
            } catch is SequenceExportError { }
            try check(!FileManager.default.fileExists(atPath: output.path), "Rejected source never published")
        }
        // A destination created after preflight must survive atomic publication unchanged.
        let raceOutput = directory.appendingPathComponent("raced.mov")
        let raceHelper = directory.appendingPathComponent("race-helper")
        try "#!/bin/bash\nprintf sentinel > '\(raceOutput.path)'\nexec '\(ffmpeg.path)' \"$@\"\n".write(to: raceHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: raceHelper.path)
        do {
            _ = try await ProxyGenerationService(ffmpegURL: raceHelper, ffprobeURL: ffprobe).generate(asset: source, preset: .h264, scaleDivisor: 2, to: raceOutput)
            throw ProxySmokeFailure.failed("Destination publication race overwrote existing data")
        } catch is SequenceExportError { }
        try check(try String(contentsOf: raceOutput, encoding: .utf8) == "sentinel", "Publication race preserves destination")
        // Mutating source metadata during the encode invalidates publication, even when frames decode correctly.
        let mutationHelper = directory.appendingPathComponent("mutation-helper")
        try "#!/bin/bash\n/usr/bin/touch -t 202001010000 '\(source.originalURL!.path)'\nexec '\(ffmpeg.path)' \"$@\"\n".write(to: mutationHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mutationHelper.path)
        let mutatedOutput = directory.appendingPathComponent("mutated.mov")
        do {
            _ = try await ProxyGenerationService(ffmpegURL: mutationHelper, ffprobeURL: ffprobe).generate(asset: source, preset: .h264, scaleDivisor: 2, to: mutatedOutput)
            throw ProxySmokeFailure.failed("Changed source fingerprint accepted")
        } catch is SequenceExportError { }
        try check(!FileManager.default.fileExists(atPath: mutatedOutput.path), "Changed source never publishes")
        let failedService = ProxyGenerationService(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"), ffprobeURL: ffprobe)
        do {
            _ = try await failedService.generate(asset: source, preset: .h264, scaleDivisor: 2, to: directory.appendingPathComponent("failed.mov"))
            throw ProxySmokeFailure.failed("Failed helper accepted")
        } catch is SequenceExportError { }
        let helper = directory.appendingPathComponent("stubborn-helper")
        let pidFile = directory.appendingPathComponent("helper.pid")
        try "#!/bin/bash\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let stubborn = ProxyGenerationService(ffmpegURL: helper, ffprobeURL: ffprobe)
        let cancelled = directory.appendingPathComponent("cancelled.mov")
        let task = Task { try await stubborn.generate(asset: source, preset: .h264, scaleDivisor: 2, to: cancelled) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProxySmokeFailure.failed("Missing helper PID") }
        task.cancel()
        do { _ = try await task.value; throw ProxySmokeFailure.failed("Cancelled generation published") } catch is CancellationError { }
        try check(Darwin.kill(pid, 0) != 0 && errno == ESRCH, "Cancellation reaped helper")
        try check(!FileManager.default.fileExists(atPath: cancelled.path), "Cancellation never publishes")
        try check(try Data(contentsOf: source.originalURL!) == before, "Original bytes preserved")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".afc-proxy-") }
        try check(leftovers.isEmpty, "Private staging cleaned")
        print("Proxy service smoke passed: ProRes/H264, output SHA256, relocated/tampered proxy, legacy rejection, rational CFR, VFR/SAR rejection, no overwrite, failure, cancellation, originals preserved")
    }
}
