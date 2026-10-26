import Foundation

public extension Project {
    /// Additional components that can be replaced without choosing between different timing or gain.
    /// Track order provides a stable UI order; the selected component is never included.
    func audioConsolidationCandidates(for clipID: UUID) throws -> [TimelineClip] {
        guard let origin = tracks.first(where: { $0.clips.contains { $0.id == clipID } }),
              let selected = origin.clips.first(where: { $0.id == clipID }) else {
            throw TimelineEditError.missingClip
        }
        guard selected.requiredTrackKind == .audio else { throw TimelineEditError.invalidAudioSelection }
        guard let group = selected.linkGroupID else { return [] }
        return tracks.filter {
            $0.kind == .audio && $0.familyID == origin.familyID && $0.template.gain == origin.template.gain
        }.flatMap(\.clips).filter {
            $0.id != clipID && $0.linkGroupID == group && $0.assetID == selected.assetID &&
            $0.timelineStart == selected.timelineStart && $0.sourceRange == selected.sourceRange &&
            $0.fadeIn == selected.fadeIn && $0.fadeOut == selected.fadeOut && $0.gain == selected.gain && $0.volumeKeyframes == selected.volumeKeyframes && $0.speed == selected.speed && $0.eq == selected.eq && $0.dynamics == selected.dynamics
        }
    }
}
