import Foundation

/// How a source range enters the timeline at a position.
public enum PlacementMode: Sendable {
    /// Place on the first free tracks, creating siblings where clips overlap.
    case place
    /// Open a gap across every track and place into it, shifting later clips.
    case insert
    /// Replace whatever occupies the destination tracks during the source range.
    case overwrite
}

public extension Project {
    /// Places an asset at `time` using `mode`. Returns the new clip IDs (picture first).
    @discardableResult
    mutating func placeAsset(_ assetID: UUID, at time: RationalTime, sourceRange: TimeRange? = nil, mode: PlacementMode) throws -> [UUID] {
        guard let asset = assets.first(where: { $0.id == assetID }) else { throw EditorCoreError.invalidModel("Missing media asset") }
        let duration = try (sourceRange ?? asset.defaultPlacementRange()).duration
        var candidate = self
        switch mode {
        case .place: break
        case .insert:
            try candidate.openGap(at: time, duration: duration)
        case .overwrite:
            // Learn the destination tracks by placing past the end, where nothing collides.
            var probe = candidate
            let end = try TimelineRenderPlan(project: probe).duration
            let ids = Set(try probe.appendAsset(assetID, at: end, sourceRange: sourceRange))
            let targets = Set(probe.tracks.filter { $0.clips.contains { ids.contains($0.id) } }.map(\.id))
            try candidate.clear(TimeRange(start: time, duration: duration), onTracks: targets)
        }
        let ids = try candidate.appendAsset(assetID, at: time, sourceRange: sourceRange)
        var engine = try TimelineEditEngine(project: self)
        try engine.commit(candidate)
        self = engine.project
        return ids
    }

    /// Splits clips crossing `time` and moves everything from `time` onwards later by `duration`.
    mutating func openGap(at time: RationalTime, duration: RationalTime) throws {
        guard duration.numerator > 0 else { return }
        var engine = try TimelineEditEngine(project: self)
        var crossing: Set<UUID> = []
        for clip in engine.project.tracks.flatMap(\.clips) {
            let range = try clip.timelineRange()
            if try clip.timelineStart.compared(to: time) == .orderedAscending, try range.end().compared(to: time) == .orderedDescending {
                crossing.insert(clip.id)
            }
        }
        // Split each crossing link group once; the split covers its linked components.
        var handled: Set<UUID> = []
        for id in crossing where !handled.contains(id) {
            guard let clip = engine.project.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
            let group = engine.project.tracks.flatMap(\.clips).filter { $0.id == id || (clip.linkGroupID != nil && $0.linkGroupID == clip.linkGroupID) }
            handled.formUnion(group.map(\.id))
            do { try engine.apply(.split(clipID: id, at: time)) }
            catch { throw EditorCoreError.invalidModel("Cannot insert inside a fade, transition or partly linked clip at the playhead. Move the playhead to a cut or remove the fade first.") }
        }
        var project = engine.project
        for t in project.tracks.indices {
            for c in project.tracks[t].clips.indices where try project.tracks[t].clips[c].timelineStart.compared(to: time) != .orderedAscending {
                project.tracks[t].clips[c].timelineStart = try project.tracks[t].clips[c].timelineStart.adding(duration)
            }
        }
        project.dropBrokenTransitions()
        try project.validate()
        self = project
    }

    /// Removes relations whose clips no longer meet, for example after a gap opened at their cut.
    mutating func dropBrokenTransitions() {
        let context = audioCrossfadeContext()
        let snapshot = self
        audioCrossfades.removeAll { (try? snapshot.audioCrossfadeGeometry(for: $0, context: context)) == nil }
    }

    /// Removes the parts of clips on `trackIDs` inside `range`, trimming or splitting clips at its edges.
    /// Right-hand remainders of a split share a new link group per original group.
    mutating func clear(_ range: TimeRange, onTracks trackIDs: Set<UUID>) throws {
        let start = range.start, end = try range.end()
        var rightGroups: [UUID: UUID] = [:]
        var project = self
        for t in project.tracks.indices where trackIDs.contains(project.tracks[t].id) {
            var kept: [TimelineClip] = []
            for clip in project.tracks[t].clips {
                let clipEnd = try clip.timelineRange().end()
                let startsBefore = try clip.timelineStart.compared(to: start) == .orderedAscending
                let endsAfter = try clipEnd.compared(to: end) == .orderedDescending
                guard try clipEnd.compared(to: start) == .orderedDescending, try clip.timelineStart.compared(to: end) == .orderedAscending else {
                    kept.append(clip); continue
                }
                if startsBefore {
                    var left = clip
                    left.sourceRange.duration = try start.subtracting(clip.timelineStart)
                    left.fadeOut = .init()
                    if try left.fadeIn.duration.compared(to: left.sourceRange.duration) == .orderedDescending { left.fadeIn.duration = left.sourceRange.duration }
                    kept.append(left)
                }
                if endsAfter {
                    var right = clip
                    let removed = try end.subtracting(clip.timelineStart)
                    if startsBefore {
                        right.id = UUID()
                        right.linkGroupID = clip.linkGroupID.map { group in
                            if let existing = rightGroups[group] { return existing }
                            let fresh = UUID(); rightGroups[group] = fresh; return fresh
                        }
                    }
                    if clip.selection != .still { right.sourceRange.start = try clip.sourceTime(atTimelineOffset: removed) }
                    right.sourceRange.duration = try clip.sourceRange.duration.subtracting(removed)
                    right.timelineStart = end
                    right.fadeIn = .init()
                    if try right.fadeOut.duration.compared(to: right.sourceRange.duration) == .orderedDescending { right.fadeOut.duration = right.sourceRange.duration }
                    kept.append(right)
                }
            }
            project.tracks[t].clips = kept
        }
        // Drop transitions whose endpoints changed; untouched relations survive.
        let clips = Dictionary(project.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let previous = Dictionary(tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        project.audioCrossfades.removeAll { relation in
            [relation.outgoingClipID, relation.incomingClipID].contains { clips[$0] == nil || clips[$0] != previous[$0] }
        }
        try project.validate()
        self = project
    }
}

extension TimelineEditEngine {
    /// Deletes a clip with its linked components and closes the gap across every track.
    /// Unrelated clips crossing the removed interval refuse the edit, like a ripple trim.
    public mutating func rippleDelete(clipID: UUID) throws {
        let all = project.tracks.flatMap(\.clips)
        guard let selected = all.first(where: { $0.id == clipID }) else { throw TimelineEditError.missingClip }
        let group = all.filter { $0.id == clipID || (selected.linkGroupID != nil && $0.linkGroupID == selected.linkGroupID) }
        let ids = Set(group.map(\.id))
        var start = selected.timelineStart, end = try selected.timelineRange().end()
        for clip in group {
            if try clip.timelineStart.compared(to: start) == .orderedAscending { start = clip.timelineStart }
            let clipEnd = try clip.timelineRange().end()
            if try clipEnd.compared(to: end) == .orderedDescending { end = clipEnd }
        }
        let removed = try TimeRange(start: start, duration: end.subtracting(start))
        var shiftedGroups: Set<UUID> = [], stationaryGroups: Set<UUID> = []
        for clip in all where !ids.contains(clip.id) {
            guard try !clip.timelineRange().overlaps(removed) else { throw TimelineEditError.rippleTrimOverlap }
            if let group = clip.linkGroupID {
                if try clip.timelineStart.compared(to: end) != .orderedAscending { shiftedGroups.insert(group) } else { stationaryGroups.insert(group) }
            }
        }
        guard shiftedGroups.isDisjoint(with: stationaryGroups) else { throw TimelineEditError.rippleTrimOverlap }
        var candidate = project
        for t in candidate.tracks.indices {
            candidate.tracks[t].clips.removeAll { ids.contains($0.id) }
            for c in candidate.tracks[t].clips.indices where try candidate.tracks[t].clips[c].timelineStart.compared(to: end) != .orderedAscending {
                candidate.tracks[t].clips[c].timelineStart = try candidate.tracks[t].clips[c].timelineStart.subtracting(removed.duration)
            }
        }
        candidate.audioCrossfades.removeAll { ids.contains($0.outgoingClipID) || ids.contains($0.incomingClipID) }
        candidate.dropBrokenTransitions()
        try commit(candidate)
    }
}

/// Copied timeline clips with the tracks they came from. Times are relative to the earliest clip.
public struct ClipClipboard: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let trackID: UUID
        public let familyID: UUID
        public let clip: TimelineClip
        public let offset: RationalTime
    }
    public let entries: [Entry]
    public let duration: RationalTime
}

public extension Project {
    /// The clip and its linked components, ready to paste elsewhere.
    func copyClips(linkedTo clipID: UUID) throws -> ClipClipboard {
        let all = tracks.flatMap { track in track.clips.map { (track, $0) } }
        guard let selected = all.first(where: { $0.1.id == clipID })?.1 else { throw TimelineEditError.missingClip }
        let group = all.filter { $0.1.id == clipID || (selected.linkGroupID != nil && $0.1.linkGroupID == selected.linkGroupID) }
        var origin = selected.timelineStart, end = try selected.timelineRange().end()
        for (_, clip) in group {
            if try clip.timelineStart.compared(to: origin) == .orderedAscending { origin = clip.timelineStart }
            let clipEnd = try clip.timelineRange().end()
            if try clipEnd.compared(to: end) == .orderedDescending { end = clipEnd }
        }
        return ClipClipboard(entries: try group.map { track, clip in
            .init(trackID: track.id, familyID: track.familyID, clip: clip, offset: try clip.timelineStart.subtracting(origin))
        }, duration: try end.subtracting(origin))
    }

    /// Places copies (new identities, one new link group) at `time` on their original tracks, or
    /// on their family's tracks when those were removed. Overlaps create sibling tracks.
    @discardableResult
    mutating func pasteClips(_ clipboard: ClipClipboard, at time: RationalTime) throws -> [UUID] {
        guard !clipboard.entries.isEmpty else { return [] }
        let group = clipboard.entries.count > 1 ? UUID() : nil
        var engine = try TimelineEditEngine(project: self)
        var ids: [UUID] = []
        for entry in clipboard.entries {
            guard assets.contains(where: { $0.id == entry.clip.assetID }) else {
                throw EditorCoreError.invalidModel("The copied clip's media is no longer in this project")
            }
            var clip = entry.clip
            clip.id = UUID(); clip.linkGroupID = group
            clip.timelineStart = try time.adding(entry.offset)
            var placed = engine
            if engine.project.tracks.contains(where: { $0.id == entry.trackID }) {
                try placed.apply(.place(clip: clip, trackID: entry.trackID))
            } else {
                try placed.apply(.placeInFamily(clip: clip, familyID: entry.familyID))
            }
            engine = placed
            ids.append(clip.id)
        }
        // Callers record the whole paste as one undoable change.
        self = engine.project
        return ids
    }
}
