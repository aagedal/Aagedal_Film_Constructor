import Foundation

/// Track IDs must come from MPV's loaded track-list, matched by file and ff-index.
/// Container stream indices are deliberately never treated as MPV track IDs.
public struct MPVTrackBinding: Equatable, Sendable {
    public let source: RenderSourceInput
    public let trackID: Int
    public init(url: URL, streamIndex: Int, kind: MediaStreamKind, trackID: Int) {
        source = RenderSourceInput(url: url, streamIndex: streamIndex, kind: kind)
        self.trackID = trackID
    }
}

public struct MPVRenderGraph: Equatable, Codable, Sendable {
    public let filterGraph: String
    public let videoFrames: Int64
    public let audioSamples: Int64
}

/// Experimental adapter for testing the exact export filters in lavfi-complex.
/// This does not establish seeking suitability: MPV may reset filter state on seek.
public enum MPVRenderCompiler {
    public static func compile(_ plan: TimelineRenderPlan, bindings: [MPVTrackBinding]) throws -> MPVRenderGraph {
        // The destination is only used to validate the export subset; no file is created.
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: URL(fileURLWithPath: "/__editor_mpv_graph__.mov"))
        var labels: [String] = []
        var used: [(binding: MPVTrackBinding, indices: [Int])] = []
        for (index, source) in command.inputs.enumerated() {
            let matches = bindings.filter { $0.source == source }
            guard matches.count == 1, let binding = matches.first, binding.trackID > 0 else {
                throw EditorCoreError.invalidModel("Missing or ambiguous MPV source track binding")
            }
            let label = "\(source.kind == .video ? "vid" : "aid")\(binding.trackID)"
            if let entry = used.firstIndex(where: { $0.binding == binding }) {
                used[entry].indices.append(index)
            } else {
                guard !labels.contains(label) else {
                    throw EditorCoreError.invalidModel("MPV track ID aliases different source streams")
                }
                labels.append(label)
                used.append((binding, [index]))
            }
        }
        var graph = command.filterGraph
        var splits: [String] = []
        for (entry, label) in zip(used, labels) {
            let repeated = entry.indices.count > 1
            for index in entry.indices {
                let replacement = repeated ? "mpvinput\(index)" : label
                graph = graph.replacingOccurrences(of: "[\(index):\(entry.binding.source.streamIndex)]", with: "[\(replacement)]")
            }
            if repeated {
                let filter = entry.binding.source.kind == .video ? "split" : "asplit"
                splits.append("[\(label)]\(filter)=\(entry.indices.count)" + entry.indices.map { "[mpvinput\($0)]" }.joined())
            }
        }
        graph = graph.replacingOccurrences(of: "[video]", with: "[vo]")
            .replacingOccurrences(of: "[audio]", with: "[ao]")
        return MPVRenderGraph(filterGraph: (splits + [graph]).joined(separator: ";"), videoFrames: command.videoFrames, audioSamples: command.audioSamples)
    }
}
