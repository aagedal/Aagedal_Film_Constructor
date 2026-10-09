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
    /// Explicit prototype subset: frame-aligned video, sample-aligned audio,
    /// zero stream offsets, square-pixel SDR sources, mono/stereo output, originals.
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
        let frames = try integral(plan.duration.multiplied(by: settings.frameRate.value), "Sequence duration must align to frames")
        guard frames > 0 else { throw EditorCoreError.invalidModel("Cannot render an empty sequence") }
        let sampleTime = try plan.duration.multiplied(by: Int64(settings.audioSampleRate))
        let samples = sampleTime.numerator / sampleTime.denominator + (sampleTime.numerator % sampleTime.denominator == 0 ? 0 : 1)
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
            guard let url = component.originalURL, url.isFileURL, url != outputURL else {
                throw EditorCoreError.invalidModel("Missing original or output aliases a source")
            }
            try component.sourceRange.validate(); try component.timelineRange.validate()
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
            case .still:
                throw EditorCoreError.invalidModel("Still-image export is not qualified by this prototype")
            case .video(let stream):
                let start = try integral(component.sourceRange.start.multiplied(by: settings.frameRate.value), "Video source in must align to sequence frames")
                let count = try integral(component.sourceRange.duration.multiplied(by: settings.frameRate.value), "Video duration must align to sequence frames")
                let placement = try integral(component.timelineRange.start.multiplied(by: settings.frameRate.value), "Video placement must align to frames")
                let end = try RationalTime(start).adding(RationalTime(count)).numerator
                let scaling: String
                let w = settings.width, h = settings.height
                switch component.scalingMode {
                case .fit: scaling = "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2"
                case .fill: scaling = "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)"
                case .none: scaling = "pad='max(iw,\(w))':'max(ih,\(h))':(ow-iw)/2:(oh-ih)/2,crop=\(w):\(h)"
                }
                let source = try input(stream, kind: .video)
                graph.append("\(source)setpts=PTS-STARTPTS,fps=\(rate):round=near,trim=start_frame=\(start):end_frame=\(end),setpts=PTS-STARTPTS+\(placement),\(scaling),setsar=1,format=yuv444p[v\(index)]")
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
                for (channel, sourceChannel) in selection.channels.enumerated() {
                    guard let stream = component.sourceStreams.first(where: { $0.index == sourceChannel.streamIndex }), let sourceLayout = stream.audioLayout,
                          sourceLayout.channels.indices.contains(sourceChannel.channelIndex) else { throw EditorCoreError.invalidModel("Invalid source channel") }
                    let source = try input(sourceChannel.streamIndex, kind: .audio)
                    let map = settings.audioLayout.channels.indices.map { "c\($0)=\($0 == routing[channel] ? "c\(sourceChannel.channelIndex)" : "0*c\(sourceChannel.channelIndex)")" }.joined(separator: "|")
                    let label = "a\(index)c\(channel)"
                    graph.append("\(source)aresample=\(settings.audioSampleRate),atrim=start_sample=\(start):end_sample=\(end),asetpts=PTS-STARTPTS,pan=\(layout)|\(map),volume=\(component.gain),adelay=\(delay)S:all=1[\(label)]")
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
    private static func fraction(_ time: RationalTime) -> String { "\(time.numerator)/\(time.denominator)" }
    private static func integral(_ time: RationalTime, _ message: String) throws -> Int64 {
        guard time.denominator == 1, time.numerator >= 0 else { throw EditorCoreError.invalidModel(message) }
        return time.numerator
    }
}
