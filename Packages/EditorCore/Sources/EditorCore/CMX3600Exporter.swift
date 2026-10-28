import Foundation

/// Caller-supplied source timing evidence. No values are inferred from sequence settings.
/// For video, constantFrameRate must describe verified source frame timing, not a nominal rate tag.
public struct CMX3600SourceTiming: Equatable, Sendable {
    public let frameRate: FrameRate
    public let startTimecode: Timecode
    public let reelName: String
    public let streamIndex: Int
    public let constantFrameRate: Bool
    public init(frameRate: FrameRate, startTimecode: Timecode, reelName: String, streamIndex: Int, constantFrameRate: Bool = false) {
        self.frameRate = frameRate; self.startTimecode = startTimecode; self.reelName = reelName
        self.streamIndex = streamIndex; self.constantFrameRate = constantFrameRate
    }
}

public struct CMX3600ExportReport: Equatable, Sendable {
    public let trackID: UUID
    public let clipCount: Int
    public let gapCount: Int
    public let eventCount: Int
    public let notes: [String]
    /// Edits the file leaves out or simplifies, to show before saving.
    public let warnings: [String]
}
public struct CMX3600ExportResult: Equatable, Sendable {
    public let edl: String
    public let report: CMX3600ExportReport
}
public enum CMX3600ExportError: Error, Equatable, Sendable, LocalizedError {
    case unsupported([String])
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reasons):
            return "This track cannot be exported to CMX3600 EDL:\n" + reasons.map { "• " + $0 }.joined(separator: "\n")
        }
    }
}

/// Cuts, dissolves, fades and speed changes of one explicitly selected track, never a flattened sequence.
/// Edits the format cannot carry are left out and listed in the report's warnings; timing is never
/// rounded, so a clip off the grid is left out rather than moved. All out points are exclusive.
public enum CMX3600Exporter {
    public static func export(project: Project, trackID: UUID, projectName: String = "Sequence", sourceTiming: [UUID: CMX3600SourceTiming] = [:]) throws -> CMX3600ExportResult {
        try project.validate()
        guard let track = project.tracks.first(where: { $0.id == trackID }) else {
            throw CMX3600ExportError.unsupported(["Select an existing timeline track."])
        }
        let settings = project.settings
        let rate = settings.frameRate
        var reasons: [String] = []
        var warnings = ExportWarnings()
        let supportedRates = [try FrameRate(24), try FrameRate(24000, 1001), try FrameRate(25), try FrameRate(30), try FrameRate(30000, 1001)]
        if !supportedRates.contains(rate) { reasons.append("Supported sequence rates are 24, 24000/1001, 25, 30 and 30000/1001 fps.") }
        if !lineText(projectName) { reasons.append("The title must be nonempty printable ASCII on one line.") }
        if track.clips.isEmpty { reasons.append("The selected track has no clips.") }
        if track.template.gain != 1 { warnings.add("Track gain is not exported.") }
        let channel: String
        if track.kind == .video { channel = "V" }
        else {
            channel = track.audioLayout == .stereo ? "AA" : "A"
            if track.audioLayout != .mono && track.audioLayout != .stereo { reasons.append("Only complete mono or stereo audio tracks are supported.") }
            if track.template.effects.contains(where: \.isActive) { warnings.add("Track effects are not exported.") }
            if let layout = track.audioLayout, !track.template.routing.isDefaultPlacement(of: layout, in: project.settings.audioLayout) {
                warnings.add("Audio output channel remapping is not exported.")
            }
        }
        var cuts = try project.interchangeCuts()
        let assetName = { (clipID: UUID) in project.assets.first { $0.id == project.tracks.flatMap(\.clips).first { $0.id == clipID }?.assetID }?.name ?? "Clip" }
        let trackOfClip = Dictionary(uniqueKeysWithValues: project.tracks.flatMap { track in track.clips.map { ($0.id, track.id) } })
        cuts.transitions.removeAll { transition in
            let relation = transition.relation
            guard trackOfClip[relation.outgoingClipID] == trackID || trackOfClip[relation.incomingClipID] == trackID else { return false }
            let name = assetName(trackOfClip[relation.incomingClipID] == trackID ? relation.incomingClipID : relation.outgoingClipID)
            guard transition.trackID == trackID, trackOfClip[relation.incomingClipID] == trackID else {
                warnings.add("Crossfades with a clip on another track are exported as cuts.", for: name); return true
            }
            guard let before = try? frames(transition.before, rate: rate), let after = try? frames(transition.after, rate: rate) else {
                warnings.add("Dissolves off the frame grid are exported as cuts.", for: name); return true
            }
            guard before + after <= 999 else { warnings.add("Dissolves longer than 999 frames are exported as cuts.", for: name); return true }
            if relation.style != nil { warnings.add("Slide, push and wipe transitions are exported as dissolves.", for: name) }
            return false
        }
        let clips = try track.clips.sorted { try cuts.ranges[$0.id]!.timeline.start.compared(to: cuts.ranges[$1.id]!.timeline.start) == .orderedAscending }
        /// One edit line. A dissolve event has a zero-length line for the outgoing source (or BL)
        /// followed by a `D` line for the incoming one.
        struct Line {
            let reel: String
            let sourceIn: Int64
            let sourceOut: Int64
            let recordIn: Int64
            let recordOut: Int64
            var dissolve: Int64? = nil
            var name: String? = nil
            /// Motion-effect speed in timecode frames per second, for an M2 line.
            var speed: String? = nil
        }
        struct Event {
            var lines: [Line]
            var recordIn: Int64 { lines.last!.recordIn }
            var recordOut: Int64 { lines.last!.recordOut }
        }
        /// A clip's record span (sequence frames from zero), source mapping and edges.
        struct Placement {
            let id: UUID
            let reel: String
            let name: String
            let start: Int64
            let end: Int64
            let speed: String?
            let fadeIn: Int64
            let fadeOut: Int64
            /// Absolute source frame shown at a record frame, nil off the source frame grid.
            let sourceAt: (Int64) throws -> Int64?
        }
        var placements: [Placement] = []
        var reelOwners: [String: UUID] = [:]
        let dayFrames = framesPerDay(rate: rate, mode: settings.startTimecode.mode)
        func record(_ offset: Int64) throws -> Int64 {
            let sum = settings.startTimecode.frameCount.addingReportingOverflow(offset)
            guard !sum.overflow else { throw EditorCoreError.overflow }
            return sum.partialValue
        }
        for clip in clips {
            let asset = project.assets.first { $0.id == clip.assetID }!
            let name = asset.name
            func omit(_ why: String) { warnings.add("Clips left out: \(why)", for: name) }
            if clip.gain != 1 { warnings.add("Clip volume is not exported.", for: name) }
            if clip.dynamics != nil { warnings.add("Compression is not exported.", for: name) }
            if clip.key != nil { warnings.add("Keying is not exported.", for: name) }
            if !clip.eq.isFlat { warnings.add("EQ is not exported.", for: name) }
            if clip.stabilization != nil { warnings.add("Stabilisation is not exported.", for: name) }
            if !clip.volumeKeyframes.isEmpty { warnings.add("Volume keyframes are not exported.", for: name) }
            if !clip.color.isNeutral { warnings.add("Colour correction is not exported.", for: name) }
            if !clip.transform.isIdentity || !clip.transformKeyframes.isEmpty { warnings.add("Scale, position and opacity are not exported.", for: name) }
            // Clip names are comments only: characters outside printable ASCII become “?”.
            var commentName = String(String.UnicodeScalarView(name.unicodeScalars.map { (32...126).contains($0.value) ? $0 : "?" }))
            if !lineText(name) {
                warnings.add("Clip names outside printable ASCII on one line are written with “?” in place of other characters.", for: name)
                if commentName.trimmingCharacters(in: .whitespaces).isEmpty { commentName = "Clip" }
            }
            // Speed is written as an M2 motion effect in timecode frames per second, to one decimal.
            var speedText: String?
            if clip.speed != .one {
                let tenths = try clip.speed.multiplied(by: RationalTime(Int64(rate.nominalFramesPerSecond) * 10))
                if tenths.denominator != 1 || tenths.numerator > 9999 { omit("the speed must be a whole tenth of a frame per second, up to 999.9."); continue }
                speedText = String(format: "%03d.%d", tenths.numerator / 10, tenths.numerator % 10)
            }
            guard let timing = sourceTiming[asset.id] else {
                omit("verified source frame rate, start timecode and reel identity are required."); continue
            }
            if timing.frameRate != rate { omit("source and sequence frame rates must match exactly."); continue }
            if timing.startTimecode.mode != settings.startTimecode.mode { omit("source and record timecode modes must match."); continue }
            do { try timing.startTimecode.validate(rate: timing.frameRate) }
            catch { omit("source timecode is invalid for its frame rate."); continue }
            if let known = asset.sourceTimecode, known != timing.startTimecode { omit("timing evidence disagrees with stored source timecode."); continue }
            if !validReel(timing.reelName) { omit("reel names require 1–8 uppercase ASCII letters or digits; BL is reserved for gaps."); continue }
            if let owner = reelOwners[timing.reelName], owner != asset.id { omit("different assets cannot share a reel name."); continue }
            reelOwners[timing.reelName] = asset.id
            switch clip.selection {
            case .still: omit("still images are not supported."); continue
            case .video(let index):
                if asset.streams.filter({ $0.kind == .video }).count != 1 || timing.streamIndex != index { omit("exactly one video stream matching timing evidence is required."); continue }
                if !timing.constantFrameRate { omit("source constant-frame-rate timing has not been verified."); continue }
                if clip.scalingMode != .fit { warnings.add("Fill and unscaled geometry are not exported.", for: name) }
            case .audio(let selection):
                let streams = asset.streams.filter { $0.kind == .audio }
                guard let stream = streams.first, streams.count == 1, stream.index == timing.streamIndex, let layout = stream.audioLayout else {
                    omit("exactly one complete audio stream matching timing evidence is required."); continue
                }
                let identity = layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
                if selection.channels != identity || selection.layout != layout {
                    warnings.add("Partial, reordered or combined source audio channels are not exported; the reel's audio is referenced.", for: name)
                }
            }
            if asset.streams.first(where: { $0.index == timing.streamIndex })?.timeOffset != .zero { omit("nonzero or unknown source stream offsets are not supported."); continue }
            let editorial = cuts.ranges[clip.id]!
            guard let start = try frames(editorial.timeline.start, rate: rate), let duration = try frames(editorial.timeline.duration, rate: rate),
                  try frames(editorial.source.start, rate: rate) != nil else {
                omit("source and record endpoints must lie exactly on frame boundaries; export never rounds."); continue
            }
            func fade(_ fade: AudioFade) throws -> Int64 {
                if let count = try frames(fade.duration, rate: rate) { return count }
                warnings.add("Fades off the frame grid are left out.", for: name)
                return 0
            }
            let fadeIn = try fade(clip.fadeIn), fadeOut = try fade(clip.fadeOut)
            let endSum = start.addingReportingOverflow(duration)
            guard !endSum.overflow else { throw EditorCoreError.overflow }
            let recordIn = try record(start), recordOut = try record(endSum.partialValue)
            if recordIn < 0 || recordOut >= dayFrames {
                omit("source and record timecodes must stay within one 24-hour day, including exclusive out points."); continue
            }
            let speed = clip.speed, isStill = clip.selection == .still, sourceStart = editorial.source.start, origin = timing.startTimecode.frameCount
            placements.append(Placement(id: clip.id, reel: timing.reelName, name: commentName, start: start, end: endSum.partialValue,
                                        speed: speedText, fadeIn: fadeIn, fadeOut: fadeOut, sourceAt: { frame in
                let offset = try RationalTime(frame - start).divided(by: rate.value)
                let source = isStill ? sourceStart : try sourceStart.adding(offset.multiplied(by: speed))
                guard let count = try Self.frames(source, rate: rate) else { return nil }
                let sum = origin.addingReportingOverflow(count)
                guard !sum.overflow else { throw EditorCoreError.overflow }
                return sum.partialValue
            }))
        }

        var events: [Event] = []
        var gapCount = 0
        /// A clip found unwritable while building events: it is left out and the events rebuilt.
        var failure: (id: UUID, why: String)?
        var dropped: Set<UUID> = []
        func buildEvents() throws {
            events = []; gapCount = 0; failure = nil
            let live = placements.filter { !dropped.contains($0.id) }
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            var cursor: Int64 = 0
            // Builds a line, or records a failure for a source position off the frame grid or outside the day.
            func line(_ p: Placement, from: Int64, to: Int64, zeroLength: Bool = false) throws -> Line? {
                guard let sourceIn = try p.sourceAt(from), let sourceOut = try p.sourceAt(zeroLength ? from : to) else {
                    failure = (p.id, "at their speed, edit points must fall on whole source frames."); return nil
                }
                guard sourceIn >= 0 && sourceOut < dayFrames else {
                    failure = (p.id, "source timecodes must stay within one 24-hour day, including handles."); return nil
                }
                return Line(reel: p.reel, sourceIn: sourceIn, sourceOut: sourceOut, recordIn: try record(from), recordOut: try record(zeroLength ? from : to), name: p.name, speed: p.speed)
            }
            func black(from: Int64, frames: Int64) throws -> Line { Line(reel: "BL", sourceIn: 0, sourceOut: frames, recordIn: try record(from), recordOut: try record(from + frames)) }
            for p in live {
                // A dissolve whose other clip is left out becomes a cut.
                let incoming = cuts.transition(incoming: p.id).flatMap { byID[$0.relation.outgoingClipID] == nil ? nil : $0 }
                let outgoing = cuts.transition(outgoing: p.id).flatMap { byID[$0.relation.incomingClipID] == nil ? nil : $0 }
                // The last record frame this clip's own event covers: up to the next dissolve or fade out.
                var tail = p.end
                if let outgoing { tail = p.end - (try frames(outgoing.before, rate: rate) ?? 0) }
                else if p.fadeOut > 0 { tail = p.end - p.fadeOut }
                if let incoming, let previous = byID[incoming.relation.outgoingClipID] {
                    let before = try frames(incoming.before, rate: rate) ?? 0, after = try frames(incoming.after, rate: rate) ?? 0
                    let head = p.start - before
                    guard let from = try line(previous, from: head, to: head, zeroLength: true), var to = try line(p, from: head, to: tail) else { return }
                    to.dissolve = before + after
                    events.append(Event(lines: [from, to]))
                } else {
                    if p.start > cursor {
                        events.append(Event(lines: [try black(from: cursor, frames: p.start - cursor)]))
                        gapCount += 1
                    }
                    guard var own = try line(p, from: p.start, to: tail) else { return }
                    if p.fadeIn > 0 {
                        // A fade in is a dissolve from black.
                        own.dissolve = p.fadeIn
                        events.append(Event(lines: [try black(from: p.start, frames: 0), own]))
                    } else { events.append(Event(lines: [own])) }
                }
                if outgoing == nil && p.fadeOut > 0 {
                    // A fade out is a dissolve to black.
                    guard let from = try line(p, from: tail, to: tail, zeroLength: true) else { return }
                    var to = try black(from: tail, frames: p.fadeOut)
                    to.dissolve = p.fadeOut
                    events.append(Event(lines: [from, to]))
                }
                cursor = outgoing == nil ? p.end : tail
            }
        }
        while true {
            try buildEvents()
            guard let failure else { break }
            dropped.insert(failure.id)
            warnings.add("Clips left out: \(failure.why)", for: track.clips.first { $0.id == failure.id }.map { assetName($0.id) } ?? "Clip")
        }
        if !track.clips.isEmpty && placements.count == dropped.count { reasons.append("None of the selected track's clips can be exported.") }
        if events.count > 999 { reasons.append("The selected track exceeds 999 CMX3600 events, including gap events.") }
        // Sequence markers become locator comments under the event that contains them.
        var locators: [Int: [(record: Int64, color: String, text: String)]] = [:]
        for marker in project.markers {
            let label = "“\(marker.name)”"
            var text = marker.note.isEmpty ? marker.name : "\(marker.name) - \(marker.note)"
            if !text.isEmpty && !lineText(text) {
                warnings.add("Marker text outside printable ASCII on one line is written with “?” in place of other characters.", for: label)
                text = String(String.UnicodeScalarView(text.unicodeScalars.map { (32...126).contains($0.value) ? $0 : "?" }))
            }
            guard let offset = try frames(marker.time, rate: rate) else {
                warnings.add("Markers off the sequence frame grid are left out.", for: label); continue
            }
            let recordTime = try record(offset)
            guard let index = events.firstIndex(where: { $0.recordIn <= recordTime && recordTime < $0.recordOut }) else {
                warnings.add("Markers after the selected track's final clip are left out.", for: label); continue
            }
            locators[index, default: []].append((recordTime, marker.color.cmxLocatorColor, text))
        }
        guard reasons.isEmpty else { throw CMX3600ExportError.unsupported(reasons + warnings.list) }
        func timecode(_ count: Int64) throws -> String {
            // CMX uses the FCM header to declare counting mode and colon-separated labels.
            try Timecode(frameCount: count, mode: settings.startTimecode.mode).formatted(rate: rate).replacingOccurrences(of: ";", with: ":")
        }
        var lines = ["TITLE: \(projectName)", "FCM: \(settings.startTimecode.mode == .dropFrame ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        for (index, event) in events.enumerated() {
            let number = String(format: "%03d", index + 1)
            for line in event.lines {
                let reel = line.reel.padding(toLength: 8, withPad: " ", startingAt: 0)
                let kind = line.dissolve.map { "D    " + String(format: "%03d", $0) } ?? "C       "
                lines.append("\(number)  \(reel) \(channel)  \(kind) \(try timecode(line.sourceIn)) \(try timecode(line.sourceOut)) \(try timecode(line.recordIn)) \(try timecode(line.recordOut))")
            }
            for line in event.lines {
                if let speed = line.speed {
                    lines.append("M2   \(line.reel.padding(toLength: 8, withPad: " ", startingAt: 0))       \(speed)                \(try timecode(line.sourceIn))")
                }
            }
            let names = event.lines.compactMap(\.name)
            if event.lines.count == 2, event.lines[1].name != nil {
                if let name = event.lines[0].name { lines.append("* FROM CLIP NAME: \(name)") }
                lines.append("* TO CLIP NAME: \(event.lines[1].name!)")
            } else if let name = names.first { lines.append("* FROM CLIP NAME: \(name)") }
            for locator in locators[index] ?? [] {
                lines.append("* LOC: \(try timecode(locator.record)) \(locator.color.padding(toLength: 7, withPad: " ", startingAt: 0)) \(locator.text)")
            }
            lines.append("")
        }
        return CMX3600ExportResult(edl: lines.joined(separator: "\n"), report: CMX3600ExportReport(trackID: trackID, clipCount: placements.count - dropped.count, gapCount: gapCount, eventCount: events.count, notes: [
            "One selected track only: cuts and explicit BL gaps through its final clip; other tracks and the sequence tail are excluded.",
            "Dissolves and crossfades are dissolve events centred on their cuts; fades are dissolves from or to BL; speed changes are M2 lines in timecode frames per second.",
            "Configure the receiving editor to the exact sequence frame rate \(rate.value.numerator)/\(rate.value.denominator). CMX3600 does not encode an exact rational rate.",
            "Reel identities and clip-name comments aid manual media matching; paths, geometry, track families and link groups are not preserved.",
            "Native editor import and media conform have not been qualified.",
            "Sequence markers are written as Avid-style * LOC: comments at record timecode under the event that contains them; orange, purple and pink use the nearest locator colour."
        ], warnings: warnings.list))
    }
    private static func frames(_ time: RationalTime, rate: FrameRate) throws -> Int64? {
        let result = try time.multiplied(by: rate.value)
        return result.denominator == 1 ? result.numerator : nil
    }
    private static func framesPerDay(rate: FrameRate, mode: TimecodeMode) -> Int64 {
        let fps = Int64(rate.nominalFramesPerSecond)
        return mode == .dropFrame ? (fps * 600 - (fps / 15) * 9) * 144 : fps * 86_400
    }
    private static func lineText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && value.utf8.allSatisfy { (32...126).contains($0) }
    }
    private static func validReel(_ value: String) -> Bool {
        (1...8).contains(value.utf8.count) && value != "BL" && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
}

private extension MarkerColor {
    /// The classic eight Avid locator colours.
    var cmxLocatorColor: String {
        switch self {
        case .red, .orange: "RED"
        case .yellow: "YELLOW"
        case .green: "GREEN"
        case .cyan: "CYAN"
        case .blue: "BLUE"
        case .purple, .pink: "MAGENTA"
        }
    }
}
