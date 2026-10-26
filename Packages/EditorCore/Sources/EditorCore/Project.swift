import Foundation

public struct Project: Equatable, Codable, Sendable {
    public var settings: SequenceSettings
    public var assets: [MediaAsset]
    public var mediaBins: [MediaBin]
    /// Assets without an assignment live at the root of the media browser.
    public var assetBinAssignments: [UUID: UUID]
    public var families: [TrackFamily]
    /// Frontmost video track first. Render consumers must preserve this explicit order.
    public var tracks: [TimelineTrack]
    public var audioCrossfades: [AudioCrossfade]
    public var preferences: EditorPreferences
    /// The open sequence is `settings`, `families`, `tracks` and `audioCrossfades`; the
    /// project's other sequences are stored whole and swapped in when opened.
    public var sequenceID: UUID
    public var sequenceName: String
    public var storedSequences: [StoredSequence]
    /// Sequences without an assignment live at the root of the media browser.
    public var sequenceBinAssignments: [UUID: UUID]
    public init(settings: SequenceSettings, assets: [MediaAsset] = [], families: [TrackFamily] = [], tracks: [TimelineTrack] = [], preferences: EditorPreferences = .init(), audioCrossfades: [AudioCrossfade] = [], mediaBins: [MediaBin] = [], assetBinAssignments: [UUID: UUID] = [:],
                sequenceID: UUID = Project.defaultSequenceID, sequenceName: String = Project.defaultSequenceName, storedSequences: [StoredSequence] = [], sequenceBinAssignments: [UUID: UUID] = [:]) {
        self.mediaBins = mediaBins; self.assetBinAssignments = assetBinAssignments
        self.sequenceID = sequenceID; self.sequenceName = sequenceName; self.storedSequences = storedSequences; self.sequenceBinAssignments = sequenceBinAssignments
        self.settings = settings; self.assets = assets; self.families = families; self.tracks = tracks; self.preferences = preferences; self.audioCrossfades = audioCrossfades
    }
    /// Validate at document decoding/edit commit boundaries; mutable value models can represent an in-progress edit.
    public func validate() throws {
        try settings.validate()
        func unique(_ ids: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw EditorCoreError.invalidModel("Duplicate identity") }
        }
        try unique(assets.map(\.id)); try unique(families.map(\.id)); try unique(tracks.map(\.id)); try unique(tracks.flatMap { $0.clips.map(\.id) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let familiesByID = Dictionary(uniqueKeysWithValues: families.map { ($0.id, $0) })
        try validateMediaBins()
        try validateSequences()
        try validateAudioCrossfades()
        for asset in assets {
            guard asset.duration.numerator > 0, Set(asset.streams.map(\.index)).count == asset.streams.count else { throw EditorCoreError.invalidModel("Invalid asset duration or stream identities") }
            if let title = asset.title {
                try title.validate()
                guard asset.streams.isEmpty else { throw EditorCoreError.invalidModel("A title has no media streams") }
            }
            if let proxy = asset.proxy {
                try proxy.validate()
                guard asset.streams.contains(where: { $0.index == proxy.videoStreamIndex && $0.kind == .video }) else {
                    throw EditorCoreError.invalidModel("Proxy references a missing video stream")
                }
            }
            for stream in asset.streams {
                guard stream.index >= 0, (stream.kind == .audio) == (stream.audioLayout != nil) else { throw EditorCoreError.invalidModel("Invalid source stream") }
                try stream.audioLayout?.validate()
                if let format = stream.videoFormat {
                    guard stream.kind == .video else { throw EditorCoreError.invalidModel("Video format on an audio stream") }
                    try format.validate()
                }
            }
        }
        for family in families {
            guard !family.baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditorCoreError.invalidModel("Empty family name") }
            try validateTemplate(family.template)
        }
        for track in tracks {
            guard let family = familiesByID[track.familyID], family.template.kind == track.kind else { throw EditorCoreError.invalidModel("Missing or incompatible track family") }
            try validateTemplate(track.template)
            for clip in track.clips {
                guard clip.requiredTrackKind == track.kind, clip.requiredAudioLayout == track.audioLayout, let asset = assetsByID[clip.assetID] else { throw EditorCoreError.invalidModel("Missing asset or incompatible track") }
                try clip.sourceRange.validate()
                try clip.fadeIn.validate(duration: clip.sourceRange.duration)
                try clip.fadeOut.validate(duration: clip.sourceRange.duration)
                // Clip volume is at most +24 dB, and only audio has volume.
                guard clip.gain.isFinite, clip.gain >= 0, clip.gain <= 16, clip.requiredTrackKind == .audio || clip.gain == 1 else {
                    throw EditorCoreError.invalidModel("Invalid clip volume")
                }
                try clip.transform.validate()
                try VolumeEnvelope.validate(clip.volumeKeyframes)
                try clip.color.validate()
                try PictureAnimation.validate(clip.transformKeyframes)
                try clip.eq.validate()
                try clip.key?.validate()
                try clip.dynamics?.validate()
                guard clip.requiredTrackKind == .audio || clip.dynamics == nil else { throw EditorCoreError.invalidModel("Pictures have no dynamics") }
                guard clip.requiredTrackKind == .video || clip.key == nil else { throw EditorCoreError.invalidModel("Audio has no key") }
                guard clip.requiredTrackKind == .audio || clip.eq.isFlat else { throw EditorCoreError.invalidModel("Pictures have no EQ") }
                guard clip.requiredTrackKind == .video || clip.transformKeyframes.isEmpty else { throw EditorCoreError.invalidModel("Audio has no position keyframes") }
                guard clip.requiredTrackKind == .video || clip.color.isNeutral else { throw EditorCoreError.invalidModel("Audio has no colour") }
                guard clip.requiredTrackKind == .audio || clip.volumeKeyframes.isEmpty else { throw EditorCoreError.invalidModel("Pictures have no volume") }
                guard clip.requiredTrackKind == .video || clip.transform.isIdentity else { throw EditorCoreError.invalidModel("Audio has no picture transform") }
                // Picture fades are linear opacity ramps over lower layers or black.
                guard clip.requiredTrackKind == .audio || (clip.fadeIn.curve == .linear && clip.fadeOut.curve == .linear) else {
                    throw EditorCoreError.invalidModel("Picture fades are linear")
                }
                _ = try clip.timelineRange()
                // Speeds from 10% to 1000%; stills hold one picture and have no speed.
                guard try clip.speed.compared(to: RationalTime(1, 10)) != .orderedAscending, try clip.speed.compared(to: RationalTime(10)) != .orderedDescending,
                      clip.selection != .still || clip.speed == .one else { throw EditorCoreError.invalidModel("Speed must be 10–1000%, and stills have no speed") }
                guard try clip.sourceEnd().compared(to: asset.duration) != .orderedDescending else { throw EditorCoreError.invalidModel("Source range exceeds media") }
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
            // Positive-length intervals overlap iff two neighboring intervals in start
            // order overlap. Preserve stored clip order and compare exact rational times.
            let ranges = try track.clips.map { try $0.timelineRange() }.sorted {
                try $0.start.compared(to: $1.start) == .orderedAscending
            }
            for index in ranges.indices.dropFirst() {
                guard try ranges[index - 1].end().compared(to: ranges[index].start) != .orderedDescending else {
                    throw EditorCoreError.invalidModel("Overlapping clips on one track")
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
    private enum CodingKeys: String, CodingKey { case settings, assets, families, tracks, preferences, audioCrossfades, mediaBins, assetBinAssignments, sequenceID, sequenceName, storedSequences, sequenceBinAssignments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(settings: try c.decode(SequenceSettings.self, forKey: .settings), assets: try c.decode([MediaAsset].self, forKey: .assets), families: try c.decode([TrackFamily].self, forKey: .families), tracks: try c.decode([TimelineTrack].self, forKey: .tracks), preferences: try c.decode(EditorPreferences.self, forKey: .preferences), audioCrossfades: try c.decodeIfPresent([AudioCrossfade].self, forKey: .audioCrossfades) ?? [], mediaBins: try c.decodeIfPresent([MediaBin].self, forKey: .mediaBins) ?? [], assetBinAssignments: try c.decodeIfPresent([UUID: UUID].self, forKey: .assetBinAssignments) ?? [:],
                  sequenceID: try c.decodeIfPresent(UUID.self, forKey: .sequenceID) ?? Self.defaultSequenceID,
                  sequenceName: try c.decodeIfPresent(String.self, forKey: .sequenceName) ?? Self.defaultSequenceName,
                  storedSequences: try c.decodeIfPresent([StoredSequence].self, forKey: .storedSequences) ?? [],
                  sequenceBinAssignments: try c.decodeIfPresent([UUID: UUID].self, forKey: .sequenceBinAssignments) ?? [:])
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
        public var fadeIn: AudioFade = .init()
        public var fadeOut: AudioFade = .init()
        public var transform: PictureTransform = .identity
        public var volumeKeyframes: [VolumeKeyframe] = []
        public var color: ColorAdjustment = .neutral
        /// Source seconds per timeline second; `sourceRange.duration` stays in timeline time.
        public var speed: RationalTime = .one
        public var transformKeyframes: [TransformKeyframe] = []
        /// A wipe that uncovers this picture over the timeline interval, from the left edge
        /// rightwards (or from the right edge leftwards).
        public struct Reveal: Equatable, Sendable {
            public let start: RationalTime
            public let duration: RationalTime
            public let fromLeft: Bool
        }
        public var reveal: Reveal?
        public var eq: AudioEQ = .flat
        public var key: ChromaKey?
        public var dynamics: AudioDynamics?
        /// Whether the picture is scaled, moved, animated or translucent rather than filling the frame as is.
        public var hasPlacement: Bool { !transform.isIdentity || !transformKeyframes.isEmpty || reveal != nil || key != nil }
        /// Keyframe times on the sequence timeline, in seconds.
        public func timelineSeconds(ofSource time: RationalTime) -> Double {
            timelineRange.start.seconds + (time.seconds - sourceRange.start.seconds) / speed.seconds
        }
        /// Source time consumed by the component.
        public func sourceExtent() throws -> RationalTime { try sourceRange.duration.multiplied(by: speed) }
        /// Front-to-back picture order. Upper tracks are in front; within one track only a
        /// dissolve overlaps, and its incoming (later) picture is in front.
        public static func isInFront(_ a: Self, of b: Self) -> Bool {
            if a.layerOrder != b.layerOrder { return a.layerOrder < b.layerOrder }
            if a.timelineRange.start != b.timelineRange.start {
                return (try? a.timelineRange.start.compared(to: b.timelineRange.start)) == .orderedDescending
            }
            return a.clipID.uuidString < b.clipID.uuidString
        }
    }
    public let settings: SequenceSettings
    public let components: [Component]
    public let duration: RationalTime
    public init(project: Project) throws {
        try project.validate()
        settings = project.settings
        let assetsByID = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let incomingByClip = Dictionary(uniqueKeysWithValues: project.audioCrossfades.map { ($0.incomingClipID, $0) })
        let outgoingByClip = Dictionary(uniqueKeysWithValues: project.audioCrossfades.map { ($0.outgoingClipID, $0) })
        var geometries: [UUID: AudioCrossfadeGeometry] = [:]
        if !project.audioCrossfades.isEmpty {
            let context = project.audioCrossfadeContext()
            for relation in project.audioCrossfades {
                geometries[relation.id] = try project.audioCrossfadeGeometry(for: relation, context: context)
            }
        }
        var result: [Component] = []
        result.reserveCapacity(project.tracks.reduce(0) { $0 + $1.clips.count })
        var end = RationalTime.zero
        let soloing = project.tracks.contains { $0.kind == .audio && $0.soloed }
        for (order, track) in project.tracks.enumerated() {
            // Muted tracks, and unsoloed sound while another track is soloed, are left out.
            if track.muted || (soloing && track.kind == .audio && !track.soloed) { continue }
            // Stable sorting prevents array insertion history from changing the canonical plan.
            let clips = try track.clips.sorted { a, b in
                let comparison = try a.timelineStart.compared(to: b.timelineStart)
                return comparison == .orderedAscending || (comparison == .orderedSame && a.id.uuidString < b.id.uuidString)
            }
            for clip in clips {
                let range = try clip.timelineRange()
                let clipEnd = try range.end()
                if try clipEnd.compared(to: end) == .orderedDescending { end = clipEnd }
                let asset = assetsByID[clip.assetID]!
                var sourceRange = clip.sourceRange
                var renderRange = range
                var fadeIn = clip.fadeIn, fadeOut = clip.fadeOut
                var transformKeyframes = clip.transformKeyframes
                var reveal: Component.Reveal?
                if let incoming = incomingByClip[clip.id] {
                    let geometry = geometries[incoming.id]!
                    sourceRange = geometry.incomingSourceRange
                    renderRange = geometry.incomingTimelineRange
                    if clip.requiredTrackKind == .video, let style = incoming.style, style.isWipe {
                        reveal = .init(start: renderRange.start, duration: incoming.duration, fromLeft: style == .wipeRight)
                    } else if clip.requiredTrackKind == .video, let style = incoming.style {
                        // The incoming picture moves in across the transition instead of fading.
                        let start = sourceRange.start
                        transformKeyframes = [TransformKeyframe(time: start, offsetX: style.incomingFrom),
                                              TransformKeyframe(time: try start.adding(incoming.duration.multiplied(by: clip.speed)))]
                    } else {
                        fadeIn = AudioFade(duration: incoming.duration, curve: incoming.curve)
                    }
                }
                if let outgoing = outgoingByClip[clip.id] {
                    let geometry = geometries[outgoing.id]!
                    let extensionDuration = try geometry.outgoingSourceRange.duration.subtracting(clip.sourceRange.duration)
                    sourceRange.duration = try sourceRange.duration.adding(extensionDuration)
                    renderRange.duration = try renderRange.duration.adding(extensionDuration)
                    // A dissolve keeps the outgoing picture opaque beneath the incoming one; a push moves it out.
                    if clip.requiredTrackKind == .audio { fadeOut = AudioFade(duration: outgoing.duration, curve: outgoing.curve) }
                    else if let target = outgoing.style?.outgoingTo {
                        let end = try sourceRange.start.adding(sourceRange.duration.multiplied(by: clip.speed))
                        // A clip moved in by one transition and out by the next keeps both moves.
                        transformKeyframes += [TransformKeyframe(time: try end.subtracting(outgoing.duration.multiplied(by: clip.speed))),
                                               TransformKeyframe(time: end, offsetX: target)]
                    }
                }
                result.append(Component(clipID: clip.id, assetID: asset.id, originalURL: asset.originalURL, sourceStreams: asset.streams, sourceRange: sourceRange, timelineRange: renderRange, selection: clip.selection, scalingMode: clip.scalingMode, trackID: track.id, layerOrder: order, routing: track.template.routing, gain: track.template.gain * clip.gain, fadeIn: fadeIn, fadeOut: fadeOut, transform: clip.transform, volumeKeyframes: clip.volumeKeyframes, color: clip.color, speed: clip.speed, transformKeyframes: transformKeyframes, reveal: reveal, eq: clip.eq, key: clip.key, dynamics: clip.dynamics))
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
