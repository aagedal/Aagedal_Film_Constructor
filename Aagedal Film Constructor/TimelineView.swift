import SwiftUI
import AppKit
import EditorCore

/// A clip's live move or trim, which its linked components follow until the edit commits.
private struct LinkedDrag: Equatable {
    var sourceID: UUID
    var ids: Set<UUID>
    var offset: CGFloat
    var leading: Double
    var trailing: Double
}

struct TimelineView: View {
    @ObservedObject var store: EditorStore
    @FocusState private var timelineFocused: Bool
    @State private var pixelsPerSecond = 35.0
    @State private var previousZoom: Double?
    @State private var showingTimecodeEntry = false
    @State private var timecodeEntry = ""
    @State private var viewport = CGRect.zero
    @State private var interactingClipIDs: Set<UUID> = []
    @State private var linkedDrag: LinkedDrag?
    @State private var clipFrames: [UUID: CGRect] = [:]
    @State private var crossfadeHoverID: UUID?
    @State private var isDropTargeted = false
    @State private var dropCanvasFrame = CGRect.zero
    @State private var dropViewport = CGRect.zero
    /// Horizontal scroll, so track headers stay at the left edge while lanes scroll.
    @State private var scrollX: CGFloat = 0
    private let labelWidth: CGFloat = 145
    /// A track row and the spacing below it.
    private let rowHeight: CGFloat = 65
    private var visibleDuration: Double { max(20, store.duration + 5) }
    private var canvasWidth: CGFloat { max(1, viewport.width - labelWidth, visibleDuration * pixelsPerSecond) }
    private var fittedZoom: Double { max(0.000001, min(100, (viewport.width - labelWidth - 12) / visibleDuration)) }
    private func toggleZoomToFit() {
        if let previousZoom, abs(pixelsPerSecond - fittedZoom) < 0.000001 {
            pixelsPerSecond = previousZoom
            self.previousZoom = nil
        } else {
            previousZoom = pixelsPerSecond
            pixelsPerSecond = fittedZoom
        }
    }
    private var tickInterval: Double {
        let desired = max(75 / pixelsPerSecond, visibleDuration / 400)
        return [1.0, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600].first(where: { $0 >= desired }) ?? desired
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(store.project.sequenceName).font(.headline).lineLimit(1).help("The open sequence; open another from the media bin")
                Button(action: store.undo) { Image(systemName: "arrow.uturn.backward") }.help("Undo").accessibilityLabel("Undo").disabled(!store.canUndo)
                Button(action: store.redo) { Image(systemName: "arrow.uturn.forward") }.help("Redo").accessibilityLabel("Redo").disabled(!store.canRedo)
                Divider().frame(height: 18)
                Button(action: store.splitSelectedClip) { Label("Split at playhead", systemImage: "scissors") }
                    .labelStyle(.iconOnly).help("Split at playhead").disabled(store.selectedClip == nil)
                Button { store.addTransitionAtPlayhead() } label: { Label("Add transition", systemImage: "square.2.layers.3d.top.filled") }
                    .labelStyle(.iconOnly).help("Dissolve or crossfade the selected clip's edit nearest the playhead, or fade a free edge (⌘T)")
                    .disabled(store.selectedClip == nil)
                Button(action: store.addTitle) { Label("New title", systemImage: "textformat") }
                    .labelStyle(.iconOnly).help("Add a title at the playhead (⌃T)")
                Button(action: store.deleteSelectedClip) { Label("Delete clip", systemImage: "trash") }
                    .labelStyle(.iconOnly).help("Delete selected clip").disabled(store.selectedClip == nil)
                Toggle(isOn: $store.snappingEnabled) { Image(systemName: "magnet") }
                    .toggleStyle(.button).help("Snap clip edges to adjacent clips and the playhead").accessibilityLabel("Snapping")
                Spacer()
                Button { store.stepPlayhead(frames: -1) } label: { Image(systemName: "backward.frame") }.help("Previous frame").accessibilityLabel("Previous frame")
                Button { store.stepPlayhead(frames: 1) } label: { Image(systemName: "forward.frame") }.help("Next frame").accessibilityLabel("Next frame")
                Button(store.playheadTimecode) {
                    timecodeEntry = store.playheadTimecode
                    showingTimecodeEntry = true
                }
                .font(.system(.caption, design: .monospaced))
                .help("Go to sequence timecode")
                .popover(isPresented: $showingTimecodeEntry) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Go to timecode").font(.headline)
                        TextField("HH:MM:SS:FF", text: $timecodeEntry)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(goToTimecode)
                        Button(action: goToTimecode) { Label("Go to timecode", systemImage: "arrow.right") }
                            .labelStyle(.iconOnly).help("Go to timecode").keyboardShortcut(.defaultAction)
                    }.padding().frame(width: 220)
                }
                Text("\(store.playheadSeconds, specifier: "%.3f") s").font(.system(.caption, design: .monospaced))
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $pixelsPerSecond, in: min(2, fittedZoom)...100).frame(width: 100).help("Timeline zoom")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button { store.timelineFitRequest = UUID() } label: { Label("Zoom Timeline to Fit", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .labelStyle(.iconOnly).help("Zoom timeline to fit; repeat to restore zoom").disabled(store.duration <= 0)
            }.padding(10)
            Divider()
            ScrollViewReader { scroller in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("Tracks").font(.caption.bold()).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).frame(width: labelWidth, height: 30, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .offset(x: scrollX).zIndex(2)
                            ruler
                        }
                        if store.project.tracks.isEmpty {
                            emptyTrackLane("V1", systemImage: "film", tint: .indigo)
                            emptyTrackLane("A1", systemImage: "waveform", tint: .teal)
                            Text("Drop media here to start your sequence")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, labelWidth + 12).padding(.top, 12)
                        }
                        ForEach(store.project.tracks) { track in
                            HStack(spacing: 0) {
                                TimelineTrackHeader(store: store, track: track)
                                    .padding(.horizontal, 10).frame(width: labelWidth, height: 64, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .offset(x: scrollX).zIndex(2)
                                trackLane(track)
                            }
                            // A clip dragged to another track draws over the rows it crosses.
                            .zIndex(track.clips.contains { interactingClipIDs.contains($0.id) } ? 1 : 0)
                        }
                    }
                    .id("timelineStart")
                    .padding(.bottom, 15)
                    .frame(minHeight: viewport.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("timelineDrop")) } action: { dropCanvasFrame = $0 }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
                .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x) } action: { _, x in scrollX = x }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("timelineDrop")) } action: { dropViewport = $0 }
                .onChange(of: store.timelineFitRequest) {
                    toggleZoomToFit()
                    scroller.scrollTo("timelineStart", anchor: .topLeading)
                }
            }
        }
        .coordinateSpace(name: "timelineDrop")
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, location in
            guard !store.project.tracks.isEmpty else {
                return store.importMediaToTimeline(urls: urls, at: 0)
            }
            guard dropViewport.contains(location), !dropCanvasFrame.isEmpty else {
                return store.importMediaToTimeline(urls: urls, at: store.playheadSeconds)
            }
            // Canvas geometry includes horizontal/vertical scroll offsets.
            // Subtract the track labels and ruler before interpreting the drop.
            let seconds = max(0, (location.x - dropCanvasFrame.minX - labelWidth) / pixelsPerSecond)
            let row = Int(floor((location.y - dropCanvasFrame.minY - 31) / 65))
            let trackID = store.project.tracks.indices.contains(row) ? store.project.tracks[row].id : nil
            return store.importMediaToTimeline(urls: urls, at: seconds, trackID: trackID)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.07))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) }
                    .overlay(alignment: .bottomTrailing) {
                        Label("Add to timeline", systemImage: "rectangle.stack.badge.plus")
                            .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule()).padding(12)
                    }
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focused($timelineFocused)
        .focusEffectDisabled()
        .focusedValue(\.editorCommandScope, .timeline)
        .simultaneousGesture(TapGesture().onEnded {
            if !showingTimecodeEntry { timelineFocused = true }
        })
    }

    private func goToTimecode() {
        showingTimecodeEntry = false
        store.seek(toTimecode: timecodeEntry)
    }

    // These lanes identify the empty canvas without creating tracks in the project.
    private func emptyTrackLane(_ name: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 0) {
            Label(name, systemImage: systemImage)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(width: labelWidth, height: 64, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .offset(x: scrollX).zIndex(2)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                tint.opacity(0.035)
                ForEach(0...Int(visibleDuration / tickInterval), id: \.self) { index in
                    Rectangle().fill(Color.secondary.opacity(0.08)).frame(width: 1, height: 64)
                        .offset(x: Double(index) * tickInterval * pixelsPerSecond)
                }
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                playhead(height: 64)
            }.frame(width: canvasWidth, height: 64)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name == "V1" ? "Empty video lane" : "Empty audio lane")
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .controlBackgroundColor)
            ForEach(0...Int(visibleDuration / tickInterval), id: \.self) { index in
                let seconds = Double(index) * tickInterval
                VStack(alignment: .leading, spacing: 3) {
                    Text(timeLabel(seconds)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 8)
                }.offset(x: seconds * pixelsPerSecond + 3, y: 3)
            }
            playhead(height: 30)
        }
        .frame(width: canvasWidth, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in store.focusSequenceViewer(); store.seek(to: max(0, min(store.duration, value.location.x / pixelsPerSecond))) })
    }

    private func visibleClips(in track: TimelineTrack) -> [TimelineClip] {
        let range = TimelineClipVisibility.range(viewport: dropViewport, canvas: dropCanvasFrame, labelWidth: labelWidth)
        return track.clips.filter { clip in
            TimelineClipVisibility.includes(startSeconds: clip.timelineStart.seconds,
                durationSeconds: clip.sourceRange.duration.seconds, pixelsPerSecond: pixelsPerSecond, range: range,
                pinned: clip.id == store.selectedClipID || interactingClipIDs.contains(clip.id) || linkedDrag?.ids.contains(clip.id) == true)
        }
    }

    private func trackLane(_ track: TimelineTrack) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { location in store.focusSequenceViewer(); store.seek(to: max(0, min(store.duration, location.x / pixelsPerSecond))) }
            ForEach(visibleClips(in: track)) { clip in
                TimelineClipView(clip: clip, asset: store.asset(id: clip.assetID), selected: store.selectedClipID == clip.id, pixelsPerSecond: pixelsPerSecond, viewport: viewport, previewRevision: store.mediaPreviewRevision,
                    select: { store.selectTimelineClip(clip.id) },
                    interactionChanged: { active in
                        if active { interactingClipIDs.insert(clip.id) }
                        else { interactingClipIDs.remove(clip.id) }
                    },
                    proposedMove: { store.proposedMove(clip: clip, to: $0, tolerance: 8 / pixelsPerSecond) },
                    proposedRow: { dragRow(for: clip, height: $0) },
                    rowHeight: rowHeight,
                    move: { seconds, rows in
                        // Linked clips stop following before the edit lands, so they never show it twice.
                        linkedDrag = nil
                        store.selectTimelineClip(clip.id)
                        store.moveSelectedClip(to: seconds, rowOffset: rows)
                    },
                    proposedTrim: { store.proposedTrimDelta(clip: clip, edge: $0, delta: $1, tolerance: 8 / pixelsPerSecond, alone: $2) },
                    trim: { edge, delta, alone in
                        linkedDrag = nil
                        store.selectTimelineClip(clip.id)
                        store.trimSelectedClip(edge: edge, delta: delta, alone: alone)
                    },
                    retiming: isRetiming(clip),
                    proposedRetime: { store.proposedRetimeDelta(clip: clip, delta: $0) },
                    retime: { delta in
                        linkedDrag = nil
                        store.selectTimelineClip(clip.id)
                        store.retimeSelectedClip(durationDelta: delta)
                    },
                    setSpeed: { percent in
                        store.selectTimelineClip(clip.id)
                        store.setSelectedClipSpeed(percent: percent)
                    },
                    follow: linkedDrag.flatMap { $0.sourceID != clip.id && $0.ids.contains(clip.id) ? $0 : nil },
                    dragChanged: { offset, leading, trailing, alone in
                        if clip.linkGroupID == nil || alone || (offset == 0 && leading == 0 && trailing == 0) {
                            if linkedDrag?.sourceID == clip.id { linkedDrag = nil }
                        } else {
                            linkedDrag = LinkedDrag(sourceID: clip.id, ids: Set(TimelineGesture.components(of: clip, in: store.project).map(\.id)),
                                                    offset: offset, leading: leading, trailing: trailing)
                        }
                    },
                    project: store.project,
                    proposedFade: { store.proposedFadeDuration(clip: clip, seconds: $0) },
                    crossfadeHighlighted: crossfadeHoverID == clip.id,
                    reportFrame: { frame in
                        if frame.isNull { clipFrames.removeValue(forKey: clip.id) }
                        else { clipFrames[clip.id] = frame }
                    },
                    hoverFade: { edge, point, seconds in
                        crossfadeHoverID = point.flatMap { crossfadeDrop(clip: clip, edge: edge, point: $0, seconds: seconds)?.target.id }
                    },
                    linkFade: { edge, point, seconds, baseline in
                        crossfadeHoverID = nil
                        guard let drop = crossfadeDrop(clip: clip, edge: edge, point: point, seconds: seconds) else {
                            if viewport.contains(point), store.project.tracks.flatMap(\.clips).contains(where: {
                                $0.id != clip.id && $0.requiredTrackKind == clip.requiredTrackKind && clipFrames[$0.id]?.contains(point) == true
                            }) {
                                store.errorMessage = clip.requiredTrackKind == .video
                                    ? "Cannot dissolve between these clips. They must meet on the same video track with enough source beyond the cut, and the joined edges cannot also have standalone fades."
                                    : "Cannot link this audio pair. Use adjacent cuts with enough source handles or compatible overlapping audio. Audio layouts and output routing must match; linked edges cannot also have standalone fades."
                                return true
                            }
                            return false
                        }
                        do {
                            try store.applyAudioCrossfade(outgoingClipID: drop.outgoing.id, incomingClipID: drop.incoming.id,
                                seconds: drop.seconds, curve: clip.requiredTrackKind == .video ? .linear : .equalPower, expectedProject: baseline)
                        } catch { store.errorMessage = store.audioEditErrorMessage(error) }
                        return true
                    },
                    setFade: { edge, seconds, expected in
                        do {
                            try store.applyFades(clipID: clip.id,
                                fadeInSeconds: edge == .leading ? seconds : expected.fadeIn.duration.seconds,
                                fadeInCurve: expected.fadeIn.curve,
                                fadeOutSeconds: edge == .trailing ? seconds : expected.fadeOut.duration.seconds,
                                fadeOutCurve: expected.fadeOut.curve, expectedClip: expected)
                        } catch { store.errorMessage = store.audioEditErrorMessage(error) }
                    })
                .offset(x: clip.timelineStart.seconds * pixelsPerSecond, y: 6)
                .contextMenu { clipMenu(clip) }
            }
            playhead(height: 64).allowsHitTesting(false)
        }.frame(width: canvasWidth, height: 64)
    }

    /// Retime mode shows on the selected clip and its linked components.
    private func isRetiming(_ clip: TimelineClip) -> Bool {
        guard store.retimeMode, clip.selection != .still, let selected = store.selectedClip else { return false }
        return selected.id == clip.id || (selected.linkGroupID != nil && selected.linkGroupID == clip.linkGroupID)
    }

    private func compatible(_ clip: TimelineClip, _ track: TimelineTrack) -> Bool {
        clip.requiredTrackKind == track.kind && clip.requiredAudioLayout == track.audioLayout
    }

    /// The row offset a vertical drag of `height` points lands on: the farthest compatible
    /// track it reaches, or one row past the outermost track for a new track (pictures above
    /// the top, sound below the bottom). 0 keeps the clip on its track.
    private func dragRow(for clip: TimelineClip, height: CGFloat) -> Int {
        let tracks = store.project.tracks
        guard let current = tracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }) else { return 0 }
        let wanted = Int((height / rowHeight).rounded())
        let step = wanted > 0 ? 1 : -1
        var best = 0, index = current
        for _ in 0..<abs(wanted) {
            index += step
            if tracks.indices.contains(index) {
                if compatible(clip, tracks[index]) { best = index - current }
            } else {
                if (index < 0 && clip.requiredTrackKind == .video) || (index >= tracks.count && clip.requiredTrackKind == .audio) {
                    best = index - current
                }
                break
            }
        }
        return best
    }

    /// Right-click actions on a clip; each selects the clip first.
    @ViewBuilder private func clipMenu(_ clip: TimelineClip) -> some View {
        let act = { (action: @escaping () -> Void) in { store.selectTimelineClip(clip.id); action() } }
        let end = clip.timelineStart.seconds + clip.sourceRange.duration.seconds
        let isPicture = clip.requiredTrackKind == .video
        let tracks = store.project.tracks
        let current = tracks.firstIndex { $0.clips.contains { $0.id == clip.id } }
        Button("Cut", action: act(store.cutSelectedClip))
        Button("Copy", action: act(store.copySelectedClip))
        Button("Paste at Playhead", action: act(store.pasteAtPlayhead)).disabled(store.clipboard == nil)
        Button("Duplicate", action: act(store.duplicateSelectedClip))
        Divider()
        Button("Split at Playhead", action: act(store.splitSelectedClip))
            .disabled(store.playheadSeconds <= clip.timelineStart.seconds || store.playheadSeconds >= end)
        Button("Add Transition", action: act { store.addTransitionAtPlayhead() })
        Button("Move Playhead to Clip Start", action: act { store.seek(to: clip.timelineStart.seconds) })
        Button("Move Playhead to Clip End", action: act { store.seek(to: end) })
        Divider()
        Menu("Move to Track") {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if compatible(clip, track) {
                    Button(track.displayName(in: store.project), action: act { store.moveSelectedClip(to: clip.timelineStart.seconds, rowOffset: index - (current ?? index)) })
                        .disabled(index == current)
                }
            }
            Divider()
            Button("New Track", action: act {
                guard let current else { return }
                store.moveSelectedClip(to: clip.timelineStart.seconds, rowOffset: isPicture ? -current - 1 : tracks.count - current)
            })
        }
        Button(store.retimeMode ? "Hide Retime Controls" : "Retime Controls", action: act(store.toggleRetimeMode))
            .disabled(clip.selection == .still)
        Menu("Speed") {
            ForEach(["25", "50", "100", "200", "400"], id: \.self) { preset in
                Button("\(preset)%", action: act { store.setSelectedClipSpeed(percent: preset) })
            }
        }.disabled(clip.selection == .still)
        if isPicture {
            Menu("Scaling") {
                Button("Fit", action: act { store.setScalingMode(.fit) })
                Button("Fill", action: act { store.setScalingMode(.fill) })
                Button("Native Size", action: act { store.setScalingMode(.none) })
            }
            Button("Reset Transform", action: act { store.setSelectedClipTransform(scale: "100", x: "0", y: "0", opacity: "100") })
                .disabled(clip.transform.isIdentity)
        }
        Divider()
        Button("Reveal in Media Bin", action: act { store.selectAsset(clip.assetID) })
        if let url = store.asset(id: clip.assetID)?.originalURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Delete", action: act(store.deleteSelectedClip))
        Button("Ripple Delete", action: act(store.rippleDeleteSelectedClip))
    }

    private func crossfadeDrop(clip: TimelineClip, edge: TimelineTrimEdge, point: CGPoint, seconds: Double)
        -> (target: TimelineClip, outgoing: TimelineClip, incoming: TimelineClip, seconds: Double)? {
        guard viewport.contains(point) else { return nil }
        let clips = store.project.tracks.flatMap(\.clips)
        guard let target = clips.first(where: { $0.id != clip.id && $0.requiredTrackKind == clip.requiredTrackKind && clipFrames[$0.id]?.contains(point) == true }) else { return nil }
        let outgoing = edge == .trailing ? clip : target
        let incoming = edge == .trailing ? target : clip
        let overlap = outgoing.timelineStart.seconds + outgoing.sourceRange.duration.seconds - incoming.timelineStart.seconds
        let isPicture = clip.requiredTrackKind == .video
        let unit = isPicture ? 1 / store.project.settings.frameRate.value.seconds : 1 / Double(store.project.settings.audioSampleRate)
        let duration = overlap > 0 ? overlap : max(unit, seconds)
        guard (try? store.previewAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: duration,
                                                curve: isPicture ? .linear : .equalPower)) != nil else { return nil }
        return (target, outgoing, incoming, duration)
    }

    private func playhead(height: CGFloat) -> some View {
        Rectangle().fill(Color.orange).frame(width: 2, height: height)
            .offset(x: store.playheadSeconds * pixelsPerSecond)
    }
    private func timeLabel(_ seconds: Double) -> String {
        if seconds >= 60 { return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))" }
        return "\(Int(seconds))s"
    }
}

private struct TimelineClipView: View {
    let clip: TimelineClip
    let asset: MediaAsset?
    let selected: Bool
    let pixelsPerSecond: Double
    let viewport: CGRect
    let previewRevision: UUID
    let select: () -> Void
    let interactionChanged: (Bool) -> Void
    let proposedMove: (Double) -> Double
    /// The track row offset a vertical drag reaches (0 stays on this track).
    let proposedRow: (CGFloat) -> Int
    let rowHeight: CGFloat
    let move: (Double, Int) -> Void
    /// The Bool is true for an Option-drag, which trims this component alone.
    let proposedTrim: (TimelineTrimEdge, Double, Bool) -> Double
    let trim: (TimelineTrimEdge, Double, Bool) -> Void
    /// Retime mode (⌘R): a speed bar on top, and the end handle changes speed.
    let retiming: Bool
    let proposedRetime: (Double) -> Double
    let retime: (Double) -> Void
    let setSpeed: (String) -> Void
    /// Another clip's live drag that this linked component follows.
    let follow: LinkedDrag?
    let dragChanged: (CGFloat, Double, Double, Bool) -> Void
    let project: Project
    let proposedFade: (Double) -> Double
    let crossfadeHighlighted: Bool
    let reportFrame: (CGRect) -> Void
    let hoverFade: (TimelineTrimEdge, CGPoint?, Double) -> Void
    let linkFade: (TimelineTrimEdge, CGPoint, Double, Project) -> Bool
    let setFade: (TimelineTrimEdge, Double, TimelineClip) -> Void
    @GestureState private var interactionActive = false
    @GestureState private var ownOffset: CGFloat = 0
    @GestureState private var ownRow = 0
    @GestureState private var ownLeading = 0.0
    @GestureState private var ownTrailing = 0.0
    @GestureState private var trimAlone = false
    private var dragOffset: CGFloat { ownOffset != 0 ? ownOffset : follow?.offset ?? 0 }
    private var leadingDelta: Double { ownLeading != 0 ? ownLeading : follow?.leading ?? 0 }
    private var trailingDelta: Double { ownTrailing != 0 ? ownTrailing : follow?.trailing ?? 0 }
    @GestureState private var fadeInPreview: Double?
    @GestureState private var fadeOutPreview: Double?
    @State private var fadeGestureClip: TimelineClip?
    @State private var fadeGestureProject: Project?
    @State private var clipFrame = CGRect.zero
    @State private var preview: TimelinePreview?
    @State private var loadedRequest: TimelinePreviewRequest?
    private var clipDuration: Double { max(0.001, clip.sourceRange.duration.seconds - leadingDelta + trailingDelta) }
    private var clipWidth: CGFloat { max(10, clipDuration * pixelsPerSecond) }
    private var previewOffset: CGFloat { max(0, viewport.minX - clipFrame.minX) }
    private var previewWidth: CGFloat { max(1, min(clipWidth - previewOffset, viewport.maxX - clipFrame.minX - previewOffset)) }
    private var previewRequest: TimelinePreviewRequest? {
        guard clipFrame.intersects(viewport), let url = asset?.originalURL else { return nil }
        return TimelinePreviewRequest(url: url, selection: clip.selection,
            start: max(0, clip.sourceRange.start.seconds + (leadingDelta + previewOffset / pixelsPerSecond) * clip.speed.seconds),
            duration: min(clipDuration - previewOffset / pixelsPerSecond, previewWidth / pixelsPerSecond) * clip.speed.seconds,
            thumbnailCount: min(12, max(1, Int(ceil(min(1080, previewWidth) / 90)))),
            waveformBins: min(512, max(16, Int(ceil(min(1536, previewWidth) / 3)))), revision: previewRevision)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(clip.requiredTrackKind == .video ? Color.indigo.opacity(0.85) : Color.teal.opacity(0.85))
            .overlay(alignment: .leading) {
                if loadedRequest == previewRequest, let preview {
                    TimelineClipPreview(preview: preview)
                        .frame(width: previewWidth)
                        .offset(x: previewOffset)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset?.name ?? "Media").font(.caption.bold()).lineLimit(1)
                    Text("\(clip.sourceRange.duration.seconds - leadingDelta + trailingDelta, specifier: "%.2f") s\(clip.speed == .one ? "" : String(format: " · %g%%", clip.speed.seconds * 100))")
                        .font(.caption2.monospacedDigit()).lineLimit(1)
                }.foregroundStyle(.white).padding(.horizontal, 12)
                    .shadow(color: .black.opacity(0.9), radius: 2)
            }
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(crossfadeHighlighted ? Color.yellow : selected ? Color.orange : Color.white.opacity(0.15), lineWidth: crossfadeHighlighted || selected ? 2 : 1) }
            .overlay { fadeEnvelope.allowsHitTesting(false) }
            .overlay { volumeAutomation.allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) {
                if let crossfade = project.audioCrossfades.first(where: { $0.outgoingClipID == clip.id || $0.incomingClipID == clip.id }) {
                    Label("\(crossfade.duration.seconds, specifier: "%.2f") s", systemImage: clip.requiredTrackKind == .video ? "square.2.layers.3d.top.filled" : "link")
                        .font(.caption2).foregroundStyle(.yellow).padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .help(clip.requiredTrackKind == .video ? "Cross dissolve; edit or remove in the inspector" : "Linked audio crossfade; edit or remove in the inspector")
                        .allowsHitTesting(false)
                }
            }
            .frame(width: clipWidth, height: 52)
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { clipFrame = $0; reportFrame($0) }
            .onDisappear {
                interactionChanged(false)
                reportFrame(.null)
                hoverFade(.leading, nil, 0)
                fadeGestureClip = nil
                fadeGestureProject = nil
                preview = nil
                loadedRequest = nil
            }
            .task(id: previewRequest) {
                guard !Task.isCancelled else { return }
                let request = previewRequest
                preview = nil
                loadedRequest = nil
                guard let request else { return }
                do {
                    // Coalesce zoom and live trim updates before starting a decoder.
                    try await Task.sleep(for: .milliseconds(120))
                    var result: TimelinePreview
                    while true {
                        do {
                            result = try await TimelinePreviewService.shared.preview(for: request)
                            break
                        } catch TimelinePreviewError.queueFull {
                            try await Task.sleep(for: .milliseconds(250))
                            try Task.checkCancellation()
                            guard previewRequest == request else { return }
                        }
                    }
                    try Task.checkCancellation()
                    guard previewRequest == request else { return }
                    preview = result
                    loadedRequest = request
                } catch {
                    // Offline and unsupported sources keep the readable clip placeholder.
                }
            }
            .onChange(of: interactionActive) { _, active in interactionChanged(active) }
            .onChange(of: [Double(ownOffset), ownLeading, ownTrailing, trimAlone ? 1 : 0]) { _, _ in
                dragChanged(ownOffset, ownLeading, ownTrailing, trimAlone)
            }
            .onTapGesture(perform: select)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($interactionActive) { _, state, _ in state = true }
                .updating($ownOffset) { value, state, _ in
                    state = (proposedMove(clip.timelineStart.seconds + value.translation.width / pixelsPerSecond) - clip.timelineStart.seconds) * pixelsPerSecond
                }
                .updating($ownRow) { value, state, _ in state = proposedRow(value.translation.height) }
                .onChanged { _ in select() }
                .onEnded { value in
                    move(proposedMove(clip.timelineStart.seconds + value.translation.width / pixelsPerSecond), proposedRow(value.translation.height))
                })
            .overlay(alignment: .leading) { if !retiming { trimHandle(.leading) } }
            .overlay(alignment: .trailing) { if retiming { retimeHandle } else { trimHandle(.trailing) } }
            .overlay(alignment: .topLeading) { if retiming { speedBar } }
            .overlay(alignment: .topLeading) {
                fadeHandle(.leading)
                fadeHandle(.trailing)
            }
            .onChange(of: fadeInPreview) { _, value in
                if value == nil && fadeOutPreview == nil { fadeGestureClip = nil; fadeGestureProject = nil; hoverFade(.leading, nil, 0) }
            }
            .onChange(of: fadeOutPreview) { _, value in
                if value == nil && fadeInPreview == nil { fadeGestureClip = nil; fadeGestureProject = nil; hoverFade(.leading, nil, 0) }
            }
            .offset(x: dragOffset + leadingDelta * pixelsPerSecond, y: CGFloat(ownRow) * rowHeight)
            .help(clip.requiredTrackKind == .audio
                ? "Drag to move, also up or down to another track; drag side handles to trim linked clips (Option-drag trims this clip alone); drag yellow handles to fade this audio component"
                : "Drag to move, also up or down to another track; drag the edge handles to trim linked clips (Option-drag trims this clip alone); drag yellow handles to fade the picture or onto the next clip to dissolve")
    }

    /// Volume keyframes as an orange line; full height is +6 dB, the bottom is silence.
    @ViewBuilder private var volumeAutomation: some View {
        if !clip.volumeKeyframes.isEmpty {
            Canvas { context, size in
                let start = clip.sourceRange.start.seconds + leadingDelta
                func y(_ gain: Double) -> CGFloat { size.height * (1 - min(1, gain / 2)) }
                func x(_ source: Double) -> CGFloat { (source - start) * pixelsPerSecond }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y(VolumeEnvelope.gain(atSourceSeconds: start, keyframes: clip.volumeKeyframes))))
                for keyframe in clip.volumeKeyframes { path.addLine(to: CGPoint(x: x(keyframe.time.seconds), y: y(keyframe.gain))) }
                path.addLine(to: CGPoint(x: size.width, y: y(VolumeEnvelope.gain(atSourceSeconds: start + clipDuration, keyframes: clip.volumeKeyframes))))
                context.stroke(path, with: .color(.orange), lineWidth: 1.5)
                for keyframe in clip.volumeKeyframes {
                    let point = CGPoint(x: x(keyframe.time.seconds), y: y(keyframe.gain))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.orange))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var fadeEnvelope: some View {
        Canvas { context, size in
            for edge in [TimelineTrimEdge.leading, .trailing] {
                let duration = edge == .leading ? (fadeInPreview ?? clip.fadeIn.duration.seconds)
                    : (fadeOutPreview ?? clip.fadeOut.duration.seconds)
                guard duration > 0 else { continue }
                let curve = edge == .leading ? clip.fadeIn.curve : clip.fadeOut.curve
                let width = min(size.width, duration * pixelsPerSecond)
                var path = Path()
                for step in 0...32 {
                    let progress = Double(step) / 32
                    let gain = curve == .linear ? progress : sin(progress * .pi / 2)
                    let x = edge == .leading ? progress * width : size.width - progress * width
                    let point = CGPoint(x: x, y: size.height * (1 - gain))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }

    private func fadeHandle(_ edge: TimelineTrimEdge) -> some View {
        let fade = edge == .leading ? clip.fadeIn : clip.fadeOut
        let duration = edge == .leading ? (fadeInPreview ?? fade.duration.seconds) : (fadeOutPreview ?? fade.duration.seconds)
        let inset = min(clipWidth - 6, max(6, duration * pixelsPerSecond))
        return Circle().fill(Color.yellow)
            .frame(width: 7, height: 7)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .offset(x: (edge == .leading ? inset : clipWidth - inset) - 7,
                    y: edge == .leading ? 0 : 12)
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($interactionActive) { _, state, _ in state = true }
                .updating(edge == .leading ? $fadeInPreview : $fadeOutPreview) { value, state, _ in
                    let original = fadeGestureClip ?? clip
                    let start = edge == .leading ? original.fadeIn.duration.seconds : original.fadeOut.duration.seconds
                    let delta = value.translation.width / pixelsPerSecond * (edge == .leading ? 1 : -1)
                    state = proposedFade(start + delta)
                }
                .onChanged { value in
                    if fadeGestureClip == nil { fadeGestureClip = clip; fadeGestureProject = project }
                    let original = fadeGestureClip ?? clip
                    let start = edge == .leading ? original.fadeIn.duration.seconds : original.fadeOut.duration.seconds
                    let delta = value.translation.width / pixelsPerSecond * (edge == .leading ? 1 : -1)
                    hoverFade(edge, value.location, abs(start + delta) * 2)
                    select()
                }
                .onEnded { value in
                    let original = fadeGestureClip ?? clip
                    let start = edge == .leading ? original.fadeIn.duration.seconds : original.fadeOut.duration.seconds
                    let delta = value.translation.width / pixelsPerSecond * (edge == .leading ? 1 : -1)
                    if !linkFade(edge, value.location, abs(start + delta) * 2, fadeGestureProject ?? project) {
                        setFade(edge, proposedFade(start + delta), original)
                    }
                    fadeGestureClip = nil
                    fadeGestureProject = nil
                })
            .help(clip.requiredTrackKind == .video
                ? (edge == .leading ? "Drag inward to fade in from black; drop onto the previous clip to dissolve" : "Drag inward to fade out to black; drop onto the next clip to dissolve")
                : (edge == .leading ? "Drag inward to fade in; drop onto another audio clip to link it" : "Drag inward to fade out; drop onto incoming audio to link it"))
            .accessibilityLabel(edge == .leading ? "Fade in handle" : "Fade out handle")
    }

    /// The clip's speed while retiming (live during a drag), with a menu of common speeds.
    private var speedBar: some View {
        let extent = (try? clip.sourceExtent().seconds) ?? clipDuration
        let percent = extent / clipDuration * 100
        return Menu {
            ForEach(["10", "25", "50", "75", "100", "150", "200", "400", "1000"], id: \.self) { preset in
                Button("\(preset)%") { setSpeed(preset) }
            }
        } label: {
            Label(String(format: "%g%%", (percent * 10).rounded() / 10), systemImage: "speedometer")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.caption2.bold()).foregroundStyle(.black)
        .padding(.horizontal, 6).frame(height: 15)
        .background(Color.orange.opacity(0.9), in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomTrailingRadius: 5))
        .help("Clip speed; pick a speed, or drag the end handle to retime")
    }

    /// Dragging the end of a clip in retime mode changes its speed: longer is slower.
    private var retimeHandle: some View {
        Image(systemName: "chevron.left.chevron.right")
            .font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
            .frame(width: 14, height: 52)
            .background(Color.orange.opacity(0.9))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($interactionActive) { _, state, _ in state = true }
                .updating($ownTrailing) { value, state, _ in state = proposedRetime(value.translation.width / pixelsPerSecond) }
                .onChanged { _ in select() }
                .onEnded { value in retime(proposedRetime(value.translation.width / pixelsPerSecond)) })
            .help("Drag to retime: longer plays slower, shorter faster (10–1000%)")
            .accessibilityLabel("Retime handle")
    }

    private func trimHandle(_ edge: TimelineTrimEdge) -> some View {
        Capsule().fill(Color.white.opacity(selected ? 0.9 : 0.4))
            .frame(width: 3, height: 26)
            .frame(width: 10, height: 52)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($interactionActive) { _, state, _ in state = true }
                .updating($trimAlone) { _, state, _ in state = NSEvent.modifierFlags.contains(.option) }
                .updating(edge == .leading ? $ownLeading : $ownTrailing) { value, state, _ in
                    state = proposedTrim(edge, value.translation.width / pixelsPerSecond, NSEvent.modifierFlags.contains(.option))
                }
                .onChanged { _ in select() }
                .onEnded { value in
                    let alone = NSEvent.modifierFlags.contains(.option)
                    trim(edge, proposedTrim(edge, value.translation.width / pixelsPerSecond, alone), alone)
                })
            .help(edge == .leading ? "Trim clip start; Option-drag to trim only this clip, keeping its link"
                                   : "Trim clip end; Option-drag to trim only this clip, keeping its link")
    }
}


private struct TimelineClipPreview: View {
    let preview: TimelinePreview

    var body: some View {
        GeometryReader { geometry in
            if !preview.images.isEmpty {
                HStack(spacing: 0) {
                    ForEach(preview.images.indices, id: \.self) { index in
                        Image(decorative: preview.images[index], scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width / CGFloat(preview.images.count), height: geometry.size.height)
                            .clipped()
                    }
                }
                .overlay(Color.black.opacity(0.3))
            } else if !preview.peaks.isEmpty {
                Canvas { context, size in
                    let rowHeight = size.height / CGFloat(preview.peaks.count)
                    for (channel, peaks) in preview.peaks.enumerated() {
                        guard !peaks.isEmpty else { continue }
                        let center = rowHeight * (CGFloat(channel) + 0.5)
                        var path = Path()
                        for (bin, peak) in peaks.enumerated() {
                            let x = (CGFloat(bin) + 0.5) * size.width / CGFloat(peaks.count)
                            let amplitude = max(0.5, CGFloat(peak) * rowHeight * 0.42)
                            path.move(to: CGPoint(x: x, y: center - amplitude))
                            path.addLine(to: CGPoint(x: x, y: center + amplitude))
                        }
                        context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: max(1, size.width / CGFloat(peaks.count)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
