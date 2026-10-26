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

/// Cuts-only interchange of one explicitly selected track, never a flattened sequence.
/// Rejects unrepresentable edits before returning any text; all out points are exclusive.
public enum CMX3600Exporter {
    public static func export(project: Project, trackID: UUID, projectName: String = "Sequence", sourceTiming: [UUID: CMX3600SourceTiming] = [:]) throws -> CMX3600ExportResult {
        try project.validate()
        guard let track = project.tracks.first(where: { $0.id == trackID }) else {
            throw CMX3600ExportError.unsupported(["Select an existing timeline track."])
        }
        let settings = project.settings
        let rate = settings.frameRate
        var reasons: [String] = []
        let supportedRates = [try FrameRate(24), try FrameRate(24000, 1001), try FrameRate(25), try FrameRate(30), try FrameRate(30000, 1001)]
        if !supportedRates.contains(rate) { reasons.append("Supported sequence rates are 24, 24000/1001, 25, 30 and 30000/1001 fps.") }
        if !lineText(projectName) { reasons.append("The title must be nonempty printable ASCII on one line.") }
        if track.clips.isEmpty { reasons.append("The selected track has no clips.") }
        if track.template.gain != 1 { reasons.append("Track gain must be unity.") }
        let channel: String
        if track.kind == .video { channel = "V" }
        else {
            channel = track.audioLayout == .stereo ? "AA" : "A"
            if track.audioLayout != .mono && track.audioLayout != .stereo { reasons.append("Only complete mono or stereo audio tracks are supported.") }
            let identity = Array(0..<(track.audioLayout?.channels.count ?? 0))
            if !track.template.routing.outputChannels.isEmpty && track.template.routing.outputChannels != identity {
                reasons.append("Audio output channel remapping is not supported.")
            }
        }
        let selectedIDs = Set(track.clips.map(\.id))
        if project.audioCrossfades.contains(where: { selectedIDs.contains($0.incomingClipID) || selectedIDs.contains($0.outgoingClipID) }) {
            reasons.append("The selected track participates in an audio crossfade.")
        }
        let clips = try track.clips.sorted { try $0.timelineStart.compared(to: $1.timelineStart) == .orderedAscending }
        struct Event {
            let reel: String
            let sourceIn: Int64
            let sourceOut: Int64
            let recordIn: Int64
            let recordOut: Int64
            let name: String?
        }
        var events: [Event] = []
        var cursor: Int64 = 0
        var gapCount = 0
        var reelOwners: [String: UUID] = [:]
        let dayFrames = framesPerDay(rate: rate, mode: settings.startTimecode.mode)
        func record(_ offset: Int64) throws -> Int64 {
            let sum = settings.startTimecode.frameCount.addingReportingOverflow(offset)
            guard !sum.overflow else { throw EditorCoreError.overflow }
            return sum.partialValue
        }
        for clip in clips {
            let asset = project.assets.first { $0.id == clip.assetID }!
            let label = "Clip \(clip.id.uuidString) (\(asset.name))"
            let priorReasonCount = reasons.count
            if clip.fadeIn.duration != .zero || clip.fadeOut.duration != .zero { reasons.append("\(label): fades are not supported.") }
            if clip.gain != 1 { reasons.append("\(label): clip volume must be unity.") }
            if !clip.transform.isIdentity { reasons.append("\(label): scale, position and opacity are not supported.") }
            if !lineText(asset.name) { reasons.append("\(label): the clip name must be nonempty printable ASCII on one line.") }
            guard let timing = sourceTiming[asset.id] else {
                reasons.append("\(label): verified source frame rate, start timecode and reel identity are required.")
                continue
            }
            if timing.frameRate != rate { reasons.append("\(label): source and sequence frame rates must match exactly.") }
            if timing.startTimecode.mode != settings.startTimecode.mode { reasons.append("\(label): source and record timecode modes must match.") }
            do { try timing.startTimecode.validate(rate: timing.frameRate) }
            catch { reasons.append("\(label): source timecode is invalid for its frame rate.") }
            if let known = asset.sourceTimecode, known != timing.startTimecode { reasons.append("\(label): timing evidence disagrees with stored source timecode.") }
            if !validReel(timing.reelName) { reasons.append("\(label): reel names require 1–8 uppercase ASCII letters or digits; BL is reserved for gaps.") }
            if let owner = reelOwners[timing.reelName], owner != asset.id { reasons.append("\(label): different assets cannot share a reel name.") }
            reelOwners[timing.reelName] = asset.id
            switch clip.selection {
            case .still: reasons.append("\(label): still images are not supported.")
            case .video(let index):
                if asset.streams.filter({ $0.kind == .video }).count != 1 || timing.streamIndex != index { reasons.append("\(label): exactly one video stream matching timing evidence is required.") }
                if !timing.constantFrameRate { reasons.append("\(label): source constant-frame-rate timing has not been verified.") }
                if clip.scalingMode != .fit { reasons.append("\(label): fill and unscaled geometry are not represented by cuts-only EDL.") }
            case .audio(let selection):
                let streams = asset.streams.filter { $0.kind == .audio }
                if let stream = streams.first, streams.count == 1, stream.index == timing.streamIndex, let layout = stream.audioLayout {
                    let identity = layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
                    if selection.channels != identity || selection.layout != layout { reasons.append("\(label): partial, reordered or combined source audio channels are not supported.") }
                } else { reasons.append("\(label): exactly one complete audio stream matching timing evidence is required.") }
            }
            if asset.streams.first(where: { $0.index == timing.streamIndex })?.timeOffset != .zero { reasons.append("\(label): nonzero or unknown source stream offsets are not supported.") }
            guard let start = try frames(clip.timelineStart, rate: rate), let duration = try frames(clip.sourceRange.duration, rate: rate),
                  let sourceStart = try frames(clip.sourceRange.start, rate: rate) else {
                reasons.append("\(label): source and record endpoints must lie exactly on frame boundaries; export never rounds.")
                continue
            }
            let sourceInSum = timing.startTimecode.frameCount.addingReportingOverflow(sourceStart)
            let sourceOutSum = sourceInSum.partialValue.addingReportingOverflow(duration)
            let endSum = start.addingReportingOverflow(duration)
            guard !sourceInSum.overflow, !sourceOutSum.overflow, !endSum.overflow else { throw EditorCoreError.overflow }
            let recordIn = try record(start), recordOut = try record(endSum.partialValue)
            if sourceInSum.partialValue < 0 || sourceOutSum.partialValue >= dayFrames || recordIn < 0 || recordOut >= dayFrames {
                reasons.append("\(label): source and record timecodes must stay within one 24-hour day, including exclusive out points.")
            }
            guard reasons.count == priorReasonCount else { continue }
            if start > cursor {
                events.append(Event(reel: "BL", sourceIn: 0, sourceOut: start - cursor, recordIn: try record(cursor), recordOut: recordIn, name: nil))
                gapCount += 1
            }
            events.append(Event(reel: timing.reelName, sourceIn: sourceInSum.partialValue, sourceOut: sourceOutSum.partialValue, recordIn: recordIn, recordOut: recordOut, name: asset.name))
            cursor = endSum.partialValue
        }
        if events.count > 999 { reasons.append("The selected track exceeds 999 CMX3600 events, including gap events.") }
        guard reasons.isEmpty else { throw CMX3600ExportError.unsupported(reasons) }
        func timecode(_ count: Int64) throws -> String {
            // CMX uses the FCM header to declare counting mode and colon-separated labels.
            try Timecode(frameCount: count, mode: settings.startTimecode.mode).formatted(rate: rate).replacingOccurrences(of: ";", with: ":")
        }
        var lines = ["TITLE: \(projectName)", "FCM: \(settings.startTimecode.mode == .dropFrame ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        for (index, event) in events.enumerated() {
            let number = String(format: "%03d", index + 1)
            let reel = event.reel.padding(toLength: 8, withPad: " ", startingAt: 0)
            lines.append("\(number)  \(reel) \(channel)  C        \(try timecode(event.sourceIn)) \(try timecode(event.sourceOut)) \(try timecode(event.recordIn)) \(try timecode(event.recordOut))")
            if let name = event.name { lines.append("* FROM CLIP NAME: \(name)") }
            lines.append("")
        }
        return CMX3600ExportResult(edl: lines.joined(separator: "\n"), report: CMX3600ExportReport(trackID: trackID, clipCount: clips.count, gapCount: gapCount, eventCount: events.count, notes: [
            "One selected track only: cuts and explicit BL gaps through its final clip; other tracks and the sequence tail are excluded.",
            "Configure the receiving editor to the exact sequence frame rate \(rate.value.numerator)/\(rate.value.denominator). CMX3600 does not encode an exact rational rate.",
            "Reel identities and clip-name comments aid manual media matching; paths, geometry, track families and link groups are not preserved.",
            "Native editor import and media conform have not been qualified."
        ]))
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
