import SwiftUI
import EditorCore

struct TimelineView: View {
    @ObservedObject var store: EditorStore
    @FocusState private var timelineFocused: Bool
    @State private var pixelsPerSecond = 35.0
    @State private var showingTimecodeEntry = false
    @State private var timecodeEntry = ""
    @State private var viewport = CGRect.zero
    private let labelWidth: CGFloat = 145
    private var visibleDuration: Double { max(20, store.duration + 5) }
    private var canvasWidth: CGFloat { max(650, visibleDuration * pixelsPerSecond) }
    private var tickInterval: Double {
        let desired = max(75 / pixelsPerSecond, visibleDuration / 400)
        return [1.0, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600].first(where: { $0 >= desired }) ?? desired
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Timeline").font(.headline)
                Button(action: store.undo) { Image(systemName: "arrow.uturn.backward") }.help("Undo").disabled(!store.canUndo)
                Button(action: store.redo) { Image(systemName: "arrow.uturn.forward") }.help("Redo").disabled(!store.canRedo)
                Divider().frame(height: 18)
                Button("Split at playhead", action: store.splitSelectedClip).disabled(store.selectedClip == nil)
                Button("Delete clip", action: store.deleteSelectedClip).disabled(store.selectedClip == nil)
                Toggle(isOn: $store.snappingEnabled) { Image(systemName: "magnet") }
                    .toggleStyle(.button).help("Snap clip edges to adjacent clips and the playhead")
                Spacer()
                Button { store.stepPlayhead(frames: -1) } label: { Image(systemName: "backward.frame") }.help("Previous frame")
                Button { store.stepPlayhead(frames: 1) } label: { Image(systemName: "forward.frame") }.help("Next frame")
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
                        Button("Go", action: goToTimecode).keyboardShortcut(.defaultAction)
                    }.padding().frame(width: 220)
                }
                Text("\(store.playheadSeconds, specifier: "%.3f") s").font(.system(.caption, design: .monospaced))
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $pixelsPerSecond, in: 2...100).frame(width: 100).help("Timeline zoom")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if store.project.tracks.isEmpty {
                ContentUnavailableView {
                    Label("Build your sequence", systemImage: "rectangle.stack")
                } description: {
                    Text("Select imported media and click Append to add clips.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("Tracks").font(.caption.bold()).foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: 30, alignment: .leading)
                            ruler
                        }
                        ForEach(store.project.tracks) { track in
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(track.displayName(in: store.project), systemImage: track.kind == .video ? "film" : "speaker.wave.2")
                                        .font(.caption.bold()).lineLimit(1)
                                    Text(track.kind == .video ? "Video" : "\(track.audioLayout?.channels.count ?? 0) channels")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.padding(.horizontal, 10).frame(width: labelWidth, height: 64, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                trackLane(track)
                            }
                        }
                    }
                    .padding(.bottom, 15)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
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
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in store.seek(to: max(0, min(store.duration, value.location.x / pixelsPerSecond))) })
    }

    private func trackLane(_ track: TimelineTrack) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { location in store.seek(to: max(0, min(store.duration, location.x / pixelsPerSecond))) }
            ForEach(track.clips) { clip in
                TimelineClipView(clip: clip, asset: store.project.assets.first(where: { $0.id == clip.assetID }), selected: store.selectedClipID == clip.id, pixelsPerSecond: pixelsPerSecond, viewport: viewport, previewRevision: store.mediaPreviewRevision,
                    select: { store.selectedClipID = clip.id },
                    proposedMove: { store.proposedMove(clip: clip, to: $0, tolerance: 8 / pixelsPerSecond) },
                    move: { seconds in
                        store.selectedClipID = clip.id
                        store.moveSelectedClip(to: seconds)
                    },
                    proposedTrim: { store.proposedTrimDelta(clip: clip, edge: $0, delta: $1, tolerance: 8 / pixelsPerSecond) },
                    trim: { edge, delta in
                        store.selectedClipID = clip.id
                        store.trimSelectedClip(edge: edge, delta: delta)
                    })
                .offset(x: clip.timelineStart.seconds * pixelsPerSecond, y: 6)
            }
            playhead(height: 64).allowsHitTesting(false)
        }.frame(width: canvasWidth, height: 64)
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
    let proposedMove: (Double) -> Double
    let move: (Double) -> Void
    let proposedTrim: (TimelineTrimEdge, Double) -> Double
    let trim: (TimelineTrimEdge, Double) -> Void
    @GestureState private var dragOffset: CGFloat = 0
    @GestureState private var leadingDelta = 0.0
    @GestureState private var trailingDelta = 0.0
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
            start: max(0, clip.sourceRange.start.seconds + leadingDelta + previewOffset / pixelsPerSecond),
            duration: min(clipDuration - previewOffset / pixelsPerSecond, previewWidth / pixelsPerSecond),
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
                    Text("\(clip.sourceRange.duration.seconds - leadingDelta + trailingDelta, specifier: "%.2f") s").font(.caption2.monospacedDigit()).lineLimit(1)
                }.foregroundStyle(.white).padding(.horizontal, 12)
                    .shadow(color: .black.opacity(0.9), radius: 2)
            }
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.orange : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1) }
            .frame(width: clipWidth, height: 52)
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { clipFrame = $0 }
            .task(id: previewRequest) {
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
            .onTapGesture(perform: select)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($dragOffset) { value, state, _ in
                    state = (proposedMove(clip.timelineStart.seconds + value.translation.width / pixelsPerSecond) - clip.timelineStart.seconds) * pixelsPerSecond
                }
                .onChanged { _ in select() }
                .onEnded { value in move(proposedMove(clip.timelineStart.seconds + value.translation.width / pixelsPerSecond)) })
            .overlay(alignment: .leading) { trimHandle(.leading) }
            .overlay(alignment: .trailing) { trimHandle(.trailing) }
            .offset(x: dragOffset + leadingDelta * pixelsPerSecond)
            .help("Drag to move; drag the edge handles to trim linked clips")
    }

    private func trimHandle(_ edge: TimelineTrimEdge) -> some View {
        Capsule().fill(Color.white.opacity(selected ? 0.9 : 0.4))
            .frame(width: 3, height: 26)
            .frame(width: 10, height: 52)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating(edge == .leading ? $leadingDelta : $trailingDelta) { value, state, _ in
                    state = proposedTrim(edge, value.translation.width / pixelsPerSecond)
                }
                .onChanged { _ in select() }
                .onEnded { value in trim(edge, proposedTrim(edge, value.translation.width / pixelsPerSecond)) })
            .help(edge == .leading ? "Trim clip start" : "Trim clip end")
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
