import Foundation

public enum TimelineTrimEdge: Sendable { case leading, trailing }

/// Geometry shared by the drag preview and committed edit. Linked source and timeline
/// bounds constrain the entire gesture, including components with shorter media.
public enum TimelineGesture {
    public static func components(of clip: TimelineClip, in project: Project) -> [TimelineClip] {
        project.tracks.flatMap(\.clips).filter {
            $0.id == clip.id || (clip.linkGroupID != nil && $0.linkGroupID == clip.linkGroupID)
        }
    }

    public static func snap(_ proposed: Double, movingEdges: [Double], targets: [Double], tolerance: Double) -> Double {
        guard tolerance >= 0, proposed.isFinite else { return proposed }
        let offsets = movingEdges.flatMap { edge in targets.map { $0 - (proposed + edge) } }
        guard let offset = offsets.filter({ abs($0) <= tolerance }).min(by: { abs($0) < abs($1) }) else { return proposed }
        return proposed + offset
    }

    public static func trimDelta(_ proposed: Double, edge: TimelineTrimEdge, clip: TimelineClip, project: Project, quantum: Double) -> Double {
        guard proposed.isFinite, quantum > 0 else { return 0 }
        var lower = -Double.greatestFiniteMagnitude
        var upper = Double.greatestFiniteMagnitude
        for component in components(of: clip, in: project) {
            switch edge {
            case .leading:
                lower = max(lower, -component.sourceRange.start.seconds / component.speed.seconds, -component.timelineStart.seconds)
                upper = min(upper, component.sourceRange.duration.seconds - quantum)
            case .trailing:
                lower = max(lower, quantum - component.sourceRange.duration.seconds)
                if let asset = project.assets.first(where: { $0.id == component.assetID }) {
                    upper = min(upper, (asset.duration.seconds - ((try? component.sourceEnd().seconds) ?? .infinity)) / component.speed.seconds)
                }
            }
        }
        // Work on a frame/sample grid without rounding beyond the legal source bounds.
        let minimum = ceil(lower / quantum - 1e-8)
        let maximum = floor(upper / quantum + 1e-8)
        guard minimum <= maximum else { return 0 }
        return min(maximum, max(minimum, (proposed / quantum).rounded())) * quantum
    }
}
