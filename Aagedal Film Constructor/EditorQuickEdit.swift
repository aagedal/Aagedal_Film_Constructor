import AppKit
import EditorCore

/// Sequence In and Out on the frame grid. Either may be missing: the range then runs from
/// the start or to the end of the sequence.
struct SequenceMarks: Equatable {
    var inPoint: RationalTime?
    var outPoint: RationalTime?
}

/// A one-shot timeline zoom step; the timeline keeps the playhead in view.
struct TimelineZoomRequest: Equatable {
    let id = UUID()
    let factor: Double
}

/// Keyboard-first editing at the playhead: sequence marks, navigation and clip actions
/// common to other editors.
extension EditorStore {
    // MARK: Sequence In and Out

    var currentSequenceMarks: SequenceMarks? { sequenceMarks[project.sequenceID] }

    /// The marked span of the open sequence, from In (or the start) to Out (or the end).
    func sequenceMarkedRange(duration: RationalTime) -> TimeRange? {
        guard let marks = currentSequenceMarks else { return nil }
        let start = marks.inPoint ?? .zero
        var end = marks.outPoint ?? duration
        if (try? end.compared(to: duration)) == .orderedDescending { end = duration }
        guard (try? end.compared(to: start)) == .orderedDescending, let length = try? end.subtracting(start) else { return nil }
        return try? TimeRange(start: start, duration: length)
    }

    /// Out is exclusive, like source marks. A mark that would cross the other one clears it.
    func markSequence(inPoint: Bool) {
        do {
            let time = try playheadFrameTime()
            var marks = currentSequenceMarks ?? SequenceMarks()
            if inPoint {
                marks.inPoint = time
                if let out = marks.outPoint, try out.compared(to: time) != .orderedDescending { marks.outPoint = nil }
            } else {
                guard time.numerator > 0 else { statusMessage = "Out must be after the start of the sequence."; NSSound.beep(); return }
                marks.outPoint = time
                if let start = marks.inPoint, try start.compared(to: time) != .orderedAscending { marks.inPoint = nil }
            }
            sequenceMarks[project.sequenceID] = marks
            statusMessage = (inPoint ? "Sequence In at " : "Sequence Out at ") + timecode(forSeconds: time.seconds)
                + ". Render Sequence exports from In to Out; ⌥X clears."
        } catch { errorMessage = String(describing: error) }
    }

    func clearSequenceMarks() {
        sequenceMarks.removeValue(forKey: project.sequenceID)
        statusMessage = "Sequence In and Out cleared."
    }

    /// Goes to the In or Out of the visible viewer; a missing sequence mark means the start or end.
    func goToMark(inPoint: Bool) {
        if showSequenceMonitor {
            guard let marks = currentSequenceMarks else { NSSound.beep(); return }
            seek(to: (inPoint ? marks.inPoint?.seconds ?? 0 : marks.outPoint?.seconds ?? duration))
        } else if let range = selectedSourceRange, let end = try? range.end() {
            seekSource(toSeconds: inPoint ? range.start.seconds : end.seconds)
        }
    }

    // MARK: Navigation

    /// Steps whichever viewer is showing: the source while it is visible and loaded, otherwise the sequence.
    func stepActiveViewer(frames: Int64) {
        if !showSequenceMonitor && sourcePlayback != nil { stepSource(frames: frames) } else { stepPlayhead(frames: frames) }
    }

    func goToActiveViewerEnd(start: Bool) {
        if !showSequenceMonitor, sourcePlayback != nil, let asset = selectedAsset {
            seekSource(toSeconds: start ? 0 : asset.duration.seconds)
        } else {
            seek(to: start ? 0 : duration)
        }
    }

    // MARK: Clip actions

    /// Splits every clip under the playhead, on every track, as one undoable edit. Clips the
    /// split cannot divide (inside a transition, for example) are left whole.
    func splitAllAtPlayhead() {
        do {
            let at = try playheadFrameTime()
            var splits = 0, refused = 0
            try change { project in
                var engine = try TimelineEditEngine(project: project)
                for id in project.tracks.flatMap(\.clips).map(\.id) {
                    // A linked split has already divided this component.
                    guard let clip = engine.project.tracks.flatMap(\.clips).first(where: { $0.id == id }),
                          try at.compared(to: clip.timelineStart) == .orderedDescending,
                          try at.compared(to: clip.timelineRange().end()) == .orderedAscending else { continue }
                    var attempt = engine
                    do { try attempt.apply(.split(clipID: id, at: at)); engine = attempt; splits += 1 } catch { refused += 1 }
                }
                project = engine.project
            }
            focusSequenceViewer()
            if splits == 0 && refused == 0 { statusMessage = "No clips under the playhead to split."; NSSound.beep() }
            else if refused > 0 { statusMessage = "Split \(splits) clip\(splits == 1 ? "" : "s"); \(refused) inside a transition or fade stayed whole." }
            else { statusMessage = "Split \(splits) clip\(splits == 1 ? "" : "s") at the playhead." }
        } catch { errorMessage = String(describing: error) }
    }

    /// Trims the selected clip's start or end to the playhead and leaves the gap (no ripple).
    func trimSelectedClipToPlayhead(edge: TimelineTrimEdge) {
        guard let clip = selectedClip, canRippleTrimSelectedClip else { NSSound.beep(); return }
        let edgeTime = clip.timelineStart.seconds + (edge == .leading ? 0 : clip.sourceRange.duration.seconds)
        trimSelectedClip(edge: edge, delta: playheadSeconds - edgeTime)
        focusSequenceViewer()
    }

    /// Moves the selected clip and its linked components by whole sequence frames.
    func nudgeSelectedClip(frames: Int) {
        guard let clip = selectedClip else { return }
        let target = clip.timelineStart.seconds + Double(frames) / project.settings.frameRate.value.seconds
        guard target >= -0.0000005 else { NSSound.beep(); return }
        moveSelectedClip(to: max(0, target))
    }

    /// Disables or enables the selected clip and its linked components together.
    func toggleSelectedClipEnabled() {
        guard let clip = selectedClip else { return }
        let ids = TimelineGesture.components(of: clip, in: project).map(\.id)
        let enabled = !clip.isEnabled
        do {
            try change {
                var engine = try TimelineEditEngine(project: $0)
                try engine.apply(.setEnabled(clipIDs: ids, enabled: enabled))
                $0 = engine.project
            }
            statusMessage = enabled ? "Clip enabled." : "Clip disabled: it keeps its place but is left out of preview and export."
        } catch { errorMessage = String(describing: error) }
    }

    /// Selects the frontmost clip under the playhead; pressing again moves to the next one down.
    func selectClipAtPlayhead() {
        let t = playheadSeconds + 0.0000005
        let candidates = project.tracks.flatMap(\.clips).filter {
            $0.timelineStart.seconds <= t && t < $0.timelineStart.seconds + $0.sourceRange.duration.seconds
        }
        guard !candidates.isEmpty else { NSSound.beep(); return }
        let next = candidates.firstIndex { $0.id == selectedClipID }.map { (candidates.index(after: $0)) % candidates.count } ?? 0
        selectTimelineClip(candidates[next].id)
    }

    func deselectTimeline() {
        selectedClipID = nil
        selectedMarkerID = nil
    }

    func toggleSnapping() {
        snappingEnabled.toggle()
        statusMessage = snappingEnabled ? "Snapping on." : "Snapping off."
    }
}
