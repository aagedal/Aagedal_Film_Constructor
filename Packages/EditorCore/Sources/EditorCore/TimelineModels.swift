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
public struct MediaStream: Equatable, Codable, Sendable {
    public var index: Int
    public var kind: MediaStreamKind
    public var label: String?
    public var audioLayout: ChannelLayout?
    public var timeOffset: RationalTime
    public init(index: Int, kind: MediaStreamKind, label: String? = nil, audioLayout: ChannelLayout? = nil, timeOffset: RationalTime = .zero) {
        self.index = index; self.kind = kind; self.label = label; self.audioLayout = audioLayout; self.timeOffset = timeOffset
    }
}
public struct MediaAsset: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var originalURL: URL?
    public var duration: RationalTime
    public var streams: [MediaStream]
    public var sourceTimecode: Timecode?
    public init(id: UUID = UUID(), name: String, originalURL: URL? = nil, duration: RationalTime, streams: [MediaStream] = [], sourceTimecode: Timecode? = nil) {
        self.id = id; self.name = name; self.originalURL = originalURL; self.duration = duration; self.streams = streams; self.sourceTimecode = sourceTimecode
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
    public init(id: UUID = UUID(), assetID: UUID, sourceRange: TimeRange, timelineStart: RationalTime = .zero, selection: ClipSelection, scalingMode: ScalingMode = .fit, linkGroupID: UUID? = nil) {
        self.id = id; self.assetID = assetID; self.sourceRange = sourceRange; self.timelineStart = timelineStart; self.selection = selection; self.scalingMode = scalingMode; self.linkGroupID = linkGroupID
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
    public init(id: UUID = UUID(), familyID: UUID, customName: String? = nil, template: TrackTemplate, retained: Bool = false, clips: [TimelineClip] = []) {
        self.id = id; self.familyID = familyID; self.customName = customName; self.template = template; self.retained = retained; self.clips = clips
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
