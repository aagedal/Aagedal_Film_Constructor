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
    mutating func appendAsset(_ assetID: UUID, at time: RationalTime? = nil) throws -> [UUID] {
        try validate()
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            throw EditorCoreError.invalidModel("Missing media asset")
        }
        let start = try time ?? TimelineRenderPlan(project: self).duration
        let sourceRange = try TimeRange(start: .zero, duration: asset.duration)
        var selections: [ClipSelection] = []
        if let video = asset.streams.first(where: { $0.kind == .video }) {
            selections.append(.video(streamIndex: video.index))
        } else if asset.streams.isEmpty {
            selections.append(.still)
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
            selections.append(.audio(AudioSourceSelection(channels: channels, layout: settings.audioLayout)))
        }
        guard !selections.isEmpty else { throw EditorCoreError.invalidModel("Media has no supported streams") }
        let linkGroup = selections.count > 1 ? UUID() : nil
        var candidate = self
        var clipIDs: [UUID] = []
        for selection in selections {
            let clip = TimelineClip(assetID: asset.id, sourceRange: sourceRange, timelineStart: start,
                                    selection: selection, linkGroupID: linkGroup)
            let template = TrackTemplate(kind: clip.requiredTrackKind, audioLayout: clip.requiredAudioLayout)
            let familyID: UUID
            if let family = candidate.families.first(where: {
                $0.template.kind == template.kind && $0.template.audioLayout == template.audioLayout
            }) {
                familyID = family.id
            } else {
                let family = TrackFamily(baseName: template.kind == .video ? "Video" : "Audio", template: template)
                candidate.families.append(family)
                familyID = family.id
            }
            var engine = try TimelineEditEngine(project: candidate)
            try engine.apply(.placeInFamily(clip: clip, familyID: familyID))
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
