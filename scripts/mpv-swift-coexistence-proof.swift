import Foundation
import EditorCore
import NativePlaybackRuntime

struct NativeRow: Sendable {
    let file: String
    let sourceFrame: Int64
    let completed: Double
    var json: [String: Any] { ["file": file, "sourceFrame": sourceFrame, "completed": completed] }
}

func project(_ path: String, offset: Int64) throws -> Project {
    let rate = try FrameRate(24)
    let settings = try SequenceSettings(width: 320, height: 180, frameRate: rate,
                                       audioSampleRate: 48000, audioLayout: .mono)
    let asset = MediaAsset(name: "Source", originalURL: URL(fileURLWithPath: path),
        duration: try rate.time(forFrames: 72), streams: [
            .init(index: 0, kind: .video), .init(index: 2, kind: .audio, audioLayout: .mono)])
    let range = try TimeRange(start: rate.time(forFrames: offset), duration: rate.time(forFrames: 60))
    let picture = TrackTemplate(kind: .video)
    let sound = TrackTemplate(kind: .audio, audioLayout: .mono)
    let videoFamily = TrackFamily(baseName: "Picture", template: picture)
    let audioFamily = TrackFamily(baseName: "Sound", template: sound)
    return Project(settings: settings, assets: [asset], families: [videoFamily, audioFamily], tracks: [
        .init(familyID: videoFamily.id, template: picture, clips: [
            .init(assetID: asset.id, sourceRange: range, selection: .video(streamIndex: 0))]),
        .init(familyID: audioFamily.id, template: sound, clips: [
            .init(assetID: asset.id, sourceRange: range, selection: .audio(.init(
                channels: [.init(streamIndex: 2, channelIndex: 0)], layout: .mono)))])])
}

@main
struct CoexistenceProof {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("expected source, output, native-only|concurrent") }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        let concurrent = args[3] == "concurrent"
        var report: [String: Any] = ["passed": false]
        var native: [NativeRow] = []
        var captures: [[String: Any]] = [], windows: [[String: Any]] = []
        var session: NativePlaybackSession?
        do {
            let monitor = try NativePlaybackSession(project: project(args[1], offset: 0), maximumCacheBytes: 0)
            session = monitor
            var previousEpoch: UUID?
            for cycle in 0..<12 {
                let offset: Int64 = cycle % 2 == 0 ? 0 : 6
                let client = concurrent ? try Client() : nil
                if let client { _ = try await client.open(args[1], video: 0, audio: 2) }
                try await monitor.replace(project: project(args[1], offset: offset))
                if let previousEpoch, await monitor.accepts(previousEpoch) {
                    throw ProofFailure("edited plan accepted old epoch")
                }
                let start = ProcessInfo.processInfo.systemUptime
                // This task exercises the public Swift actor and its serial decode
                // worker while the main actor polls MPV; no C decoder shortcut.
                let decoding = Task { @MainActor in
                    var rows: [NativeRow] = []
                    for index in 0..<10 {
                        let frame: Int64 = [0, 36, 6, 48, 12][index % 5]
                        await monitor.invalidate()
                        let picture = try await monitor.video(frame: frame)
                        let sound = try await monitor.audio(start: frame * 2000, count: 1024)
                        guard await monitor.accepts(picture.epoch), await monitor.accepts(sound.epoch) else {
                            throw ProofFailure("stale native result")
                        }
                        let stem = "native-\(cycle)-\(index)"
                        try picture.value.write(to: output.appendingPathComponent(stem + ".rgb"))
                        try sound.value.withUnsafeBytes { try Data($0).write(to: output.appendingPathComponent(stem + ".f32")) }
                        rows.append(NativeRow(file: stem, sourceFrame: frame + offset,
                                              completed: ProcessInfo.processInfo.systemUptime))
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    return rows
                }
                do {
                    if let client {
                        defer { try? client.close() }
                        try await client.paused(false)
                        let observed = client.events.count
                        try await client.wait(from: observed) { _ in client.position().map { $0 > 0.05 } == true }
                        try await client.paused(true)
                        try await client.rapid()
                        for target in [0.0, 1.5, 0.25, 2.0, 0.5] {
                            try await client.seek(target)
                            let name = "mpv-\(cycle)-\(Int(target * 24)).rgb"
                            _ = try client.capture(output.appendingPathComponent(name))
                            captures.append(["file": name, "target": target, "position": client.position()!])
                        }
                        // Retain the source-command window before awaiting the
                        // native task, so overlap cannot be manufactured by it.
                        windows.append(["start": start, "end": ProcessInfo.processInfo.systemUptime])
                        native += try await decoding.value
                    } else { native += try await decoding.value }
                } catch {
                    decoding.cancel()
                    _ = await decoding.result
                    throw error
                }
                previousEpoch = await monitor.epoch
                let stats = await monitor.statistics()
                guard stats.pendingRequests == 0, stats.cachedBytes == 0 else { throw ProofFailure("native work retained") }
            }
            await monitor.close()
            await monitor.close()
            do {
                _ = try await monitor.video(frame: 0)
                throw ProofFailure("closed native session admitted decode")
            } catch PlaybackSessionError.closed {}
            report = ["passed": true, "cycles": 12, "replacements": 12, "oldEpochRejections": 11,
                      "native": native.map(\.json), "captures": captures, "windows": windows,
                      "closedAdmissionRejected": true]
        } catch { report["error"] = String(describing: error) }
        if let session { await session.close() }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"))
        } catch { fatalError("report write: \(error)") }
        if report["passed"] as? Bool != true { print(report["error"] ?? "failed"); exit(1) }
    }
}
