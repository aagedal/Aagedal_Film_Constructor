import Foundation

public enum SpeakerPosition: String, Codable, Sendable { case mono, left, right, center, lowFrequency, leftSurround, rightSurround, leftRear, rightRear }
public struct ChannelLayout: Hashable, Codable, Sendable {
    /// nil positions preserve unknown speaker identities rather than guessing a layout.
    public var channels: [SpeakerPosition?]
    public init(channels: [SpeakerPosition?]) { self.channels = channels }
    public static let mono = Self(channels: [.mono])
    public static let stereo = Self(channels: [.left, .right])
    public static let surround51 = Self(channels: [.left, .right, .center, .lowFrequency, .leftSurround, .rightSurround])
    public func validate() throws {
        let known = channels.compactMap { $0 }
        guard !channels.isEmpty, channels.count <= 64, Set(known).count == known.count else { throw EditorCoreError.invalidModel("Invalid channel layout") }
    }
}
public enum MediaStreamKind: String, Codable, Sendable { case video, audio }
/// Exact source properties qualified for sequence matching. Absent metadata means
/// the importer could not prove a supported constant cadence and raster.
public struct VideoSourceFormat: Equatable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public init(width: Int, height: Int, frameRate: FrameRate) throws {
        self.width = width; self.height = height; self.frameRate = frameRate
        try validate()
    }
    public func validate() throws {
        guard width > 0, height > 0, width <= 65536, height <= 65536 else {
            throw EditorCoreError.invalidSettings
        }
        _ = try FrameRate(frameRate.value.numerator, frameRate.value.denominator)
    }
    private enum CodingKeys: String, CodingKey { case width, height, frameRate }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width),
                      height: c.decode(Int.self, forKey: .height),
                      frameRate: c.decode(FrameRate.self, forKey: .frameRate))
    }
}
public struct MediaStream: Equatable, Codable, Sendable {
    public var index: Int
    public var kind: MediaStreamKind
    public var label: String?
    public var audioLayout: ChannelLayout?
    public var videoFormat: VideoSourceFormat?
    public var timeOffset: RationalTime
    public init(index: Int, kind: MediaStreamKind, label: String? = nil, audioLayout: ChannelLayout? = nil, timeOffset: RationalTime = .zero, videoFormat: VideoSourceFormat? = nil) {
        self.index = index; self.kind = kind; self.label = label; self.audioLayout = audioLayout; self.timeOffset = timeOffset
        self.videoFormat = videoFormat
    }
}
public struct MediaAsset: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var originalURL: URL?
    public var duration: RationalTime
    public var streams: [MediaStream]
    public var sourceTimecode: Timecode?
    /// Embedded timecode of the first frame as exact seconds (frames × timecode frame duration),
    /// read from the media's timecode track. Interchange references media in this clock.
    public var sourceTimecodeStart: RationalTime?
    public var proxy: MediaProxy?
    /// Generated title text; `originalURL` then references its rendered image.
    public var title: TitleDefinition?
    public init(id: UUID = UUID(), name: String, originalURL: URL? = nil, duration: RationalTime, streams: [MediaStream] = [], sourceTimecode: Timecode? = nil, proxy: MediaProxy? = nil) {
        self.id = id; self.name = name; self.originalURL = originalURL; self.duration = duration; self.streams = streams; self.sourceTimecode = sourceTimecode; self.proxy = proxy
    }
}
public extension MediaAsset {
    /// Imported stills hold for up to an hour; they are placed at the default duration.
    static func stillSourceExtent() throws -> RationalTime { try RationalTime(3600) }
    static func defaultStillDuration() throws -> RationalTime { try RationalTime(5) }
    var isStill: Bool { streams.isEmpty }
    /// The range placed by Append and Finder drops when no source marks are set.
    func defaultPlacementRange() throws -> TimeRange {
        let still = try Self.defaultStillDuration()
        guard isStill, try duration.compared(to: still) == .orderedDescending else {
            return try TimeRange(start: .zero, duration: duration)
        }
        return try TimeRange(start: .zero, duration: still)
    }
}
public struct SourceChannel: Hashable, Codable, Sendable {
    public var streamIndex: Int
    public var channelIndex: Int
    public init(streamIndex: Int, channelIndex: Int) { self.streamIndex = streamIndex; self.channelIndex = channelIndex }
}
public struct AudioSourceSelection: Hashable, Codable, Sendable {
    /// Each output channel has an explicit input channel, including selections spanning mono streams.
    public var channels: [SourceChannel]
    public var layout: ChannelLayout
    public init(channels: [SourceChannel], layout: ChannelLayout) { self.channels = channels; self.layout = layout }
}
public enum ClipSelection: Hashable, Codable, Sendable { case video(streamIndex: Int), audio(AudioSourceSelection), still }
public enum ScalingMode: String, Codable, Sendable { case fit, fill, none }
/// Placement of a picture after its scaling mode: a uniform scale about the frame centre,
/// an offset in fractions of the frame size (positive x right, positive y down) and opacity.
public struct PictureTransform: Equatable, Codable, Sendable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var opacity: Double
    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, opacity: Double = 1) {
        self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY; self.opacity = opacity
    }
    public static let identity = PictureTransform()
    public var isIdentity: Bool { self == .identity }
    /// Scales from 1% to 1000%, offsets within two frames, opacity from 0 to 1.
    public func validate() throws {
        guard [scale, offsetX, offsetY, opacity].allSatisfy(\.isFinite), (0.01...10).contains(scale),
              (-2...2).contains(offsetX), (-2...2).contains(offsetY), (0...1).contains(opacity) else {
            throw EditorCoreError.invalidModel("Scale must be 1–1000%, position within two frames and opacity 0–100%")
        }
    }
}
public enum TrackKind: String, Codable, Sendable { case video, audio }
public struct AudioRouting: Equatable, Codable, Sendable {
    /// Destination speaker for every input channel; an empty map means identity routing.
    public var outputChannels: [Int]
    public init(outputChannels: [Int] = []) { self.outputChannels = outputChannels }
}
public struct TrackTemplate: Equatable, Codable, Sendable {
    public var kind: TrackKind
    public var audioLayout: ChannelLayout?
    public var routing: AudioRouting
    public var gain: Double
    public init(kind: TrackKind, audioLayout: ChannelLayout? = nil, routing: AudioRouting = .init(), gain: Double = 1) {
        self.kind = kind; self.audioLayout = audioLayout; self.routing = routing; self.gain = gain
    }
}
public struct TimelineClip: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var sourceRange: TimeRange
    public var timelineStart: RationalTime
    public var selection: ClipSelection
    public var scalingMode: ScalingMode
    public var linkGroupID: UUID?
    public var fadeIn: AudioFade
    public var fadeOut: AudioFade
    /// Linear clip volume for audio components, applied on top of the track gain.
    public var gain: Double
    /// Picture placement after scaling; identity for audio.
    public var transform: PictureTransform
    public init(id: UUID = UUID(), assetID: UUID, sourceRange: TimeRange, timelineStart: RationalTime = .zero, selection: ClipSelection, scalingMode: ScalingMode = .fit, linkGroupID: UUID? = nil, fadeIn: AudioFade = .init(), fadeOut: AudioFade = .init(), gain: Double = 1, transform: PictureTransform = .identity) {
        self.id = id; self.assetID = assetID; self.sourceRange = sourceRange; self.timelineStart = timelineStart; self.selection = selection; self.scalingMode = scalingMode; self.linkGroupID = linkGroupID; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.gain = gain; self.transform = transform
    }
    private enum CodingKeys: String, CodingKey { case id, assetID, sourceRange, timelineStart, selection, scalingMode, linkGroupID, fadeIn, fadeOut, gain, transform }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), assetID: try c.decode(UUID.self, forKey: .assetID),
                  sourceRange: try c.decode(TimeRange.self, forKey: .sourceRange), timelineStart: try c.decode(RationalTime.self, forKey: .timelineStart),
                  selection: try c.decode(ClipSelection.self, forKey: .selection), scalingMode: try c.decode(ScalingMode.self, forKey: .scalingMode),
                  linkGroupID: try c.decodeIfPresent(UUID.self, forKey: .linkGroupID),
                  fadeIn: try c.decodeIfPresent(AudioFade.self, forKey: .fadeIn) ?? .init(),
                  fadeOut: try c.decodeIfPresent(AudioFade.self, forKey: .fadeOut) ?? .init(),
                  gain: try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1,
                  transform: try c.decodeIfPresent(PictureTransform.self, forKey: .transform) ?? .identity)
    }
    public var requiredTrackKind: TrackKind { if case .audio = selection { return .audio }; return .video }
    public var requiredAudioLayout: ChannelLayout? { if case .audio(let selection) = selection { return selection.layout }; return nil }
    public func timelineRange() throws -> TimeRange { try TimeRange(start: timelineStart, duration: sourceRange.duration) }
}
public struct TrackFamily: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var baseName: String
    public var template: TrackTemplate
    public init(id: UUID = UUID(), baseName: String, template: TrackTemplate) { self.id = id; self.baseName = baseName; self.template = template }
}
public struct TimelineTrack: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var familyID: UUID
    public var customName: String?
    public var template: TrackTemplate
    public var retained: Bool
    public var clips: [TimelineClip]
    /// A muted track is left out of render and preview: hidden picture or silent sound.
    public var muted: Bool
    /// While any audio track is soloed, only soloed audio tracks are heard.
    public var soloed: Bool
    public init(id: UUID = UUID(), familyID: UUID, customName: String? = nil, template: TrackTemplate, retained: Bool = false, clips: [TimelineClip] = [],
                muted: Bool = false, soloed: Bool = false) {
        self.id = id; self.familyID = familyID; self.customName = customName; self.template = template; self.retained = retained; self.clips = clips
        self.muted = muted; self.soloed = soloed
    }
    private enum CodingKeys: String, CodingKey { case id, familyID, customName, template, retained, clips, muted, soloed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), familyID: try c.decode(UUID.self, forKey: .familyID),
                  customName: try c.decodeIfPresent(String.self, forKey: .customName), template: try c.decode(TrackTemplate.self, forKey: .template),
                  retained: try c.decode(Bool.self, forKey: .retained), clips: try c.decode([TimelineClip].self, forKey: .clips),
                  muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false, soloed: try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false)
    }
    public var kind: TrackKind { template.kind }
    public var audioLayout: ChannelLayout? { template.audioLayout }
    public func displayName(in project: Project) -> String {
        if let customName { return customName }
        guard let family = project.families.first(where: { $0.id == familyID }) else { return "Track" }
        let siblings = project.tracks.filter { $0.familyID == familyID }
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == id }) else { return family.baseName }
        return "\(family.baseName) \(index + 1)"
    }
}
public struct EditorPreferences: Equatable, Codable, Sendable {
    public var automaticallyRemoveEmptyTracks: Bool
    public var askBeforeAudioTrackLayoutChanges: Bool
    public init(automaticallyRemoveEmptyTracks: Bool = true, askBeforeAudioTrackLayoutChanges: Bool = true) {
        self.automaticallyRemoveEmptyTracks = automaticallyRemoveEmptyTracks; self.askBeforeAudioTrackLayoutChanges = askBeforeAudioTrackLayoutChanges
    }
}
