import SwiftUI
import AVKit
import EditorCore

struct ContentView: View {
    @ObservedObject var store: EditorStore
    var saveProtection: ProjectSaveProtection? = nil
    @AppStorage("workspace.showMediaBin") private var showMediaBin = true
    @AppStorage("workspace.showInspector") private var showInspector = true
    @AppStorage("workspace.showTimeline") private var showTimeline = true
    @AppStorage("workspace.showMixer") private var showMixer = false
    @State private var isMediaBinDropTargeted = false
    @State private var binName = ""
    @State private var creatingBin = false
    @State private var renamingBin = false
    @State private var renamingSequenceID: UUID?
    @State private var sequenceName = ""
    @StateObject private var sequencePlayback = SequencePlaybackController(proxyResolver: EditorStore.resolveSequenceProxies)

    var body: some View {
        VSplitView {
            HSplitView {
                if showMediaBin {
                    mediaBin.frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
                        .focusedValue(\.editorCommandScope, .source)
                        .simultaneousGesture(TapGesture().onEnded { store.focusSourceViewer() })
                }
                monitor.frame(minWidth: 320, maxWidth: .infinity)
                    .focusedValue(\.editorCommandScope, store.showSequenceMonitor ? .timeline : .source)
                if showInspector {
                    ProjectInspector(store: store).frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                }
                if showMixer {
                    MixerPanel(store: store).frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }
            }
            .frame(minHeight: 260)
            if showTimeline {
                TimelineView(store: store).frame(minHeight: 220, idealHeight: 320)
                    .simultaneousGesture(TapGesture().onEnded { store.focusSequenceViewer() })
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(TextFocusReleaser(store: store))
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.importMedia) { Image(systemName: "plus.rectangle.on.folder").accessibilityLabel("Import media") }
                    .help("Import media into the selected bin").disabled(store.isImporting)
                Button(action: store.appendSelectedAsset) { Image(systemName: "text.badge.plus").accessibilityLabel("Append to timeline") }
                    .help("Append selected media to timeline").disabled(store.selectedAsset == nil || store.isImporting)
                Menu {
                    Button("Append with audio selection…", action: store.beginAudioAppend)
                        .disabled(store.selectedAsset?.streams.contains(where: { $0.kind == .audio }) != true || store.isImporting)
                } label: { Image(systemName: "waveform.badge.plus").accessibilityLabel("Audio placement") }
                .help("Audio placement options")
                Menu {
                    Button("Create proxies…") { store.beginProxyCreation() }
                        .disabled(!store.project.assets.contains { store.selectedAssetIDs.contains($0.id) && $0.streams.contains { $0.kind == .video } } || store.proxyGenerationTask != nil || store.isRelinkingProxy)
                    Button("Proxy queue…") { store.showProxyQueue = true }
                } label: { Image(systemName: "film.stack").accessibilityLabel("Proxies") }
                .help("Proxy creation and queue")
                Menu {
                    Toggle("Media bin", isOn: $showMediaBin)
                    Toggle("Inspector", isOn: $showInspector)
                    Toggle("Timeline", isOn: $showTimeline)
                    Toggle("Mixer", isOn: $showMixer)
                    Divider()
                    Button("Show all panels") {
                        showMediaBin = true; showInspector = true; showTimeline = true
                    }
                } label: { Image(systemName: "rectangle.3.group").accessibilityLabel("Panels") }
                .help("Show or hide workspace panels")
                Menu {
                    Button("Render sequence…", action: store.beginRenderExport)
                    Button("Export FCPXML…", action: store.exportFCPXML)
                    Button("Export track EDL…", action: store.beginEDLExport)
                    Button("Export OpenTimelineIO…", action: store.exportOTIO)
                } label: { Image(systemName: "square.and.arrow.up").accessibilityLabel("Export") }
                .help("Export sequence").disabled(store.duration <= 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let saveProtection {
                    ProjectSaveProtectionNotice(protection: saveProtection)
                }
                HStack {
                    if store.isImporting { ProgressView().controlSize(.small) }
                    Text(store.statusMessage).lineLimit(1)
                    Spacer()
                    Text(store.showSequenceMonitor ? "Sequence preview" : "Source preview").foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.bar)
        }
        .onChange(of: store.project) { _, project in
            if store.showSequenceMonitor { sequencePlayback.update(project: project, seconds: store.playheadSeconds, representation: store.playbackRepresentation) }
        }
        .onChange(of: store.playheadSeconds) { _, seconds in
            if store.showSequenceMonitor { sequencePlayback.update(project: store.project, seconds: seconds, representation: store.playbackRepresentation) }
        }
        .onChange(of: store.playbackRepresentation) { _, representation in
            if store.showSequenceMonitor {
                sequencePlayback.update(project: store.project, seconds: store.playheadSeconds, representation: representation)
            }
        }
        .onChange(of: store.showSequenceMonitor) { _, show in
            if show {
                store.pauseSource()
                store.sequencePlayback = sequencePlayback
                sequencePlayback.activate(project: store.project, seconds: store.playheadSeconds, representation: store.playbackRepresentation)
            } else { store.sequencePlayback = nil; sequencePlayback.deactivate() }
        }
        .onAppear {
            sequencePlayback.positionChanged = { seconds in store.playheadSeconds = seconds }
            if store.showSequenceMonitor {
                store.sequencePlayback = sequencePlayback
                sequencePlayback.activate(project: store.project, seconds: store.playheadSeconds, representation: store.playbackRepresentation)
            }
        }
        .onDisappear { store.sequencePlayback = nil; sequencePlayback.deactivate() }
        .sheet(item: $store.proxyCreationDraft) { draft in
            ProxyCreationView(store: store, draft: draft)
        }
        .sheet(isPresented: $store.showProxyQueue) {
            ProxyQueueView(store: store)
        }
        .sheet(item: $store.audioAppendAsset) { asset in
            AudioSourceEditor(store: store, asset: asset)
        }
        .sheet(item: $store.edlExportDraft) { draft in
            EDLExportView(store: store, draft: draft)
        }
        .sheet(item: $store.renderExportDraft) { draft in
            SequenceExportView(draft: draft)
        }
        .alert("Unable to complete action", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var mediaBin: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    Button("Media") { store.selectMediaBin(nil) }
                    ForEach(store.project.mediaBins) { bin in
                        Button(store.project.mediaBinPath(id: bin.id)) { store.selectMediaBin(bin.id) }
                    }
                } label: {
                    Text(store.selectedMediaBinID.map { store.project.mediaBinPath(id: $0) } ?? "Media")
                        .font(.headline).lineLimit(1)
                }
                Spacer()
                Text("\(store.visibleBinAssets.count + store.visibleBinSequences.count)").foregroundStyle(.secondary)
                Menu {
                    Button("New sequence", action: store.createSequence)
                    Button("New sub-bin…") { binName = ""; creatingBin = true }
                    if let bin = store.project.mediaBins.first(where: { $0.id == store.selectedMediaBinID }) {
                        Button("Rename bin…") { binName = bin.name; renamingBin = true }
                        Menu("Move bin to") {
                            Button("Media") { store.moveMediaBin(bin.id, to: nil) }
                            ForEach(store.project.mediaBins.filter { $0.id != bin.id }) { destination in
                                Button(store.project.mediaBinPath(id: destination.id)) {
                                    store.moveMediaBin(bin.id, to: destination.id)
                                }
                            }
                        }
                        Button("Remove bin, keep contents", action: store.removeSelectedMediaBin)
                        Button("Go to parent") { store.selectMediaBin(bin.parentID) }
                    }
                } label: { Image(systemName: "folder.badge.plus") }
                .accessibilityLabel("Organize media bins").help("Organize media bins")
            }.padding(12)
            Divider()
            let childBins = store.project.mediaBins.filter { $0.parentID == store.selectedMediaBinID }
            if !childBins.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(childBins) { bin in
                            Button { store.selectMediaBin(bin.id) } label: {
                                Label(bin.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.horizontal, 12)
                        }
                    }.padding(.vertical, 8)
                }.frame(maxHeight: 120)
                Divider()
            }
            if store.visibleBinAssets.isEmpty && store.visibleBinSequences.isEmpty {
                ContentUnavailableView {
                    Label(store.selectedMediaBinID == nil ? "Import your media" : "Empty bin", systemImage: "folder.badge.plus")
                } description: {
                    Text("Import or drop video, audio, or still images into this bin.")
                } actions: {
                    Button(action: store.importMedia) { Label("Import media", systemImage: "plus.rectangle.on.folder") }
                        .labelStyle(.iconOnly).help("Import media").disabled(store.isImporting)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: {
                    store.inspectorFocus == .sequence ? store.selectedAssetIDs.union([store.project.sequenceID]) : store.selectedAssetIDs
                }, set: { ids in
                    let sequences = Set(store.project.sequenceSummaries.map(\.id))
                    if let sequence = ids.subtracting(store.selectedAssetIDs).first(where: sequences.contains) {
                        store.selectSequence(sequence)
                        // The bin's own tap switches to the source viewer; switch back after it.
                        DispatchQueue.main.async { store.focusSequenceViewer() }
                    } else {
                        store.focusSourceViewer()
                        store.selectAssets(ids.subtracting(sequences))
                    }
                })) {
                    ForEach(store.visibleBinSequences) { sequence in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "film.stack").foregroundStyle(sequence.isOpen ? Color.accentColor : .secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sequence.name).lineLimit(2)
                                Text(sequence.isOpen ? "Sequence · open" : "Sequence").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4).tag(sequence.id)
                        .contextMenu {
                            Button("Open") { store.selectSequence(sequence.id) }.disabled(sequence.isOpen)
                            Button("Rename…") { sequenceName = sequence.name; renamingSequenceID = sequence.id }
                            Menu("Move to bin") {
                                Button("Media") { store.moveSequences([sequence.id], to: nil) }
                                ForEach(store.project.mediaBins) { bin in
                                    Button(store.project.mediaBinPath(id: bin.id)) { store.moveSequences([sequence.id], to: bin.id) }
                                }
                            }
                            Divider()
                            Button("Delete sequence") { store.removeSequence(sequence.id) }
                                .disabled(store.project.storedSequences.isEmpty)
                        }
                    }
                    ForEach(store.visibleBinAssets) { asset in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: assetIcon(asset)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.name).lineLimit(2)
                                Text(asset.isStill ? assetKind(asset) : "\(String(format: "%.2f", asset.duration.seconds)) s · \(assetKind(asset))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4).tag(asset.id)
                        .contextMenu {
                            Menu("Move to bin") {
                                let ids = store.selectedAssetIDs.contains(asset.id) ? store.selectedAssetIDs : [asset.id]
                                Button("Media") { store.moveBinAssets(ids, to: nil) }
                                ForEach(store.project.mediaBins) { bin in
                                    Button(store.project.mediaBinPath(id: bin.id)) { store.moveBinAssets(ids, to: bin.id) }
                                }
                            }
                            Button("Create proxies…") { store.beginProxyCreation(assetID: asset.id) }
                                .disabled(!asset.streams.contains(where: { $0.kind == .video }) || store.proxyGenerationTask != nil || store.isRelinkingProxy)
                            if asset.proxy != nil {
                                Button("Relink proxy…") { store.beginProxyRelink(assetID: asset.id) }
                                    .disabled(store.isRelinkingProxy || store.proxyGenerationTask != nil)
                            }
                            Button("Append to timeline") {
                                store.selectAsset(asset.id)
                                store.appendSelectedAsset()
                            }
                            if asset.streams.contains(where: { $0.kind == .audio }) {
                                Button("Append with audio selection…") {
                                    store.selectAsset(asset.id)
                                    store.beginAudioAppend()
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button(action: store.importMedia) { Label("Import media", systemImage: "plus.rectangle.on.folder") }
                    .labelStyle(.iconOnly).help("Import into this bin").disabled(store.isImporting)
                Spacer()
                Button { store.placeSelectedSourceAtPlayhead(mode: .insert) } label: { Label("Insert at playhead", systemImage: "arrow.right.to.line.compact") }
                    .labelStyle(.iconOnly).help("Insert at the playhead, moving later clips (,)").disabled(store.selectedAsset == nil || store.isImporting)
                Button { store.placeSelectedSourceAtPlayhead(mode: .overwrite) } label: { Label("Overwrite at playhead", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                    .labelStyle(.iconOnly).help("Overwrite the sequence at the playhead (.)").disabled(store.selectedAsset == nil || store.isImporting)
                Button(action: store.appendSelectedAsset) { Label("Append to timeline", systemImage: "text.badge.plus") }
                    .labelStyle(.iconOnly).help("Append selected media to timeline").disabled(store.selectedAsset == nil || store.isImporting)
            }.padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !store.isImporting, store.audioAppendAsset == nil,
                  store.renderExportDraft == nil, store.edlExportDraft == nil else { return false }
            store.importMedia(urls: files)
            return true
        } isTargeted: { isMediaBinDropTargeted = $0 }
        .overlay {
            if isMediaBinDropTargeted {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                    Label("Import to media bin", systemImage: "plus.rectangle.on.folder")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 48)
                }
                .allowsHitTesting(false)
            }
        }
        .alert("New sub-bin", isPresented: $creatingBin) {
            TextField("Name", text: $binName)
            Button("Create") { store.createMediaBin(name: binName) }
                .disabled(binName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename sequence", isPresented: Binding(get: { renamingSequenceID != nil }, set: { if !$0 { renamingSequenceID = nil } })) {
            TextField("Name", text: $sequenceName)
            Button("Rename") { if let id = renamingSequenceID { store.renameSequence(id, name: sequenceName) } }
                .disabled(sequenceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename bin", isPresented: $renamingBin) {
            TextField("Name", text: $binName)
            Button("Rename") { store.renameSelectedMediaBin(name: binName) }
                .disabled(binName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var viewerToggle: some View {
        Button(action: store.toggleViewer) {
            Image(systemName: store.showSequenceMonitor ? "timeline.selection" : "film")
        }
        .accessibilityLabel("Switch source and sequence viewer")
        .accessibilityValue(store.showSequenceMonitor ? "Sequence" : "Source")
        .help(store.showSequenceMonitor ? "Switch to source viewer (Tab by default)" : "Switch to sequence viewer (Tab by default)")
    }

    private var representationToggle: some View {
        Button {
            store.setPlaybackRepresentation(store.playbackRepresentation == .proxy ? .original : .proxy)
        } label: {
            Image(systemName: store.playbackRepresentation == .proxy ? "square.stack.3d.up.fill" : "square.stack.3d.up")
        }
        .accessibilityLabel(store.playbackRepresentation == .proxy ? "Prefer Proxy" : "Prefer HiRes")
        .accessibilityValue(store.playbackRepresentation == .proxy ? "Proxy preferred" : "HiRes preferred")
        .help(store.playbackRepresentation == .proxy ? "Proxy preferred. Click to prefer HiRes; available media is used as fallback." : "HiRes preferred. Click to prefer Proxy; available media is used as fallback.")
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            if store.showSequenceMonitor { sequenceMonitor } else { sourceMonitor }
        }
    }

    private var sequenceMonitor: some View {
        VStack(spacing: 0) {
            HStack {
                viewerToggle
                Text("Sequence monitor").font(.headline)
                Spacer()
                Text(store.playheadTimecode).monospacedDigit()
            }.padding(12)
            ZStack {
                Color.black
                if let image = sequencePlayback.image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "film").font(.system(size: 38))
                        Text(store.duration <= 0 ? "Append media to monitor a sequence" : sequencePlayback.message)
                            .multilineTextAlignment(.center)
                    }.foregroundStyle(.white.opacity(0.7)).padding(20)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    representationToggle
                    Button { store.stepPlayhead(frames: -1) } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Previous sequence frame")
                    Button(action: sequencePlayback.playReverse) { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Play sequence backwards")
                        .help("Play backwards, silent (J); press again for 2×, 4× or 8×")
                        .disabled(!sequencePlayback.available || sequencePlayback.isPreparing || store.duration <= 0)
                    Button(action: sequencePlayback.pause) { Image(systemName: "pause.fill") }
                        .accessibilityLabel("Pause sequence")
                    Button(action: sequencePlayback.play) { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play sequence")
                        .disabled(!sequencePlayback.available || sequencePlayback.isPreparing || store.duration <= 0)
                    Button { store.stepPlayhead(frames: 1) } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next sequence frame")
                    if sequencePlayback.isPreparing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(sequencePlayback.reverseSpeed.map { String(format: "Reverse %g×", $0) } ?? (sequencePlayback.isPlaying ? "Playing" : "Paused")).font(.caption)
                }
                Text(sequencePlayback.message).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }

    private var sourceMonitor: some View {
        VStack(spacing: 0) {
            HStack {
                viewerToggle
                Text("Source monitor").font(.headline)
                Spacer()
                Text(store.selectedAsset?.name ?? "No source selected").foregroundStyle(.secondary).lineLimit(1)
            }.padding(12)
            ZStack {
                Color.black
                if let image = store.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                } else if let player = store.sourcePlayer {
                    SourcePlayerView(player: player)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle").font(.system(size: 38))
                        Text(store.selectedAsset == nil ? "Select media to preview" : "Source preview unavailable")
                        if store.selectedAsset != nil {
                            Button(action: store.relinkSelectedAsset) { Label("Relink media", systemImage: "link") }
                                .labelStyle(.iconOnly).help("Relink media")
                        }
                    }.foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                representationToggle
                Text(store.proxyPlaybackMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Group {
                    Button(action: store.playSourceBackwards) { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Play source backwards")
                        .help("Play source backwards (silent)")
                        .disabled(store.sourcePlayback == nil)
                    Button(action: store.pauseSource) { Image(systemName: "pause.fill") }
                        .accessibilityLabel("Pause source")
                        .help("Pause source")
                        .disabled(!store.canControlSourceTransport)
                    Button(action: store.playSourceForwards) { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play source forwards")
                        .help("Play source forwards")
                        .disabled(!store.canControlSourceTransport)
                }
            }.padding(10)
            if let range = store.selectedSourceRange {
                HStack(spacing: 10) {
                    Button { store.markSource(inPoint: true) } label: { Label("Mark In", systemImage: "arrow.right.to.line") }
                        .labelStyle(.iconOnly).help("Mark source In (I by default)").disabled(!store.canControlSourceTransport)
                    Button { store.markSource(inPoint: false) } label: { Label("Mark Out", systemImage: "arrow.left.to.line") }
                        .labelStyle(.iconOnly).help("Mark source Out, exclusive (O by default)").disabled(!store.canControlSourceTransport)
                    Text("\(range.start.seconds, specifier: "%.2f") – \((try? range.end().seconds) ?? 0, specifier: "%.2f") s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Selected source range; Out is exclusive")
                    Spacer()
                    Text("\(range.duration.seconds, specifier: "%.2f") s").font(.caption.monospacedDigit())
                    Button(action: store.clearSourceMarks) { Label("Clear source marks", systemImage: "xmark") }
                        .labelStyle(.iconOnly).help("Clear marks (Option-X by default)")
                        .disabled(store.selectedAssetID.map { store.sourceRanges[$0] == nil } ?? true)
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }

        }
    }

    private func assetIcon(_ asset: MediaAsset) -> String {
        if asset.streams.contains(where: { $0.kind == .video }) { return "film" }
        return asset.streams.isEmpty ? "photo" : "waveform"
    }
    private func assetKind(_ asset: MediaAsset) -> String {
        if asset.streams.contains(where: { $0.kind == .video }) { return "Video" }
        return asset.streams.isEmpty ? "Still image" : "Audio"
    }
}

private struct ProjectSaveProtectionNotice: View {
    @ObservedObject var protection: ProjectSaveProtection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reminder = protection.reminderMessage {
                HStack(spacing: 10) {
                    Label(reminder, systemImage: "externaldrive.badge.exclamationmark")
                    Spacer()
                    Button("Save project…", systemImage: "square.and.arrow.down") {
                        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                    }.labelStyle(.iconOnly).help("Save project")
                    Button("Remind me later", systemImage: "clock", action: protection.dismissReminder)
                        .labelStyle(.iconOnly).help("Remind me later")
                }
            }
            if let status = protection.backupStatusMessage {
                Label(status, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
            if let date = protection.lastBackupDate, let folder = protection.backupsURL {
                HStack {
                    Label("Backup saved \(date.formatted(date: .omitted, time: .shortened))", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show backups", systemImage: "folder") { NSWorkspace.shared.open(folder) }
                        .labelStyle(.iconOnly)
                        .help("Open timestamped project snapshots in Finder")
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, protection.reminderMessage == nil && protection.backupStatusMessage == nil && protection.lastBackupDate == nil ? 0 : 8)
    }
}

private struct ProjectInspector: View {
    @ObservedObject var store: EditorStore
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var frameRate = "24"
    @State private var startTimecode = "00:00:00:00"
    @State private var audioSampleRate = "48000"
    @State private var audioLayout = ChannelLayout.stereo
    @State private var editingAudio = false
    @State private var fadeInDuration = "0"
    @State private var fadeOutDuration = "0"
    @State private var fadeInCurve = AudioFadeCurve.linear
    @State private var fadeOutCurve = AudioFadeCurve.linear
    @State private var fadeDraftClip: TimelineClip?
    @State private var clipVolume = "0"
    @State private var transformScale = "100"
    @State private var transformX = "0"
    @State private var transformY = "0"
    @State private var transformOpacity = "100"
    @State private var crossfadeTargetID: UUID?
    @State private var crossfadeDuration = "0.5"
    @State private var crossfadeCurve = AudioFadeCurve.equalPower
    @State private var transitionStyle = TransitionStyle.dissolve
    @State private var crossfadeDraftProject: Project?

    private enum Tab: Hashable { case video, audio }
    @State private var tab = Tab.video
    @State private var sequenceName = ""
    @State private var markerName = ""
    @State private var markerNote = ""
    @State private var recordedRate = ""
    @State private var playRate = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.inspectorFocus == .sequence {
                    sequenceInspector
                } else if store.inspectorFocus == .clip, let clip = store.selectedClip {
                    clipInspector(clip)
                } else if store.inspectorFocus == .asset, let asset = store.selectedAsset {
                    assetInspector(asset)
                } else if store.inspectorFocus == .marker, let marker = store.selectedMarker {
                    markerInspector(marker)
                } else {
                    Text("Inspector").font(.headline)
                    Text("Select a timeline clip, a sequence or media in the bin to inspect it.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(12)
        }
        .onAppear { refreshClip(); refreshSettings(); refreshMarker() }
        .onChange(of: store.selectedMarker) { _, _ in refreshMarker() }
        .onChange(of: store.selectedClip) { _, _ in refreshClip() }
        .onChange(of: store.selectedClipID) { _, _ in
            if let clip = store.selectedClip { tab = clip.requiredTrackKind == .video ? .video : .audio }
        }
        .onChange(of: store.project.settings) { _, _ in refreshSettings() }
        .onChange(of: store.project.sequenceName) { _, _ in refreshSettings() }
        .onChange(of: store.project.audioCrossfades) { _, _ in refreshCrossfade() }
        .sheet(isPresented: $editingAudio) {
            if let clip = store.selectedClip, clip.requiredTrackKind == .audio {
                AudioSourceEditor(store: store, clip: clip)
            }
        }
    }

    /// The selected clip's linked component of the other kind, if any.
    private func linkedComponent(of clip: TimelineClip, kind: TrackKind) -> TimelineClip? {
        TimelineGesture.components(of: clip, in: store.project).first { $0.id != clip.id && $0.requiredTrackKind == kind }
    }

    @ViewBuilder private func clipInspector(_ clip: TimelineClip) -> some View {
        let isPicture = clip.requiredTrackKind == .video
        Text(store.asset(id: clip.assetID)?.name ?? "Clip").font(.headline).lineLimit(2)
        Picker("Section", selection: $tab) {
            Label("Video", systemImage: "film").tag(Tab.video)
            Label("Audio", systemImage: "waveform").tag(Tab.audio)
        }
        .pickerStyle(.segmented).labelsHidden()
        if tab == .video {
            if isPicture { videoSections(clip) }
            else {
                Text("This clip is sound only.").font(.callout).foregroundStyle(.secondary)
                if let picture = linkedComponent(of: clip, kind: .video) {
                    Button("Select linked picture", systemImage: "film") { store.selectTimelineClip(picture.id) }
                }
            }
        } else {
            audioSections(clip)
        }
    }

    @ViewBuilder private func videoSections(_ clip: TimelineClip) -> some View {
        if let asset = store.asset(id: clip.assetID), let title = asset.title {
            GroupBox("Title") {
                TitleEditor(title: title) { store.updateTitle(assetID: asset.id, to: $0) }
                    .id(asset.id).padding(5)
            }
        }
        if clip.selection != .still { frameRateControls(clip) }
        GroupBox("Transform") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Scaling", selection: Binding(get: { clip.scalingMode }, set: store.setScalingMode)) {
                    Text("Fit").tag(ScalingMode.fit)
                    Text("Fill").tag(ScalingMode.fill)
                    Text("Native size").tag(ScalingMode.none)
                }
                HStack {
                    numericField("Scale (%)", text: $transformScale)
                    numericField("Opacity (%)", text: $transformOpacity)
                }
                HStack {
                    numericField("Position X (%)", text: $transformX)
                    numericField("Position Y (%)", text: $transformY)
                }
                HStack {
                    Button("Apply transform", systemImage: "checkmark") {
                        store.setSelectedClipTransform(scale: transformScale, x: transformX, y: transformY, opacity: transformOpacity)
                    }.labelStyle(.iconOnly).help("Apply scale, position and opacity")
                    Button("Picture in picture", systemImage: "pip") {
                        store.setSelectedClipTransform(scale: "33", x: "30", y: "30", opacity: "100")
                    }.labelStyle(.iconOnly).help("Shrink to a third in the lower right corner")
                    Menu {
                        ForEach(EditorStore.MotionPreset.allCases) { preset in
                            Button(preset.rawValue) { store.applyMotionPreset(preset) }
                        }
                    } label: { Label("Motion presets", systemImage: "wand.and.rays") }
                    .labelStyle(.iconOnly).help("Animate this picture or title with a common move").fixedSize()
                    Button("Add position keyframe at playhead", systemImage: "diamond") {
                        store.addTransformKeyframeAtPlayhead(scale: transformScale, x: transformX, y: transformY, opacity: transformOpacity)
                    }.labelStyle(.iconOnly).help("Keyframe this scale, position and opacity at the playhead; the picture changes between keyframes")
                    Button("Reset transform", systemImage: "arrow.counterclockwise") {
                        store.setSelectedClipTransform(scale: "100", x: "0", y: "0", opacity: "100")
                    }.labelStyle(.iconOnly).help("Reset scale, position and opacity").disabled(clip.transform.isIdentity)
                }
                Text("Position is a share of the frame: positive X moves right, positive Y down. Layers below show around and through the picture.")
                    .font(.caption).foregroundStyle(.secondary)
                if !clip.transformKeyframes.isEmpty {
                    ForEach(clip.transformKeyframes.indices, id: \.self) { index in
                        let keyframe = clip.transformKeyframes[index]
                        let at = clip.timelineStart.seconds + (keyframe.time.seconds - clip.sourceRange.start.seconds) / clip.speed.seconds
                        HStack {
                            Image(systemName: "diamond.fill").foregroundStyle(.cyan)
                            Text(String(format: "%.2f s · %g%% · %g, %g · %g%%", at, keyframe.scale * 100, keyframe.offsetX * 100,
                                        keyframe.offsetY * 100, keyframe.opacity * 100))
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Button("Go to keyframe", systemImage: "arrow.right.to.line") { store.seek(to: max(0, at)) }
                                .labelStyle(.iconOnly).help("Move the playhead to this keyframe")
                            Button("Remove keyframe", systemImage: "xmark") {
                                var remaining = clip.transformKeyframes; remaining.remove(at: index)
                                store.setSelectedTransformKeyframes(remaining)
                            }.labelStyle(.iconOnly).help("Remove this keyframe")
                        }
                    }
                    Button("Clear position keyframes", systemImage: "trash") { store.setSelectedTransformKeyframes([]) }
                    Text("Scale, position and opacity change between keyframes; keyframe opacity multiplies the static opacity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
        GroupBox {
            ColorControls(color: clip.color) { store.setSelectedClipColor($0) }.id(clip.id).padding(5)
        }
        GroupBox {
            KeyControls(key: clip.key) { store.setSelectedClipKey($0) }.id(clip.id).padding(5)
        }
        if case .video = clip.selection {
            GroupBox("Stabilise") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button(store.isStabilising ? "Stabilising…" : "Stabilise", systemImage: "camera.metering.center.weighted") {
                            store.stabiliseSelectedClip()
                        }.disabled(store.isStabilising)
                        if store.isStabilising { ProgressView().controlSize(.small) }
                    }
                    Text("Smooths camera shake by making a stabilised copy of this shot's media (plus a second each side for trims). Undo returns to the original.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }
        }
        GroupBox("Fades") { fadeControls(clip).padding(5) }
        GroupBox { VStack(alignment: .leading, spacing: 8) { crossfadeControls(clip) }.padding(5) }
    }

    /// Frame-rate interpretation, and the speed the clip plays at.
    @ViewBuilder private func frameRateControls(_ clip: TimelineClip) -> some View {
        GroupBox("Frame rate") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom) {
                    numericField("Recorded at (fps)", text: $recordedRate)
                    numericField("Play at (fps)", text: $playRate)
                    Button("Interpret frame rate", systemImage: "checkmark") {
                        store.interpretSelectedClip(recorded: recordedRate, playAt: playRate)
                    }.labelStyle(.iconOnly).help("Play every recorded frame at this rate, for example 120 fps at 24 fps for smooth slow motion")
                        .disabled(recordedRate.isEmpty || playRate.isEmpty)
                }
                HStack {
                    Text(clip.speed == .one ? "Plays at normal speed." : String(format: "Plays at %g%% speed.", (clip.speed.seconds * 10000).rounded() / 100))
                        .font(.caption)
                    Spacer()
                    Button("Normal speed", systemImage: "arrow.counterclockwise") { store.setSelectedClipSpeed(percent: "100") }
                        .labelStyle(.iconOnly).help("Play at normal speed").disabled(clip.speed == .one)
                }
                Text("Linked sound slows or speeds up with the picture and keeps its pitch. Press ⌘R to retime by dragging on the timeline.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
    }

    @ViewBuilder private func audioSections(_ clip: TimelineClip) -> some View {
        let isPicture = clip.requiredTrackKind == .video
        if let asset = store.asset(id: clip.assetID), !asset.audioChannels.isEmpty {
            AudioConfigurationControls(store: store, asset: asset, components: store.selectedAudioComponents) {
                if let sound = store.selectedAudioComponents.first { store.selectTimelineClip(sound.id); editingAudio = true }
            }
        }
        if store.selectedVolumeClips.isEmpty {
            Text(store.asset(id: clip.assetID)?.audioChannels.isEmpty == false ? "Turn on an audio component above to add this clip's sound." : "This clip has no sound.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            GroupBox("Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom) {
                        numericField(isPicture ? "Linked audio volume (dB)" : "Clip volume (dB)", text: $clipVolume)
                        Button("Apply volume", systemImage: "speaker.wave.2") { store.setSelectedClipVolume(decibels: clipVolume) }
                            .labelStyle(.iconOnly).help("Apply clip volume; track gain applies on top")
                        Button("Add keyframe at playhead", systemImage: "diamond") { store.addVolumeKeyframeAtPlayhead(decibels: clipVolume) }
                            .labelStyle(.iconOnly).help("Add a volume keyframe at the playhead with this volume; volume ramps between keyframes")
                    }
                    if let automation = store.selectedVolumeClips.first, !automation.volumeKeyframes.isEmpty {
                        let keyframes = automation.volumeKeyframes
                        ForEach(keyframes.indices, id: \.self) { index in
                            let keyframe = keyframes[index]
                            HStack {
                                let at = automation.timelineStart.seconds + keyframe.time.seconds - automation.sourceRange.start.seconds
                                Image(systemName: "diamond.fill").foregroundStyle(.orange)
                                Text(String(format: "%.2f s · %@", at, keyframe.gain == 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10(keyframe.gain))))
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Button("Go to keyframe", systemImage: "arrow.right.to.line") { store.seek(to: max(0, at)) }
                                    .labelStyle(.iconOnly).help("Move the playhead to this keyframe")
                                Button("Remove keyframe", systemImage: "xmark") {
                                    var remaining = keyframes; remaining.remove(at: index)
                                    store.setSelectedVolumeKeyframes(remaining)
                                }.labelStyle(.iconOnly).help("Remove this keyframe")
                            }
                        }
                        Button("Clear keyframes", systemImage: "trash") { store.setSelectedVolumeKeyframes([]) }
                            .help("Remove all volume keyframes")
                    }
                }.padding(5)
            }
            if let sound = store.selectedVolumeClips.first {
                GroupBox { EQControls(eq: sound.eq) { store.setSelectedEQ($0) }.id(sound.id).padding(5) }
                GroupBox { DynamicsControls(dynamics: sound.dynamics) { store.setSelectedDynamics($0) }.id(sound.id).padding(5) }
                GroupBox("Noise reduction") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(store.isReducingNoise ? "Reducing noise…" : "Reduce noise", systemImage: "waveform.badge.minus") {
                                store.reduceNoiseOnSelectedAudio()
                            }.disabled(store.isReducingNoise)
                            if store.isReducingNoise { ProgressView().controlSize(.small) }
                        }
                        Text("Makes a noise-reduced copy (12 dB) of this sound, plus a second each side for trims. Undo returns to the original.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
            }
        }
        if !isPicture {
            GroupBox("Fades") { fadeControls(clip).padding(5) }
            GroupBox { VStack(alignment: .leading, spacing: 8) { crossfadeControls(clip) }.padding(5) }
        } else if let sound = linkedComponent(of: clip, kind: .audio) {
            Button("Select linked sound for fades and crossfades", systemImage: "waveform") { store.selectTimelineClip(sound.id) }
        }
    }

    @ViewBuilder private func fadeControls(_ clip: TimelineClip) -> some View {
        let isPicture = clip.requiredTrackKind == .video
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                numericField("Fade in (s)", text: $fadeInDuration)
                numericField("Fade out (s)", text: $fadeOutDuration)
            }
            if !isPicture {
                fadeCurvePicker("Fade in curve", selection: $fadeInCurve)
                fadeCurvePicker("Fade out curve", selection: $fadeOutCurve)
            }
            Button("Apply fades", systemImage: "checkmark") { applyFades(clip) }
                .labelStyle(.iconOnly).help(isPicture ? "Apply picture fades" : "Apply audio fades")
            Text(isPicture ? "The picture fades from and to the layers below it, or black. Linked audio keeps its own fades; ⌘T fades both."
                 : "Fades apply to this audio component. Durations may overlap.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshMarker() {
        markerName = store.selectedMarker?.name ?? ""
        markerNote = store.selectedMarker?.note ?? ""
    }
    private func saveMarker(_ marker: SequenceMarker, color: MarkerColor? = nil) {
        store.updateMarker(marker.id, name: markerName, note: markerNote, color: color ?? marker.color)
    }

    @ViewBuilder private func markerInspector(_ marker: SequenceMarker) -> some View {
        HStack {
            Image(systemName: "bookmark.fill").foregroundStyle(marker.color.swatch)
            Text(marker.name.isEmpty ? "Marker" : marker.name).font(.headline).lineLimit(2)
        }
        GroupBox("Marker") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $markerName).textFieldStyle(.roundedBorder)
                        .onSubmit { saveMarker(marker) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Note").font(.caption).foregroundStyle(.secondary)
                    TextField("Note", text: $markerNote, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                        .onSubmit { saveMarker(marker) }
                }
                HStack(spacing: 6) {
                    ForEach(MarkerColor.allCases, id: \.self) { color in
                        Button { saveMarker(marker, color: color) } label: {
                            Circle().fill(color.swatch).frame(width: 14, height: 14)
                                .overlay { if color == marker.color { Circle().stroke(Color.primary, lineWidth: 2).padding(-2) } }
                        }
                        .buttonStyle(.plain).help(color.rawValue.capitalized).accessibilityLabel("\(color.rawValue.capitalized) marker")
                    }
                }
                HStack {
                    Button(store.timecode(forSeconds: marker.time.seconds)) { store.seek(to: marker.time.seconds) }
                        .font(.system(.caption, design: .monospaced)).help("Move the playhead to this marker")
                    Spacer()
                    Button("Save marker", systemImage: "checkmark") { saveMarker(marker) }
                        .labelStyle(.iconOnly).help("Save name and note")
                        .disabled(markerName.trimmingCharacters(in: .whitespacesAndNewlines) == marker.name && markerNote == marker.note)
                    Button("Delete marker", systemImage: "trash") { store.removeMarker(marker.id) }
                        .labelStyle(.iconOnly).help("Delete marker")
                }
                Text("Drag the marker's flag on the ruler to move it. Markers stay at their sequence time when clips move around them.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
        markerList
    }

    @ViewBuilder private var markerList: some View {
        if !store.project.markers.isEmpty {
            GroupBox("Markers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.project.markers) { marker in
                        Button { store.selectMarker(marker.id) } label: {
                            HStack {
                                Image(systemName: "bookmark.fill").foregroundStyle(marker.color.swatch)
                                Text(store.timecode(forSeconds: marker.time.seconds)).font(.system(.caption, design: .monospaced))
                                Text(marker.name).lineLimit(1)
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2).padding(.horizontal, 4)
                        .background(store.selectedMarkerID == marker.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }
        }
    }

    @ViewBuilder private var sequenceInspector: some View {
        Text(store.project.sequenceName).font(.headline)
        GroupBox("Sequence") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Name", text: $sequenceName).textFieldStyle(.roundedBorder)
                            .onSubmit { store.renameSequence(store.project.sequenceID, name: sequenceName) }
                    }
                    Button("Rename sequence", systemImage: "checkmark") { store.renameSequence(store.project.sequenceID, name: sequenceName) }
                        .labelStyle(.iconOnly).help("Rename sequence").disabled(sequenceName == store.project.sequenceName)
                }
                HStack {
                    numericField("Width", text: $width)
                    numericField("Height", text: $height)
                }
                if store.project.tracks.allSatisfy({ $0.clips.isEmpty }), let asset = store.selectedAsset { matchButtons(asset) }
                HStack(alignment: .bottom) {
                    numericField("Frames / second", text: $frameRate)
                    Menu {
                        ForEach(["24", "25", "30", "50", "60", "24000/1001", "30000/1001", "60000/1001"], id: \.self) { rate in
                            Button(rate) { frameRate = rate }
                        }
                    } label: { Label("Frame rate presets", systemImage: "list.bullet") }
                    .labelStyle(.iconOnly).help("Frame rate presets").fixedSize()
                }
                Text("Enter an exact fraction, integer or decimal. Use 30000/1001 for 29.97 fps drop frame.")
                    .font(.caption).foregroundStyle(.secondary)
                numericField("Audio sample rate (Hz)", text: $audioSampleRate)
                Picker("Output layout", selection: $audioLayout) {
                    Text("Mono").tag(ChannelLayout.mono)
                    Text("Stereo").tag(ChannelLayout.stereo)
                    Text("5.1 surround").tag(ChannelLayout.surround51)
                    if ![ChannelLayout.mono, .stereo, .surround51].contains(audioLayout) {
                        Text("Saved layout (\(audioLayout.channels.count) channels)").tag(audioLayout)
                    }
                }
                numericField("Start timecode", text: $startTimecode)
                Text("Use HH:MM:SS:FF, or HH:MM:SS;FF for drop frame. Existing audio output maps must remain compatible.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply settings", systemImage: "checkmark") { applySequenceSettings() }
                    .labelStyle(.iconOnly).help("Apply sequence settings")
            }.padding(5)
        }
        GroupBox("Editing") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remove empty tracks after edits", isOn: Binding(
                    get: { store.project.preferences.automaticallyRemoveEmptyTracks },
                    set: store.setAutomaticTrackCleanup
                ))
                Toggle("Confirm audio track layout changes", isOn: Binding(
                    get: { store.project.preferences.askBeforeAudioTrackLayoutChanges },
                    set: store.setAudioLayoutConfirmation
                ))
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
        markerList
    }

    @ViewBuilder private func matchButtons(_ asset: MediaAsset) -> some View {
        ForEach(asset.streams.filter { $0.kind == .video && $0.videoFormat != nil }, id: \.index) { stream in
            if let format = stream.videoFormat {
                HStack {
                    Text("\(format.width) × \(format.height) · \(format.frameRate.editableText) fps")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Match sequence to \(stream.label ?? "video")", systemImage: "arrow.down.left.and.arrow.up.right") {
                        store.matchSequenceToSelectedSource(streamIndex: stream.index)
                    }.labelStyle(.iconOnly).help("Match the open sequence to \(stream.label ?? "video"): \(format.width) × \(format.height), \(format.frameRate.editableText) fps")
                }
            }
        }
        if asset.streams.contains(where: { $0.kind == .video }) && !asset.streams.contains(where: { $0.videoFormat != nil }) {
            Text("Source matching needs verified constant frame timing and square-pixel, unrotated picture. Set sequence settings manually for this source.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func assetInspector(_ asset: MediaAsset) -> some View {
        Text(asset.name).font(.headline).lineLimit(2)
        GroupBox("Source file") {
            VStack(alignment: .leading, spacing: 8) {
                Text(asset.originalURL?.path ?? "No file reference").font(.caption).textSelection(.enabled)
                Text(asset.isStill ? "Still image" : String(format: "%.2f s", asset.duration.seconds)).font(.caption).foregroundStyle(.secondary)
                ForEach(asset.streams, id: \.index) { stream in
                    Text("\(stream.kind == .video ? "Video" : "Audio") \(stream.index)\(stream.label.map { " · " + $0 } ?? "")\(stream.audioLayout.map { " · \($0.channels.count) ch" } ?? "")\(stream.videoFormat.map { " · \($0.width) × \($0.height)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Relink media…", systemImage: "link", action: store.relinkSelectedAsset)
                    .labelStyle(.iconOnly).help("Relink source media")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
        if !asset.audioChannels.isEmpty {
            GroupBox("Audio configuration") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default", selection: Binding(get: { asset.audioConfiguration }, set: { value in
                        if let value { store.setDefaultAudioConfiguration(value, assetID: asset.id) }
                    })) {
                        Text("Sequence layout").tag(AudioConfiguration?.none)
                        ForEach(asset.availableAudioConfigurations(sequence: store.project.settings.audioLayout), id: \.self) {
                            Text($0.displayName).tag(Optional($0))
                        }
                    }
                    Text("How this media's \(asset.audioChannels.count) audio channel\(asset.audioChannels.count == 1 ? "" : "s") split into timeline components. Changing it updates every use in the open sequence and new placements; mono components play in the centre on mono tracks.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(5)
            }
        }
        if store.project.tracks.allSatisfy({ $0.clips.isEmpty }) {
            GroupBox("Open sequence") { VStack(alignment: .leading, spacing: 6) { matchButtons(asset) }.padding(5) }
        }
    }

    /// Seconds shown to the microsecond, without trailing zeros.
    private func display(_ seconds: Double) -> String {
        var text = String(format: "%.6f", seconds)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
    /// An untouched field returns the exact stored value, so rounding for display never edits.
    private func entered(_ text: String, current: Double?) -> Double? {
        if let current, text == display(current) { return current }
        return Double(text)
    }
    private func numericField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func fadeCurvePicker(_ label: String, selection: Binding<AudioFadeCurve>) -> some View {
        Picker(label, selection: selection) {
            Text("Linear").tag(AudioFadeCurve.linear)
            Text("Equal power").tag(AudioFadeCurve.equalPower)
        }
    }
    private func applyFades(_ clip: TimelineClip) {
        guard let fadeIn = entered(fadeInDuration, current: clip.fadeIn.duration.seconds),
              let fadeOut = entered(fadeOutDuration, current: clip.fadeOut.duration.seconds),
              fadeIn.isFinite, fadeOut.isFinite, fadeIn >= 0, fadeOut >= 0, let expected = fadeDraftClip else {
            store.errorMessage = "Enter nonnegative fade durations in seconds."
            return
        }
        do {
            try store.applyFades(clipID: clip.id, fadeInSeconds: fadeIn, fadeInCurve: fadeInCurve,
                                     fadeOutSeconds: fadeOut, fadeOutCurve: fadeOutCurve, expectedClip: expected)
            refreshClip()
        } catch { store.errorMessage = store.audioEditErrorMessage(error) }
    }
    @ViewBuilder
    private func crossfadeControls(_ clip: TimelineClip) -> some View {
        let isPicture = clip.requiredTrackKind == .video
        Text(isPicture ? "Transition to next clip" : "Linked crossfade").font(.subheadline.bold())
        let targets = store.audioCrossfadeTargets(for: clip)
        Picker(isPicture ? "Incoming clip" : "Incoming audio", selection: $crossfadeTargetID) {
            Text("Select a clip").tag(nil as UUID?)
            ForEach(targets) { target in
                Text("\(store.project.assets.first { $0.id == target.assetID }?.name ?? "Audio") · \(store.project.tracks.first { $0.clips.contains { $0.id == target.id } }?.displayName(in: store.project) ?? "Track") · \(String(format: "%.3f", target.timelineStart.seconds)) s")
                    .tag(Optional(target.id))
            }
        }
        .onChange(of: crossfadeTargetID) { _, id in
            if let existing = store.project.audioCrossfades.first(where: { $0.outgoingClipID == clip.id && $0.incomingClipID == id }) {
                crossfadeDuration = display(existing.duration.seconds)
                crossfadeCurve = existing.curve
                transitionStyle = existing.style ?? .dissolve
            } else if let target = targets.first(where: { $0.id == id }) {
                let overlap = clip.timelineStart.seconds + clip.sourceRange.duration.seconds - target.timelineStart.seconds
                crossfadeDuration = display(overlap > 0 ? overlap : isPicture ? 1 : 0.5)
                crossfadeCurve = isPicture ? .linear : .equalPower
            }
            crossfadeDraftProject = store.project
        }
        numericField(isPicture ? "Dissolve duration (s)" : "Crossfade duration (s)", text: $crossfadeDuration)
        if !isPicture { fadeCurvePicker("Crossfade curve", selection: $crossfadeCurve) }
        else {
            Picker("Style", selection: $transitionStyle) {
                ForEach(TransitionStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        Button(isPicture ? "Apply dissolve" : "Apply crossfade", systemImage: "checkmark") {
            guard let target = crossfadeTargetID,
                  let seconds = entered(crossfadeDuration, current: store.project.audioCrossfades.first { $0.outgoingClipID == clip.id && $0.incomingClipID == crossfadeTargetID }?.duration.seconds),
                  let baseline = crossfadeDraftProject else {
                store.errorMessage = isPicture ? "Select the incoming clip and enter a positive dissolve duration in seconds."
                    : "Select incoming audio and enter a positive crossfade duration in seconds."
                return
            }
            do {
                try store.applyAudioCrossfade(outgoingClipID: clip.id, incomingClipID: target, seconds: seconds,
                                             curve: crossfadeCurve, style: isPicture ? transitionStyle : nil, expectedProject: baseline)
                refreshCrossfade()
            } catch { store.errorMessage = store.audioEditErrorMessage(error) }
        }.labelStyle(.iconOnly).help(isPicture ? "Apply cross dissolve" : "Apply linked audio crossfade").disabled(crossfadeTargetID == nil)
        ForEach(store.project.audioCrossfades.filter { $0.outgoingClipID == clip.id || $0.incomingClipID == clip.id }) { crossfade in
            HStack {
                Text("\(crossfade.outgoingClipID == clip.id ? "To next" : "From previous") · \(isPicture ? (crossfade.style ?? .dissolve).displayName + " · " : "")\(String(format: "%.3f", crossfade.duration.seconds)) s")
                    .font(.caption)
                Spacer()
                Button(isPicture ? "Remove dissolve" : "Remove crossfade", systemImage: "xmark") {
                    do {
                        try store.removeAudioCrossfade(crossfade.id, expectedProject: store.project)
                        refreshCrossfade()
                    } catch { store.errorMessage = store.audioEditErrorMessage(error) }
                }.labelStyle(.iconOnly).help(isPicture ? "Remove cross dissolve" : "Remove linked crossfade")
            }
        }
        Text(isPicture
             ? (targets.isEmpty ? "No clip to dissolve into. The next clip must meet this one on the same track, with source beyond the cut."
                : "The dissolve is centred on the cut and uses source beyond it. Editing either clip can remove it. Each edit is one undo step.")
             : (targets.isEmpty ? "No compatible incoming audio. Adjacent cuts need available source handles; overlapping clips need a matching overlap duration."
                : "Adjacent cuts use available source handles. Overlapping audio uses its existing overlap. Editing an endpoint can remove its linked crossfade. Each edit is one undo step."))
            .font(.caption).foregroundStyle(.secondary)
    }
    private func refreshCrossfade() {
        crossfadeDraftProject = store.project
        guard let clip = store.selectedClip else { crossfadeTargetID = nil; return }
        if let existing = store.project.audioCrossfades.first(where: { $0.outgoingClipID == clip.id }) {
            crossfadeTargetID = existing.incomingClipID
            crossfadeDuration = display(existing.duration.seconds)
            crossfadeCurve = existing.curve
            transitionStyle = existing.style ?? .dissolve
        } else {
            crossfadeTargetID = nil
            crossfadeDuration = clip.requiredTrackKind == .video ? "1" : "0.5"
            crossfadeCurve = clip.requiredTrackKind == .video ? .linear : .equalPower
        }
    }
    private func refreshClip() {
        guard let clip = store.selectedClip else { return }
        fadeInDuration = display(clip.fadeIn.duration.seconds)
        fadeOutDuration = display(clip.fadeOut.duration.seconds)
        fadeInCurve = clip.fadeIn.curve
        fadeOutCurve = clip.fadeOut.curve
        fadeDraftClip = clip
        func percent(_ value: Double) -> String { String(format: "%g", (value * 1000).rounded() / 10) }
        let recorded = store.asset(id: clip.assetID)?.streams.first { $0.kind == .video }?.videoFormat?.frameRate
        recordedRate = recorded?.editableText ?? ""
        if let recorded, let effective = try? recorded.value.multiplied(by: clip.speed), let rate = try? FrameRate(effective.numerator, effective.denominator) {
            playRate = rate.editableText
        } else { playRate = store.project.settings.frameRate.editableText }
        transformScale = percent(clip.transform.scale); transformX = percent(clip.transform.offsetX)
        transformY = percent(clip.transform.offsetY); transformOpacity = percent(clip.transform.opacity)
        if let gain = store.selectedVolumeClips.first?.gain {
            clipVolume = gain == 0 ? "-inf" : String(format: "%.1f", 20 * log10(gain))
        }
        refreshCrossfade()
    }
    private func applySequenceSettings() {
        guard let w = Int(width), let h = Int(height), let sampleRate = Int(audioSampleRate) else {
            store.errorMessage = "Enter valid dimensions and an audio sample rate."
            return
        }
        store.updateSequence(width: w, height: h, frameRateText: frameRate,
                             audioSampleRate: sampleRate, audioLayout: audioLayout,
                             startTimecodeLabel: startTimecode)
    }
    private func refreshSettings() {
        width = String(store.project.settings.width)
        height = String(store.project.settings.height)
        frameRate = store.project.settings.frameRate.editableText
        audioSampleRate = String(store.project.settings.audioSampleRate)
        audioLayout = store.project.settings.audioLayout
        startTimecode = (try? store.project.settings.startTimecode.formatted(rate: store.project.settings.frameRate)) ?? "00:00:00:00"
        sequenceName = store.project.sequenceName
    }
}

/// A clip's audio configuration, as in Final Cut Pro: pick how the source channels split into
/// components, and turn single components on or off. Each change lands on the timeline at
/// once, on tracks of the component's own layout.
private struct AudioConfigurationControls: View {
    @ObservedObject var store: EditorStore
    let asset: MediaAsset
    /// The clip's sound components on the timeline now.
    let components: [TimelineClip]
    let editCustom: () -> Void

    private var sequence: ChannelLayout { store.project.settings.audioLayout }
    private var current: [AudioSourceSelection] {
        components.compactMap { if case .audio(let selection) = $0.selection { selection } else { nil } }
    }
    /// The configuration these components come from: an exact match, else one they are part of.
    private var configuration: AudioConfiguration? {
        let selections = Set(current)
        guard !selections.isEmpty else { return nil }
        return asset.audioConfiguration(matching: current, sequence: sequence)
            ?? asset.availableAudioConfigurations(sequence: sequence).first {
                Set(asset.audioComponents($0, sequence: sequence).map(\.selection)).isSuperset(of: selections)
            }
    }

    var body: some View {
        GroupBox("Audio configuration") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Channels", selection: Binding(get: { configuration }, set: { value in
                    if let value { store.configureSelectedAudio(asset.audioComponents(value, sequence: sequence)) }
                })) {
                    if configuration == nil { Text(current.isEmpty ? "None" : "Custom").tag(AudioConfiguration?.none) }
                    ForEach(asset.availableAudioConfigurations(sequence: sequence), id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                if let configuration {
                    let plans = asset.audioComponents(configuration, sequence: sequence)
                    ForEach(plans.indices, id: \.self) { index in
                        Toggle(name(plans[index].selection), isOn: Binding(get: { current.contains(plans[index].selection) }, set: { on in
                            store.configureSelectedAudio(plans.filter { $0.selection == plans[index].selection ? on : current.contains($0.selection) })
                        }))
                        .font(.callout)
                    }
                } else {
                    ForEach(current.indices, id: \.self) { Text(name(current[$0])).font(.callout) }
                }
                HStack {
                    Spacer()
                    Button("Custom channels and routing…", systemImage: "slider.horizontal.below.square.and.square.filled", action: editCustom)
                        .labelStyle(.iconOnly).help("Choose source channels and sequence outputs by hand").disabled(components.isEmpty)
                }
                Text("Each component gets its own track of its layout; mono plays in the centre. Set the default for this media in the bin.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
    }

    /// "Ch 1–2 · Stereo", numbering channels across the source's audio streams.
    private func name(_ selection: AudioSourceSelection) -> String {
        let all = asset.audioChannels
        let numbers = selection.channels.map { channel in (all.firstIndex(of: channel) ?? 0) + 1 }
        let label = selection.layout == .mono ? "Mono" : selection.layout == .stereo ? "Stereo" : selection.layout == .surround51 ? "5.1" : "\(selection.layout.channels.count) ch"
        let channels = numbers.count > 1 && numbers == Array(numbers[0]...(numbers[0] + numbers.count - 1))
            ? "Ch \(numbers[0])–\(numbers.last!)" : "Ch " + numbers.map(String.init).joined(separator: "+")
        return "\(channels) · \(label)"
    }
}

/// Chroma key: on/off, key colour, similarity and blend (sliders commit on release).
private struct KeyControls: View {
    let key: ChromaKey?
    let apply: (ChromaKey?) -> Void
    @State private var draft: ChromaKey
    init(key: ChromaKey?, apply: @escaping (ChromaKey?) -> Void) {
        self.key = key; self.apply = apply
        _draft = State(initialValue: key ?? ChromaKey())
    }
    private var color: Binding<Color> {
        Binding(get: {
            let c = draft.rgb ?? (0, 255, 0)
            return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
        }, set: { value in
            guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
            func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
            draft.color = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
            if key != nil { apply(draft) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Chroma key", isOn: Binding(get: { key != nil }, set: { apply($0 ? draft : nil) })).font(.subheadline.bold())
            if key != nil {
                ColorPicker("Key colour", selection: color, supportsOpacity: false)
                slider("Similarity", value: $draft.similarity, range: 0.01...0.5)
                slider("Blend", value: $draft.blend, range: 0...0.5)
                Text("Pick the screen colour; raise similarity until the background clears, then blend to soften edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: key) { _, value in if let value { draft = value } }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing && key != nil && draft != key { apply(draft) } }
            Text(String(format: "%.0f%%", value.wrappedValue * 100)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Compressor (threshold, ratio, makeup) and optional limiter; sliders commit on release.
private struct DynamicsControls: View {
    let dynamics: AudioDynamics?
    let apply: (AudioDynamics?) -> Void
    @State private var draft: AudioDynamics
    init(dynamics: AudioDynamics?, apply: @escaping (AudioDynamics?) -> Void) {
        self.dynamics = dynamics; self.apply = apply
        _draft = State(initialValue: dynamics ?? AudioDynamics())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Compressor", isOn: Binding(get: { dynamics != nil }, set: { apply($0 ? draft : nil) })).font(.subheadline.bold())
            if dynamics != nil {
                slider("Threshold", value: $draft.threshold, range: -60...0, label: String(format: "%.0f dB", draft.threshold))
                slider("Ratio", value: $draft.ratio, range: 1...20, label: String(format: "%.1f:1", draft.ratio))
                slider("Makeup", value: $draft.makeup, range: 0...24, label: String(format: "+%.0f dB", draft.makeup))
                Toggle("Limiter", isOn: Binding(get: { draft.limiterCeiling != nil }, set: {
                    draft.limiterCeiling = $0 ? -1 : nil; apply(draft)
                }))
                if draft.limiterCeiling != nil {
                    slider("Ceiling", value: Binding(get: { draft.limiterCeiling ?? -1 }, set: { draft.limiterCeiling = $0 }), range: -30...0,
                           label: String(format: "%.1f dB", draft.limiterCeiling ?? -1))
                }
            }
        }
        .onChange(of: dynamics) { _, value in if let value { draft = value } }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing && dynamics != nil && draft != dynamics { apply(draft) } }
            Text(label).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

/// Low, mid and high bands; each slider commits one undoable change on release.
private struct EQControls: View {
    let eq: AudioEQ
    let apply: (AudioEQ) -> Void
    @State private var draft: AudioEQ
    init(eq: AudioEQ, apply: @escaping (AudioEQ) -> Void) {
        self.eq = eq; self.apply = apply
        _draft = State(initialValue: eq)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("EQ").font(.subheadline.bold())
                Spacer()
                Button("Reset EQ", systemImage: "arrow.counterclockwise") { draft = .flat; apply(.flat) }
                    .labelStyle(.iconOnly).help("Flatten all bands").disabled(eq.isFlat)
            }
            band("Low", "120 Hz shelf", value: $draft.low)
            band("Mid", "1 kHz", value: $draft.mid)
            band("High", "8 kHz shelf", value: $draft.high)
        }
        .onChange(of: eq) { _, value in draft = value }
    }
    private func band(_ title: String, _ help: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 40, alignment: .leading).help(help)
            Slider(value: value, in: -24...24) { editing in if !editing && draft != eq { apply(draft) } }
            Text(String(format: "%+.0f dB", value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}

/// Brightness, contrast and saturation; each slider commits one undoable change on release.
private struct ColorControls: View {
    let color: ColorAdjustment
    let apply: (ColorAdjustment) -> Void
    @State private var draft: ColorAdjustment
    init(color: ColorAdjustment, apply: @escaping (ColorAdjustment) -> Void) {
        self.color = color; self.apply = apply
        _draft = State(initialValue: color)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Colour, levels and blur").font(.subheadline.bold())
                Spacer()
                Button("Reset colour", systemImage: "arrow.counterclockwise") { draft = .neutral; apply(.neutral) }
                    .labelStyle(.iconOnly).help("Reset brightness, contrast, saturation, blur and levels").disabled(color.isNeutral)
            }
            slider("Brightness", value: $draft.brightness, range: -1...1, label: String(format: "%+.0f", draft.brightness * 100))
            slider("Contrast", value: $draft.contrast, range: 0...2, label: String(format: "%.0f%%", draft.contrast * 100))
            slider("Saturation", value: $draft.saturation, range: 0...2, label: String(format: "%.0f%%", draft.saturation * 100))
            slider("Blur", value: $draft.blur, range: 0...0.05, label: String(format: "%.1f", draft.blur * 100))
            Text("Levels").font(.caption.bold()).padding(.top, 4)
            slider("Black", value: $draft.blackPoint, range: 0...0.5, label: String(format: "%.0f", draft.blackPoint * 255))
            slider("White", value: $draft.whitePoint, range: 0.5...1, label: String(format: "%.0f", draft.whitePoint * 255))
            slider("Gamma", value: $draft.gamma, range: 0.3...3, label: String(format: "%.2f", draft.gamma))
        }
        .onChange(of: color) { _, value in draft = value }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing && draft != color { apply(draft) } }
            Text(label).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Edits a draft of the title; Apply commits it as one undoable change.
private struct TitleEditor: View {
    let title: TitleDefinition
    let apply: (TitleDefinition) -> Void
    @State private var draft: TitleDefinition
    init(title: TitleDefinition, apply: @escaping (TitleDefinition) -> Void) {
        self.title = title; self.apply = apply
        _draft = State(initialValue: title)
    }
    private var color: Binding<Color> {
        Binding(get: {
            let c = draft.rgba ?? (1, 1, 1, 1)
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }, set: { value in
            guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
            func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
            draft.color = String(format: "#%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.body).frame(minHeight: 54, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: $draft.fontSize, in: 0.02...0.3)
                Text("\(Int((draft.fontSize * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            }
            Picker("Position", selection: $draft.position) {
                Text("Top").tag(TitlePosition.top)
                Text("Centre").tag(TitlePosition.center)
                Text("Lower third").tag(TitlePosition.lowerThird)
                Text("Bottom").tag(TitlePosition.bottom)
            }
            Picker("Font", selection: $draft.fontFamily) {
                Text("System").tag(nil as String?)
                ForEach(TitleRenderer.fontFamilies, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Alignment", selection: Binding(get: { draft.alignment ?? .center }, set: { draft.alignment = $0 == .center ? nil : $0 })) {
                Text("Left").tag(TitleAlignment.left)
                Text("Centre").tag(TitleAlignment.center)
                Text("Right").tag(TitleAlignment.right)
            }.pickerStyle(.segmented)
            ColorPicker("Colour", selection: color, supportsOpacity: true)
            Toggle("Bold", isOn: $draft.bold)
            Toggle("Background band", isOn: $draft.background)
            HStack {
                Button("Apply title", systemImage: "checkmark") { apply(draft) }
                    .disabled(draft == title)
                Button("Revert", systemImage: "arrow.uturn.backward") { draft = title }
                    .labelStyle(.iconOnly).help("Discard title changes").disabled(draft == title)
            }
            Text("Drag the clip's edges to change how long the title shows, and use ⌘T or the fade handles to fade it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: title) { _, value in draft = value }
    }
}

/// AppKit player view. SwiftUI's VideoPlayer only links the _AVKit_SwiftUI overlay,
/// which aborts at first display on macOS 27 when AVKit itself is not loaded.
private struct SourcePlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Editor shortcuts own Space, Tab and J/K/L; the player must not take keyboard focus.
    final class NonFocusingPlayerView: AVPlayerView {
        override var acceptsFirstResponder: Bool { false }
    }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = NonFocusingPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Editing shortcuts are suspended while a text field has focus. Keep focus out of
/// fields when a workspace opens, and end text editing when the user clicks
/// anything that isn't a text field (timeline, monitor, bin), as other editors do.
private struct TextFocusReleaser: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> ReleaserView { ReleaserView(store: store) }
    func updateNSView(_ nsView: ReleaserView, context: Context) {}

    /// Also registers the window with the keyboard router so shortcuts reach this workspace.
    final class ReleaserView: NSView {
        private static var monitor: Any?
        private weak var store: EditorStore?
        init(store: EditorStore) { self.store = store; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.installMonitor()
            guard let window else { return }
            if let store { EditorKeyboardRouter.shared.register(window: window, store: store) }
            // The initial key view is chosen as the window first becomes key.
            for delay in [0.05, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window, window.firstResponder is NSText else { return }
                    window.makeFirstResponder(nil)
                }
            }
        }
        private static func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let window = event.window, window.firstResponder is NSText,
                      let frame = window.contentView?.superview else { return event }
                var view = frame.hitTest(event.locationInWindow)
                while let current = view {
                    if current is NSText || current is NSTextField { return event }
                    view = current.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }
    }
}
