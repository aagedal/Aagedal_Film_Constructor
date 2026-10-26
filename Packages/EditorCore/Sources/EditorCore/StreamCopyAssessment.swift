import Foundation

/// Metadata from an original stream, rather than the render compiler's conformed output.
/// Unknown values must stay nil: codec names and keyframe flags alone do not prove copy safety.
public struct StreamCopyMetadata: Equatable, Sendable {
    public var codec: String
    public var codecParameters: Data
    public var timeBase: RationalTime
    public var pixelFormat: String?
    public var colorDescription: String?
    public var width: Int?
    public var height: Int?
    public var sampleAspectRatio: RationalTime?
    public var rotationDegrees: Int?
    public var constantFrameRate: FrameRate?
    public var audioSampleRate: Int?
    public var audioLayout: ChannelLayout?

    public init(codec: String, codecParameters: Data, timeBase: RationalTime,
                pixelFormat: String? = nil, colorDescription: String? = nil,
                width: Int? = nil, height: Int? = nil, sampleAspectRatio: RationalTime? = nil,
                rotationDegrees: Int? = nil, constantFrameRate: FrameRate? = nil,
                audioSampleRate: Int? = nil, audioLayout: ChannelLayout? = nil) {
        self.codec = codec; self.codecParameters = codecParameters; self.timeBase = timeBase
        self.pixelFormat = pixelFormat; self.colorDescription = colorDescription
        self.width = width; self.height = height; self.sampleAspectRatio = sampleAspectRatio
        self.rotationDegrees = rotationDegrees; self.constantFrameRate = constantFrameRate
        self.audioSampleRate = audioSampleRate; self.audioLayout = audioLayout
    }
}

/// A verifier's assertions for one exact range and one destination muxer.
/// The caller must verify the fingerprint against the current original before use.
/// No current app probe produces this evidence. In particular an FFprobe key_frame
/// flag cannot establish independent random access or closed outgoing dependencies.
public struct StreamCopyEvidence: Equatable, Sendable {
    public var assetID: UUID
    public var originalURL: URL
    public var sourceFingerprint: Data
    public var streamIndex: Int
    public var sourceRange: TimeRange
    public var destinationContainer: String
    public var metadata: StreamCopyMetadata
    public var packetBoundariesExact: Bool
    public var independentlyDecodableStart: Bool
    public var outgoingDependenciesComplete: Bool
    public var rebasedTimestampsExact: Bool
    public var codecDelayAndPaddingExact: Bool
    /// Includes codec parameters, pixel/color interpretation, edit support and bitstream transforms.
    public var containerPreservesStream: Bool

    public init(assetID: UUID, originalURL: URL, sourceFingerprint: Data, streamIndex: Int,
                sourceRange: TimeRange, destinationContainer: String, metadata: StreamCopyMetadata,
                packetBoundariesExact: Bool = false, independentlyDecodableStart: Bool = false,
                outgoingDependenciesComplete: Bool = false, rebasedTimestampsExact: Bool = false,
                codecDelayAndPaddingExact: Bool = false, containerPreservesStream: Bool = false) {
        self.assetID = assetID; self.originalURL = originalURL; self.sourceFingerprint = sourceFingerprint
        self.streamIndex = streamIndex; self.sourceRange = sourceRange
        self.destinationContainer = destinationContainer; self.metadata = metadata
        self.packetBoundariesExact = packetBoundariesExact
        self.independentlyDecodableStart = independentlyDecodableStart
        self.outgoingDependenciesComplete = outgoingDependenciesComplete
        self.rebasedTimestampsExact = rebasedTimestampsExact
        self.codecDelayAndPaddingExact = codecDelayAndPaddingExact
        self.containerPreservesStream = containerPreservesStream
    }
}

public enum StreamCopyReason: String, Equatable, Sendable {
    case missingStream, multipleComponents, generatedGapOrTimingChange, missingOriginal
    case stillImage, missingSourceStream, nonzeroStreamOffset, audioProcessing, videoProcessing, channelRemapping
    case missingEvidence, ambiguousEvidence, evidenceDoesNotMatch, missingMetadata
    case videoGeometryChange, frameRateChange, audioFormatChange
    case inexactPacketBoundaries, unprovenRandomAccess, incompleteOutgoingDependencies
    case inexactTimestampRebase, inexactCodecDelayOrPadding, incompatibleContainer
}

public struct StreamCopyStreamAssessment: Equatable, Sendable {
    public let kind: MediaStreamKind
    public let streamIndex: Int?
    public let sourceRange: TimeRange?
    public let reasons: [StreamCopyReason]
    /// Conditional on fresh, correctly generated evidence; this does not authorize an export.
    public var isEligible: Bool { reasons.isEmpty }
}

public struct StreamCopyAssessment: Equatable, Sendable {
    public let video: StreamCopyStreamAssessment
    public let audio: StreamCopyStreamAssessment
    public static let qualificationLimitations = "Assessment only: one component per media kind covering the full sequence, with original streams and exact caller-verified packet evidence. No packet verifier, remux compiler, mixed copy/render export or media qualification is implemented. Evidence must be freshly verified against originals; eligibility is not an export guarantee."

    /// Assesses each kind independently, so edited audio does not invalidate clean picture.
    /// Multiple sources/cuts and multiple whole audio streams remain outside this initial scope.
    public static func assess(_ plan: TimelineRenderPlan, destinationContainer: String,
                              evidence: [StreamCopyEvidence] = []) throws -> Self {
        try plan.settings.validate()
        func assessKind(_ kind: MediaStreamKind) throws -> StreamCopyStreamAssessment {
            let components = plan.components.filter { $0.selectionKind == kind }
            guard let component = components.first else {
                return .init(kind: kind, streamIndex: nil, sourceRange: nil, reasons: [.missingStream])
            }
            var reasons: [StreamCopyReason] = []
            func reject(_ reason: StreamCopyReason) { if !reasons.contains(reason) { reasons.append(reason) } }
            if components.count != 1 { reject(.multipleComponents) }
            try component.sourceRange.validate(); try component.timelineRange.validate()
            if component.timelineRange.start != .zero || component.timelineRange.duration != plan.duration ||
                component.sourceRange.duration != component.timelineRange.duration { reject(.generatedGapOrTimingChange) }
            if component.originalURL?.isFileURL != true { reject(.missingOriginal) }
            let streamIndex: Int?
            if component.speed != .one { reject(.generatedGapOrTimingChange) }
            switch component.selection {
            case .still: streamIndex = nil; reject(.stillImage)
            case .video(let index):
                streamIndex = index
                if component.hasPlacement || !component.color.isNeutral || component.fadeIn.duration != .zero || component.fadeOut.duration != .zero {
                    reject(.videoProcessing)
                }
            case .audio(let selection):
                let indices = Set(selection.channels.map(\.streamIndex))
                streamIndex = indices.count == 1 ? indices.first : nil
                guard let index = streamIndex,
                      let layout = component.sourceStreams.first(where: { $0.index == index && $0.kind == .audio })?.audioLayout else {
                    reject(.channelRemapping)
                    return .init(kind: kind, streamIndex: streamIndex, sourceRange: component.sourceRange, reasons: reasons)
                }
                let whole = layout.channels.indices.map { SourceChannel(streamIndex: index, channelIndex: $0) }
                if selection.channels != whole || selection.layout != layout || selection.layout != plan.settings.audioLayout ||
                    (!component.routing.outputChannels.isEmpty && component.routing.outputChannels != Array(whole.indices)) {
                    reject(.channelRemapping)
                }
                if component.gain != 1 || component.fadeIn.duration != .zero || component.fadeOut.duration != .zero || !component.volumeKeyframes.isEmpty {
                    reject(.audioProcessing)
                }
            }
            guard let index = streamIndex else {
                return .init(kind: kind, streamIndex: nil, sourceRange: component.sourceRange, reasons: reasons)
            }
            if let stream = component.sourceStreams.first(where: { $0.index == index && $0.kind == kind }) {
                if stream.timeOffset != .zero { reject(.nonzeroStreamOffset) }
            } else { reject(.missingSourceStream) }
            let candidates = evidence.filter { $0.assetID == component.assetID && $0.streamIndex == index }
            if candidates.isEmpty { reject(.missingEvidence) }
            if candidates.count > 1 { reject(.ambiguousEvidence) }
            if let proof = candidates.first {
                if proof.originalURL != component.originalURL || proof.sourceRange != component.sourceRange ||
                    proof.destinationContainer != destinationContainer || destinationContainer.isEmpty || proof.sourceFingerprint.isEmpty {
                    reject(.evidenceDoesNotMatch)
                }
                let metadata = proof.metadata
                if metadata.codec.isEmpty || metadata.codecParameters.isEmpty || metadata.timeBase.numerator <= 0 { reject(.missingMetadata) }
                if kind == .video {
                    if metadata.pixelFormat?.isEmpty != false || metadata.colorDescription?.isEmpty != false ||
                        metadata.width == nil || metadata.height == nil || metadata.sampleAspectRatio == nil || metadata.rotationDegrees == nil {
                        reject(.missingMetadata)
                    }
                    if metadata.width != plan.settings.width || metadata.height != plan.settings.height ||
                        metadata.sampleAspectRatio != (try! RationalTime(1)) || metadata.rotationDegrees != 0 { reject(.videoGeometryChange) }
                    if metadata.constantFrameRate != plan.settings.frameRate { reject(.frameRateChange) }
                    let startFrames = try component.sourceRange.start.multiplied(by: plan.settings.frameRate.value)
                    let durationFrames = try component.sourceRange.duration.multiplied(by: plan.settings.frameRate.value)
                    if startFrames.denominator != 1 || durationFrames.denominator != 1 { reject(.generatedGapOrTimingChange) }
                } else {
                    if metadata.audioSampleRate != plan.settings.audioSampleRate || metadata.audioLayout != plan.settings.audioLayout { reject(.audioFormatChange) }
                    let startSamples = try component.sourceRange.start.multiplied(by: Int64(plan.settings.audioSampleRate))
                    let durationSamples = try component.sourceRange.duration.multiplied(by: Int64(plan.settings.audioSampleRate))
                    if startSamples.denominator != 1 || durationSamples.denominator != 1 { reject(.generatedGapOrTimingChange) }
                }
                if !proof.packetBoundariesExact { reject(.inexactPacketBoundaries) }
                if !proof.independentlyDecodableStart { reject(.unprovenRandomAccess) }
                if !proof.outgoingDependenciesComplete { reject(.incompleteOutgoingDependencies) }
                if !proof.rebasedTimestampsExact { reject(.inexactTimestampRebase) }
                if !proof.codecDelayAndPaddingExact { reject(.inexactCodecDelayOrPadding) }
                if !proof.containerPreservesStream { reject(.incompatibleContainer) }
            }
            return .init(kind: kind, streamIndex: index, sourceRange: component.sourceRange, reasons: reasons)
        }
        return try Self(video: assessKind(.video), audio: assessKind(.audio))
    }
}

private extension TimelineRenderPlan.Component {
    var selectionKind: MediaStreamKind {
        if case .audio = selection { return .audio }
        return .video
    }
}
