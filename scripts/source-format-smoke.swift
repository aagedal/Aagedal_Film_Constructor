import AVFoundation
import EditorCore

@main struct SourceFormatSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["cfr", "cfr24", "cfr23976", "single", "rotated", "vfr", "anamorphic"] {
            let asset = AVURLAsset(url: root.appendingPathComponent("\(name).mp4"))
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let format = try await MediaImporter.qualifiedVideoFormat(asset: asset, track: track)
            if name.hasPrefix("cfr") {
                let rate = try name == "cfr24" ? FrameRate(24) : name == "cfr23976" ? FrameRate(24000, 1001) : FrameRate(30000, 1001)
                guard format == (try VideoSourceFormat(width: 320, height: 180, frameRate: rate)) else {
                    throw NSError(domain: "SourceFormatSmoke", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Exact CFR format missing: \(String(describing: format))"])
                }
            } else if format != nil {
                throw NSError(domain: "SourceFormatSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported \(name) qualified"])
            }
        }
        let cancelled = Task {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: root.appendingPathComponent("cfr.mp4"))
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            return try await MediaImporter.qualifiedVideoFormat(asset: asset, track: track)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw NSError(domain: "SourceFormatSmoke", code: 3)
        } catch is CancellationError {}
        print("Source format smoke passed: 24/24000÷1001/30000÷1001 CFR, single-frame/rotation/VFR/anamorphic refusal, cancellation")
    }
}
