import Foundation

/// Collision resolution preserves unrelated times; explicit ripple commands close time across tracks.
public enum EditCommand: Sendable {
    case place(clip: TimelineClip, trackID: UUID)
    case placeInFamily(clip: TimelineClip, familyID: UUID)
    case move(clipID: UUID, trackID: UUID, start: RationalTime)
    /// Linked components receive equal source/timeline deltas; source-bound failures roll back the whole group.
    case trim(clipID: UUID, sourceRange: TimeRange, timelineStart: RationalTime)
    /// A linked split requires the cut to be inside every component. Both resulting halves remain linked.
    /// Cuts inside active fades are rejected because an edge fade cannot preserve a partial envelope.
    case split(clipID: UUID, at: RationalTime)
    /// Shorten an aligned linked group at the playhead and close the removed interval
    /// across every track. Unrelated clips intersecting that interval reject the edit.
    case rippleTrim(clipID: UUID, edge: TimelineTrimEdge, at: RationalTime)
    case delete(clipID: UUID)
    /// Change only the selected audio component, preserving linked components.
    case setAudioCrossfade(outgoingClipID: UUID, incomingClipID: UUID, duration: RationalTime, curve: AudioFadeCurve = .equalPower)
    case removeAudioCrossfade(crossfadeID: UUID)
    /// Audio components take any curve; pictures fade their opacity linearly.
    case setFades(clipID: UUID, fadeIn: AudioFade, fadeOut: AudioFade)
    /// Set the linear volume of the listed audio components; other kinds are refused.
    case setGain(clipIDs: [UUID], gain: Double)
    /// Replace the volume automation of the listed audio components.
    case setVolumeKeyframes(clipIDs: [UUID], keyframes: [VolumeKeyframe])
    /// Change the speed of a clip and its linked components, keeping their source in and the
    /// source they play. Timeline length changes; overlaps move to sibling tracks.
    case setSpeed(clipID: UUID, speed: RationalTime)
    /// Colour-correct one picture component.
    case setColor(clipID: UUID, color: ColorAdjustment)
    /// Place one picture component; linked components keep their own transforms.
    case setTransform(clipID: UUID, transform: PictureTransform)
    /// Replace one audio component with explicitly mapped components, preserving linked picture/timing.
    case selectAudioSource(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting])
    /// Replace explicitly chosen, aligned linked audio components with one mapped component.
    case consolidateAudioSources(clipID: UUID, replacingClipIDs: [UUID], selection: AudioSourceSelection, routing: AudioRouting)
}

public enum TimelineEditError: Error, Equatable, Sendable {
    case missingClip, missingTrack, missingFamily, incompatibleTrack, duplicateClip
    case invalidSplit, unsupportedLinkedSplit
    case invalidRippleTrim, rippleTrimOverlap
    case invalidAudioCrossfade, missingAudioCrossfade
    case invalidAudioSelection, incompatibleAudioRouting, incompatibleAudioConsolidation
}

extension TimelineEditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAudioCrossfade:
            return "Choose ordered audio clips with compatible layouts and routing. Existing overlaps must match the crossfade duration; adjacent cuts need sufficient source handles. Paired edges must be free of independent fades and durations must use whole audio samples."
        case .invalidRippleTrim:
            return "Place the playhead inside the selected clip. Linked components must have matching start and end times."
        case .rippleTrimOverlap:
            return "Cannot ripple trim while another clip crosses the removed interval. Move or trim that clip first."
        case .missingAudioCrossfade: return "The audio crossfade no longer exists."
        default: return nil
        }
    }
}

/// Value snapshots make placement, sibling creation and cleanup one atomic history entry.
/// Drag previews should use a copy of this engine and discard it when cancelled.
public struct TimelineEditEngine: Sendable {
    public private(set) var project: Project
    private var undoHistory: [Project] = []
    private var redoHistory: [Project] = []
    public var canUndo: Bool { !undoHistory.isEmpty }
    public var canRedo: Bool { !redoHistory.isEmpty }

    public init(project: Project) throws {
        try Self.validate(project)
        self.project = project
    }

    public mutating func apply(_ command: EditCommand) throws {
        var candidate = project
        try Self.perform(command, in: &candidate)
        switch command {
        case .setAudioCrossfade, .removeAudioCrossfade: break
        default: Self.dissolveInvalidCrossfades(in: &candidate, previous: project)
        }
        try commit(candidate)
    }

    /// Returns component identities in selection order. The first component retains the selected ID.
    /// Inspect a copied engine for confirmation previews; committing applies one undoable transaction.
    @discardableResult
    public mutating func selectAudioSource(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting]) throws -> [UUID] {
        var candidate = project
        let ids = try Self.selectAudioSource(clipID: clipID, selections: selections, routing: routing, in: &candidate)
        Self.dissolveInvalidCrossfades(in: &candidate, previous: project)
        try commit(candidate)
        return ids
    }

    /// The selected identity survives; only the explicitly listed additional components are removed.
    public mutating func consolidateAudioSources(clipID: UUID, replacingClipIDs: [UUID], selection: AudioSourceSelection, routing: AudioRouting) throws {
        try apply(.consolidateAudioSources(clipID: clipID, replacingClipIDs: replacingClipIDs, selection: selection, routing: routing))
    }

    /// Dissolution removes only derived paired envelopes/handles. Standalone edge fades are preserved.
    /// Source remapping dissolves the relation even if timing remains compatible; unchanged mappings
    /// and jointly moved linked endpoints retain it while its geometry remains valid.
    private static func dissolveInvalidCrossfades(in candidate: inout Project, previous: Project) {
        guard !candidate.audioCrossfades.isEmpty else { return }
        let oldClips = Dictionary(previous.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let context = candidate.audioCrossfadeContext()
        var geometries: [UUID: AudioCrossfadeGeometry] = [:]
        let surviving = candidate.audioCrossfades.filter { relation in
            for id in [relation.outgoingClipID, relation.incomingClipID] {
                guard let old = oldClips[id],
                      let new = context.endpoints[id]?.clip,
                      old.selection == new.selection, old.assetID == new.assetID else { return false }
            }
            guard let geometry = try? candidate.audioCrossfadeGeometry(for: relation, context: context) else { return false }
            geometries[relation.id] = geometry
            return true
        }
        candidate.audioCrossfades = surviving
        // Dissolve only the two conflicting edges; unrelated relations remain untouched.
        var conflicts: Set<UUID> = []
        let outgoingByClip = Dictionary(surviving.map { ($0.outgoingClipID, $0) }, uniquingKeysWith: { first, _ in first })
        for incoming in surviving {
            if let outgoing = outgoingByClip[incoming.incomingClipID],
               let left = try? geometries[incoming.id]?.incomingTimelineRange.start.adding(incoming.duration),
               let right = try? geometries[outgoing.id]?.outgoingTimelineRange.end().subtracting(outgoing.duration),
               (try? left.compared(to: right)) == .orderedDescending {
                conflicts.insert(incoming.id); conflicts.insert(outgoing.id)
            }
        }
        candidate.audioCrossfades.removeAll { conflicts.contains($0.id) }
    }

    mutating func commit(_ proposed: Project) throws {
        var candidate = proposed
        if candidate.preferences.automaticallyRemoveEmptyTracks {
            candidate.tracks.removeAll { $0.clips.isEmpty && !$0.retained }
        }
        try Self.validate(candidate)
        guard candidate != project else { return }
        undoHistory.append(project)
        project = candidate
        redoHistory.removeAll()
    }

    public mutating func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(project)
        project = previous
    }

    public mutating func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(project)
        project = next
    }

    private static func validate(_ project: Project) throws {
        try project.validate()
    }

    private static func compatible(_ clip: TimelineClip, track: TimelineTrack) -> Bool {
        switch clip.selection {
        case .video, .still: return track.kind == .video
        case .audio(let selection): return track.kind == .audio && track.audioLayout == selection.layout
        }
    }

    private static func place(_ clip: TimelineClip, on trackID: UUID, in project: inout Project) throws {
        guard let targetIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw TimelineEditError.missingTrack
        }
        let target = project.tracks[targetIndex]
        guard compatible(clip, track: target) else { throw TimelineEditError.incompatibleTrack }
        let range = try TimeRange(start: clip.timelineStart, duration: clip.sourceRange.duration)
        func free(_ track: TimelineTrack) throws -> Bool {
            guard compatible(clip, track: track) else { return false }
            for existing in track.clips {
                if try range.overlaps(TimeRange(start: existing.timelineStart, duration: existing.sourceRange.duration)) { return false }
            }
            return true
        }
        if try free(target) {
            project.tracks[targetIndex].clips.append(clip)
        } else if let siblingIndex = try project.tracks.indices.first(where: {
            try project.tracks[$0].familyID == target.familyID && project.tracks[$0].template == target.template && free(project.tracks[$0])
        }) {
            project.tracks[siblingIndex].clips.append(clip)
        } else {
            let sibling = TimelineTrack(familyID: target.familyID, template: target.template, clips: [clip], muted: target.muted, soloed: target.soloed)
            project.tracks.insert(sibling, at: targetIndex + 1)
        }
    }

    private static func linked(to clipID: UUID, in project: Project) throws -> [(trackID: UUID, clip: TimelineClip)] {
        let all = project.tracks.flatMap { track in track.clips.map { (trackID: track.id, clip: $0) } }
        guard let selected = all.first(where: { $0.clip.id == clipID }) else { throw TimelineEditError.missingClip }
        guard let group = selected.clip.linkGroupID else { return [selected] }
        return all.filter { $0.clip.linkGroupID == group }
    }

    private static func remove(_ ids: Set<UUID>, from project: inout Project) {
        for index in project.tracks.indices { project.tracks[index].clips.removeAll { ids.contains($0.id) } }
    }

    private static func selectAudioSource(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], replacingClipIDs: [UUID] = [], in project: inout Project) throws -> [UUID] {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipID }) }),
              let selected = project.tracks[trackIndex].clips.first(where: { $0.id == clipID }) else {
            throw TimelineEditError.missingClip
        }
        guard case .audio = selected.selection, !selections.isEmpty, selections.count == routing.count else {
            throw TimelineEditError.invalidAudioSelection
        }
        let origin = project.tracks[trackIndex]
        if !replacingClipIDs.isEmpty {
            let eligible = Set(try project.audioConsolidationCandidates(for: clipID).map(\.id))
            guard selections.count == 1, Set(replacingClipIDs).count == replacingClipIDs.count,
                  replacingClipIDs.allSatisfy({ eligible.contains($0) }) else {
                throw TimelineEditError.incompatibleAudioConsolidation
            }
        }
        if replacingClipIDs.isEmpty, selections.count == 1, selected.selection == .audio(selections[0]), origin.template.routing == routing[0] {
            return [clipID]
        }
        for (selection, route) in zip(selections, routing) {
            try selection.layout.validate()
            guard selection.channels.count == selection.layout.channels.count else { throw TimelineEditError.invalidAudioSelection }
            if route.outputChannels.isEmpty {
                guard selection.layout == project.settings.audioLayout else { throw TimelineEditError.incompatibleAudioRouting }
            } else {
                guard route.outputChannels.count == selection.channels.count,
                      route.outputChannels.allSatisfy({ $0 >= 0 && $0 < project.settings.audioLayout.channels.count }) else {
                    throw TimelineEditError.incompatibleAudioRouting
                }
            }
        }
        remove(Set(replacingClipIDs + [clipID]), from: &project)
        let group = selected.linkGroupID ?? (selections.count > 1 ? UUID() : nil)
        var ids: [UUID] = []
        for (index, pair) in zip(selections, routing).enumerated() {
            var clip = selected
            if index > 0 { clip.id = UUID() }
            clip.selection = .audio(pair.0)
            clip.linkGroupID = group
            ids.append(clip.id)
            func available(_ track: TimelineTrack) throws -> Bool {
                guard track.familyID == origin.familyID, compatible(clip, track: track), track.template.routing == pair.1,
                      replacingClipIDs.isEmpty || track.template.gain == origin.template.gain else { return false }
                let range = try clip.timelineRange()
                return try !track.clips.contains(where: { try $0.timelineRange().overlaps(range) })
            }
            // Reconfigure only an empty originating track; other clips retain their interpretation.
            if let originalIndex = project.tracks.firstIndex(where: { $0.id == origin.id }), project.tracks[originalIndex].clips.isEmpty {
                project.tracks[originalIndex].template.audioLayout = pair.0.layout
                project.tracks[originalIndex].template.routing = pair.1
                project.tracks[originalIndex].clips.append(clip)
            } else if let destination = try project.tracks.indices.first(where: { try available(project.tracks[$0]) }) {
                project.tracks[destination].clips.append(clip)
            } else {
                var template = origin.template
                template.audioLayout = pair.0.layout
                template.routing = pair.1
                let sibling = TimelineTrack(familyID: origin.familyID, template: template, clips: [clip], muted: origin.muted, soloed: origin.soloed)
                let insertion = project.tracks.firstIndex(where: { $0.id == origin.id }).map { $0 + 1 } ?? project.tracks.count
                project.tracks.insert(sibling, at: insertion)
            }
        }
        return ids
    }

    private static func perform(_ command: EditCommand, in project: inout Project) throws {
        switch command {
        case .place(let clip, let trackID):
            guard !project.tracks.contains(where: { $0.clips.contains(where: { $0.id == clip.id }) }) else {
                throw TimelineEditError.duplicateClip
            }
            try place(clip, on: trackID, in: &project)
        case .placeInFamily(let clip, let familyID):
            guard let family = project.families.first(where: { $0.id == familyID }) else { throw TimelineEditError.missingFamily }
            if let track = project.tracks.first(where: { $0.familyID == familyID && compatible(clip, track: $0) }) {
                try perform(.place(clip: clip, trackID: track.id), in: &project)
            } else {
                let track = TimelineTrack(familyID: familyID, template: family.template)
                guard compatible(clip, track: track) else { throw TimelineEditError.incompatibleTrack }
                project.tracks.append(track)
                try perform(.place(clip: clip, trackID: track.id), in: &project)
            }
        case .move(let clipID, let trackID, let start):
            let components = try linked(to: clipID, in: project)
            let selected = components.first { $0.clip.id == clipID }!
            let delta = try start.subtracting(selected.clip.timelineStart)
            remove(Set(components.map { $0.clip.id }), from: &project)
            for component in components {
                var clip = component.clip
                clip.timelineStart = try clip.timelineStart.adding(delta)
                try place(clip, on: clip.id == clipID ? trackID : component.trackID, in: &project)
            }
        case .trim(let clipID, let range, let start):
            let components = try linked(to: clipID, in: project)
            let selected = components.first { $0.clip.id == clipID }!
            let sourceDelta = try range.start.subtracting(selected.clip.sourceRange.start)
            let durationDelta = try range.duration.subtracting(selected.clip.sourceRange.duration)
            let timelineDelta = try start.subtracting(selected.clip.timelineStart)
            remove(Set(components.map { $0.clip.id }), from: &project)
            for component in components {
                var clip = component.clip
                clip.sourceRange = try TimeRange(start: clip.sourceRange.start.adding(sourceDelta), duration: clip.sourceRange.duration.adding(durationDelta))
                clip.timelineStart = try clip.timelineStart.adding(timelineDelta)
                if try clip.fadeIn.duration.compared(to: clip.sourceRange.duration) == .orderedDescending { clip.fadeIn.duration = clip.sourceRange.duration }
                if try clip.fadeOut.duration.compared(to: clip.sourceRange.duration) == .orderedDescending { clip.fadeOut.duration = clip.sourceRange.duration }
                try place(clip, on: component.trackID, in: &project)
            }
        case .rippleTrim(let clipID, let edge, let at):
            let components = try linked(to: clipID, in: project)
            let selected = components.first { $0.clip.id == clipID }!.clip
            let end = try selected.timelineRange().end()
            guard try at.compared(to: selected.timelineStart) == .orderedDescending,
                  try at.compared(to: end) == .orderedAscending,
                  components.allSatisfy({ $0.clip.timelineStart == selected.timelineStart && $0.clip.sourceRange.duration == selected.sourceRange.duration }) else {
                throw TimelineEditError.invalidRippleTrim
            }
            let removed = try TimeRange(start: edge == .leading ? selected.timelineStart : at,
                                        duration: edge == .leading ? at.subtracting(selected.timelineStart) : end.subtracting(at))
            let removedEnd = try removed.end()
            let ids = Set(components.map { $0.clip.id })
            // Refuse implicit destructive edits to overlapping layers or connected clips.
            // Also preserve a link group that would otherwise straddle the ripple boundary.
            var shiftedGroups: Set<UUID> = []
            var stationaryGroups: Set<UUID> = []
            for clip in project.tracks.flatMap(\.clips) where !ids.contains(clip.id) {
                guard try !clip.timelineRange().overlaps(removed) else { throw TimelineEditError.rippleTrimOverlap }
                if let group = clip.linkGroupID {
                    if try clip.timelineStart.compared(to: removedEnd) != .orderedAscending { shiftedGroups.insert(group) }
                    else { stationaryGroups.insert(group) }
                }
            }
            guard shiftedGroups.isDisjoint(with: stationaryGroups) else { throw TimelineEditError.rippleTrimOverlap }
            for ti in project.tracks.indices {
                for ci in project.tracks[ti].clips.indices {
                    var clip = project.tracks[ti].clips[ci]
                    if ids.contains(clip.id) {
                        clip.sourceRange = try TimeRange(
                            start: edge == .leading ? clip.sourceTime(atTimelineOffset: removed.duration) : clip.sourceRange.start,
                            duration: clip.sourceRange.duration.subtracting(removed.duration))
                        // The remaining picture starts at the old cut after a leading ripple.
                        if try clip.fadeIn.duration.compared(to: clip.sourceRange.duration) == .orderedDescending { clip.fadeIn.duration = clip.sourceRange.duration }
                        if try clip.fadeOut.duration.compared(to: clip.sourceRange.duration) == .orderedDescending { clip.fadeOut.duration = clip.sourceRange.duration }
                    } else if try clip.timelineStart.compared(to: removedEnd) != .orderedAscending {
                        clip.timelineStart = try clip.timelineStart.subtracting(removed.duration)
                    }
                    project.tracks[ti].clips[ci] = clip
                }
            }
        case .split(let clipID, let at):
            let components = try linked(to: clipID, in: project)
            let ids = Set(components.map { $0.clip.id })
            for relation in project.audioCrossfades where ids.contains(relation.outgoingClipID) || ids.contains(relation.incomingClipID) {
                let geometry = try project.audioCrossfadeGeometry(for: relation)
                let fadeStart = geometry.incomingTimelineRange.start
                let fadeEnd = try fadeStart.adding(relation.duration)
                guard try at.compared(to: fadeStart) != .orderedDescending || at.compared(to: fadeEnd) != .orderedAscending else {
                    throw TimelineEditError.invalidSplit
                }
            }
            // Split outside paired envelopes dissolves the pair, preserving standalone outer fades.
            project.audioCrossfades.removeAll { ids.contains($0.outgoingClipID) || ids.contains($0.incomingClipID) }
            let rightGroup = components.first?.clip.linkGroupID == nil ? nil : UUID()
            remove(Set(components.map { $0.clip.id }), from: &project)
            for component in components {
                var left = component.clip
                let leftDuration = try at.subtracting(left.timelineStart)
                guard leftDuration.numerator > 0,
                      try leftDuration.compared(to: left.sourceRange.duration) == .orderedAscending else {
                    throw components.count > 1 ? TimelineEditError.unsupportedLinkedSplit : TimelineEditError.invalidSplit
                }
                // A partial envelope cannot be represented by an edge fade without changing its sound.
                let fadeOutStart = try left.sourceRange.duration.subtracting(left.fadeOut.duration)
                guard try leftDuration.compared(to: left.fadeIn.duration) != .orderedAscending,
                      try leftDuration.compared(to: fadeOutStart) != .orderedDescending else {
                    throw components.count > 1 ? TimelineEditError.unsupportedLinkedSplit : TimelineEditError.invalidSplit
                }
                var right = left
                left.fadeOut = .init()
                right.fadeIn = .init()
                right.id = UUID()
                right.linkGroupID = rightGroup
                right.timelineStart = at
                right.sourceRange = try TimeRange(start: left.sourceTime(atTimelineOffset: leftDuration), duration: left.sourceRange.duration.subtracting(leftDuration))
                left.sourceRange = try TimeRange(start: left.sourceRange.start, duration: leftDuration)
                try place(left, on: component.trackID, in: &project)
                try place(right, on: component.trackID, in: &project)
            }
        case .setAudioCrossfade(let outgoingID, let incomingID, let duration, let curve):
            if let index = project.audioCrossfades.firstIndex(where: { $0.outgoingClipID == outgoingID && $0.incomingClipID == incomingID }) {
                project.audioCrossfades[index].duration = duration
                project.audioCrossfades[index].curve = curve
            } else {
                project.audioCrossfades.append(AudioCrossfade(outgoingClipID: outgoingID, incomingClipID: incomingID, duration: duration, curve: curve))
            }
        case .removeAudioCrossfade(let id):
            guard let index = project.audioCrossfades.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingAudioCrossfade }
            project.audioCrossfades.remove(at: index)
        case .setFades(let clipID, let fadeIn, let fadeOut):
            guard let trackIndex = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
                  let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else { throw TimelineEditError.missingClip }
            project.tracks[trackIndex].clips[clipIndex].fadeIn = fadeIn
            project.tracks[trackIndex].clips[clipIndex].fadeOut = fadeOut
        case .setGain(let clipIDs, let gain):
            guard !clipIDs.isEmpty else { throw TimelineEditError.missingClip }
            for id in clipIDs {
                guard let t = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
                      let c = project.tracks[t].clips.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingClip }
                guard project.tracks[t].clips[c].requiredTrackKind == .audio else { throw TimelineEditError.invalidAudioSelection }
                project.tracks[t].clips[c].gain = gain
            }
        case .setVolumeKeyframes(let clipIDs, let keyframes):
            guard !clipIDs.isEmpty else { throw TimelineEditError.missingClip }
            for id in clipIDs {
                guard let t = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
                      let c = project.tracks[t].clips.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingClip }
                guard project.tracks[t].clips[c].requiredTrackKind == .audio else { throw TimelineEditError.invalidAudioSelection }
                project.tracks[t].clips[c].volumeKeyframes = keyframes
            }
        case .setSpeed(let clipID, let speed):
            let components = try linked(to: clipID, in: project)
            // Keep picture lengths on whole frames, else whole audio samples.
            let grid = components.contains { $0.clip.requiredTrackKind == .video } ? project.settings.frameRate.value : try RationalTime(Int64(project.settings.audioSampleRate))
            let selected = components.first { $0.clip.id == clipID }!.clip
            let extent = try selected.sourceExtent().divided(by: speed).multiplied(by: grid)
            let units = max(1, extent.numerator / extent.denominator)
            let duration = try RationalTime(units).divided(by: grid)
            remove(Set(components.map { $0.clip.id }), from: &project)
            for component in components {
                var clip = component.clip
                guard clip.selection != .still else { throw EditorCoreError.invalidModel("Stills have no speed") }
                clip.speed = speed
                clip.sourceRange.duration = duration
                if try clip.fadeIn.duration.compared(to: duration) == .orderedDescending { clip.fadeIn.duration = duration }
                if try clip.fadeOut.duration.compared(to: duration) == .orderedDescending { clip.fadeOut.duration = duration }
                try place(clip, on: component.trackID, in: &project)
            }
        case .setColor(let clipID, let color):
            guard let t = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
                  let c = project.tracks[t].clips.firstIndex(where: { $0.id == clipID }) else { throw TimelineEditError.missingClip }
            guard project.tracks[t].clips[c].requiredTrackKind == .video else { throw TimelineEditError.incompatibleTrack }
            project.tracks[t].clips[c].color = color
        case .setTransform(let clipID, let transform):
            guard let t = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
                  let c = project.tracks[t].clips.firstIndex(where: { $0.id == clipID }) else { throw TimelineEditError.missingClip }
            guard project.tracks[t].clips[c].requiredTrackKind == .video else { throw TimelineEditError.incompatibleTrack }
            project.tracks[t].clips[c].transform = transform
        case .delete(let clipID):
            let components = try linked(to: clipID, in: project)
            remove(Set(components.map { $0.clip.id }), from: &project)
        case .selectAudioSource(let clipID, let selections, let routing):
            _ = try selectAudioSource(clipID: clipID, selections: selections, routing: routing, in: &project)
        case .consolidateAudioSources(let clipID, let replacingClipIDs, let selection, let routing):
            guard !replacingClipIDs.isEmpty else { throw TimelineEditError.incompatibleAudioConsolidation }
            _ = try selectAudioSource(clipID: clipID, selections: [selection], routing: [routing], replacingClipIDs: replacingClipIDs, in: &project)
        }
    }
}
