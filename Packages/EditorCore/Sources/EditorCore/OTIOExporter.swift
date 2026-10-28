import Foundation

public struct OTIOExportResult: Equatable, Sendable {
    public let json: String
    /// Edits the file leaves out or simplifies, to show before saving.
    public let warnings: [String]
}

public enum OTIOExportError: Error, Equatable, Sendable, LocalizedError {
    case unsupported([String])
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reasons):
            return "This sequence cannot be exported to OpenTimelineIO:\n" + reasons.map { "• " + $0 }.joined(separator: "\n")
        }
    }
}

/// Editorial interchange, not a render description. Edits the subset cannot carry are left out
/// and listed in the result's warnings; timing is never rounded, so a clip off the grid is left
/// out rather than moved. See docs/otio-export.md for timing conventions and editor limitations.
public enum OTIOExporter {
    private static let largestExactInteger: Int64 = 9_007_199_254_740_992

    public static func export(project: Project, projectName: String = "Sequence") throws -> OTIOExportResult {
        try project.validate()
        let plan = try TimelineRenderPlan(project: project)
        let settings = project.settings
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        var reasons: [String] = []
        var warnings = ExportWarnings()
        if plan.components.isEmpty { reasons.append("The sequence has no clips.") }
        var cuts = try project.interchangeCuts()
        let clips = Dictionary(uniqueKeysWithValues: project.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let trackOfClip = Dictionary(uniqueKeysWithValues: project.tracks.flatMap { track in track.clips.map { ($0.id, track) } })
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
        if !plan.mix.isPlainSum { warnings.add("Track effects, bus effects and extra buses are not exported.") }
        var dropped: Set<UUID> = []
        for component in plan.components {
            let asset = assets[component.assetID]!
            let name = asset.name
            func omit(_ why: String) { warnings.add("Clips left out: \(why)", for: name); dropped.insert(component.clipID) }
            guard let url = asset.originalURL, url.isFileURL, !url.path.isEmpty else { omit("an original local file reference is required."); continue }
            if asset.sourceTimecode?.frameCount != nil && asset.sourceTimecode?.frameCount != 0 {
                omit("source timecode without a known source frame rate is not supported."); continue
            }
            if component.gain != 1 { warnings.add("Track gain and clip volume are not exported.", for: name) }
            let clip = clips[component.clipID]!
            if clip.fadeIn.duration != .zero || clip.fadeOut.duration != .zero { warnings.add("Fades are not exported.", for: name) }
            if component.dynamics != nil { warnings.add("Compression is not exported.", for: name) }
            if component.key != nil { warnings.add("Keying is not exported.", for: name) }
            if !component.eq.isFlat { warnings.add("EQ is not exported.", for: name) }
            if component.stabilization != nil { warnings.add("Stabilisation is not exported.", for: name) }
            if !component.volumeKeyframes.isEmpty { warnings.add("Volume keyframes are not exported.", for: name) }
            if !component.color.isNeutral { warnings.add("Colour correction is not exported.", for: name) }
            // The project clip, not the render component: a slide or push moves the component itself.
            if !clip.transform.isIdentity || !clip.transformKeyframes.isEmpty { warnings.add("Scale, position, opacity and their keyframes are not exported.", for: name) }
            let clock: RationalTime
            switch component.selection {
            case .still:
                omit("still-image hold duration and geometry are not qualified."); continue
            case .video(let index):
                clock = settings.frameRate.value
                let streams = asset.streams.filter { $0.kind == .video }
                if streams.first(where: { $0.index == index })?.timeOffset != .zero { omit("source stream offsets are not supported."); continue }
                if streams.count != 1 { warnings.add("The choice among multiple video streams is not exported; the receiving editor picks the stream.", for: name) }
                if component.scalingMode != .fit { warnings.add("Fill and unscaled geometry are not exported; receiving editors fit the picture.", for: name) }
            case .audio(let selection):
                clock = try RationalTime(Int64(settings.audioSampleRate))
                let streams = asset.streams.filter { $0.kind == .audio }
                if selection.channels.contains(where: { channel in streams.first { $0.index == channel.streamIndex }?.timeOffset != .zero }) {
                    omit("source stream offsets are not supported."); continue
                }
                if streams.count == 1, let stream = streams.first, let layout = stream.audioLayout {
                    let identity = layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
                    if selection.channels != identity || selection.layout != layout {
                        warnings.add("Partial or reordered audio channel selections are not exported; the whole audio stream is referenced.", for: name)
                    }
                    if layout != settings.audioLayout { warnings.add("Source audio layouts that differ from the sequence layout are not converted.", for: name) }
                } else { warnings.add("The choice among multiple audio streams is not exported; the receiving editor picks the audio.", for: name) }
                if !component.routing.isDefaultPlacement(of: selection.layout, in: plan.settings.audioLayout) {
                    warnings.add("Output channel routing is not exported.", for: name)
                }
            }
            let editorial = cuts.ranges[component.clipID]!
            var inRange = asset.duration.numerator <= largestExactInteger && asset.duration.denominator <= largestExactInteger
            var onGrid = true
            for time in [editorial.source.start, editorial.source.duration, try editorial.source.end(), editorial.timeline.start, try editorial.timeline.end()] {
                if try !aligned(time, clock: clock) { onGrid = false }
                else if try time.multiplied(by: clock).numerator > largestExactInteger { inRange = false }
            }
            if !onGrid { omit("source and timeline edits must align to \(component.selection.isOTIOAudio ? "sequence audio sample" : "sequence frame") boundaries; export never rounds."); continue }
            if !inRange { omit("time exceeds OTIO's exact integer range."); continue }
        }
        let exported = Set(plan.components.map(\.clipID)).subtracting(dropped)
        if !plan.components.isEmpty && exported.isEmpty { reasons.append("None of the sequence's clips can be exported.") }
        cuts.transitions.removeAll { transition in
            let relation = transition.relation
            // A transition whose other side is hidden, muted or left out becomes a cut.
            guard exported.contains(relation.outgoingClipID), exported.contains(relation.incomingClipID) else { return true }
            let name = assets[clips[relation.incomingClipID]!.assetID]!.name
            guard trackOfClip[relation.incomingClipID]?.id == transition.trackID else {
                warnings.add("Crossfades between clips on different tracks are exported as cuts.", for: name); return true
            }
            let clock = trackOfClip[relation.incomingClipID]?.kind == .audio ? (try? RationalTime(Int64(settings.audioSampleRate))) ?? .one : settings.frameRate.value
            guard (try? aligned(transition.before, clock: clock)) == true, (try? aligned(transition.after, clock: clock)) == true else {
                warnings.add("Transitions off the \(clock == settings.frameRate.value ? "frame" : "sample") grid are exported as cuts.", for: name); return true
            }
            // OTIO's SMPTE dissolve is the only portable transition.
            if relation.style != nil { warnings.add("Slide, push and wipe transitions are exported as cross dissolves.", for: name) }
            return false
        }
        var markers: [SequenceMarker] = []
        for marker in project.markers {
            let label = "“\(marker.name)”"
            if try !aligned(marker.time, clock: settings.frameRate.value) { warnings.add("Markers off the sequence frame grid are left out.", for: label) }
            else if try marker.time.multiplied(by: settings.frameRate.value).numerator > largestExactInteger { warnings.add("Markers beyond OTIO's exact integer range are left out.", for: label) }
            else if try marker.time.compared(to: plan.duration) != .orderedAscending { warnings.add("Markers after the end of the sequence are left out.", for: label) }
            else { markers.append(marker) }
        }
        guard reasons.isEmpty else { throw OTIOExportError.unsupported(reasons + warnings.list) }

        var tracks: [[String: Any]] = []
        // OTIO Stack children are back-to-front; the editor stores frontmost first.
        for track in project.tracks.reversed() {
            let audio = track.kind == .audio
            let clock = audio ? try RationalTime(Int64(settings.audioSampleRate)) : settings.frameRate.value
            var children: [[String: Any]] = []
            var cursor = RationalTime.zero
            let components = plan.components.filter { $0.trackID == track.id && exported.contains($0.clipID) }
            for component in components {
                // Clips meet at each transition's cut; the transition draws on their handles.
                let editorial = cuts.ranges[component.clipID]!
                let gap = try editorial.timeline.start.subtracting(cursor)
                if gap.numerator > 0 { children.append(try item(schema: "Gap.1", name: "Gap", range: TimeRange(start: .zero, duration: gap), clock: clock)) }
                let asset = assets[component.assetID]!
                // Source ranges are in the media's own timecode clock, as receiving editors expect.
                let origin = asset.sourceTimecodeStart ?? .zero
                // With a time warp, OTIO's source range keeps the clip's duration in the track and starts at the media in point.
                var clip = try item(schema: "Clip.2", name: asset.name, range: editorial.source, clock: clock)
                if origin != .zero, var range = clip["source_range"] as? [String: Any] {
                    let start = try editorial.source.start.adding(origin)
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
                    "asset_id": component.assetID.uuidString, "timeline_start": exactTime(editorial.timeline.start),
                    "source_start": exactTime(editorial.source.start), "duration": exactTime(editorial.source.duration),
                    "speed": exactTime(component.speed)]]
                if component.speed != .one {
                    clip["effects"] = [["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "Speed", "effect_name": "LinearTimeWarp",
                                        "metadata": [:], "time_scalar": component.speed.seconds]]
                }
                children.append(clip)
                cursor = try editorial.timeline.end()
                if let transition = cuts.transition(outgoing: component.clipID) {
                    children.append(["OTIO_SCHEMA": "Transition.1", "name": audio ? "Crossfade" : "Cross Dissolve",
                                     "transition_type": "SMPTE_Dissolve",
                                     "metadata": ["aagedal_film_constructor": ["transition_id": transition.relation.id.uuidString,
                                                                               "curve": transition.relation.curve.rawValue]],
                                     "in_offset": try time(transition.before, clock: clock), "out_offset": try time(transition.after, clock: clock)])
                }
            }
            let tail = try plan.duration.subtracting(cursor)
            if tail.numerator > 0 { children.append(try item(schema: "Gap.1", name: "Gap", range: TimeRange(start: .zero, duration: tail), clock: clock)) }
            var object = composition(schema: "Track.1", name: track.displayName(in: project), children: children)
            object["kind"] = audio ? "Audio" : "Video"
            object["metadata"] = ["aagedal_film_constructor": ["track_id": track.id.uuidString]]
            tracks.append(object)
        }
        var stack = composition(schema: "Stack.1", name: "Tracks", children: tracks)
        // Sequence markers belong to the stack, one frame long, in sequence time from zero.
        stack["markers"] = try markers.map { marker -> [String: Any] in
            ["OTIO_SCHEMA": "Marker.2", "name": marker.name, "comment": marker.note, "color": marker.color.rawValue.uppercased(),
             "metadata": ["aagedal_film_constructor": ["marker_id": marker.id.uuidString, "time": exactTime(marker.time)]],
             "marked_range": ["OTIO_SCHEMA": "TimeRange.1", "start_time": try time(marker.time, clock: settings.frameRate.value),
                              "duration": try time(settings.frameRate.time(forFrames: 1), clock: settings.frameRate.value)]]
        }
        let timeline: [String: Any] = ["OTIO_SCHEMA": "Timeline.1", "name": projectName,
            "global_start_time": ["OTIO_SCHEMA": "RationalTime.1", "value": settings.startTimecode.frameCount, "rate": settings.frameRate.value.seconds],
            "tracks": stack,
            "metadata": ["aagedal_film_constructor": ["export_subset": "cuts-dissolves-and-speed-v2",
                "frame_rate": exactTime(settings.frameRate.value), "start_timecode_frames": settings.startTimecode.frameCount,
                "timecode_mode": settings.startTimecode.mode.rawValue, "width": settings.width, "height": settings.height,
                "audio_sample_rate": settings.audioSampleRate, "audio_channels": settings.audioLayout.channels.count,
                "qualification": "Editorial timing, original references, SMPTE dissolves and linear time warps. OTIO uses floating-point frame rates; exact rational timing is retained in namespaced metadata. Spatial conform and native editor import are not qualified."]]]
        let data = try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return OTIOExportResult(json: String(decoding: data, as: UTF8.self) + "\n", warnings: warnings.list)
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
