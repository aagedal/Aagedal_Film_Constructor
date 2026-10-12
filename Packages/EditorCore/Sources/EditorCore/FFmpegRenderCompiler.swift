import Foundation

/// A container stream used by one filter input, independent of backend track IDs.
public struct RenderSourceInput: Equatable, Codable, Sendable {
    public let url: URL
    public let streamIndex: Int
    public let kind: MediaStreamKind
}

/// Development MOV/ProRes command. Callers manage helper access, cancellation and
/// output registration. No helper discovery or process launch occurs here.
public struct FFmpegRenderCommand: Equatable, Codable, Sendable {
    /// One entry per -i argument, in FFmpeg input-index order.
    public let inputs: [RenderSourceInput]
    public let arguments: [String]
    public let filterGraph: String
    public let videoFrames: Int64
    public let audioSamples: Int64
}

public enum FFmpegRenderCompiler {
    /// Source qualification must be performed by the caller: the canonical plan
    /// does not carry pixel aspect, rotation, color or variable-frame-rate metadata.
    public static let qualificationLimitations = "Development export requires square-pixel SDR sources without rotation; color management and VFR mappings are not qualified. Video source checks scan the full stream and refuse sources exceeding 30 seconds of checking, 2 MB of probe output, or 100,000 frames. Nonzero stream offsets are unsupported. PNG/JPEG stills use only the first decoded frame."

    /// Explicit prototype subset: frame-aligned video/stills, sample-aligned audio,
    /// zero stream offsets, mono/stereo output, originals.
    /// Video is conformed on the sequence grid with FFmpeg fps round=near before trim.
    /// Source geometry/color metadata and VFR mappings are not yet qualified.
    public static func compile(_ plan: TimelineRenderPlan, outputURL: URL) throws -> FFmpegRenderCommand {
        try plan.settings.validate()
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "mov" else {
            throw EditorCoreError.invalidModel("Prototype export requires a local MOV destination")
        }
        let settings = plan.settings
        guard settings.width % 2 == 0, settings.height % 2 == 0,
              settings.audioLayout == .mono || settings.audioLayout == .stereo else {
            throw EditorCoreError.invalidModel("Prototype requires even raster dimensions and mono/stereo output")
        }
        // Sample-aligned audio may end between video frames. Cover the full sequence
        // with a final black/video frame, retaining the exact audio duration.
        let frames = try ceiling(plan.duration.multiplied(by: settings.frameRate.value))
        guard frames > 0 else { throw EditorCoreError.invalidModel("Cannot render an empty sequence") }
        let sampleTime = try plan.duration.multiplied(by: Int64(settings.audioSampleRate))
        let samples = try ceiling(sampleTime)
        let rate = fraction(settings.frameRate.value)
        let layout = settings.audioLayout == .mono ? "mono" : "stereo"
        var arguments = ["-hide_banner", "-nostdin", "-n"]
        var graph = ["color=c=black:s=\(settings.width)x\(settings.height):r=\(rate),trim=end_frame=\(frames),setpts=PTS-STARTPTS,format=yuv444p[base]",
                     "anullsrc=r=\(settings.audioSampleRate):cl=\(layout),atrim=end_sample=\(samples)[silence]"]
        var inputs: [RenderSourceInput] = []
        var inputIndex = 0
        var videoLabel = "base"
        var audioLabels = ["silence"]
        // Composite back to front: track zero is frontmost in the canonical plan.
        let components = plan.components.sorted {
            if $0.layerOrder != $1.layerOrder { return $0.layerOrder > $1.layerOrder }
            return $0.clipID.uuidString < $1.clipID.uuidString
        }
        for (index, component) in components.enumerated() {
            guard let url = component.originalURL, url.isFileURL, !aliases(url, outputURL) else {
                throw EditorCoreError.invalidModel("Missing original or output aliases a source")
            }
            try component.sourceRange.validate(); try component.timelineRange.validate()
            try component.fadeIn.validate(duration: component.sourceRange.duration)
            try component.fadeOut.validate(duration: component.sourceRange.duration)
            guard component.sourceRange.duration == component.timelineRange.duration,
                  try component.timelineRange.end().compared(to: plan.duration) != .orderedDescending,
                  component.gain.isFinite, component.gain >= 0 else {
                throw EditorCoreError.invalidModel("Invalid render component")
            }
            func input(_ stream: Int, kind: MediaStreamKind) throws -> String {
                guard let source = component.sourceStreams.first(where: { $0.index == stream && $0.kind == kind }), source.timeOffset == .zero else {
                    throw EditorCoreError.invalidModel("Missing stream or unsupported nonzero stream offset")
                }
                inputs.append(RenderSourceInput(url: url, streamIndex: stream, kind: kind))
                arguments += ["-i", url.path]
                defer { inputIndex += 1 }
                return "[\(inputIndex):\(stream)]"
            }
            switch component.selection {
            case .still, .video:
                guard component.fadeIn.duration == .zero && component.fadeOut.duration == .zero else {
                    throw EditorCoreError.invalidModel("Only audio clips support fades")
                }
                let isStill = component.selection == .still
                let start = isStill ? 0 : try integral(component.sourceRange.start.multiplied(by: settings.frameRate.value), "Visual source in must align to sequence frames")
                let count = try integral(component.sourceRange.duration.multiplied(by: settings.frameRate.value), "Video duration must align to sequence frames")
                let placement = try integral(component.timelineRange.start.multiplied(by: settings.frameRate.value), "Video placement must align to frames")
                let end = try RationalTime(start).adding(RationalTime(count)).numerator
                let scaling: String
                let w = settings.width, h = settings.height
                switch component.scalingMode {
                case .fit: scaling = "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2\(isStill ? ":color=black@0" : "")"
                case .fill: scaling = "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)"
                case .none: scaling = "pad='max(iw,\(w))':'max(ih,\(h))':(ow-iw)/2:(oh-ih)/2\(isStill ? ":color=black@0" : ""),crop=\(w):\(h)"
                }
                let source: String
                let timing: String
                if isStill {
                    guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
                          component.sourceStreams.isEmpty || (component.sourceStreams.count == 1 && component.sourceStreams[0].kind == .video) else {
                        throw EditorCoreError.invalidModel("Still export requires a PNG/JPEG original with an unambiguous image stream")
                    }
                    if let stream = component.sourceStreams.first {
                        source = try input(stream.index, kind: .video)
                    } else {
                        // Imported images have synthetic duration and no probed streams.
                        inputs.append(RenderSourceInput(url: url, streamIndex: 0, kind: .video))
                        arguments += ["-i", url.path]
                        source = "[\(inputIndex):0]"
                        inputIndex += 1
                    }
                    // Finite frame cloning avoids infinite input loops and preserves alpha.
                    timing = "trim=end_frame=1,loop=loop=\(count - 1):size=1:start=0,settb=expr=\(settings.frameRate.value.denominator)/\(settings.frameRate.value.numerator),setpts=N+\(placement)"
                } else {
                    guard case .video(let stream) = component.selection else { throw EditorCoreError.invalidModel("Invalid visual selection") }
                    source = try input(stream, kind: .video)
                    timing = "setpts=PTS-STARTPTS,fps=\(rate):round=near,trim=start_frame=\(start):end_frame=\(end),setpts=PTS-STARTPTS+\(placement)"
                }
                let geometry = isStill ? "format=yuva444p,\(scaling),setsar=1" : "\(scaling),setsar=1,format=yuv444p"
                graph.append("\(source)\(timing),\(geometry)[v\(index)]")
                // Explicit half-open visibility also prevents framesync holding a layer past its cut.
                let visibleEnd = try RationalTime(placement).adding(RationalTime(count)).numerator
                let enabled = "gte(n,\(placement))*lt(n,\(visibleEnd))"
                graph.append("[\(videoLabel)][v\(index)]overlay=eof_action=repeat:repeatlast=1:format=yuv444:enable='\(enabled)'[layer\(index)]")
                videoLabel = "layer\(index)"
            case .audio(let selection):
                try selection.layout.validate()
                guard selection.channels.count == selection.layout.channels.count else { throw EditorCoreError.invalidModel("Incomplete audio selection") }
                let routing = component.routing.outputChannels.isEmpty ? Array(selection.channels.indices) : component.routing.outputChannels
                guard routing.count == selection.channels.count, routing.allSatisfy({ settings.audioLayout.channels.indices.contains($0) }),
                      !component.routing.outputChannels.isEmpty || selection.layout == settings.audioLayout else {
                    throw EditorCoreError.invalidModel("Invalid audio output map")
                }
                let start = try integral(component.sourceRange.start.multiplied(by: Int64(settings.audioSampleRate)), "Audio in must align to samples")
                let end = try integral(component.sourceRange.end().multiplied(by: Int64(settings.audioSampleRate)), "Audio out must align to samples")
                let delay = try integral(component.timelineRange.start.multiplied(by: Int64(settings.audioSampleRate)), "Audio placement must align to samples")
                let envelope = try audioEnvelope(component, sampleCount: end - start, sampleRate: settings.audioSampleRate, layout: layout)
                for (channel, sourceChannel) in selection.channels.enumerated() {
                    guard let stream = component.sourceStreams.first(where: { $0.index == sourceChannel.streamIndex }), let sourceLayout = stream.audioLayout,
                          sourceLayout.channels.indices.contains(sourceChannel.channelIndex) else { throw EditorCoreError.invalidModel("Invalid source channel") }
                    let source = try input(sourceChannel.streamIndex, kind: .audio)
                    let map = settings.audioLayout.channels.indices.map { "c\($0)=\($0 == routing[channel] ? "c\(sourceChannel.channelIndex)" : "0*c\(sourceChannel.channelIndex)")" }.joined(separator: "|")
                    let label = "a\(index)c\(channel)"
                    graph.append("\(source)aresample=\(settings.audioSampleRate),atrim=start_sample=\(start):end_sample=\(end),asetpts=PTS-STARTPTS,pan=\(layout)|\(map),aformat=sample_fmts=flt,volume=\(component.gain):precision=float\(envelope),adelay=\(delay)S:all=1[\(label)]")
                    audioLabels.append(label)
                }
            }
        }
        graph.append("[\(videoLabel)]trim=end_frame=\(frames)[video]")
        graph.append(audioLabels.map { "[\($0)]" }.joined() + "amix=inputs=\(audioLabels.count):normalize=0,atrim=end_sample=\(samples)[audio]")
        let filterGraph = graph.joined(separator: ";")
        arguments += ["-filter_complex", filterGraph, "-map", "[video]", "-map", "[audio]", "-r", rate, "-fps_mode", "cfr", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le", "-ar", String(settings.audioSampleRate), "-ac", String(settings.audioLayout.channels.count), "-video_track_timescale", String(settings.frameRate.value.numerator), "-timecode", try settings.startTimecode.formatted(rate: settings.frameRate), outputURL.path]
        return FFmpegRenderCommand(inputs: inputs, arguments: arguments, filterGraph: filterGraph, videoFrames: frames, audioSamples: samples)
    }
    /// aeval's n begins at zero after trim, before timeline delay. The rational
    /// denominators retain sub-sample fade durations without rounding either edge.
    private static func audioEnvelope(_ component: TimelineRenderPlan.Component, sampleCount: Int64,
                                      sampleRate: Int, layout: String) throws -> String {
        func edge(_ fade: AudioFade, position: String) throws -> String? {
            guard fade.duration != .zero else { return nil }
            let samples = try fade.duration.multiplied(by: Int64(sampleRate))
            let progress = "min(1,max(0,(\(position))*\(samples.denominator)/\(samples.numerator)))"
            switch fade.curve {
            case .linear: return progress
            case .equalPower: return "sin(PI/2*(\(progress)))"
            }
        }
        let edges = try [edge(component.fadeIn, position: "n"),
                         edge(component.fadeOut, position: "\(sampleCount)-n")].compactMap { $0 }
        guard !edges.isEmpty else { return "" }
        let expression = edges.joined(separator: "*")
        let channels = layout == "mono" ? 1 : 2
        let values = (0..<channels).map { "val(\($0))*(\(expression))" }.joined(separator: "|")
        return ",aeval=exprs='\(values)':channel_layout=\(layout)"
    }
    private static func ceiling(_ time: RationalTime) throws -> Int64 {
        guard time.numerator >= 0 else { throw EditorCoreError.invalidModel("Negative render duration") }
        let whole = time.numerator / time.denominator
        let (result, overflow) = whole.addingReportingOverflow(time.numerator % time.denominator == 0 ? 0 : 1)
        guard !overflow else { throw EditorCoreError.invalidModel("Render duration overflow") }
        return result
    }
    private static func aliases(_ source: URL, _ output: URL) -> Bool {
        if source.standardizedFileURL.resolvingSymlinksInPath() == output.standardizedFileURL.resolvingSymlinksInPath() { return true }
        // Existing hard links also identify the same original. Missing destinations
        // are expected and are compared by their normalized, resolved path above.
        guard let a = try? FileManager.default.attributesOfItem(atPath: source.path),
              let b = try? FileManager.default.attributesOfItem(atPath: output.path),
              let aFile = a[.systemFileNumber] as? NSNumber, let bFile = b[.systemFileNumber] as? NSNumber,
              let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber else { return false }
        return aFile == bFile && aDevice == bDevice
    }
    private static func fraction(_ time: RationalTime) -> String { "\(time.numerator)/\(time.denominator)" }
    private static func integral(_ time: RationalTime, _ message: String) throws -> Int64 {
        guard time.denominator == 1, time.numerator >= 0 else { throw EditorCoreError.invalidModel(message) }
        return time.numerator
    }
}
