import Foundation

/// Two-sided trims: roll, slip and slide change clips at a cut without changing the
/// sequence length or moving anything else. Linked components follow, as in ordinary trims.
extension TimelineEditEngine {
    /// The clip meeting `edge` of a clip on the same track: ending where it starts, or
    /// starting where it ends. Its own linked components are never its neighbour.
    static func adjacentClip(to clipID: UUID, edge: TimelineTrimEdge, in project: Project) throws -> TimelineClip? {
        guard let track = project.tracks.first(where: { $0.clips.contains { $0.id == clipID } }),
              let clip = track.clips.first(where: { $0.id == clipID }) else { throw TimelineEditError.missingClip }
        let cut = edge == .leading ? clip.timelineStart : try clip.timelineRange().end()
        return try track.clips.first { other in
            guard other.id != clipID, clip.linkGroupID == nil || other.linkGroupID != clip.linkGroupID else { return false }
            return try (edge == .leading ? other.timelineRange().end() : other.timelineStart) == cut
        }
    }

    /// Moves one edge of a clip by `delta` (positive is later), with the source following on a
    /// leading edge. Refuses edits past the media, the sequence start or below zero length.
    static func trimmed(_ clip: TimelineClip, edge: TimelineTrimEdge, by delta: RationalTime, in project: Project) throws -> TimelineClip {
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { throw TimelineEditError.missingClip }
        var result = clip
        switch edge {
        case .leading:
            result.timelineStart = try clip.timelineStart.adding(delta)
            result.sourceRange.start = try clip.sourceTime(atTimelineOffset: delta)
            result.sourceRange.duration = try clip.sourceRange.duration.subtracting(delta)
        case .trailing:
            result.sourceRange.duration = try clip.sourceRange.duration.adding(delta)
        }
        guard result.timelineStart.numerator >= 0, result.sourceRange.start.numerator >= 0, result.sourceRange.duration.numerator > 0,
              try result.sourceEnd().compared(to: asset.duration) != .orderedDescending else { throw TimelineEditError.trimBeyondMedia }
        if try result.fadeIn.duration.compared(to: result.sourceRange.duration) == .orderedDescending { result.fadeIn.duration = result.sourceRange.duration }
        if try result.fadeOut.duration.compared(to: result.sourceRange.duration) == .orderedDescending { result.fadeOut.duration = result.sourceRange.duration }
        return result
    }

    /// Replaces the listed components with their edited versions on their own tracks.
    /// Collisions with unrelated clips create siblings, as moves and trims do.
    private static func replace(_ edited: [(trackID: UUID, clip: TimelineClip)], in project: inout Project) throws {
        remove(Set(edited.map(\.clip.id)), from: &project)
        for component in edited { try place(component.clip, on: component.trackID, in: &project) }
    }

    static func roll(clipID: UUID, edge: TimelineTrimEdge, delta: RationalTime, in project: inout Project) throws {
        guard delta.numerator != 0 else { return }
        guard let neighbour = try adjacentClip(to: clipID, edge: edge, in: project) else { throw TimelineEditError.noAdjacentClip }
        let opposite: TimelineTrimEdge = edge == .leading ? .trailing : .leading
        let components = try linked(to: clipID, in: project)
        let neighbours = try linked(to: neighbour.id, in: project)
        let snapshot = project
        try replace(components.map { ($0.trackID, try trimmed($0.clip, edge: edge, by: delta, in: snapshot)) }
                    + neighbours.map { ($0.trackID, try trimmed($0.clip, edge: opposite, by: delta, in: snapshot)) }, in: &project)
    }

    static func slip(clipID: UUID, delta: RationalTime, in project: inout Project) throws {
        guard delta.numerator != 0 else { return }
        let components = try linked(to: clipID, in: project)
        guard components.allSatisfy({ $0.clip.selection != .still }) else { throw EditorCoreError.invalidModel("A still has no other source to slip to") }
        let snapshot = project
        try replace(components.map { component in
            var clip = component.clip
            let offset = try delta.multiplied(by: clip.speed)
            clip.sourceRange.start = try clip.sourceRange.start.adding(offset)
            guard clip.sourceRange.start.numerator >= 0, let asset = snapshot.assets.first(where: { $0.id == clip.assetID }),
                  try clip.sourceEnd().compared(to: asset.duration) != .orderedDescending else { throw TimelineEditError.trimBeyondMedia }
            clip.volumeKeyframes = try shifted(clip.volumeKeyframes, by: offset)
            clip.transformKeyframes = try shifted(clip.transformKeyframes, by: offset)
            return (component.trackID, clip)
        }, in: &project)
    }

    static func slide(clipID: UUID, delta: RationalTime, in project: inout Project) throws {
        guard delta.numerator != 0 else { return }
        let components = try linked(to: clipID, in: project)
        let ids = Set(components.map(\.clip.id))
        let snapshot = project
        var edited: [(trackID: UUID, clip: TimelineClip)] = try components.map { component in
            var clip = component.clip
            clip.timelineStart = try clip.timelineStart.adding(delta)
            guard clip.timelineStart.numerator >= 0 else { throw TimelineEditError.trimBeyondMedia }
            return (component.trackID, clip)
        }
        // The clip before ends later as it slides right; the clip after starts later.
        for (edge, neighbourEdge) in [(TimelineTrimEdge.leading, TimelineTrimEdge.trailing), (.trailing, .leading)] {
            guard let neighbour = try adjacentClip(to: clipID, edge: edge, in: snapshot) else { continue }
            for component in try linked(to: neighbour.id, in: snapshot) where !ids.contains(component.clip.id) && !edited.contains(where: { $0.clip.id == component.clip.id }) {
                edited.append((component.trackID, try trimmed(component.clip, edge: neighbourEdge, by: delta, in: snapshot)))
            }
        }
        try replace(edited, in: &project)
    }

    /// Keyframes moved with a slip so they keep their place in the clip. Points pushed before the
    /// start of the media are replaced by one point at zero with the value the curve had there.
    private static func shifted(_ keyframes: [VolumeKeyframe], by offset: RationalTime) throws -> [VolumeKeyframe] {
        let moved = try keyframes.map { VolumeKeyframe(time: try $0.time.adding(offset), gain: $0.gain) }
        guard moved.contains(where: { $0.time.numerator < 0 }) else { return moved }
        let kept = moved.filter { $0.time.numerator > 0 }
        return [VolumeKeyframe(time: .zero, gain: VolumeEnvelope.gain(atSourceSeconds: 0, keyframes: moved))] + kept
    }

    private static func shifted(_ keyframes: [TransformKeyframe], by offset: RationalTime) throws -> [TransformKeyframe] {
        let moved = try keyframes.map { var k = $0; k.time = try k.time.adding(offset); return k }
        guard moved.contains(where: { $0.time.numerator < 0 }) else { return moved }
        let kept = moved.filter { $0.time.numerator > 0 }
        let at = PictureAnimation.transform(atSourceSeconds: 0, base: .identity, keyframes: moved)
        return [TransformKeyframe(time: .zero, scale: at.scale, offsetX: at.offsetX, offsetY: at.offsetY, opacity: at.opacity)] + kept
    }
}

public extension Project {
    /// The clip meeting `edge` of a clip on its track, which a roll at that edge trims.
    func adjacentClip(to clipID: UUID, edge: TimelineTrimEdge) -> TimelineClip? {
        try? TimelineEditEngine.adjacentClip(to: clipID, edge: edge, in: self)
    }

    /// Removes everything inside `range` on every track and leaves the gap (lift).
    mutating func lift(_ range: TimeRange) throws {
        var candidate = self
        try candidate.clear(range, onTracks: Set(tracks.map(\.id)))
        var engine = try TimelineEditEngine(project: self)
        try engine.commit(candidate)
        self = engine.project
    }

    /// Removes everything inside `range` on every track and closes the gap, moving later
    /// clips earlier (extract). Transitions whose clips no longer meet become cuts.
    mutating func extract(_ range: TimeRange) throws {
        var candidate = self
        try candidate.clear(range, onTracks: Set(tracks.map(\.id)))
        let end = try range.end()
        for t in candidate.tracks.indices {
            for c in candidate.tracks[t].clips.indices where try candidate.tracks[t].clips[c].timelineStart.compared(to: end) != .orderedAscending {
                candidate.tracks[t].clips[c].timelineStart = try candidate.tracks[t].clips[c].timelineStart.subtracting(range.duration)
            }
        }
        candidate.dropBrokenTransitions()
        var engine = try TimelineEditEngine(project: self)
        try engine.commit(candidate)
        self = engine.project
    }
}

public extension TimelineGesture {
    /// The legal range of a roll at `edge`: both the clip's edge and the neighbour's opposite
    /// edge must stay within their media, on the frame/sample grid.
    static func rollDelta(_ proposed: Double, edge: TimelineTrimEdge, clip: TimelineClip, project: Project, quantum: Double) -> Double {
        guard let neighbour = project.adjacentClip(to: clip.id, edge: edge) else { return 0 }
        let own = trimBounds(edge: edge, clip: clip, project: project, quantum: quantum)
        let other = trimBounds(edge: edge == .leading ? .trailing : .leading, clip: neighbour, project: project, quantum: quantum)
        return onGrid(proposed, lower: max(own.lower, other.lower), upper: min(own.upper, other.upper), quantum: quantum)
    }
}
