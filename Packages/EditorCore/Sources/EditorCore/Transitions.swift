import Foundation

extension TimelineEditEngine {
    /// Adds a transition at the selected clip's edit point nearest `time`, for the clip and its
    /// linked components, as one undoable edit. Where a neighbour on the same track meets that
    /// edge, pictures cross dissolve and audio crossfades; otherwise the edge fades from or to
    /// black (or silence). Durations shrink to fit the available handles and clip lengths.
    /// Returns the number of components that received a transition.
    @discardableResult
    public mutating func addTransition(clipID: UUID, near time: RationalTime, duration: RationalTime) throws -> Int {
        guard duration.numerator > 0 else { throw TimelineEditError.invalidAudioCrossfade }
        var candidate = project
        let all = candidate.tracks.flatMap { track in track.clips.map { (track: track, clip: $0) } }
        guard let selected = all.first(where: { $0.clip.id == clipID })?.clip else { throw TimelineEditError.missingClip }
        let group = all.filter { $0.clip.id == clipID || (selected.linkGroupID != nil && $0.clip.linkGroupID == selected.linkGroupID) }
        let start = selected.timelineStart, end = try selected.timelineRange().end()
        let leading = try time.subtracting(start).compared(to: end.subtracting(time)) == .orderedAscending
        var applied = 0
        for component in group {
            let clip = component.clip
            let grid = clip.requiredTrackKind == .video ? candidate.settings.frameRate.value : try RationalTime(Int64(candidate.settings.audioSampleRate))
            let edge = leading ? clip.timelineStart : try clip.timelineRange().end()
            let neighbour = try component.track.clips.first { other in
                guard other.id != clip.id else { return false }
                return leading ? try other.timelineRange().end() == edge : other.timelineStart == edge
            }
            if let neighbour {
                let outgoing = leading ? neighbour : clip, incoming = leading ? clip : neighbour
                if candidate.audioCrossfades.contains(where: { $0.outgoingClipID == outgoing.id && $0.incomingClipID == incoming.id }) { continue }
                // A transition replaces standalone fades on the joined edges.
                Self.updateClip(outgoing.id, in: &candidate) { $0.fadeOut = .init() }
                Self.updateClip(incoming.id, in: &candidate) { $0.fadeIn = .init() }
                let curve: AudioFadeCurve = clip.requiredTrackKind == .video ? .linear : .equalPower
                for units in try Self.fittingUnits(duration, grid: grid) {
                    let relation = AudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id,
                                                  duration: try RationalTime(units).divided(by: grid), curve: curve)
                    if (try? candidate.audioCrossfadeGeometry(for: relation)) != nil {
                        candidate.audioCrossfades.append(relation); applied += 1
                        break
                    }
                }
            } else {
                // Leave existing linked crossfades untouched; they own this edge.
                guard !candidate.audioCrossfades.contains(where: { leading ? $0.incomingClipID == clip.id : $0.outgoingClipID == clip.id }) else { continue }
                let available = leading ? try clip.sourceRange.duration.subtracting(clip.fadeOut.duration)
                                        : try clip.sourceRange.duration.subtracting(clip.fadeIn.duration)
                let limit = try available.compared(to: duration) == .orderedAscending ? available : duration
                let units = try limit.multiplied(by: grid)
                guard units.numerator / units.denominator > 0 else { continue }
                let fade = AudioFade(duration: try RationalTime(units.numerator / units.denominator).divided(by: grid),
                                     curve: clip.requiredTrackKind == .video ? .linear : .equalPower)
                Self.updateClip(clip.id, in: &candidate) { if leading { $0.fadeIn = fade } else { $0.fadeOut = fade } }
                applied += 1
            }
        }
        guard applied > 0 else { throw TimelineEditError.invalidAudioCrossfade }
        try commit(candidate)
        return applied
    }

    /// The requested duration in whole grid units, then successively shorter fallbacks.
    private static func fittingUnits(_ duration: RationalTime, grid: RationalTime) throws -> [Int64] {
        let exact = try duration.multiplied(by: grid)
        var units = max(1, (exact.numerator + exact.denominator / 2) / exact.denominator)
        var result: [Int64] = []
        while units >= 1 { result.append(units); units = units > 1 && units < 4 ? units - 1 : units / 2 }
        return result
    }

    private static func updateClip(_ id: UUID, in project: inout Project, _ change: (inout TimelineClip) -> Void) {
        for t in project.tracks.indices {
            if let c = project.tracks[t].clips.firstIndex(where: { $0.id == id }) { change(&project.tracks[t].clips[c]); return }
        }
    }
}
