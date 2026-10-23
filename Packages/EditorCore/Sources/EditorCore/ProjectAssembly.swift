import Foundation

public extension Project {
    /// Import into the bin without altering the sequence. Failed imports leave the project unchanged.
    mutating func addAsset(_ asset: MediaAsset) throws {
        var candidate = self
        candidate.assets.append(asset)
        try candidate.validate()
        self = candidate
    }

    /// Place the first picture and audio stream together, or a still for streamless image assets.
    /// A nil placement appends after the latest component on any track. Overlaps use sibling tracks.
    @discardableResult
    mutating func appendAsset(_ assetID: UUID, at time: RationalTime? = nil, sourceRange: TimeRange? = nil) throws -> [UUID] {
        try validate()
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            throw EditorCoreError.invalidModel("Missing media asset")
        }
        var audioSelections: [AudioSourceSelection] = []
        var routes: [AudioRouting] = []
        if let audio = asset.streams.first(where: { $0.kind == .audio }), let layout = audio.audioLayout,
           settings.audioLayout == .surround51, layout == .mono || layout == .stereo {
            // In a 5.1 sequence, stereo plays on front left/right and mono on centre.
            let channels = layout.channels.indices.map { SourceChannel(streamIndex: audio.index, channelIndex: $0) }
            audioSelections.append(AudioSourceSelection(channels: channels, layout: layout))
            routes.append(AudioRouting(outputChannels: layout == .mono ? [2] : [0, 1]))
            return try appendAsset(assetID, at: time, sourceRange: sourceRange, audioSelections: audioSelections, routing: routes)
        }
        if let audio = asset.streams.first(where: { $0.kind == .audio }), let layout = audio.audioLayout {
            let channels: [SourceChannel]
            if layout.channels.count == 1 && settings.audioLayout == .stereo {
                // Make dual mono explicit in the source map; output routing stays stereo identity.
                channels = [SourceChannel(streamIndex: audio.index, channelIndex: 0),
                            SourceChannel(streamIndex: audio.index, channelIndex: 0)]
            } else if layout == settings.audioLayout {
                channels = layout.channels.indices.map { SourceChannel(streamIndex: audio.index, channelIndex: $0) }
            } else {
                throw EditorCoreError.invalidModel("Audio layout needs an explicit channel selection before placement")
            }
            audioSelections.append(AudioSourceSelection(channels: channels, layout: settings.audioLayout))
        }
        return try appendAsset(assetID, at: time, sourceRange: sourceRange, audioSelections: audioSelections,
                               routing: audioSelections.map { _ in AudioRouting() })
    }

    /// Place picture with explicitly selected audio components and their output maps.
    /// Empty audio selections place picture only. Every component shares one link group.
    @discardableResult
    mutating func appendAsset(_ assetID: UUID, at time: RationalTime? = nil, sourceRange: TimeRange? = nil,
                              audioSelections: [AudioSourceSelection], routing: [AudioRouting]) throws -> [UUID] {
        try validate()
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            throw EditorCoreError.invalidModel("Missing media asset")
        }
        guard audioSelections.count == routing.count else {
            throw EditorCoreError.invalidModel("Every audio selection needs an output map")
        }
        // Check every source and destination before constructing any tracks or clips.
        for (selection, route) in zip(audioSelections, routing) {
            try selection.layout.validate()
            guard selection.channels.count == selection.layout.channels.count else {
                throw EditorCoreError.invalidModel("Incomplete source channel map")
            }
            for channel in selection.channels {
                guard let stream = asset.streams.first(where: { $0.index == channel.streamIndex && $0.kind == .audio }),
                      let layout = stream.audioLayout, channel.channelIndex >= 0,
                      channel.channelIndex < layout.channels.count else {
                    throw EditorCoreError.invalidModel("Missing source audio channel")
                }
            }
            if route.outputChannels.isEmpty {
                guard selection.layout == settings.audioLayout else {
                    throw EditorCoreError.invalidModel("An explicit output map is required for differing layouts")
                }
            } else {
                guard route.outputChannels.count == selection.channels.count,
                      route.outputChannels.allSatisfy({ $0 >= 0 && $0 < settings.audioLayout.channels.count }) else {
                    throw EditorCoreError.invalidModel("Invalid output channel map")
                }
            }
        }
        let start = try time ?? TimelineRenderPlan(project: self).duration
        let sourceRange = try sourceRange ?? asset.defaultPlacementRange()
        try sourceRange.validate()
        guard try sourceRange.end().compared(to: asset.duration) != .orderedDescending else {
            throw EditorCoreError.invalidModel("Source range exceeds media duration")
        }
        var selections: [(ClipSelection, AudioRouting)] = []
        if let video = asset.streams.first(where: { $0.kind == .video }) {
            selections.append((.video(streamIndex: video.index), AudioRouting()))
        } else if asset.streams.isEmpty {
            selections.append((.still, AudioRouting()))
        }
        selections.append(contentsOf: zip(audioSelections, routing).map { (.audio($0.0), $0.1) })
        guard !selections.isEmpty else { throw EditorCoreError.invalidModel("Media has no supported streams") }
        let linkGroup = selections.count > 1 ? UUID() : nil
        var candidate = self
        var clipIDs: [UUID] = []
        for (selection, route) in selections {
            let clip = TimelineClip(assetID: asset.id, sourceRange: sourceRange, timelineStart: start,
                                    selection: selection, linkGroupID: linkGroup)
            let template = TrackTemplate(kind: clip.requiredTrackKind, audioLayout: clip.requiredAudioLayout, routing: route)
            let familyID: UUID
            if let family = candidate.families.first(where: {
                $0.template == template
            }) {
                familyID = family.id
            } else {
                let family = TrackFamily(baseName: template.kind == .video ? "Video" : "Audio", template: template)
                candidate.families.append(family)
                familyID = family.id
            }
            // Existing siblings may have been reconfigured by an audio source edit.
            // Reuse only the complete template, including routing and gain.
            let trackID: UUID
            if let track = candidate.tracks.first(where: { $0.familyID == familyID && $0.template == template }) {
                trackID = track.id
            } else {
                let track = TimelineTrack(familyID: familyID, template: template)
                candidate.tracks.append(track)
                trackID = track.id
            }
            var engine = try TimelineEditEngine(project: candidate)
            try engine.apply(.place(clip: clip, trackID: trackID))
            candidate = engine.project
            clipIDs.append(clip.id)
        }
        try candidate.validate()
        self = candidate
        return clipIDs
    }

    /// Relink a missing original without changing stream identities or timeline edits.
    func replacingAssetLocation(id: UUID, url: URL) throws -> Project {
        guard let index = assets.firstIndex(where: { $0.id == id }) else {
            throw EditorCoreError.invalidModel("Missing media asset")
        }
        var candidate = self
        candidate.assets[index].originalURL = url
        try candidate.validate()
        return candidate
    }
}
