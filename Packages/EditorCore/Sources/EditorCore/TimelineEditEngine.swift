import Foundation

/// These commands do not ripple: collision resolution never changes unrelated clip times.
public enum EditCommand: Sendable {
    case place(clip: TimelineClip, trackID: UUID)
    case placeInFamily(clip: TimelineClip, familyID: UUID)
    case move(clipID: UUID, trackID: UUID, start: RationalTime)
    /// Linked components receive equal source/timeline deltas; source-bound failures roll back the whole group.
    case trim(clipID: UUID, sourceRange: TimeRange, timelineStart: RationalTime)
    /// A linked split requires the cut to be inside every component. Both resulting halves remain linked.
    case split(clipID: UUID, at: RationalTime)
    case delete(clipID: UUID)
}

public enum TimelineEditError: Error, Equatable, Sendable {
    case missingClip, missingTrack, missingFamily, incompatibleTrack, duplicateClip
    case invalidSplit, unsupportedLinkedSplit
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
            try project.tracks[$0].familyID == target.familyID && free(project.tracks[$0])
        }) {
            project.tracks[siblingIndex].clips.append(clip)
        } else {
            let sibling = TimelineTrack(familyID: target.familyID, template: target.template, clips: [clip])
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
                try place(clip, on: component.trackID, in: &project)
            }
        case .split(let clipID, let at):
            let components = try linked(to: clipID, in: project)
            let rightGroup = components.first?.clip.linkGroupID == nil ? nil : UUID()
            remove(Set(components.map { $0.clip.id }), from: &project)
            for component in components {
                var left = component.clip
                let leftDuration = try at.subtracting(left.timelineStart)
                guard leftDuration.numerator > 0,
                      try leftDuration.compared(to: left.sourceRange.duration) == .orderedAscending else {
                    throw components.count > 1 ? TimelineEditError.unsupportedLinkedSplit : TimelineEditError.invalidSplit
                }
                var right = left
                right.id = UUID()
                right.linkGroupID = rightGroup
                right.timelineStart = at
                right.sourceRange = try TimeRange(start: left.sourceRange.start.adding(leftDuration), duration: left.sourceRange.duration.subtracting(leftDuration))
                left.sourceRange = try TimeRange(start: left.sourceRange.start, duration: leftDuration)
                try place(left, on: component.trackID, in: &project)
                try place(right, on: component.trackID, in: &project)
            }
        case .delete(let clipID):
            let components = try linked(to: clipID, in: project)
            remove(Set(components.map { $0.clip.id }), from: &project)
        }
    }
}
