import Foundation

/// A paired transition as cut-based interchange formats (FCPXML storylines, OTIO, CMX3600)
/// describe it: the two clips meet at `cut`, and the transition runs from `before` ahead of
/// the cut to `after` past it, drawing on source handles from both clips.
public struct InterchangeTransition: Equatable, Sendable {
    public var relation: AudioCrossfade
    public var trackID: UUID
    public var cut: RationalTime
    /// Timeline time before the cut, played from the incoming clip's handle.
    public var before: RationalTime
    /// Timeline time after the cut, played from the outgoing clip's handle.
    public var after: RationalTime
    public var start: RationalTime { (try? cut.subtracting(before)) ?? cut }
}

/// Editorial ranges with every paired transition expressed at a cut.
public struct InterchangeCuts: Sendable {
    public var transitions: [InterchangeTransition]
    /// Clip source and timeline ranges as they meet at each cut. Clips that already meet keep
    /// their own ranges; an overlapping pair is cut at the middle of its overlap.
    public var ranges: [UUID: (source: TimeRange, timeline: TimeRange)]
    public func transition(outgoing clipID: UUID) -> InterchangeTransition? { transitions.first { $0.relation.outgoingClipID == clipID } }
    public func transition(incoming clipID: UUID) -> InterchangeTransition? { transitions.first { $0.relation.incomingClipID == clipID } }
}

extension Project {
    public func interchangeCuts() throws -> InterchangeCuts {
        let context = audioCrossfadeContext()
        var ranges: [UUID: (source: TimeRange, timeline: TimeRange)] = [:]
        for track in tracks { for clip in track.clips { ranges[clip.id] = (clip.sourceRange, try clip.timelineRange()) } }
        var transitions: [InterchangeTransition] = []
        for relation in audioCrossfades {
            let geometry = try audioCrossfadeGeometry(for: relation, context: context)
            guard let outgoing = context.endpoints[relation.outgoingClipID], let incoming = context.endpoints[relation.incomingClipID] else {
                throw TimelineEditError.invalidAudioCrossfade
            }
            let grid = outgoing.clip.requiredTrackKind == .video ? settings.frameRate.value : try RationalTime(Int64(settings.audioSampleRate))
            let first = geometry.incomingTimelineRange.start, last = try geometry.outgoingTimelineRange.end()
            var cut = incoming.clip.timelineStart
            if try cut.compared(to: outgoing.clip.timelineRange().end()) == .orderedAscending {
                // Overlapping clips: cut at the middle of the overlap, on the grid.
                let units = try relation.duration.multiplied(by: grid)
                cut = try first.adding(RationalTime(units.numerator / units.denominator / 2).divided(by: grid))
                let trimOut = try outgoing.clip.timelineRange().end().subtracting(cut)
                let trimIn = try cut.subtracting(incoming.clip.timelineStart)
                if var out = ranges[outgoing.clip.id] {
                    out.source.duration = try out.source.duration.subtracting(trimOut)
                    out.timeline.duration = try out.timeline.duration.subtracting(trimOut)
                    ranges[outgoing.clip.id] = out
                }
                if var into = ranges[incoming.clip.id] {
                    if incoming.clip.selection != .still { into.source.start = try into.source.start.adding(trimIn.multiplied(by: incoming.clip.speed)) }
                    into.source.duration = try into.source.duration.subtracting(trimIn)
                    into.timeline.start = cut
                    into.timeline.duration = try into.timeline.duration.subtracting(trimIn)
                    ranges[incoming.clip.id] = into
                }
            }
            transitions.append(InterchangeTransition(relation: relation, trackID: outgoing.track.id, cut: cut,
                                                     before: try cut.subtracting(first), after: try last.subtracting(cut)))
        }
        return InterchangeCuts(transitions: transitions, ranges: ranges)
    }
}
