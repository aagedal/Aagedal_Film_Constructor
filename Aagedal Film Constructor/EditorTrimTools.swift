import AppKit
import CoreMedia
import EditorCore

/// Two-sided trims (roll, slip, slide), Lift and Extract of the sequence In/Out range,
/// and Match Frame.
extension EditorStore {
    // MARK: Roll, slip and slide

    /// The edge of the clip nearer the playhead.
    private func nearestEdge(of clip: TimelineClip) -> TimelineTrimEdge {
        let start = clip.timelineStart.seconds, end = start + clip.sourceRange.duration.seconds
        return abs(playheadSeconds - start) <= abs(playheadSeconds - end) ? .leading : .trailing
    }

    var canExtendEditToPlayhead: Bool {
        guard let clip = selectedClip else { return false }
        let edge = nearestEdge(of: clip)
        let cut = clip.timelineStart.seconds + (edge == .leading ? 0 : clip.sourceRange.duration.seconds)
        return abs(playheadSeconds - cut) > 0.0000005
    }

    /// Moves the selected clip's edge nearer the playhead to it. A clip meeting that edge is
    /// trimmed to keep meeting it (a roll); otherwise the edge trims into the gap.
    func extendEditToPlayhead() {
        guard let clip = selectedClip, canExtendEditToPlayhead else { NSSound.beep(); return }
        let edge = nearestEdge(of: clip)
        do {
            let cut = edge == .leading ? clip.timelineStart : try clip.timelineRange().end()
            let delta = try playheadFrameTime().subtracting(cut)
            if project.adjacentClip(to: clip.id, edge: edge) != nil {
                try applyEdit(.roll(clipID: clip.id, edge: edge, delta: delta))
                statusMessage = "Rolled the edit to the playhead."
            } else {
                trimSelectedClip(edge: edge, delta: delta.seconds)
                statusMessage = "No clip meets this edge, so the clip was trimmed to the playhead."
            }
            focusSequenceViewer()
        } catch TimelineEditError.trimBeyondMedia {
            NSSound.beep()
            statusMessage = "Cannot roll to the playhead: a clip would run past its media or below one frame."
        } catch { errorMessage = audioEditErrorMessage(error) }
    }

    /// A roll drag: the cut moves on the frame grid (sample grid for sound alone), snapping to
    /// other edges, the playhead and markers, and stopping where either clip runs out of media.
    func proposedRollDelta(clip: TimelineClip, edge: TimelineTrimEdge, delta: Double, tolerance: Double) -> Double {
        let edgeTime = clip.timelineStart.seconds + (edge == .leading ? 0 : clip.sourceRange.duration.seconds)
        let proposed = snappingEnabled ? TimelineGesture.snap(edgeTime + delta, movingEdges: [0], targets: snapTargets(excluding: clip), tolerance: tolerance) - edgeTime : delta
        let neighbour = project.adjacentClip(to: clip.id, edge: edge)
        let quantum = max(gestureQuantum(for: clip), neighbour.map { gestureQuantum(for: $0) } ?? 0)
        return TimelineGesture.rollDelta(proposed, edge: edge, clip: clip, project: project, quantum: quantum)
    }

    func canRoll(clip: TimelineClip, edge: TimelineTrimEdge) -> Bool { project.adjacentClip(to: clip.id, edge: edge) != nil }

    func rollEdit(clipID: UUID, edge: TimelineTrimEdge, delta: Double) {
        selectTimelineClip(clipID)
        do {
            try applyEdit(.roll(clipID: clipID, edge: edge, delta: editTime(delta)))
            statusMessage = "Rolled the edit."
        } catch { errorMessage = audioEditErrorMessage(error) }
    }

    /// Plays a later (positive) or earlier source range in the clip's place.
    func slipSelectedClip(frames: Int64) {
        frameEdit(frames: frames, done: frames > 0 ? "Slipped one frame later in the source." : "Slipped one frame earlier in the source.") {
            .slip(clipID: $0, delta: $1)
        }
    }

    /// Moves the clip between its neighbours, which trim to keep meeting it.
    func slideSelectedClip(frames: Int64) {
        frameEdit(frames: frames, done: frames > 0 ? "Slid the clip one frame right." : "Slid the clip one frame left.") {
            .slide(clipID: $0, delta: $1)
        }
    }

    private func frameEdit(frames: Int64, done: String, _ command: (UUID, RationalTime) -> EditCommand) {
        guard let clip = selectedClip else { NSSound.beep(); return }
        do {
            try applyEdit(command(clip.id, project.settings.frameRate.time(forFrames: frames)))
            focusSequenceViewer()
            statusMessage = done
        } catch TimelineEditError.trimBeyondMedia {
            // Held keys stop at the end of the media without an alert.
            NSSound.beep()
            statusMessage = "Stopped at the end of the media."
        } catch { errorMessage = audioEditErrorMessage(error) }
    }

    private func applyEdit(_ command: EditCommand) throws {
        try change {
            var engine = try TimelineEditEngine(project: $0)
            try engine.apply(command)
            $0 = engine.project
        }
    }

    // MARK: Lift and Extract

    var canLiftSequenceRange: Bool { currentSequenceMarks != nil && project.tracks.contains { !$0.clips.isEmpty } }

    /// Removes everything between the sequence In and Out on every track, leaving a gap
    /// (lift) or closing it (extract). The marks are cleared and the playhead goes to In.
    func liftSequenceRange(closingGap: Bool) {
        do {
            guard currentSequenceMarks != nil,
                  let range = sequenceMarkedRange(duration: try TimelineRenderPlan(project: project).duration) else {
                NSSound.beep()
                statusMessage = "Mark a sequence In or Out first (I and O with the sequence viewer showing)."
                return
            }
            try change { closingGap ? try $0.extract(range) : try $0.lift(range) }
            clearSelectionIfRemoved()
            sequenceMarks.removeValue(forKey: project.sequenceID)
            focusSequenceViewer()
            seek(to: range.start.seconds)
            statusMessage = closingGap ? "Extracted \(timecodeDuration(range.duration)); later clips moved up." : "Lifted \(timecodeDuration(range.duration)), leaving a gap."
        } catch { errorMessage = audioEditErrorMessage(error) }
    }

    private func clearSelectionIfRemoved() {
        if selectedClip == nil { selectedClipID = nil }
    }

    private func timecodeDuration(_ duration: RationalTime) -> String {
        let frames = (duration.seconds * project.settings.frameRate.value.seconds).rounded()
        return frames == 1 ? "1 frame" : "\(Int(frames)) frames"
    }

    // MARK: Match Frame

    /// The clip Match Frame opens: the selected clip under the playhead, else the frontmost
    /// enabled picture there, else the first enabled sound.
    var matchFrameClip: TimelineClip? {
        let t = playheadSeconds + 0.0000005
        func covers(_ clip: TimelineClip) -> Bool { clip.timelineStart.seconds <= t && t < clip.timelineStart.seconds + clip.sourceRange.duration.seconds }
        if let selected = selectedClip, covers(selected), asset(id: selected.assetID)?.title == nil { return selected }
        let candidates = project.tracks.filter { !$0.muted }.flatMap(\.clips).filter { $0.isEnabled && covers($0) && asset(id: $0.assetID)?.title == nil }
        return candidates.first { $0.requiredTrackKind == .video } ?? candidates.first
    }

    /// Opens the source of the clip under the playhead in the source viewer at the same frame,
    /// with the clip's source range marked In to Out.
    func matchFrame() {
        guard let clip = matchFrameClip else { NSSound.beep(); statusMessage = "No clip under the playhead to match."; return }
        do {
            let offset = max(0, playheadSeconds - clip.timelineStart.seconds)
            let sourceSeconds = clip.selection == .still ? 0 : clip.sourceRange.start.seconds + offset * clip.speed.seconds
            let marked = try TimeRange(start: clip.sourceRange.start, duration: clip.sourceExtent())
            selectAsset(clip.assetID)
            sourceRanges[clip.assetID] = marked
            showSequenceMonitor = false
            // The source loads asynchronously; a pending transport is where it opens.
            if sourcePlayback == nil, pendingSourceTransport != nil {
                pendingSourceTransport = (CMTime(seconds: sourceSeconds, preferredTimescale: 60000), false)
            } else {
                seekSource(toSeconds: sourceSeconds)
            }
            statusMessage = "Matched \(asset(id: clip.assetID)?.name ?? "the source") at the playhead; its In and Out mark the clip."
        } catch { errorMessage = audioEditErrorMessage(error) }
    }
}
