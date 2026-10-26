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
/// Scale, position and opacity at a source time. Between keyframes they change linearly;
/// before the first and after the last they hold. Opacity multiplies the clip's static opacity.
public struct TransformKeyframe: Equatable, Codable, Sendable {
    public var time: RationalTime
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var opacity: Double
    public init(time: RationalTime, scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, opacity: Double = 1) {
        self.time = time; self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY; self.opacity = opacity
    }
    private enum CodingKeys: String, CodingKey { case time, scale, offsetX, offsetY, opacity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(time: try c.decode(RationalTime.self, forKey: .time), scale: try c.decode(Double.self, forKey: .scale),
                  offsetX: try c.decode(Double.self, forKey: .offsetX), offsetY: try c.decode(Double.self, forKey: .offsetY),
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1)
    }
}

public enum PictureAnimation {
    public static func validate(_ keyframes: [TransformKeyframe]) throws {
        guard keyframes.count <= 1000, keyframes.allSatisfy({ $0.time.numerator >= 0 }),
              try zip(keyframes, keyframes.dropFirst()).allSatisfy({ try $0.time.compared(to: $1.time) == .orderedAscending }) else {
            throw EditorCoreError.invalidModel("Position keyframes need increasing times")
        }
        for keyframe in keyframes {
            try PictureTransform(scale: keyframe.scale, offsetX: keyframe.offsetX, offsetY: keyframe.offsetY, opacity: keyframe.opacity).validate()
        }
    }
    /// The placement at a source time: keyframed scale and position, and keyframed opacity
    /// times the static opacity.
    public static func transform(atSourceSeconds t: Double, base: PictureTransform, keyframes: [TransformKeyframe]) -> PictureTransform {
        guard let first = keyframes.first, let last = keyframes.last else { return base }
        func at(_ k: TransformKeyframe) -> PictureTransform { PictureTransform(scale: k.scale, offsetX: k.offsetX, offsetY: k.offsetY, opacity: base.opacity * k.opacity) }
        if t <= first.time.seconds { return at(first) }
        if t >= last.time.seconds { return at(last) }
        let next = keyframes.firstIndex { $0.time.seconds > t }!
        let a = keyframes[next - 1], b = keyframes[next]
        let f = (t - a.time.seconds) / (b.time.seconds - a.time.seconds)
        return PictureTransform(scale: a.scale + (b.scale - a.scale) * f, offsetX: a.offsetX + (b.offsetX - a.offsetX) * f,
                                offsetY: a.offsetY + (b.offsetY - a.offsetY) * f, opacity: base.opacity * (a.opacity + (b.opacity - a.opacity) * f))
    }
}

/// Basic colour correction in the picture's encoded (gamma) values: brightness is added,
/// contrast scales about mid grey and saturation scales colour away from grey.
public struct ColorAdjustment: Equatable, Codable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    /// Gaussian blur standard deviation as a fraction of the frame height; zero is sharp.
    public var blur: Double
    /// Levels on each RGB channel: input black and white points (0–1) and gamma, applied before
    /// brightness, contrast and saturation: out = ((in − black) / (white − black))^(1/gamma).
    public var blackPoint: Double
    public var whitePoint: Double
    public var gamma: Double
    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, blur: Double = 0,
                blackPoint: Double = 0, whitePoint: Double = 1, gamma: Double = 1) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.blur = blur
        self.blackPoint = blackPoint; self.whitePoint = whitePoint; self.gamma = gamma
    }
    public var hasLevels: Bool { blackPoint != 0 || whitePoint != 1 || gamma != 1 }
    private enum CodingKeys: String, CodingKey { case brightness, contrast, saturation, blur, blackPoint, whitePoint, gamma }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(brightness: try c.decode(Double.self, forKey: .brightness), contrast: try c.decode(Double.self, forKey: .contrast),
                  saturation: try c.decode(Double.self, forKey: .saturation), blur: try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0,
                  blackPoint: try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0,
                  whitePoint: try c.decodeIfPresent(Double.self, forKey: .whitePoint) ?? 1,
                  gamma: try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1)
    }
    /// Whether only blur is set, with neutral colour.
    public var isColorNeutral: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
    public static let neutral = ColorAdjustment()
    public var isNeutral: Bool { self == .neutral }
    public func validate() throws {
        guard [brightness, contrast, saturation, blur, blackPoint, whitePoint, gamma].allSatisfy(\.isFinite), (-1...1).contains(brightness),
              (0...3).contains(contrast), (0...3).contains(saturation), (0...0.1).contains(blur),
              (0...0.9).contains(blackPoint), (0.1...1).contains(whitePoint), whitePoint - blackPoint >= 0.1, (0.2...5).contains(gamma) else {
            throw EditorCoreError.invalidModel("Brightness must be −100 to +100, contrast and saturation 0–300%, blur 0–10%, levels black below white by 10% or more, gamma 0.2–5")
        }
    }
}

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
    /// Audio volume automation in source time, multiplied with gain and fades.
    public var volumeKeyframes: [VolumeKeyframe]
    /// Picture colour correction; neutral for audio.
    public var color: ColorAdjustment
    /// Animated scale and position in source time; empty for a static placement.
    public var transformKeyframes: [TransformKeyframe]
    /// Three-band EQ for audio components; flat for pictures.
    public var eq: AudioEQ
    /// Playback speed: the clip plays `sourceRange.duration × speed` of source in
    /// `sourceRange.duration` of timeline. `sourceRange.start` is in source time.
    public var speed: RationalTime
    /// Source time consumed by the clip.
    public func sourceExtent() throws -> RationalTime { try sourceRange.duration.multiplied(by: speed) }
    public func sourceEnd() throws -> RationalTime { try sourceRange.start.adding(sourceExtent()) }
    /// Source time reached `timelineOffset` into the clip.
    public func sourceTime(atTimelineOffset offset: RationalTime) throws -> RationalTime { try sourceRange.start.adding(offset.multiplied(by: speed)) }
    public init(id: UUID = UUID(), assetID: UUID, sourceRange: TimeRange, timelineStart: RationalTime = .zero, selection: ClipSelection, scalingMode: ScalingMode = .fit, linkGroupID: UUID? = nil, fadeIn: AudioFade = .init(), fadeOut: AudioFade = .init(), gain: Double = 1, transform: PictureTransform = .identity, volumeKeyframes: [VolumeKeyframe] = [], color: ColorAdjustment = .neutral, speed: RationalTime = RationalTime.one, transformKeyframes: [TransformKeyframe] = [], eq: AudioEQ = .flat) {
        self.id = id; self.assetID = assetID; self.sourceRange = sourceRange; self.timelineStart = timelineStart; self.selection = selection; self.scalingMode = scalingMode; self.linkGroupID = linkGroupID; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.gain = gain; self.transform = transform; self.volumeKeyframes = volumeKeyframes; self.color = color; self.speed = speed; self.transformKeyframes = transformKeyframes; self.eq = eq
    }
    private enum CodingKeys: String, CodingKey { case id, assetID, sourceRange, timelineStart, selection, scalingMode, linkGroupID, fadeIn, fadeOut, gain, transform, volumeKeyframes, color, speed, transformKeyframes, eq }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), assetID: try c.decode(UUID.self, forKey: .assetID),
                  sourceRange: try c.decode(TimeRange.self, forKey: .sourceRange), timelineStart: try c.decode(RationalTime.self, forKey: .timelineStart),
                  selection: try c.decode(ClipSelection.self, forKey: .selection), scalingMode: try c.decode(ScalingMode.self, forKey: .scalingMode),
                  linkGroupID: try c.decodeIfPresent(UUID.self, forKey: .linkGroupID),
                  fadeIn: try c.decodeIfPresent(AudioFade.self, forKey: .fadeIn) ?? .init(),
                  fadeOut: try c.decodeIfPresent(AudioFade.self, forKey: .fadeOut) ?? .init(),
                  gain: try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1,
                  transform: try c.decodeIfPresent(PictureTransform.self, forKey: .transform) ?? .identity,
                  volumeKeyframes: try c.decodeIfPresent([VolumeKeyframe].self, forKey: .volumeKeyframes) ?? [],
                  color: try c.decodeIfPresent(ColorAdjustment.self, forKey: .color) ?? .neutral,
                  speed: try c.decodeIfPresent(RationalTime.self, forKey: .speed) ?? RationalTime.one,
                  transformKeyframes: try c.decodeIfPresent([TransformKeyframe].self, forKey: .transformKeyframes) ?? [],
                  eq: try c.decodeIfPresent(AudioEQ.self, forKey: .eq) ?? .flat)
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
