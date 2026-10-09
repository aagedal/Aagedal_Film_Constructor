import Foundation

public struct Project: Equatable, Codable, Sendable {
    public var settings: SequenceSettings
    public var assets: [MediaAsset]
    public var families: [TrackFamily]
    /// Frontmost video track first. Render consumers must preserve this explicit order.
    public var tracks: [TimelineTrack]
    public var preferences: EditorPreferences
    public init(settings: SequenceSettings, assets: [MediaAsset] = [], families: [TrackFamily] = [], tracks: [TimelineTrack] = [], preferences: EditorPreferences = .init()) {
        self.settings = settings; self.assets = assets; self.families = families; self.tracks = tracks; self.preferences = preferences
    }
    /// Validate at document decoding/edit commit boundaries; mutable value models can represent an in-progress edit.
    public func validate() throws {
        try settings.validate()
        func unique(_ ids: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw EditorCoreError.invalidModel("Duplicate identity") }
        }
        try unique(assets.map(\.id)); try unique(families.map(\.id)); try unique(tracks.map(\.id)); try unique(tracks.flatMap { $0.clips.map(\.id) })
        for asset in assets {
            guard asset.duration.numerator > 0, Set(asset.streams.map(\.index)).count == asset.streams.count else { throw EditorCoreError.invalidModel("Invalid asset duration or stream identities") }
            for stream in asset.streams {
                guard stream.index >= 0, (stream.kind == .audio) == (stream.audioLayout != nil) else { throw EditorCoreError.invalidModel("Invalid source stream") }
                try stream.audioLayout?.validate()
            }
        }
        for family in families {
            guard !family.baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditorCoreError.invalidModel("Empty family name") }
            try validateTemplate(family.template)
        }
        for track in tracks {
            guard let family = families.first(where: { $0.id == track.familyID }), family.template.kind == track.kind else { throw EditorCoreError.invalidModel("Missing or incompatible track family") }
            try validateTemplate(track.template)
            for clip in track.clips {
                guard clip.requiredTrackKind == track.kind, clip.requiredAudioLayout == track.audioLayout, let asset = assets.first(where: { $0.id == clip.assetID }) else { throw EditorCoreError.invalidModel("Missing asset or incompatible track") }
                try clip.sourceRange.validate()
                _ = try clip.timelineRange()
                guard try clip.sourceRange.end().compared(to: asset.duration) != .orderedDescending else { throw EditorCoreError.invalidModel("Source range exceeds media") }
                switch clip.selection {
                case .still: break
                case .video(let index):
                    guard asset.streams.contains(where: { $0.index == index && $0.kind == .video }) else { throw EditorCoreError.invalidModel("Missing video stream") }
                case .audio(let selection):
                    try selection.layout.validate()
                    guard selection.channels.count == selection.layout.channels.count else { throw EditorCoreError.invalidModel("Incomplete source channel map") }
                    for channel in selection.channels {
                        guard let stream = asset.streams.first(where: { $0.index == channel.streamIndex && $0.kind == .audio }), let layout = stream.audioLayout, channel.channelIndex >= 0, channel.channelIndex < layout.channels.count else { throw EditorCoreError.invalidModel("Missing source audio channel") }
                    }
                }
            }
            for i in track.clips.indices {
                for j in track.clips.indices where j > i {
                    guard try !track.clips[i].timelineRange().overlaps(track.clips[j].timelineRange()) else { throw EditorCoreError.invalidModel("Overlapping clips on one track") }
                }
            }
        }
    }
    private func validateTemplate(_ template: TrackTemplate) throws {
        guard template.gain.isFinite, template.gain >= 0, (template.kind == .audio) == (template.audioLayout != nil) else { throw EditorCoreError.invalidModel("Invalid track settings") }
        try template.audioLayout?.validate()
        if template.kind == .video {
            guard template.routing.outputChannels.isEmpty else { throw EditorCoreError.invalidModel("Video track has audio routing") }
        } else if !template.routing.outputChannels.isEmpty {
            guard template.routing.outputChannels.count == template.audioLayout?.channels.count, template.routing.outputChannels.allSatisfy({ $0 >= 0 && $0 < settings.audioLayout.channels.count }) else { throw EditorCoreError.invalidModel("Invalid output channel map") }
        } else {
            guard template.audioLayout == settings.audioLayout else { throw EditorCoreError.invalidModel("An explicit output map is required for differing layouts") }
        }
    }
    private enum CodingKeys: String, CodingKey { case settings, assets, families, tracks, preferences }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(settings: try c.decode(SequenceSettings.self, forKey: .settings), assets: try c.decode([MediaAsset].self, forKey: .assets), families: try c.decode([TrackFamily].self, forKey: .families), tracks: try c.decode([TimelineTrack].self, forKey: .tracks), preferences: try c.decode(EditorPreferences.self, forKey: .preferences))
        try validate()
    }
}

public struct TimelineRenderPlan: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public var clipID: UUID
        public var assetID: UUID
        public var originalURL: URL?
        public var sourceStreams: [MediaStream]
        public var sourceRange: TimeRange
        public var timelineRange: TimeRange
        public var selection: ClipSelection
        public var scalingMode: ScalingMode
        public var trackID: UUID
        public var layerOrder: Int
        public var routing: AudioRouting
        public var gain: Double
    }
    public let settings: SequenceSettings
    public let components: [Component]
    public let duration: RationalTime
    public init(project: Project) throws {
        try project.validate()
        settings = project.settings
        var result: [Component] = []
        var end = RationalTime.zero
        for (order, track) in project.tracks.enumerated() {
            // Stable sorting prevents array insertion history from changing the canonical plan.
            let clips = try track.clips.sorted { a, b in
                let comparison = try a.timelineStart.compared(to: b.timelineStart)
                return comparison == .orderedAscending || (comparison == .orderedSame && a.id.uuidString < b.id.uuidString)
            }
            for clip in clips {
                let range = try clip.timelineRange()
                let clipEnd = try range.end()
                if try clipEnd.compared(to: end) == .orderedDescending { end = clipEnd }
                let asset = project.assets.first { $0.id == clip.assetID }!
                result.append(Component(clipID: clip.id, assetID: asset.id, originalURL: asset.originalURL, sourceStreams: asset.streams, sourceRange: clip.sourceRange, timelineRange: range, selection: clip.selection, scalingMode: clip.scalingMode, trackID: track.id, layerOrder: order, routing: track.template.routing, gain: track.template.gain))
            }
        }
        components = result; duration = end
    }
}

/// Synthetic timing fixture for exercising the core without a decoder or bundled media.
public enum DemoProjectFactory {
    public static func musicCollision() throws -> Project {
        let settings = try SequenceSettings()
        let template = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.8)
        let family = TrackFamily(baseName: "Music", template: template)
        let asset = MediaAsset(name: "Synthetic Music", duration: try RationalTime(30), streams: [MediaStream(index: 0, kind: .audio, audioLayout: .stereo)])
        let selection = ClipSelection.audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0), SourceChannel(streamIndex: 0, channelIndex: 1)], layout: .stereo))
        let a = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(5)), selection: selection)
        let b = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(10), duration: RationalTime(5)), timelineStart: try RationalTime(5), selection: selection)
        let track = TimelineTrack(familyID: family.id, template: template, clips: [a, b])
        return Project(settings: settings, assets: [asset], families: [family], tracks: [track])
    }
}
