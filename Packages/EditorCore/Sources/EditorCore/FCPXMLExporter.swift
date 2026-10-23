import Foundation

public struct FCPXMLExportReport: Equatable, Sendable {
    public let clipCount: Int
    public let assetCount: Int
    /// Qualification limits, which should be shown alongside a successful export.
    public let notes: [String]
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

/// A deliberately small FCPXML 1.10 interchange subset. Validation precedes serialization,
/// so callers never receive an XML document with silently omitted edits or channel mappings.
public enum FCPXMLExporter {
    public static func export(project: Project, projectName: String = "Sequence") throws -> FCPXMLExportResult {
        try project.validate()
        let plan = try TimelineRenderPlan(project: project)
        var reasons: [String] = []
        let settings = project.settings
        let rates = [32000: "32k", 44100: "44.1k", 48000: "48k", 88200: "88.2k", 96000: "96k", 176400: "176.4k", 192000: "192k"]
        if rates[settings.audioSampleRate] == nil { reasons.append("The sequence audio sample rate is not supported by FCPXML 1.10.") }
        if settings.audioLayout != .mono && settings.audioLayout != .stereo { reasons.append("Only mono and stereo sequence audio layouts are supported.") }
        if plan.components.isEmpty { reasons.append("The sequence has no clips.") }
        if !project.audioCrossfades.isEmpty { reasons.append("Audio crossfades are not supported.") }
        if !validXMLText(projectName) { reasons.append("The project name contains characters that XML 1.0 cannot represent.") }
        let frameDuration = try settings.frameRate.time(forFrames: 1)
        let tcStart = try settings.frameRate.time(forFrames: settings.startTimecode.frameCount)
        let usedIDs = Set(plan.components.map(\.assetID))
        let assets = project.assets.filter { usedIDs.contains($0.id) }
        for asset in assets {
            let label = "Media “\(asset.name)”"
            if !validXMLText(asset.name) { reasons.append("\(label) has a name that XML 1.0 cannot represent.") }
            guard let url = asset.originalURL, url.isFileURL, !url.path.isEmpty else {
                reasons.append("\(label) needs an original local file reference.")
                continue
            }
            if !validXMLText(url.absoluteString) { reasons.append("\(label) has an invalid XML file reference.") }
            if asset.sourceTimecode?.frameCount != nil && asset.sourceTimecode?.frameCount != 0 {
                reasons.append("\(label) has source timecode without a known source frame rate.")
            }
        }
        for component in plan.components {
            let asset = assets.first { $0.id == component.assetID }!
            let label = "Clip \(component.clipID.uuidString) (\(asset.name))"
            if component.fadeIn.duration != .zero || component.fadeOut.duration != .zero { reasons.append("\(label): audio fades are not supported.") }
            if component.gain != 1 { reasons.append("\(label): track gain must be unity.") }
            switch component.selection {
            case .still:
                reasons.append("\(label): still-image duration and geometry have not been qualified.")
            case .video(let index):
                let video = asset.streams.filter { $0.kind == .video }
                if video.count != 1 || video.first?.index != index { reasons.append("\(label): selecting among multiple video streams is not supported.") }
                if component.scalingMode == .none { reasons.append("\(label): unscaled geometry requires source raster metadata.") }
                if try !frameAligned(component.timelineRange.start, rate: settings.frameRate) || !frameAligned(component.timelineRange.duration, rate: settings.frameRate) {
                    reasons.append("\(label): video timeline positions and durations must fall on sequence frame boundaries.")
                }
                if video.first?.timeOffset != .zero { reasons.append("\(label): nonzero source stream offsets are not supported.") }
            case .audio(let selection):
                // Any selection of whole-asset channels is expressible as audio-channel-source srcCh.
                if Self.channelNumbers(selection, asset: asset) == nil { reasons.append("\(label): selected audio channels are missing from the source.") }
                if selection.layout != settings.audioLayout { reasons.append("\(label): the selected audio layout must match the sequence layout.") }
                for channel in selection.channels {
                    if asset.streams.first(where: { $0.index == channel.streamIndex })?.timeOffset != .zero {
                        reasons.append("\(label): nonzero source stream offsets are not supported."); break
                    }
                }
                let identity = Array(0..<selection.channels.count)
                if !component.routing.outputChannels.isEmpty && component.routing.outputChannels != identity { reasons.append("\(label): nonidentity output channel routing is not supported.") }
            }
        }
        if try !frameAligned(plan.duration, rate: settings.frameRate) { reasons.append("The sequence end must fall on a sequence frame boundary; export does not round or pad it.") }
        let times = [frameDuration, tcStart, plan.duration] + assets.map(\.duration) + assets.compactMap(\.sourceTimecodeStart) + plan.components.flatMap {
            [$0.sourceRange.start, $0.sourceRange.duration, $0.timelineRange.start]
        }
        if times.contains(where: { $0.denominator > Int64(Int32.max) }) { reasons.append("An exact time denominator exceeds the FCPXML 32-bit limit.") }
        guard reasons.isEmpty else { throw FCPXMLExportError.unsupported(reasons) }

        let refs = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, "r\($0.offset + 2)") })
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
        lines += ["  </resources>", "  <library>", "    <event name=\"Aagedal Film Constructor\">", "      <project name=\"\(attribute(projectName))\">",
                  "        <sequence format=\"r1\" duration=\"\(time(plan.duration))\" tcStart=\"\(time(tcStart))\" tcFormat=\"\(settings.startTimecode.mode == .dropFrame ? "DF" : "NDF")\" audioLayout=\"\(settings.audioLayout == .mono ? "mono" : settings.audioLayout == .stereo ? "stereo" : "surround")\" audioRate=\"\(rates[settings.audioSampleRate]!)\">",
                  "          <spine>", "            <gap name=\"Sequence bed\" offset=\"\(time(tcStart))\" start=\"0s\" duration=\"\(time(plan.duration))\">"]
        let videoTracks = project.tracks.filter { $0.kind == .video }
        let audioTracks = project.tracks.filter { $0.kind == .audio }
        // Picture and sound from the same source moment travel as one A/V asset-clip, as Final
        // Cut writes them. Resolve ignores srcEnable, so split clips would duplicate media there.
        var mergedAudio: Set<Int> = []
        var pairedAudio: [Int: Int] = [:]
        for (index, component) in plan.components.enumerated() where !component.selection.isAudio && component.selection != .still {
            if let match = plan.components.indices.first(where: { candidate in
                let other = plan.components[candidate]
                return other.selection.isAudio && !mergedAudio.contains(candidate) && other.assetID == component.assetID
                    && other.sourceRange == component.sourceRange && other.timelineRange == component.timelineRange
            }) {
                mergedAudio.insert(match); pairedAudio[index] = match
            }
        }
        for (index, component) in plan.components.enumerated() where !mergedAudio.contains(index) {
            let asset = assets.first { $0.id == component.assetID }!
            let isAudio = component.selection.isAudio
            let lane: Int
            if isAudio { lane = -(audioTracks.firstIndex { $0.id == component.trackID }! + 1) }
            else { lane = videoTracks.count - videoTracks.firstIndex { $0.id == component.trackID }! }
            let paired = pairedAudio[index] != nil
            let enable = paired ? "" : " srcEnable=\"\(isAudio ? "audio" : "video")\""
            let attributes = "ref=\"\(refs[asset.id]!)\" name=\"\(attribute(asset.name))\" lane=\"\(lane)\" offset=\"\(time(component.timelineRange.start))\" start=\"\(time(try component.sourceRange.start.adding(asset.sourceTimecodeStart ?? .zero)))\" duration=\"\(time(component.sourceRange.duration))\"\(enable)"
            let channels = pairedAudio[index].flatMap { channelSource(plan.components[$0], asset: asset) } ?? channelSource(component, asset: asset)
            if isAudio {
                if let channels {
                    lines += ["              <asset-clip \(attributes) audioRole=\"dialogue\">", "                \(channels)", "              </asset-clip>"]
                } else { lines.append("              <asset-clip \(attributes) audioRole=\"dialogue\"/>") }
            } else {
                lines.append("              <asset-clip \(attributes)\(paired ? " audioRole=\"dialogue\"" : "")>")
                lines.append("                <adjust-conform type=\"\(component.scalingMode.rawValue)\"/>")
                if let channels { lines.append("                \(channels)") }
                lines.append("              </asset-clip>")
            }
        }
        lines += ["            </gap>", "          </spine>", "        </sequence>", "      </project>", "    </event>", "  </library>", "</fcpxml>", ""]
        return FCPXMLExportResult(xml: lines.joined(separator: "\n"), report: FCPXMLExportReport(clipCount: plan.components.count, assetCount: assets.count, notes: [
            "FCPXML 1.10 subset: original file references, exact sequence timing, layered video, and audio channel selections (audio-channel-source, channels numbered across the source's audio streams).",
            "Source raster, frame rate, orientation, pixel aspect, color metadata, and sample rate are inspected from original media by the receiving editor; mixed-rate and spatial conform equivalence have not been qualified.",
            "Linked picture and sound with identical timing are written as one A/V clip. DaVinci Resolve 21 and Final Cut Pro 11 import this subset with exact timing. Track families and editor preferences are not interchange metadata."
        ]))
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
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
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
