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
                let audio = asset.streams.filter { $0.kind == .audio }
                if let stream = audio.first, audio.count == 1, let layout = stream.audioLayout {
                    let identity = layout.channels.indices.map { SourceChannel(streamIndex: stream.index, channelIndex: $0) }
                    if selection.channels != identity || selection.layout != layout { reasons.append("\(label): partial, reordered, or remapped audio channel selections are not supported.") }
                    if layout != settings.audioLayout { reasons.append("\(label): source audio layout must match the sequence layout.") }
                    if stream.timeOffset != .zero { reasons.append("\(label): nonzero source stream offsets are not supported.") }
                } else { reasons.append("\(label): exactly one complete audio stream is required.") }
                let identity = Array(0..<selection.channels.count)
                if !component.routing.outputChannels.isEmpty && component.routing.outputChannels != identity { reasons.append("\(label): nonidentity output channel routing is not supported.") }
            }
        }
        if try !frameAligned(plan.duration, rate: settings.frameRate) { reasons.append("The sequence end must fall on a sequence frame boundary; export does not round or pad it.") }
        let times = [frameDuration, tcStart, plan.duration] + assets.map(\.duration) + plan.components.flatMap {
            [$0.sourceRange.start, $0.sourceRange.duration, $0.timelineRange.start]
        }
        if times.contains(where: { $0.denominator > Int64(Int32.max) }) { reasons.append("An exact time denominator exceeds the FCPXML 32-bit limit.") }
        guard reasons.isEmpty else { throw FCPXMLExportError.unsupported(reasons) }

        let refs = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, "r\($0.offset + 2)") })
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<!DOCTYPE fcpxml>", "<fcpxml version=\"1.10\">", "  <resources>",
                     "    <format id=\"r1\" frameDuration=\"\(time(frameDuration))\" width=\"\(settings.width)\" height=\"\(settings.height)\"/>"]
        for asset in assets {
            let hasVideo = asset.streams.contains { $0.kind == .video }
            let audio = asset.streams.filter { $0.kind == .audio }
            var attributes = "id=\"\(refs[asset.id]!)\" name=\"\(attribute(asset.name))\" start=\"0s\" duration=\"\(time(asset.duration))\" hasVideo=\"\(hasVideo ? 1 : 0)\" hasAudio=\"\(audio.isEmpty ? 0 : 1)\""
            if hasVideo { attributes += " videoSources=\"\(asset.streams.filter { $0.kind == .video }.count)\"" }
            if !audio.isEmpty { attributes += " audioSources=\"\(audio.count)\" audioChannels=\"\(audio.reduce(0) { $0 + ($1.audioLayout?.channels.count ?? 0) })\"" }
            // Source raster, source frame rate, and source sample rate are not present in
            // MediaAsset. Do not invent them from the sequence settings; FCP probes the original.
            lines.append("    <asset \(attributes)>")
            lines.append("      <media-rep kind=\"original-media\" src=\"\(attribute(asset.originalURL!.absoluteString))\"/>")
            lines.append("    </asset>")
        }
        lines += ["  </resources>", "  <library>", "    <event name=\"Aagedal Film Constructor\">", "      <project name=\"\(attribute(projectName))\">",
                  "        <sequence format=\"r1\" duration=\"\(time(plan.duration))\" tcStart=\"\(time(tcStart))\" tcFormat=\"\(settings.startTimecode.mode == .dropFrame ? "DF" : "NDF")\" audioLayout=\"\(settings.audioLayout == .mono ? "mono" : "stereo")\" audioRate=\"\(rates[settings.audioSampleRate]!)\">",
                  "          <spine>", "            <gap name=\"Sequence bed\" offset=\"\(time(tcStart))\" start=\"0s\" duration=\"\(time(plan.duration))\">"]
        let videoTracks = project.tracks.filter { $0.kind == .video }
        let audioTracks = project.tracks.filter { $0.kind == .audio }
        for component in plan.components {
            let asset = assets.first { $0.id == component.assetID }!
            let isAudio = component.selection.isAudio
            let lane: Int
            if isAudio { lane = -(audioTracks.firstIndex { $0.id == component.trackID }! + 1) }
            else { lane = videoTracks.count - videoTracks.firstIndex { $0.id == component.trackID }! }
            let attributes = "ref=\"\(refs[asset.id]!)\" name=\"\(attribute(asset.name))\" lane=\"\(lane)\" offset=\"\(time(component.timelineRange.start))\" start=\"\(time(component.sourceRange.start))\" duration=\"\(time(component.sourceRange.duration))\" srcEnable=\"\(isAudio ? "audio" : "video")\""
            if isAudio { lines.append("              <asset-clip \(attributes) audioRole=\"dialogue\"/>") }
            else {
                lines.append("              <asset-clip \(attributes)>")
                lines.append("                <adjust-conform type=\"\(component.scalingMode.rawValue)\"/>")
                lines.append("              </asset-clip>")
            }
        }
        lines += ["            </gap>", "          </spine>", "        </sequence>", "      </project>", "    </event>", "  </library>", "</fcpxml>", ""]
        return FCPXMLExportResult(xml: lines.joined(separator: "\n"), report: FCPXMLExportReport(clipCount: plan.components.count, assetCount: assets.count, notes: [
            "FCPXML 1.10 subset: original file references, exact sequence timing, layered video, and complete mono/stereo audio streams.",
            "Source raster, frame rate, orientation, pixel aspect, color metadata, and sample rate are inspected from original media by the receiving editor; mixed-rate and spatial conform equivalence have not been qualified.",
            "Native Final Cut Pro or Resolve import has not been verified. Track families, link groups, and editor preferences are not interchange metadata."
        ]))
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
