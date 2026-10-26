import Foundation

public enum OTIOExportError: Error, Equatable, Sendable, LocalizedError {
    case unsupported([String])
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reasons):
            return "This sequence cannot be exported to OpenTimelineIO:\n" + reasons.map { "• " + $0 }.joined(separator: "\n")
        }
    }
}

/// Editorial interchange, not a render description. Unsupported edits fail before writing.
/// See docs/otio-export.md for timing conventions and receiving-editor limitations.
public enum OTIOExporter {
    private static let largestExactInteger: Int64 = 9_007_199_254_740_992

    public static func export(project: Project, projectName: String = "Sequence") throws -> String {
        try project.validate()
        let plan = try TimelineRenderPlan(project: project)
        let settings = project.settings
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        var reasons: [String] = []
        if plan.components.isEmpty { reasons.append("The sequence has no clips.") }
        if !project.audioCrossfades.isEmpty { reasons.append("Audio crossfades and video dissolves are not supported.") }
        if settings.audioLayout != .mono && settings.audioLayout != .stereo { reasons.append("Only mono and stereo sequence audio layouts are supported.") }
        if settings.frameRate.value.numerator > largestExactInteger || settings.frameRate.value.denominator > largestExactInteger {
            reasons.append("The sequence frame rate exceeds OTIO's exact numeric range.")
        }
        if settings.startTimecode.frameCount > largestExactInteger { reasons.append("Sequence timecode exceeds OTIO's exact integer range.") }
        let sequenceFrames = try plan.duration.multiplied(by: settings.frameRate.value)
        if sequenceFrames.denominator != 1 { reasons.append("The sequence end must fall on a sequence frame boundary; export does not round or pad it.") }
        else if sequenceFrames.numerator > largestExactInteger ||
                    settings.startTimecode.frameCount > largestExactInteger - sequenceFrames.numerator {
            reasons.append("The sequence record endpoint exceeds OTIO's exact integer range.")
        }
        if project.tracks.contains(where: { $0.kind == .audio }),
           try !aligned(plan.duration, clock: RationalTime(Int64(settings.audioSampleRate))) {
            reasons.append("The sequence end must fall on an audio sample boundary to preserve audio track tail gaps without rounding.")
        }
        for component in plan.components {
            let asset = assets[component.assetID]!
            let label = "Clip \(component.clipID.uuidString) (\(asset.name))"
            guard let url = asset.originalURL, url.isFileURL, !url.path.isEmpty else {
                reasons.append("\(label): an original local file reference is required.")
                continue
            }
            if asset.sourceTimecode?.frameCount != nil && asset.sourceTimecode?.frameCount != 0 {
                reasons.append("\(label): source timecode without a known source frame rate is not supported.")
            }
            if component.gain != 1 { reasons.append("\(label): track gain and clip volume must be unity.") }
            if component.fadeIn.duration != .zero || component.fadeOut.duration != .zero { reasons.append("\(label): fades are not supported.") }
            if !component.volumeKeyframes.isEmpty { reasons.append("\(label): volume keyframes are not supported.") }
            if !component.transform.isIdentity { reasons.append("\(label): scale, position and opacity are not supported.") }
            let clock: RationalTime
            switch component.selection {
            case .still:
                reasons.append("\(label): still-image hold duration and geometry are not qualified.")
                continue
            case .video(let index):
                clock = settings.frameRate.value
                let streams = asset.streams.filter { $0.kind == .video }
                if streams.count != 1 || streams.first?.index != index { reasons.append("\(label): selecting among multiple video streams is not supported.") }
                if streams.first?.timeOffset != .zero { reasons.append("\(label): source stream offsets are not supported.") }
                if component.scalingMode != .fit { reasons.append("\(label): fill and unscaled geometry are not supported by the OTIO editorial subset.") }
            case .audio(let selection):
                clock = try RationalTime(Int64(settings.audioSampleRate))
                let streams = asset.streams.filter { $0.kind == .audio }
                if streams.count == 1, let stream = streams.first, let layout = stream.audioLayout {
                    let identity = layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
                    if selection.channels != identity || selection.layout != layout { reasons.append("\(label): partial or reordered audio channel selections are not supported.") }
                    if layout != settings.audioLayout { reasons.append("\(label): source audio layout must match the sequence layout.") }
                    if stream.timeOffset != .zero { reasons.append("\(label): source stream offsets are not supported.") }
                } else { reasons.append("\(label): exactly one complete audio stream is required.") }
                if !component.routing.outputChannels.isEmpty && component.routing.outputChannels != Array(selection.channels.indices) {
                    reasons.append("\(label): nonidentity output channel routing is not supported.")
                }
            }
            for time in [component.sourceRange.start, component.sourceRange.duration, try component.sourceRange.end(),
                         component.timelineRange.start, try component.timelineRange.end()] {
                if try !aligned(time, clock: clock) { reasons.append("\(label): source and timeline edits must align to \(component.selection.isOTIOAudio ? "sequence audio sample" : "sequence frame") boundaries.") }
                else if try time.multiplied(by: clock).numerator > largestExactInteger { reasons.append("\(label): time exceeds OTIO's exact integer range.") }
            }
            if asset.duration.numerator > largestExactInteger || asset.duration.denominator > largestExactInteger {
                reasons.append("\(label): available media duration exceeds OTIO's exact integer range.")
            }
        }
        guard reasons.isEmpty else { throw OTIOExportError.unsupported(reasons) }

        var tracks: [[String: Any]] = []
        // OTIO Stack children are back-to-front; the editor stores frontmost first.
        for track in project.tracks.reversed() {
            let audio = track.kind == .audio
            let clock = audio ? try RationalTime(Int64(settings.audioSampleRate)) : settings.frameRate.value
            var children: [[String: Any]] = []
            var cursor = RationalTime.zero
            let components = plan.components.filter { $0.trackID == track.id }
            for component in components {
                let gap = try component.timelineRange.start.subtracting(cursor)
                if gap.numerator > 0 { children.append(try item(schema: "Gap.1", name: "Gap", range: TimeRange(start: .zero, duration: gap), clock: clock)) }
                let asset = assets[component.assetID]!
                // Source ranges are in the media's own timecode clock, as receiving editors expect.
                let origin = asset.sourceTimecodeStart ?? .zero
                var clip = try item(schema: "Clip.2", name: asset.name, range: component.sourceRange, clock: clock)
                if origin != .zero, var range = clip["source_range"] as? [String: Any] {
                    let start = try component.sourceRange.start.adding(origin)
                    // A timecode origin off the track clock keeps its exact rational encoding.
                    range["start_time"] = (try? time(start, clock: clock)) ?? rawTime(start)
                    clip["source_range"] = range
                }
                let reference: [String: Any] = ["OTIO_SCHEMA": "ExternalReference.1", "name": asset.name,
                    "metadata": [:], "target_url": asset.originalURL!.interchangeFileURL.absoluteString,
                    // This clock encodes exact seconds, without inventing the source frame rate.
                    "available_range": ["OTIO_SCHEMA": "TimeRange.1", "start_time": rawTime(origin), "duration": rawTime(asset.duration)]]
                clip["media_references"] = ["DEFAULT_MEDIA": reference]
                clip["active_media_reference_key"] = "DEFAULT_MEDIA"
                clip["metadata"] = ["aagedal_film_constructor": ["clip_id": component.clipID.uuidString,
                    "asset_id": component.assetID.uuidString, "timeline_start": exactTime(component.timelineRange.start),
                    "source_start": exactTime(component.sourceRange.start), "duration": exactTime(component.sourceRange.duration)]]
                children.append(clip)
                cursor = try component.timelineRange.end()
            }
            let tail = try plan.duration.subtracting(cursor)
            if tail.numerator > 0 { children.append(try item(schema: "Gap.1", name: "Gap", range: TimeRange(start: .zero, duration: tail), clock: clock)) }
            var object = composition(schema: "Track.1", name: track.displayName(in: project), children: children)
            object["kind"] = audio ? "Audio" : "Video"
            object["metadata"] = ["aagedal_film_constructor": ["track_id": track.id.uuidString]]
            tracks.append(object)
        }
        let timeline: [String: Any] = ["OTIO_SCHEMA": "Timeline.1", "name": projectName,
            "global_start_time": ["OTIO_SCHEMA": "RationalTime.1", "value": settings.startTimecode.frameCount, "rate": settings.frameRate.value.seconds],
            "tracks": composition(schema: "Stack.1", name: "Tracks", children: tracks),
            "metadata": ["aagedal_film_constructor": ["export_subset": "cuts-and-gaps-v1",
                "frame_rate": exactTime(settings.frameRate.value), "start_timecode_frames": settings.startTimecode.frameCount,
                "timecode_mode": settings.startTimecode.mode.rawValue, "width": settings.width, "height": settings.height,
                "audio_sample_rate": settings.audioSampleRate, "audio_channels": settings.audioLayout.channels.count,
                "qualification": "Editorial timing and original references only. OTIO uses floating-point frame rates; exact rational timing is retained in namespaced metadata. Spatial conform and native editor import are not qualified."]]]
        let data = try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func aligned(_ time: RationalTime, clock: RationalTime) throws -> Bool {
        try time.multiplied(by: clock).denominator == 1
    }
    private static func exactTime(_ time: RationalTime) -> [String: Int64] { ["numerator": time.numerator, "denominator": time.denominator] }
    private static func rawTime(_ time: RationalTime) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "value": time.numerator, "rate": time.denominator]
    }
    private static func time(_ time: RationalTime, clock: RationalTime) throws -> [String: Any] {
        let value = try time.multiplied(by: clock)
        guard value.denominator == 1, value.numerator.magnitude <= UInt64(largestExactInteger) else {
            throw OTIOExportError.unsupported(["A gap or edit cannot be represented without rounding at its track clock."])
        }
        return ["OTIO_SCHEMA": "RationalTime.1", "value": value.numerator, "rate": clock.seconds]
    }
    private static func item(schema: String, name: String, range: TimeRange, clock: RationalTime) throws -> [String: Any] {
        ["OTIO_SCHEMA": schema, "name": name, "metadata": [:], "effects": [], "markers": [], "enabled": true,
         "source_range": ["OTIO_SCHEMA": "TimeRange.1", "start_time": try time(range.start, clock: clock), "duration": try time(range.duration, clock: clock)]]
    }
    private static func composition(schema: String, name: String, children: [[String: Any]]) -> [String: Any] {
        ["OTIO_SCHEMA": schema, "name": name, "metadata": [:], "effects": [], "markers": [], "enabled": true,
         "source_range": NSNull(), "children": children]
    }
}

private extension ClipSelection {
    var isOTIOAudio: Bool { if case .audio = self { return true }; return false }
}
