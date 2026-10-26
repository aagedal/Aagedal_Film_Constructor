import Foundation

/// A paired envelope with source handles. Original clip ranges remain editorial bounds.
/// Between audio components it is a crossfade on the sample grid. Between two pictures on
/// one video track it is a linear cross dissolve on the frame grid: the incoming picture is
/// composited over the outgoing one with rising opacity.
public struct AudioCrossfade: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var outgoingClipID: UUID
    public var incomingClipID: UUID
    public var duration: RationalTime
    public var curve: AudioFadeCurve
    public init(id: UUID = UUID(), outgoingClipID: UUID, incomingClipID: UUID, duration: RationalTime, curve: AudioFadeCurve = .equalPower) {
        self.id = id; self.outgoingClipID = outgoingClipID; self.incomingClipID = incomingClipID
        self.duration = duration; self.curve = curve
    }
}

public struct AudioCrossfadeGeometry: Equatable, Sendable {
    public var outgoingSourceRange: TimeRange
    public var outgoingTimelineRange: TimeRange
    public var incomingSourceRange: TimeRange
    public var incomingTimelineRange: TimeRange
}

extension Project {
    struct AudioCrossfadeContext {
        var endpoints: [UUID: (track: TimelineTrack, clip: TimelineClip)]
        var assets: [UUID: MediaAsset]
    }

    func audioCrossfadeContext() -> AudioCrossfadeContext {
        // This helper is also used on unvalidated in-progress edits. Retain the first
        // identity like the previous linear lookup; validation rejects duplicates.
        var endpoints: [UUID: (track: TimelineTrack, clip: TimelineClip)] = [:]
        for track in tracks {
            for clip in track.clips where endpoints[clip.id] == nil {
                endpoints[clip.id] = (track, clip)
            }
        }
        return AudioCrossfadeContext(endpoints: endpoints,
                                     assets: Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Adjacent cuts prefer centered handles, falling back to the available side. Existing overlaps
    /// must match the duration exactly. Handles stay inside the union of the original timeline ranges.
    public func audioCrossfadeGeometry(for crossfade: AudioCrossfade) throws -> AudioCrossfadeGeometry {
        try audioCrossfadeGeometry(for: crossfade, context: audioCrossfadeContext())
    }

    func audioCrossfadeGeometry(for crossfade: AudioCrossfade, context: AudioCrossfadeContext) throws -> AudioCrossfadeGeometry {
        guard crossfade.duration.numerator > 0, crossfade.outgoingClipID != crossfade.incomingClipID,
              let outgoing = context.endpoints[crossfade.outgoingClipID],
              let incoming = context.endpoints[crossfade.incomingClipID],
              outgoing.clip.requiredTrackKind == incoming.clip.requiredTrackKind,
              outgoing.clip.fadeOut.duration == .zero, incoming.clip.fadeIn.duration == .zero,
              let outgoingAsset = context.assets[outgoing.clip.assetID] else {
            throw TimelineEditError.invalidAudioCrossfade
        }
        let isDissolve = outgoing.clip.requiredTrackKind == .video
        // Handles and durations use whole units of the grid each kind renders on.
        let grid = isDissolve ? settings.frameRate.value : try RationalTime(Int64(settings.audioSampleRate))
        let gridDuration = try crossfade.duration.multiplied(by: grid)
        guard gridDuration.denominator == 1 else { throw TimelineEditError.invalidAudioCrossfade }
        if isDissolve {
            guard outgoing.track.id == incoming.track.id, crossfade.curve == .linear else { throw TimelineEditError.invalidAudioCrossfade }
        } else {
            func route(_ track: TimelineTrack) -> [Int] {
                track.template.routing.outputChannels.isEmpty ? Array(0..<(track.audioLayout?.channels.count ?? 0)) : track.template.routing.outputChannels
            }
            guard outgoing.clip.requiredAudioLayout == incoming.clip.requiredAudioLayout,
                  route(outgoing.track) == route(incoming.track) else { throw TimelineEditError.invalidAudioCrossfade }
        }
        let a = try outgoing.clip.timelineRange(), b = try incoming.clip.timelineRange()
        let endA = try a.end(), endB = try b.end()
        guard try a.start.compared(to: b.start) == .orderedAscending,
              try endA.compared(to: endB) == .orderedAscending else { throw TimelineEditError.invalidAudioCrossfade }
        let overlap = try endA.subtracting(b.start)
        guard overlap.numerator >= 0 else { throw TimelineEditError.invalidAudioCrossfade }
        var left = RationalTime.zero, right = RationalTime.zero
        if overlap.numerator > 0 {
            guard overlap == crossfade.duration else { throw TimelineEditError.invalidAudioCrossfade }
        } else {
            func minimum(_ x: RationalTime, _ y: RationalTime) throws -> RationalTime {
                try x.compared(to: y) == .orderedDescending ? y : x
            }
            func gridFloor(_ time: RationalTime) throws -> RationalTime {
                let units = try time.multiplied(by: grid)
                return try RationalTime(units.numerator / units.denominator).divided(by: grid)
            }
            // A still repeats its single picture, so its hold has no source end. Source handles
            // become timeline handles at each clip's speed.
            let availableLeft = try gridFloor(minimum(incoming.clip.selection == .still ? a.duration
                : incoming.clip.sourceRange.start.divided(by: incoming.clip.speed), a.duration))
            let availableRight = try gridFloor(minimum(outgoing.clip.selection == .still ? b.duration
                : outgoingAsset.duration.subtracting(outgoing.clip.sourceEnd()).divided(by: outgoing.clip.speed), b.duration))
            guard try availableLeft.adding(availableRight).compared(to: crossfade.duration) != .orderedAscending else {
                throw TimelineEditError.invalidAudioCrossfade
            }
            left = try minimum(RationalTime(gridDuration.numerator / 2).divided(by: grid), availableLeft)
            right = try minimum(crossfade.duration.subtracting(left), availableRight)
            left = try crossfade.duration.subtracting(right)
        }
        return try AudioCrossfadeGeometry(
            outgoingSourceRange: TimeRange(start: outgoing.clip.sourceRange.start, duration: outgoing.clip.sourceRange.duration.adding(right)),
            outgoingTimelineRange: TimeRange(start: a.start, duration: a.duration.adding(right)),
            incomingSourceRange: TimeRange(start: incoming.clip.selection == .still ? incoming.clip.sourceRange.start
                                                : incoming.clip.sourceRange.start.subtracting(left.multiplied(by: incoming.clip.speed)),
                                           duration: incoming.clip.sourceRange.duration.adding(left)),
            incomingTimelineRange: TimeRange(start: b.start.subtracting(left), duration: b.duration.adding(left)))
    }

    func validateAudioCrossfades() throws {
        guard Set(audioCrossfades.map(\.id)).count == audioCrossfades.count,
              Set(audioCrossfades.map(\.outgoingClipID)).count == audioCrossfades.count,
              Set(audioCrossfades.map(\.incomingClipID)).count == audioCrossfades.count else {
            throw TimelineEditError.invalidAudioCrossfade
        }
        guard !audioCrossfades.isEmpty else { return }
        let context = audioCrossfadeContext()
        let geometries = try Dictionary(uniqueKeysWithValues: audioCrossfades.map {
            ($0.id, try audioCrossfadeGeometry(for: $0, context: context))
        })
        let outgoingByClip = Dictionary(uniqueKeysWithValues: audioCrossfades.map { ($0.outgoingClipID, $0) })
        // A middle clip can participate at both edges only while its envelopes do not overlap.
        for incoming in audioCrossfades {
            if let outgoing = outgoingByClip[incoming.incomingClipID] {
                let left = try geometries[incoming.id]!.incomingTimelineRange.start.adding(incoming.duration)
                let right = try geometries[outgoing.id]!.outgoingTimelineRange.end().subtracting(outgoing.duration)
                guard try left.compared(to: right) != .orderedDescending else { throw TimelineEditError.invalidAudioCrossfade }
            }
        }
    }
}
