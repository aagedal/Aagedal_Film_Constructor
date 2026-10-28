import Foundation

public struct FCPXMLExportReport: Equatable, Sendable {
    public let clipCount: Int
    public let assetCount: Int
    /// Qualification limits, which should be shown alongside a successful export.
    public let notes: [String]
    /// Edits the file leaves out or simplifies, to show before saving.
    public let warnings: [String]
}

public struct FCPXMLExportResult: Equatable, Sendable {
    public let xml: String
    public let report: FCPXMLExportReport
}

public enum FCPXMLExportError: Error, Equatable, Sendable, LocalizedError {
    case unsupported([String])
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reasons):
            return "This sequence cannot be exported to FCPXML:\n" + reasons.map { "• " + $0 }.joined(separator: "\n")
        }
    }
}

/// A deliberately small FCPXML 1.10 interchange subset. Edits outside it are left out and listed
/// in the report's warnings; timing is never rounded, so a clip off the grid is left out rather
/// than moved. Only a sequence that cannot be written at all is refused.
public enum FCPXMLExporter {
    public static func export(project: Project, projectName: String = "Sequence") throws -> FCPXMLExportResult {
        try project.validate()
        let plan = try TimelineRenderPlan(project: project)
        var reasons: [String] = []
        var warnings = ExportWarnings()
        let settings = project.settings
        let rates = [32000: "32k", 44100: "44.1k", 48000: "48k", 88200: "88.2k", 96000: "96k", 176400: "176.4k", 192000: "192k"]
        if rates[settings.audioSampleRate] == nil { reasons.append("The sequence audio sample rate is not supported by FCPXML 1.10.") }
        if settings.audioLayout != .mono && settings.audioLayout != .stereo { reasons.append("Only mono and stereo sequence audio layouts are supported.") }
        if plan.components.isEmpty { reasons.append("The sequence has no clips.") }
        // Dissolves and crossfades are written at their cuts in a connected storyline per track.
        var cuts = try project.interchangeCuts()
        let trackOfClip = Dictionary(uniqueKeysWithValues: project.tracks.flatMap { track in track.clips.map { ($0.id, track.id) } })
        let clipsByID = Dictionary(uniqueKeysWithValues: project.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let candidates = plan.components.map { component -> TimelineRenderPlan.Component in
            var item = component
            let clip = clipsByID[component.clipID]!
            (item.sourceRange, item.timelineRange) = cuts.ranges[component.clipID]!
            // Transitions are Final Cut transitions, so each clip keeps only its own fades and placement.
            item.fadeIn = clip.fadeIn; item.fadeOut = clip.fadeOut
            item.transformKeyframes = clip.transformKeyframes; item.reveal = nil
            return item
        }
        let replaced = "Characters XML 1.0 cannot represent are replaced."
        if !validXMLText(projectName) { warnings.add(replaced, for: "project name") }
        let frameDuration = try settings.frameRate.time(forFrames: 1)
        let tcStart = try settings.frameRate.time(forFrames: settings.startTimecode.frameCount)
        func fits32(_ times: [RationalTime]) -> Bool { !times.contains { $0.denominator > Int64(Int32.max) } }
        // Media whose clips cannot be written, and why.
        var unusable: [UUID: String] = [:]
        for asset in project.assets where plan.components.contains(where: { $0.assetID == asset.id }) {
            if !validXMLText(asset.name) { warnings.add(replaced, for: asset.name) }
            guard let url = asset.originalURL, url.isFileURL, !url.path.isEmpty else { unusable[asset.id] = "an original local file reference is required."; continue }
            if !validXMLText(url.absoluteString) { unusable[asset.id] = "the file reference cannot be written in XML." }
            else if asset.sourceTimecode?.frameCount != nil && asset.sourceTimecode?.frameCount != 0 {
                unusable[asset.id] = "source timecode without a known source frame rate is not supported."
            } else if !fits32([asset.duration] + (asset.sourceTimecodeStart.map { [$0] } ?? [])) {
                unusable[asset.id] = "an exact time needs a denominator beyond FCPXML's 32-bit limit."
            }
        }
        if !plan.mix.isPlainSum { warnings.add("Track effects, bus effects and extra buses are not exported.") }
        var dropped: Set<UUID> = []
        for component in candidates {
            let asset = project.assets.first { $0.id == component.assetID }!
            let name = asset.name
            func omit(_ why: String) { warnings.add("Clips left out: \(why)", for: name); dropped.insert(component.clipID) }
            if let why = unusable[asset.id] { omit(why); continue }
            // Fades, volume, scale, position, opacity and their keyframes are written as Final Cut adjustments.
            if component.dynamics != nil { warnings.add("Compression is not exported.", for: name) }
            if component.key != nil { warnings.add("Keying is not exported.", for: name) }
            if !component.eq.isFlat { warnings.add("EQ is not exported.", for: name) }
            if component.stabilization != nil { warnings.add("Stabilisation is not exported.", for: name) }
            if !component.color.isNeutral { warnings.add("Colour correction and blur are not exported.", for: name) }
            switch component.selection {
            case .still:
                omit("still-image duration and geometry have not been qualified."); continue
            case .video(let index):
                let video = asset.streams.filter { $0.kind == .video }
                if video.first(where: { $0.index == index })?.timeOffset != .zero { omit("nonzero source stream offsets are not supported."); continue }
                if try !frameAligned(component.timelineRange.start, rate: settings.frameRate) || !frameAligned(component.timelineRange.duration, rate: settings.frameRate) {
                    omit("video timeline positions and durations must fall on sequence frame boundaries; export never rounds."); continue
                }
                if video.count != 1 { warnings.add("The choice among multiple video streams is not exported; the receiving editor picks the stream.", for: name) }
                if component.scalingMode == .none { warnings.add("Unscaled clips are written with Final Cut's “none” conform, which receiving editors size from the source raster.", for: name) }
            case .audio(let selection):
                // Any selection of whole-asset channels is expressible as audio-channel-source srcCh.
                if Self.channelNumbers(selection, asset: asset) == nil { omit("selected audio channels are missing from the source."); continue }
                if selection.channels.contains(where: { channel in asset.streams.first { $0.index == channel.streamIndex }?.timeOffset != .zero }) {
                    omit("nonzero source stream offsets are not supported."); continue
                }
                if selection.layout != settings.audioLayout { warnings.add("Audio layouts that differ from the sequence layout are not converted.", for: name) }
                if !component.routing.isDefaultPlacement(of: selection.layout, in: settings.audioLayout) { warnings.add("Output channel routing is not exported.", for: name) }
            }
            let origin = asset.sourceTimecodeStart ?? .zero
            var times = [component.sourceRange.start, component.sourceRange.duration, component.timelineRange.start]
            if component.speed != .one {
                times += [try localTime(component.sourceRange.start, speed: component.speed, origin: origin), try localTime(asset.duration, speed: component.speed, origin: origin)]
            }
            if !fits32(times) { omit("an exact time needs a denominator beyond FCPXML's 32-bit limit."); continue }
        }
        if try !frameAligned(plan.duration, rate: settings.frameRate) { reasons.append("The sequence end must fall on a sequence frame boundary; export does not round or pad it.") }
        if !fits32([frameDuration, tcStart, plan.duration]) { reasons.append("An exact sequence time denominator exceeds the FCPXML 32-bit limit.") }
        let exported = Set(plan.components.map(\.clipID)).subtracting(dropped)
        if !plan.components.isEmpty && exported.isEmpty { reasons.append("None of the sequence's clips can be exported.") }
        cuts.transitions.removeAll { transition in
            let relation = transition.relation
            // A transition whose other side is hidden, muted or left out becomes a cut.
            guard exported.contains(relation.outgoingClipID), exported.contains(relation.incomingClipID) else { return true }
            let name = project.assets.first { $0.id == clipsByID[relation.incomingClipID]!.assetID }!.name
            guard trackOfClip[relation.incomingClipID] == transition.trackID else {
                warnings.add("Crossfades between clips on different tracks are exported as cuts.", for: name); return true
            }
            guard fits32([transition.cut, transition.before, transition.after]) else {
                warnings.add("Transitions whose exact timing exceeds FCPXML's 32-bit limit are exported as cuts.", for: name); return true
            }
            if relation.style != nil { warnings.add("Slide, push and wipe transitions are exported as cross dissolves.", for: name) }
            return false
        }
        var markers: [SequenceMarker] = []
        for marker in project.markers {
            let label = "“\(marker.name)”"
            if !validXMLText(marker.name) || !validXMLText(marker.note) { warnings.add(replaced, for: "marker \(label)") }
            if try !frameAligned(marker.time, rate: settings.frameRate) || !fits32([marker.time]) { warnings.add("Markers off the sequence frame grid are left out.", for: label) }
            else if try marker.time.compared(to: plan.duration) != .orderedAscending { warnings.add("Markers after the end of the sequence are left out.", for: label) }
            else { markers.append(marker) }
        }
        guard reasons.isEmpty else { throw FCPXMLExportError.unsupported(reasons + warnings.list) }
        let items = candidates.filter { exported.contains($0.clipID) }
        let assets = project.assets.filter { asset in items.contains { $0.assetID == asset.id } }

        let refs = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, "r\($0.offset + 2)") })
        // Final Cut's built-in Cross Dissolve and Audio Crossfade transitions.
        let dissolveEffect = "r\(assets.count + 2)", crossfadeEffect = "r\(assets.count + 3)"
        let usesTransitions = !cuts.transitions.isEmpty
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<!DOCTYPE fcpxml>", "<fcpxml version=\"1.10\">", "  <resources>",
                     "    <format id=\"r1\"\(formatName(settings).map { " name=\"\($0)\"" } ?? "") frameDuration=\"\(time(frameDuration))\" width=\"\(settings.width)\" height=\"\(settings.height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>"]
        for asset in assets {
            let hasVideo = asset.streams.contains { $0.kind == .video }
            let audio = asset.streams.filter { $0.kind == .audio }
            var attributes = "id=\"\(refs[asset.id]!)\" name=\"\(attribute(asset.name))\" start=\"\(time(asset.sourceTimecodeStart ?? .zero))\" duration=\"\(time(asset.duration))\" hasVideo=\"\(hasVideo ? 1 : 0)\" hasAudio=\"\(audio.isEmpty ? 0 : 1)\""
            if hasVideo { attributes += " videoSources=\"\(asset.streams.filter { $0.kind == .video }.count)\"" }
            if !audio.isEmpty { attributes += " audioSources=\"\(audio.count)\" audioChannels=\"\(audio.reduce(0) { $0 + ($1.audioLayout?.channels.count ?? 0) })\"" }
            // Source raster, source frame rate, and source sample rate are not present in
            // MediaAsset. Do not invent them from the sequence settings; FCP probes the original.
            lines.append("    <asset \(attributes)>")
            // Receiving editors may not follow symlinks such as /tmp → /private/tmp (Resolve leaves such
            // media offline), so reference the resolved file.
            lines.append("      <media-rep kind=\"original-media\" src=\"\(attribute(asset.originalURL!.interchangeFileURL.absoluteString))\"/>")
            lines.append("    </asset>")
        }
        if usesTransitions {
            lines.append("    <effect id=\"\(dissolveEffect)\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>")
            lines.append("    <effect id=\"\(crossfadeEffect)\" name=\"Audio Crossfade\" uid=\"FFAudioTransition\"/>")
        }
        lines += ["  </resources>", "  <library>", "    <event name=\"Aagedal Film Constructor\">", "      <project name=\"\(attribute(projectName))\">",
                  "        <sequence format=\"r1\" duration=\"\(time(plan.duration))\" tcStart=\"\(time(tcStart))\" tcFormat=\"\(settings.startTimecode.mode == .dropFrame ? "DF" : "NDF")\" audioLayout=\"\(settings.audioLayout == .mono ? "mono" : settings.audioLayout == .stereo ? "stereo" : "surround")\" audioRate=\"\(rates[settings.audioSampleRate]!)\">",
                  "          <spine>", "            <gap name=\"Sequence bed\" offset=\"\(time(tcStart))\" start=\"0s\" duration=\"\(time(plan.duration))\">"]
        let videoTracks = project.tracks.filter { $0.kind == .video }
        let audioTracks = project.tracks.filter { $0.kind == .audio }
        func edges(_ clipID: UUID) -> [RationalTime?] {
            let a = cuts.transition(incoming: clipID), b = cuts.transition(outgoing: clipID)
            return [a?.before, a?.after, b?.before, b?.after]
        }
        // Picture and sound from the same source moment travel as one A/V asset-clip, as Final
        // Cut writes them. Resolve ignores srcEnable, so split clips would duplicate media there.
        // A pair must also share its transitions, which then cover both picture and sound.
        var mergedAudio: Set<Int> = []
        var pairedAudio: [Int: Int] = [:]
        for (index, component) in items.enumerated() where !component.selection.isAudio && component.selection != .still {
            if let match = items.indices.first(where: { candidate in
                let other = items[candidate]
                return other.selection.isAudio && !mergedAudio.contains(candidate) && other.assetID == component.assetID
                    && other.sourceRange == component.sourceRange && other.timelineRange == component.timelineRange
                    && other.speed == component.speed && edges(other.clipID) == edges(component.clipID)
            }) {
                mergedAudio.insert(match); pairedAudio[index] = match
            }
        }
        // A transition joins two A/V clips or two separate ones, never one of each: otherwise the
        // sound's crossfade would lose a side. Split pairs until every transition agrees.
        let indexOfClip = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.clipID, $0.offset) })
        func pairing(_ index: Int) -> Int? {
            if let audio = pairedAudio[index] { return audio }
            return pairedAudio.first { $0.value == index }?.value
        }
        var settled = false
        while !settled {
            settled = true
            for transition in cuts.transitions {
                guard let out = indexOfClip[transition.relation.outgoingClipID], let into = indexOfClip[transition.relation.incomingClipID] else { continue }
                let outAudio = pairing(out), intoAudio = pairing(into)
                let joined = outAudio.flatMap { a in intoAudio.map { b in cuts.transition(outgoing: items[a].clipID)?.relation.incomingClipID == items[b].clipID } }
                guard (outAudio == nil) != (intoAudio == nil) || joined == false else { continue }
                for index in [out, into] {
                    if let key = pairedAudio.first(where: { $0.key == index || $0.value == index })?.key {
                        mergedAudio.remove(pairedAudio[key]!); pairedAudio[key] = nil
                    }
                }
                settled = false
            }
        }
        func lane(_ component: TimelineRenderPlan.Component) -> Int {
            component.selection.isAudio ? -(audioTracks.firstIndex { $0.id == component.trackID }! + 1)
                : videoTracks.count - videoTracks.firstIndex { $0.id == component.trackID }!
        }
        /// One asset-clip; inside a storyline it has no lane of its own.
        func clipLines(_ index: Int, inStoryline: Bool) throws -> [String] {
            let component = items[index]
            let asset = assets.first { $0.id == component.assetID }!
            let origin = asset.sourceTimecodeStart ?? .zero
            let isAudio = component.selection.isAudio
            let paired = pairedAudio[index] != nil
            let enable = paired ? "" : " srcEnable=\"\(isAudio ? "audio" : "video")\""
            // A retimed clip's start is in its own retimed time, which the time map relates to the media.
            let start = component.speed == .one ? try component.sourceRange.start.adding(origin) : try localTime(component.sourceRange.start, speed: component.speed, origin: origin)
            let attributes = "ref=\"\(refs[asset.id]!)\" name=\"\(attribute(asset.name))\"\(inStoryline ? "" : " lane=\"\(lane(component))\"") offset=\"\(time(component.timelineRange.start))\" start=\"\(time(start))\" duration=\"\(time(component.sourceRange.duration))\"\(enable)"
            let channels = pairedAudio[index].flatMap { channelSource(items[$0], asset: asset) } ?? channelSource(component, asset: asset)
            var timing: [String] = []
            if component.speed != .one {
                timing = ["                <timeMap>",
                          "                  <timept time=\"\(time(origin))\" value=\"\(time(origin))\" interp=\"linear\"/>",
                          "                  <timept time=\"\(time(try localTime(asset.duration, speed: component.speed, origin: origin)))\" value=\"\(time(try asset.duration.adding(origin)))\" interp=\"linear\"/>",
                          "                </timeMap>"]
            }
            var lines: [String] = []
            if isAudio {
                let volume = volumeAdjustment(component, origin: origin)
                if channels != nil || !volume.isEmpty || !timing.isEmpty {
                    lines += ["              <asset-clip \(attributes) audioRole=\"dialogue\">"] + timing + volume
                        + (channels.map { ["                \($0)"] } ?? []) + ["              </asset-clip>"]
                } else { lines.append("              <asset-clip \(attributes) audioRole=\"dialogue\"/>") }
            } else {
                lines.append("              <asset-clip \(attributes)\(paired ? " audioRole=\"dialogue\"" : "")>")
                lines += timing
                lines.append("                <adjust-conform type=\"\(component.scalingMode.rawValue)\"/>")
                lines += pictureAdjustments(component, settings: settings, origin: origin)
                if let pair = pairedAudio[index] { lines += volumeAdjustment(items[pair], origin: origin) }
                if let channels { lines.append("                \(channels)") }
                lines.append("              </asset-clip>")
            }
            return inStoryline ? lines.map { "  " + $0 } : lines
        }
        let written = items.indices.filter { !mergedAudio.contains($0) }
        let storylineTracks = Set(cuts.transitions.map(\.trackID))
        var writtenStorylines: Set<UUID> = []
        for index in written {
            let component = items[index]
            guard storylineTracks.contains(component.trackID) else { lines += try clipLines(index, inStoryline: false); continue }
            guard writtenStorylines.insert(component.trackID).inserted else { continue }
            // A track with transitions is a connected storyline from the bed's start, so its
            // children share the bed's time; gaps hold clips at their places.
            let track = project.tracks.first { $0.id == component.trackID }!
            lines.append("              <spine lane=\"\(lane(component))\" offset=\"0s\" name=\"\(attribute(track.displayName(in: project)))\">")
            var cursor = RationalTime.zero
            for member in written where items[member].trackID == component.trackID {
                let item = items[member]
                let gap = try item.timelineRange.start.subtracting(cursor)
                if gap.numerator > 0 {
                    lines.append("                <gap name=\"Gap\" offset=\"\(time(cursor))\" start=\"0s\" duration=\"\(time(gap))\"/>")
                }
                lines += try clipLines(member, inStoryline: true)
                cursor = try item.timelineRange.end()
                if let transition = cuts.transition(outgoing: item.clipID) {
                    let video = !item.selection.isAudio
                    let sound = item.selection.isAudio || pairedAudio[member] != nil
                    lines.append("                <transition name=\"\(video ? "Cross Dissolve" : "Audio Crossfade")\" offset=\"\(time(transition.start))\" duration=\"\(time(try transition.before.adding(transition.after)))\">")
                    if video { lines.append("                  <filter-video ref=\"\(dissolveEffect)\" name=\"Cross Dissolve\"/>") }
                    if sound { lines.append("                  <filter-audio ref=\"\(crossfadeEffect)\" name=\"Audio Crossfade\"/>") }
                    lines.append("                </transition>")
                }
            }
            lines.append("              </spine>")
        }
        // Sequence markers sit on the bed, after its anchored clips, one frame long as Final Cut writes them.
        for marker in markers {
            lines.append("              <marker start=\"\(time(marker.time))\" duration=\"\(time(frameDuration))\" value=\"\(attribute(marker.name))\"\(marker.note.isEmpty ? "" : " note=\"\(attribute(marker.note))\"")/>")
        }
        lines += ["            </gap>", "          </spine>", "        </sequence>", "      </project>", "    </event>", "  </library>", "</fcpxml>", ""]
        return FCPXMLExportResult(xml: lines.joined(separator: "\n"), report: FCPXMLExportReport(clipCount: items.count, assetCount: assets.count, notes: [
            "FCPXML 1.10 subset: original file references, exact sequence timing, layered video, and audio channel selections (audio-channel-source, channels numbered across the source's audio streams).",
            "Source raster, frame rate, orientation, pixel aspect, color metadata, and sample rate are inspected from original media by the receiving editor; mixed-rate and spatial conform equivalence have not been qualified.",
            "Linked picture and sound with identical timing are written as one A/V clip. DaVinci Resolve 21 and Final Cut Pro 11 import this subset with exact timing. Track families and editor preferences are not interchange metadata.",
            "Volume, fades, scale, position, opacity and their keyframes are written as Final Cut adjustments (position in percent of frame height, y up). They match Apple's DTD; their interpretation by receiving editors has not been verified. Equal-power fades are written as ease fades.",
            "Sequence markers are written as one-frame markers on the sequence bed with their name and note; marker colours are not part of FCPXML.",
            "Tracks with cross dissolves or crossfades are connected storylines with Final Cut's Cross Dissolve and Audio Crossfade at each cut; speed changes are linear time maps. Their import by receiving editors has not been verified."
        ], warnings: warnings.list))
    }

    private static func decimal(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
    private static func decibels(_ gain: Double) -> String { gain > 0 ? decimal(max(-96, 20 * log10(gain))) + "dB" : "-96dB" }
    private static func fades(_ component: TimelineRenderPlan.Component) -> [String] {
        func type(_ fade: AudioFade, _ eased: String) -> String { fade.curve == .linear ? " type=\"linear\"" : " type=\"\(eased)\"" }
        var result: [String] = []
        if component.fadeIn.duration != .zero { result.append("<fadeIn\(type(component.fadeIn, "easeIn")) duration=\"\(time(component.fadeIn.duration))\"/>") }
        if component.fadeOut.duration != .zero { result.append("<fadeOut\(type(component.fadeOut, "easeOut")) duration=\"\(time(component.fadeOut.duration))\"/>") }
        return result
    }
    /// A clip's local time for a source time: the media clock, or for a retimed clip the time
    /// its time map plays that source moment.
    private static func localTime(_ source: RationalTime, speed: RationalTime, origin: RationalTime) throws -> RationalTime {
        try source.divided(by: speed).adding(origin)
    }
    /// A param element with optional fades and linear keyframes (times in the clip's source time).
    /// Final Cut Pro ignores a param whose keyframes carry `interp`, so only `curve` is written.
    private static func param(_ name: String, fades: [String], keyframes: [(RationalTime, String)], origin: RationalTime, speed: RationalTime = .one) throws -> [String] {
        guard !fades.isEmpty || !keyframes.isEmpty else { return [] }
        var lines = ["                  <param name=\"\(name)\">"] + fades.map { "                    \($0)" }
        if !keyframes.isEmpty {
            lines.append("                    <keyframeAnimation>")
            for (at, value) in keyframes {
                lines.append("                      <keyframe time=\"\(time(try localTime(at, speed: speed, origin: origin)))\" value=\"\(value)\" curve=\"linear\"/>")
            }
            lines.append("                    </keyframeAnimation>")
        }
        return lines + ["                  </param>"]
    }
    /// Scale and position (adjust-transform) and opacity with fades (adjust-blend).
    private static func pictureAdjustments(_ component: TimelineRenderPlan.Component, settings: SequenceSettings, origin: RationalTime) -> [String] {
        let aspect = Double(settings.width) / Double(settings.height)
        func position(_ x: Double, _ y: Double) -> String { "\(decimal(x * aspect * 100)) \(decimal(-y * 100))" }
        let t = component.transform, keys = component.transformKeyframes
        var lines: [String] = []
        if !t.isIdentity || !keys.isEmpty {
            let first = keys.first.map { (s: $0.scale, x: $0.offsetX, y: $0.offsetY) } ?? (s: t.scale, x: t.offsetX, y: t.offsetY)
            let positions = (try? param("position", fades: [], keyframes: keys.map { ($0.time, position($0.offsetX, $0.offsetY)) }, origin: origin, speed: component.speed)) ?? []
            let scales = (try? param("scale", fades: [], keyframes: keys.map { ($0.time, "\(decimal($0.scale)) \(decimal($0.scale))") }, origin: origin, speed: component.speed)) ?? []
            let inner = positions + scales
            let open = "                <adjust-transform position=\"\(position(first.x, first.y))\" scale=\"\(decimal(first.s)) \(decimal(first.s))\""
            lines += inner.isEmpty ? [open + "/>"] : [open + ">"] + inner.map { String($0.dropFirst(2)) } + ["                </adjust-transform>"]
        }
        let opacityKeys = keys.contains { $0.opacity != 1 } ? keys.map { ($0.time, decimal(t.opacity * $0.opacity)) } : []
        let fadeLines = fades(component)
        if t.opacity != 1 || !opacityKeys.isEmpty || !fadeLines.isEmpty {
            let inner = (try? param("amount", fades: fadeLines, keyframes: opacityKeys, origin: origin, speed: component.speed)) ?? []
            let open = "                <adjust-blend amount=\"\(decimal(t.opacity))\""
            lines += inner.isEmpty ? [open + "/>"] : [open + ">"] + inner.map { String($0.dropFirst(2)) } + ["                </adjust-blend>"]
        }
        return lines
    }
    /// Clip and track gain, fades and volume keyframes as one adjust-volume.
    private static func volumeAdjustment(_ component: TimelineRenderPlan.Component, origin: RationalTime) -> [String] {
        let keys = component.volumeKeyframes.map { ($0.time, decibels(component.gain * $0.gain)) }
        let fadeLines = fades(component)
        guard component.gain != 1 || !keys.isEmpty || !fadeLines.isEmpty else { return [] }
        let inner = (try? param("amount", fades: fadeLines, keyframes: keys, origin: origin, speed: component.speed)) ?? []
        let open = "                <adjust-volume amount=\"\(decibels(component.gain))\""
        return inner.isEmpty ? [open + "/>"] : [open + ">"] + inner.map { String($0.dropFirst(2)) } + ["                </adjust-volume>"]
    }

    /// Final Cut's named progressive SDR formats (from Final Cut Pro 11's format registry).
    /// Final Cut warns on an unnamed sequence format; other rasters stay custom formats.
    private static let finalCutRasters: [String: Set<String>] = {
        let all = ["2398", "24", "25", "2997", "30", "50", "5994", "60"]
        let film = ["2398", "24", "2997", "30", "5994", "60"]
        var table: [String: Set<String>] = [:]
        for raster in ["1080", "720", "1440x1080", "2048x1024", "2048x1080", "2048x1152", "2048x1536", "2048x1556",
                       "3840x2160", "4096x2048", "4096x2160", "4096x2304", "4096x3112", "5120x2160", "5120x2560",
                       "5120x2700", "5760x2880", "7680x3840", "7680x4320", "8192x4320", "960x720"] { table[raster] = Set(all) }
        table["1280x1080"] = Set(film)
        for raster in ["640x480", "960x540"] { table[raster] = ["2398", "24", "25", "2997", "30"] }
        return table
    }()
    static func formatName(_ settings: SequenceSettings) -> String? {
        let rates: [RationalTime: String] = [try! RationalTime(24000, 1001): "2398", try! RationalTime(24): "24", try! RationalTime(25): "25",
            try! RationalTime(30000, 1001): "2997", try! RationalTime(30): "30", try! RationalTime(50): "50",
            try! RationalTime(60000, 1001): "5994", try! RationalTime(60): "60"]
        guard let token = rates[settings.frameRate.value] else { return nil }
        let raster = settings.width == 1920 && settings.height == 1080 ? "1080"
            : settings.width == 1280 && settings.height == 720 ? "720" : "\(settings.width)x\(settings.height)"
        guard finalCutRasters[raster]?.contains(token) == true else { return nil }
        return "FFVideoFormat\(raster)p\(token)"
    }
    /// 1-based channel numbers across the asset's audio streams in stream order, as FCPXML
    /// srcCh counts them; nil if a channel is missing. Whole single-stream identity needs no list.
    static func channelNumbers(_ selection: AudioSourceSelection, asset: MediaAsset) -> [Int]? {
        var first: [Int: Int] = [:], next = 1
        for stream in asset.streams where stream.kind == .audio {
            first[stream.index] = next
            next += stream.audioLayout?.channels.count ?? 0
        }
        var numbers: [Int] = []
        for channel in selection.channels {
            guard let base = first[channel.streamIndex],
                  let stream = asset.streams.first(where: { $0.index == channel.streamIndex }),
                  let count = stream.audioLayout?.channels.count, (0..<count).contains(channel.channelIndex) else { return nil }
            numbers.append(base + channel.channelIndex)
        }
        return numbers
    }
    private static func channelSource(_ component: TimelineRenderPlan.Component, asset: MediaAsset) -> String? {
        guard case .audio(let selection) = component.selection, let numbers = channelNumbers(selection, asset: asset) else { return nil }
        let audio = asset.streams.filter { $0.kind == .audio }
        let total = audio.reduce(0) { $0 + ($1.audioLayout?.channels.count ?? 0) }
        if audio.count == 1, numbers == Array(1...max(1, total)) { return nil }
        // Mono duplicated to every output is how editors already play a mono channel.
        let unique = numbers.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        let channels = (unique.count == 1 ? unique : numbers).map(String.init).joined(separator: ", ")
        return "<audio-channel-source srcCh=\"\(channels)\" role=\"dialogue\"/>"
    }
    private static func frameAligned(_ value: RationalTime, rate: FrameRate) throws -> Bool {
        try value.multiplied(by: rate.value).denominator == 1
    }
    private static func time(_ value: RationalTime) -> String {
        value.denominator == 1 ? "\(value.numerator)s" : "\(value.numerator)/\(value.denominator)s"
    }
    private static func validXMLText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 || (32...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        }
    }
    private static func attribute(_ text: String) -> String {
        let valid = validXMLText(text) ? text : String(String.UnicodeScalarView(text.unicodeScalars.map { validXMLText(String($0)) ? $0 : "\u{FFFD}" }))
        return valid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\r", with: "&#13;")
    }
}

private extension ClipSelection {
    var isAudio: Bool { if case .audio = self { return true }; return false }
}

extension URL {
    /// The on-disk path for interchange references. Foundation's resolvingSymlinksInPath()
    /// maps /private/tmp back to /tmp, which receiving editors such as Resolve can't open.
    var interchangeFileURL: URL {
        guard isFileURL, let resolved = realpath(path, nil) else { return self }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}
