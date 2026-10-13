import SwiftUI
import AVKit
import EditorCore

struct ContentView: View {
    @ObservedObject var store: EditorStore
    var saveProtection: ProjectSaveProtection? = nil
    @AppStorage("workspace.showMediaBin") private var showMediaBin = true
    @AppStorage("workspace.showInspector") private var showInspector = true
    @AppStorage("workspace.showTimeline") private var showTimeline = true
    @State private var isDropTargeted = false
    @State private var binName = ""
    @State private var creatingBin = false
    @State private var renamingBin = false
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
            }
            .frame(minHeight: 260)
            if showTimeline {
                TimelineView(store: store).frame(minHeight: 220, idealHeight: 320)
                    .simultaneousGesture(TapGesture().onEnded { store.focusSequenceViewer() })
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !store.isImporting, store.audioAppendAsset == nil,
                  store.renderExportDraft == nil, store.edlExportDraft == nil else { return false }
            store.importMedia(urls: files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
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
                Text("\(store.visibleBinAssets.count)").foregroundStyle(.secondary)
                Menu {
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
                .help("Organize media bins")
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
            if store.visibleBinAssets.isEmpty {
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
                List(selection: Binding(get: { store.selectedAssetIDs }, set: { ids in
                    store.focusSourceViewer()
                    store.selectAssets(ids)
                })) {
                    ForEach(store.visibleBinAssets) { asset in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: assetIcon(asset)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.name).lineLimit(2)
                                Text("\(asset.duration.seconds, specifier: "%.2f") s · \(assetKind(asset))")
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
                Button(action: store.appendSelectedAsset) { Label("Append to timeline", systemImage: "text.badge.plus") }
                    .labelStyle(.iconOnly).help("Append selected media to timeline").disabled(store.selectedAsset == nil || store.isImporting)
            }.padding(10)
        }
        .alert("New sub-bin", isPresented: $creatingBin) {
            TextField("Name", text: $binName)
            Button("Create") { store.createMediaBin(name: binName) }
                .disabled(binName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    Button(action: sequencePlayback.pause) { Image(systemName: "pause.fill") }
                        .accessibilityLabel("Pause sequence")
                    Button(action: sequencePlayback.play) { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play sequence")
                        .disabled(!sequencePlayback.available || sequencePlayback.isPreparing || store.duration <= 0)
                    Button { store.stepPlayhead(frames: 1) } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next sequence frame")
                    if sequencePlayback.isPreparing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(sequencePlayback.isPlaying ? "Playing" : "Paused").font(.caption)
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
                    VideoPlayer(player: player)
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
                        .disabled(store.sourcePlayer == nil)
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
                    Button("Save project…") {
                        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                    }
                    Button("Remind me later", action: protection.dismissReminder)
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
                    Button("Show backups") { NSWorkspace.shared.open(folder) }
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
    @State private var sourceStart = "0"
    @State private var clipDuration = "0"
    @State private var timelineStart = "0"
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
    @State private var crossfadeTargetID: UUID?
    @State private var crossfadeDuration = "0.5"
    @State private var crossfadeCurve = AudioFadeCurve.equalPower
    @State private var crossfadeDraftProject: Project?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inspector").font(.headline)
                if let clip = store.selectedClip {
                    GroupBox("Selected clip") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.project.assets.first(where: { $0.id == clip.assetID })?.name ?? "Media").font(.subheadline.bold())
                            numericField("Timeline start (s)", text: $timelineStart)
                            Button("Move clip", systemImage: "arrow.right") {
                                guard let value = Double(timelineStart), value.isFinite, value >= 0 else { store.errorMessage = "Enter a valid timeline start in seconds."; return }
                                store.moveSelectedClip(to: value)
                            }.labelStyle(.iconOnly).help("Move clip to the entered timeline start")
                            Divider()
                            numericField("Source in (s)", text: $sourceStart)
                            numericField("Duration (s)", text: $clipDuration)
                            Button("Apply trim", systemImage: "scissors") {
                                guard let start = Double(sourceStart), let duration = Double(clipDuration), start.isFinite, duration.isFinite, start >= 0, duration > 0 else { store.errorMessage = "Enter a nonnegative source in and a positive duration in seconds."; return }
                                store.trimSelectedClip(start: start, duration: duration)
                            }.labelStyle(.iconOnly).help("Apply source in and duration")
                            if clip.requiredTrackKind == .video {
                                Picker("Scaling", selection: Binding(get: { clip.scalingMode }, set: store.setScalingMode)) {
                                    Text("Fit").tag(ScalingMode.fit)
                                    Text("Fill").tag(ScalingMode.fill)
                                    Text("Native size").tag(ScalingMode.none)
                                }
                            } else {
                                Button("Audio source channels…", systemImage: "waveform") { editingAudio = true }
                                    .labelStyle(.iconOnly).help("Edit audio source channels and output routing")
                                Text("\(clip.requiredAudioLayout?.channels.count ?? 0) selected channels")
                                    .font(.caption).foregroundStyle(.secondary)
                                Divider()
                                numericField("Fade in (s)", text: $fadeInDuration)
                                fadeCurvePicker("Fade in curve", selection: $fadeInCurve)
                                numericField("Fade out (s)", text: $fadeOutDuration)
                                fadeCurvePicker("Fade out curve", selection: $fadeOutCurve)
                                Button("Apply fades", systemImage: "checkmark") { applyFades(clip) }
                                    .labelStyle(.iconOnly).help("Apply audio fades")
                                Text("Fades apply to this audio component. Durations may overlap.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Sequence rendering and the development monitor use fades. Source preview plays the original audio.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Divider()
                                crossfadeControls(clip)
                            }
                        }.padding(5)
                    }
                } else {
                    Text("Select a timeline clip to edit its timing.").font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Sequence") {
                    VStack(alignment: .leading, spacing: 10) {
                        numericField("Width", text: $width)
                        if store.project.tracks.allSatisfy({ $0.clips.isEmpty }), let asset = store.selectedAsset {
                            ForEach(asset.streams.filter { $0.kind == .video && $0.videoFormat != nil }, id: \.index) { stream in
                                if let format = stream.videoFormat {
                                    Button("Match \(stream.label ?? "video"): \(format.width) × \(format.height), \(format.frameRate.editableText) fps") {
                                        store.matchSequenceToSelectedSource(streamIndex: stream.index)
                                    }
                                }
                            }
                            if asset.streams.contains(where: { $0.kind == .video }) && !asset.streams.contains(where: { $0.videoFormat != nil }) {
                                Text("Source matching needs verified constant frame timing and square-pixel, unrotated picture. Set sequence settings manually for this source.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        numericField("Height", text: $height)
                        numericField("Frames / second", text: $frameRate)
                        Menu("Frame rate presets") {
                            ForEach(["24", "25", "30", "50", "60", "24000/1001", "30000/1001", "60000/1001"], id: \.self) { rate in
                                Button(rate) { frameRate = rate }
                            }
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
                        if audioLayout != .mono && audioLayout != .stereo {
                            Text("This output layout can be saved, but sequence playback and rendered export currently require mono or stereo.")
                                .font(.caption).foregroundStyle(.secondary)
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
                    }.font(.callout).padding(5)
                }
                if let asset = store.selectedAsset {
                    GroupBox("Source file") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(asset.originalURL?.path ?? "No file reference").font(.caption).textSelection(.enabled)
                            Button("Relink media…", action: store.relinkSelectedAsset)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                    }
                }
            }.padding(12)
        }
        .onAppear { refreshClip(); refreshSettings() }
        .onChange(of: store.selectedClip) { _, _ in refreshClip() }
        .onChange(of: store.project.settings) { _, _ in refreshSettings() }
        .onChange(of: store.project.audioCrossfades) { _, _ in refreshCrossfade() }
        .sheet(isPresented: $editingAudio) {
            if let clip = store.selectedClip, clip.requiredTrackKind == .audio {
                AudioSourceEditor(store: store, clip: clip)
            }
        }
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
        guard let fadeIn = Double(fadeInDuration), let fadeOut = Double(fadeOutDuration),
              fadeIn.isFinite, fadeOut.isFinite, fadeIn >= 0, fadeOut >= 0, let expected = fadeDraftClip else {
            store.errorMessage = "Enter nonnegative fade durations in seconds."
            return
        }
        do {
            try store.applyAudioFades(clipID: clip.id, fadeInSeconds: fadeIn, fadeInCurve: fadeInCurve,
                                     fadeOutSeconds: fadeOut, fadeOutCurve: fadeOutCurve, expectedClip: expected)
            refreshClip()
        } catch { store.errorMessage = store.audioEditErrorMessage(error) }
    }
    @ViewBuilder
    private func crossfadeControls(_ clip: TimelineClip) -> some View {
        Text("Linked crossfade").font(.subheadline.bold())
        let targets = store.audioCrossfadeTargets(for: clip)
        Picker("Incoming audio", selection: $crossfadeTargetID) {
            Text("Select a clip").tag(nil as UUID?)
            ForEach(targets) { target in
                Text("\(store.project.assets.first { $0.id == target.assetID }?.name ?? "Audio") · \(store.project.tracks.first { $0.clips.contains { $0.id == target.id } }?.displayName(in: store.project) ?? "Track") · \(String(format: "%.3f", target.timelineStart.seconds)) s")
                    .tag(Optional(target.id))
            }
        }
        .onChange(of: crossfadeTargetID) { _, id in
            if let existing = store.project.audioCrossfades.first(where: { $0.outgoingClipID == clip.id && $0.incomingClipID == id }) {
                crossfadeDuration = String(existing.duration.seconds)
                crossfadeCurve = existing.curve
            } else if let target = targets.first(where: { $0.id == id }) {
                let overlap = clip.timelineStart.seconds + clip.sourceRange.duration.seconds - target.timelineStart.seconds
                crossfadeDuration = String(overlap > 0 ? overlap : 0.5)
                crossfadeCurve = .equalPower
            }
            crossfadeDraftProject = store.project
        }
        numericField("Crossfade duration (s)", text: $crossfadeDuration)
        fadeCurvePicker("Crossfade curve", selection: $crossfadeCurve)
        Button("Apply crossfade", systemImage: "checkmark") {
            guard let target = crossfadeTargetID, let seconds = Double(crossfadeDuration), let baseline = crossfadeDraftProject else {
                store.errorMessage = "Select incoming audio and enter a positive crossfade duration in seconds."
                return
            }
            do {
                try store.applyAudioCrossfade(outgoingClipID: clip.id, incomingClipID: target, seconds: seconds,
                                             curve: crossfadeCurve, expectedProject: baseline)
                refreshCrossfade()
            } catch { store.errorMessage = store.audioEditErrorMessage(error) }
        }.labelStyle(.iconOnly).help("Apply linked audio crossfade").disabled(crossfadeTargetID == nil)
        ForEach(store.project.audioCrossfades.filter { $0.outgoingClipID == clip.id || $0.incomingClipID == clip.id }) { crossfade in
            HStack {
                Text("\(crossfade.outgoingClipID == clip.id ? "To next" : "From previous") · \(String(format: "%.3f", crossfade.duration.seconds)) s")
                    .font(.caption)
                Spacer()
                Button("Remove crossfade", systemImage: "xmark") {
                    do {
                        try store.removeAudioCrossfade(crossfade.id, expectedProject: store.project)
                        refreshCrossfade()
                    } catch { store.errorMessage = store.audioEditErrorMessage(error) }
                }.labelStyle(.iconOnly).help("Remove linked crossfade")
            }
        }
        Text(targets.isEmpty ? "No compatible incoming audio. Adjacent cuts need available source handles; overlapping clips need a matching overlap duration."
             : "Adjacent cuts use available source handles. Overlapping audio uses its existing overlap. Editing an endpoint can remove its linked crossfade. Each edit is one undo step.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func refreshCrossfade() {
        crossfadeDraftProject = store.project
        guard let clip = store.selectedClip else { crossfadeTargetID = nil; return }
        if let existing = store.project.audioCrossfades.first(where: { $0.outgoingClipID == clip.id }) {
            crossfadeTargetID = existing.incomingClipID
            crossfadeDuration = String(existing.duration.seconds)
            crossfadeCurve = existing.curve
        } else {
            crossfadeTargetID = nil
            crossfadeDuration = "0.5"
            crossfadeCurve = .equalPower
        }
    }
    private func refreshClip() {
        guard let clip = store.selectedClip else { return }
        sourceStart = String(clip.sourceRange.start.seconds)
        clipDuration = String(clip.sourceRange.duration.seconds)
        timelineStart = String(clip.timelineStart.seconds)
        fadeInDuration = String(clip.fadeIn.duration.seconds)
        fadeOutDuration = String(clip.fadeOut.duration.seconds)
        fadeInCurve = clip.fadeIn.curve
        fadeOutCurve = clip.fadeOut.curve
        fadeDraftClip = clip
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
    }
}
