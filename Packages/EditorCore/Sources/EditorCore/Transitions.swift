import Foundation

/// What Add Transition did: joined edits (dissolves/crossfades), dips through black or
/// silence where no media lies beyond a cut, and fades at edges without a neighbour.
public struct TransitionResult: Equatable, Sendable {
    public var joined = 0
    public var dips = 0
    public var fades = 0
    public var total: Int { joined + dips + fades }
    public init(joined: Int = 0, dips: Int = 0, fades: Int = 0) { self.joined = joined; self.dips = dips; self.fades = fades }
}

extension TimelineEditEngine {
    /// Adds a transition at the selected clip's edit point nearest `time`, for the clip and its
    /// linked components, as one undoable edit. Where a neighbour on the same track meets that
    /// edge, pictures cross dissolve and audio crossfades; otherwise the edge fades from or to
    /// black (or silence). Durations shrink to fit the available handles and clip lengths.
    /// Clips with no media beyond the cut dip through black: each fades over half the duration.
    @discardableResult
    public mutating func addTransition(clipID: UUID, near time: RationalTime, duration: RationalTime) throws -> TransitionResult {
        guard duration.numerator > 0 else { throw TimelineEditError.invalidAudioCrossfade }
        var candidate = project
        let all = candidate.tracks.flatMap { track in track.clips.map { (track: track, clip: $0) } }
        guard let selected = all.first(where: { $0.clip.id == clipID })?.clip else { throw TimelineEditError.missingClip }
        let group = all.filter { $0.clip.id == clipID || (selected.linkGroupID != nil && $0.clip.linkGroupID == selected.linkGroupID) }
        let start = selected.timelineStart, end = try selected.timelineRange().end()
        let leading = try time.subtracting(start).compared(to: end.subtracting(time)) == .orderedAscending
        var result = TransitionResult()
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
                // Each edge takes one transition; an edge already joined elsewhere is left as it is.
                if candidate.audioCrossfades.contains(where: { $0.outgoingClipID == outgoing.id || $0.incomingClipID == incoming.id }) { continue }
                // A transition replaces standalone fades on the joined edges.
                Self.updateClip(outgoing.id, in: &candidate) { $0.fadeOut = .init() }
                Self.updateClip(incoming.id, in: &candidate) { $0.fadeIn = .init() }
                let curve: AudioFadeCurve = clip.requiredTrackKind == .video ? .linear : .equalPower
                var joined = false
                for units in try Self.fittingUnits(duration, grid: grid) {
                    let relation = AudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id,
                                                  duration: try RationalTime(units).divided(by: grid), curve: curve)
                    if (try? candidate.audioCrossfadeGeometry(for: relation)) != nil {
                        candidate.audioCrossfades.append(relation); result.joined += 1; joined = true
                        break
                    }
                }
                if !joined {
                    let half = try duration.divided(by: RationalTime(2))
                    let outFade = try Self.fade(half, within: outgoing.sourceRange.duration.subtracting(outgoing.fadeIn.duration), grid: grid, curve: curve)
                    let inFade = try Self.fade(half, within: incoming.sourceRange.duration.subtracting(incoming.fadeOut.duration), grid: grid, curve: curve)
                    if let outFade, let inFade {
                        Self.updateClip(outgoing.id, in: &candidate) { $0.fadeOut = outFade }
                        Self.updateClip(incoming.id, in: &candidate) { $0.fadeIn = inFade }
                        result.dips += 1
                    }
                }
            } else {
                // Leave existing linked crossfades untouched; they own this edge.
                guard !candidate.audioCrossfades.contains(where: { leading ? $0.incomingClipID == clip.id : $0.outgoingClipID == clip.id }) else { continue }
                let available = leading ? try clip.sourceRange.duration.subtracting(clip.fadeOut.duration)
                                        : try clip.sourceRange.duration.subtracting(clip.fadeIn.duration)
                guard let fade = try Self.fade(duration, within: available, grid: grid,
                                               curve: clip.requiredTrackKind == .video ? .linear : .equalPower) else { continue }
                Self.updateClip(clip.id, in: &candidate) { if leading { $0.fadeIn = fade } else { $0.fadeOut = fade } }
                result.fades += 1
            }
        }
        guard result.total > 0 else { throw TimelineEditError.invalidAudioCrossfade }
        try commit(candidate)
        return result
    }

    /// A fade of `duration` in whole grid units, shortened to `available`; nil when under one unit.
    private static func fade(_ duration: RationalTime, within available: RationalTime, grid: RationalTime, curve: AudioFadeCurve) throws -> AudioFade? {
        let limit = try available.compared(to: duration) == .orderedAscending ? available : duration
        let units = try limit.multiplied(by: grid)
        guard units.numerator / units.denominator > 0 else { return nil }
        return AudioFade(duration: try RationalTime(units.numerator / units.denominator).divided(by: grid), curve: curve)
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
