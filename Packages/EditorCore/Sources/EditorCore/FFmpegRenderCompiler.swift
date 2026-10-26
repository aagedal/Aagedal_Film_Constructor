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

/// Rendered delivery formats. ProRes keeps PCM audio in MOV; delivery formats use
/// AAC in MP4 with fast-start metadata for direct playback and upload.
public enum RenderOutputFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case proRes422HQ, proRes422, h264, hevc
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .proRes422HQ: return "ProRes 422 HQ · PCM (MOV)"
        case .proRes422: return "ProRes 422 · PCM (MOV)"
        case .h264: return "H.264 · AAC (MP4)"
        case .hevc: return "HEVC · AAC (MP4)"
        }
    }
    public var fileExtension: String { isProRes ? "mov" : "mp4" }
    public var isProRes: Bool { self == .proRes422HQ || self == .proRes422 }
    /// FFprobe identities checked after rendering.
    public var videoCodecName: String {
        switch self {
        case .proRes422HQ, .proRes422: return "prores"
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }
    public var videoProfileName: String {
        switch self {
        case .proRes422HQ: return "HQ"
        case .proRes422: return "Standard"
        case .h264: return "High"
        case .hevc: return "Main"
        }
    }
    public var pixelFormat: String { isProRes ? "yuv422p10le" : "yuv420p" }
    public var audioCodecName: String { isProRes ? "pcm_s24le" : "aac" }
    var encoderArguments: [String] {
        switch self {
        case .proRes422HQ: return ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", pixelFormat, "-c:a", "pcm_s24le"]
        case .proRes422: return ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", pixelFormat, "-c:a", "pcm_s24le"]
        case .h264: return ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high", "-pix_fmt", pixelFormat,
                            "-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart"]
        case .hevc: return ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-profile:v", "main", "-pix_fmt", pixelFormat, "-tag:v", "hvc1",
                            "-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart"]
        }
    }
}

public enum FFmpegRenderCompiler {
    /// Source qualification must be performed by the caller: the canonical plan
    /// does not carry pixel aspect, rotation, color or variable-frame-rate metadata.
    public static let qualificationLimitations = "Video is conformed to the sequence frame rate and audio to the sequence sample rate. Rotation is applied. Non-square pixels are corrected to square. HDR sources are tone mapped to SDR Rec. 709. PNG/JPEG stills use only the first decoded frame."

    /// Explicit prototype subset: frame-aligned video/stills, sample-aligned audio,
    /// zero stream offsets, mono/stereo output, originals.
    /// Video is conformed on the sequence grid with FFmpeg fps round=near before trim.
    /// Source geometry/color metadata and VFR mappings are not yet qualified.
    /// `toneMappedSources` maps HDR originals to their display rotation in degrees (FFprobe
    /// display-matrix convention). Their picture is decoded with VideoToolbox, converted to
    /// SDR Rec. 709 (tone mapped) and rotated explicitly, since hardware frames skip autorotation.
    public static func compile(_ plan: TimelineRenderPlan, outputURL: URL,
                               format: RenderOutputFormat = .proRes422HQ,
                               toneMappedSources: [URL: Int] = [:]) throws -> FFmpegRenderCommand {
        try plan.settings.validate()
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == format.fileExtension else {
            throw EditorCoreError.invalidModel("Export requires a local \(format.fileExtension.uppercased()) destination")
        }
        let settings = plan.settings
        guard settings.width % 2 == 0, settings.height % 2 == 0,
              [ChannelLayout.mono, .stereo, .surround51].contains(settings.audioLayout) else {
            throw EditorCoreError.invalidModel("Export requires even raster dimensions and mono, stereo or 5.1 output")
        }
        // Sample-aligned audio may end between video frames. Cover the full sequence
        // with a final black/video frame, retaining the exact audio duration.
        let frames = try ceiling(plan.duration.multiplied(by: settings.frameRate.value))
        guard frames > 0 else { throw EditorCoreError.invalidModel("Cannot render an empty sequence") }
        let sampleTime = try plan.duration.multiplied(by: Int64(settings.audioSampleRate))
        let samples = try ceiling(sampleTime)
        let rate = fraction(settings.frameRate.value)
        // FFmpeg's 5.1 order (FL FR FC LFE BL BR) matches the model's L R C LFE Ls Rs.
        let layout = settings.audioLayout == .mono ? "mono" : settings.audioLayout == .stereo ? "stereo" : "5.1"
        var arguments = ["-hide_banner", "-nostdin", "-n"]
        var graph = ["color=c=black:s=\(settings.width)x\(settings.height):r=\(rate),trim=end_frame=\(frames),setpts=PTS-STARTPTS,format=yuv444p[base]",
                     "anullsrc=r=\(settings.audioSampleRate):cl=\(layout),atrim=end_sample=\(samples)[silence]"]
        var inputs: [RenderSourceInput] = []
        var inputIndex = 0
        var videoLabel = "base"
        var audioLabels = ["silence"]
        // Composite back to front: track zero is frontmost in the canonical plan.
        let components = plan.components.sorted { TimelineRenderPlan.Component.isInFront($1, of: $0) }
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
            func input(_ stream: Int, kind: MediaStreamKind, hardwareDecode: Bool = false) throws -> String {
                guard component.sourceStreams.contains(where: { $0.index == stream && $0.kind == kind }) else {
                    throw EditorCoreError.invalidModel("Missing source stream")
                }
                inputs.append(RenderSourceInput(url: url, streamIndex: stream, kind: kind))
                if hardwareDecode { arguments += ["-noautorotate", "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"] }
                arguments += ["-i", url.path]
                defer { inputIndex += 1 }
                return "[\(inputIndex):\(stream)]"
            }
            switch component.selection {
            case .still, .video:
                guard component.fadeIn.curve == .linear, component.fadeOut.curve == .linear else {
                    throw EditorCoreError.invalidModel("Picture fades are linear")
                }
                let isStill = component.selection == .still
                // Edit points snap to the nearest sequence frame. Shared boundaries round
                // identically, so adjacent clips stay adjacent; sub-frame clips are skipped.
                let start = isStill ? 0 : try nearest(component.sourceRange.start.multiplied(by: settings.frameRate.value))
                let placement = try nearest(component.timelineRange.start.multiplied(by: settings.frameRate.value))
                let count = try nearest(component.timelineRange.end().multiplied(by: settings.frameRate.value)) - placement
                guard count > 0 else { continue }
                let end = try RationalTime(start).adding(RationalTime(count)).numerator
                let scaling: String
                let w = settings.width, h = settings.height
                // Transformed pictures reveal lower layers outside their own picture area.
                let transformed = !component.transform.isIdentity
                let clearPad = isStill || transformed
                switch component.scalingMode {
                case .fit: scaling = "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2\(clearPad ? ":color=black@0" : "")"
                case .fill: scaling = "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)"
                case .none: scaling = "pad='max(iw,\(w))':'max(ih,\(h))':(ow-iw)/2:(oh-ih)/2\(clearPad ? ":color=black@0" : ""),crop=\(w):\(h)"
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
                    let rotation = toneMappedSources[url]
                    source = try input(stream, kind: .video, hardwareDecode: rotation != nil)
                    // VideoToolbox converts HDR (PQ/HLG, BT.2020) to SDR BT.709 with tone mapping.
                    var sdr = ""
                    if let rotation {
                        let turn: String
                        switch ((rotation % 360) + 360) % 360 {
                        case 270: turn = "transpose=clock,"
                        case 90: turn = "transpose=cclock,"
                        case 180: turn = "hflip,vflip,"
                        default: turn = ""
                        }
                        sdr = "scale_vt=color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,"
                            + turn + "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,"
                    }
                    let offset = component.sourceStreams.first { $0.index == stream && $0.kind == .video }?.timeOffset ?? .zero
                    // A stream beginning after (or before) asset zero keeps its asset-time position;
                    // fps pads or drops from zero so trim frame numbers remain asset frames.
                    let origin = offset == .zero ? "setpts=PTS-STARTPTS,fps=\(rate):round=near"
                        : "setpts=PTS-STARTPTS+(\(offset.numerator)/\(offset.denominator))/TB,fps=\(rate):round=near:start_time=0"
                    timing = "\(sdr)\(origin),trim=start_frame=\(start):end_frame=\(end),setpts=PTS-STARTPTS+\(placement)"
                }
                // Full-range movies (screen recordings, some cameras) are normalized to video range
                // so overlays and encoders receive one consistent range.
                // Anamorphic movies are widened to square pixels first; square sources keep their exact width.
                let squarePixels = "scale=w='if(eq(sar,1),iw,trunc(iw*sar/2)*2)':h=ih:out_range=tv,setsar=1"
                let fades = try pictureFades(component, placement: placement, count: count, rate: settings.frameRate.value)
                let geometry = isStill ? "format=yuva444p,\(scaling),setsar=1"
                    : transformed ? "\(squarePixels),format=yuva444p,\(scaling),setsar=1"
                    : "\(squarePixels),\(scaling),setsar=1,format=\(fades.isEmpty ? "yuv444p" : "yuva444p")"
                var arrangement = ""
                if transformed {
                    let t = component.transform
                    if t.scale != 1 { arrangement += ",scale=w='max(1,round(iw*\(t.scale)))':h='max(1,round(ih*\(t.scale)))'" }
                    if t.opacity != 1 { arrangement += ",lut=a='val*\(t.opacity)'" }
                }
                graph.append("\(source)\(timing),\(geometry)\(arrangement)\(fades)[v\(index)]")
                // Explicit half-open visibility also prevents framesync holding a layer past its cut.
                let visibleEnd = try RationalTime(placement).adding(RationalTime(count)).numerator
                let enabled = "gte(n,\(placement))*lt(n,\(visibleEnd))"
                // A transformed layer is centred, then offset in fractions of the frame.
                let position = transformed
                    ? ":x='(main_w-overlay_w)/2+\(component.transform.offsetX)*main_w':y='(main_h-overlay_h)/2+\(component.transform.offsetY)*main_h'" : ""
                graph.append("[\(videoLabel)][v\(index)]overlay=eof_action=repeat:repeatlast=1:format=yuv444\(position):enable='\(enabled)'[layer\(index)]")
                videoLabel = "layer\(index)"
            case .audio(let selection):
                try selection.layout.validate()
                guard selection.channels.count == selection.layout.channels.count else { throw EditorCoreError.invalidModel("Incomplete audio selection") }
                let routing = component.routing.outputChannels.isEmpty ? Array(selection.channels.indices) : component.routing.outputChannels
                guard routing.count == selection.channels.count, routing.allSatisfy({ settings.audioLayout.channels.indices.contains($0) }),
                      !component.routing.outputChannels.isEmpty || selection.layout == settings.audioLayout else {
                    throw EditorCoreError.invalidModel("Invalid audio output map")
                }
                // Audio edit points snap to the nearest output sample (under 21 µs at 48 kHz).
                let start = try nearest(component.sourceRange.start.multiplied(by: Int64(settings.audioSampleRate)))
                let delay = try nearest(component.timelineRange.start.multiplied(by: Int64(settings.audioSampleRate)))
                let end = try start + nearest(component.timelineRange.end().multiplied(by: Int64(settings.audioSampleRate))) - delay
                guard end > start else { continue }
                let envelope = try audioEnvelope(component, sampleCount: end - start, sampleRate: settings.audioSampleRate, layout: layout)
                for (channel, sourceChannel) in selection.channels.enumerated() {
                    guard let stream = component.sourceStreams.first(where: { $0.index == sourceChannel.streamIndex }), let sourceLayout = stream.audioLayout,
                          sourceLayout.channels.indices.contains(sourceChannel.channelIndex) else { throw EditorCoreError.invalidModel("Invalid source channel") }
                    let source = try input(sourceChannel.streamIndex, kind: .audio)
                    // Sample counts begin at the stream's first sample; align them to asset time.
                    let shift = try stream.timeOffset.multiplied(by: Int64(settings.audioSampleRate))
                    let offsetSamples = Int64((Double(shift.numerator) / Double(shift.denominator)).rounded())
                    let pad = offsetSamples > 0 ? "adelay=\(offsetSamples)S:all=1," : ""
                    let skip = max(0, -offsetSamples)
                    let map = settings.audioLayout.channels.indices.map { "c\($0)=\($0 == routing[channel] ? "c\(sourceChannel.channelIndex)" : "0*c\(sourceChannel.channelIndex)")" }.joined(separator: "|")
                    let label = "a\(index)c\(channel)"
                    graph.append("\(source)aresample=\(settings.audioSampleRate),\(pad)atrim=start_sample=\(start + skip):end_sample=\(end + skip),asetpts=PTS-STARTPTS,pan=\(layout)|\(map),aformat=sample_fmts=flt,volume=\(component.gain):precision=float\(envelope),adelay=\(delay)S:all=1[\(label)]")
                    audioLabels.append(label)
                }
            }
        }
        graph.append("[\(videoLabel)]trim=end_frame=\(frames),setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv[video]")
        graph.append(audioLabels.map { "[\($0)]" }.joined() + "amix=inputs=\(audioLabels.count):normalize=0,atrim=end_sample=\(samples)[audio]")
        let filterGraph = graph.joined(separator: ";")
        arguments += ["-filter_complex", filterGraph, "-map", "[video]", "-map", "[audio]", "-r", rate, "-fps_mode", "cfr"] + format.encoderArguments
            // Sequences are SDR Rec. 709; tag every output so players apply the right matrix.
            + ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-ar", String(settings.audioSampleRate), "-ac", String(settings.audioLayout.channels.count), "-video_track_timescale", String(settings.frameRate.value.numerator), "-timecode", try settings.startTimecode.formatted(rate: settings.frameRate), outputURL.path]
        return FFmpegRenderCommand(inputs: inputs, arguments: arguments, filterGraph: filterGraph, videoFrames: frames, audioSamples: samples)
    }
    /// Linear opacity ramps in timeline seconds; frames carry timeline timestamps here.
    /// A frame at the start of a fade in is transparent; the last frame of a fade out
    /// keeps 1/n of its opacity, matching a ramp that reaches zero at the cut.
    private static func pictureFades(_ component: TimelineRenderPlan.Component, placement: Int64,
                                     count: Int64, rate: RationalTime) throws -> String {
        func seconds(_ frames: Int64) throws -> RationalTime { try RationalTime(frames).divided(by: rate) }
        func decimal(_ time: RationalTime) -> String { String(format: "%.9f", time.seconds) }
        var result = ""
        if component.fadeIn.duration != .zero {
            result += ",fade=t=in:st=\(decimal(try seconds(placement))):d=\(decimal(component.fadeIn.duration)):alpha=1"
        }
        if component.fadeOut.duration != .zero {
            let start = try seconds(placement + count).subtracting(component.fadeOut.duration)
            result += ",fade=t=out:st=\(decimal(start)):d=\(decimal(component.fadeOut.duration)):alpha=1"
        }
        return result
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
        let channels = layout == "mono" ? 1 : layout == "stereo" ? 2 : 6
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
    /// Round half up to the nearest whole unit; edit times are never negative.
    private static func nearest(_ time: RationalTime) throws -> Int64 {
        guard time.numerator >= 0 else { throw EditorCoreError.invalidModel("Negative edit time") }
        let (doubled, overflow) = time.numerator.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw EditorCoreError.overflow }
        return (doubled + time.denominator) / (2 * time.denominator)
    }
}
