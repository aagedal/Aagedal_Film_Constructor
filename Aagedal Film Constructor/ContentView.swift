import SwiftUI
import AVKit
import EditorCore

struct ContentView: View {
    @ObservedObject var store: EditorStore
    @AppStorage("workspace.showMediaBin") private var showMediaBin = true
    @AppStorage("workspace.showInspector") private var showInspector = true
    @AppStorage("workspace.showTimeline") private var showTimeline = true
    @State private var isDropTargeted = false

    var body: some View {
        VSplitView {
            HSplitView {
                if showMediaBin {
                    mediaBin.frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
                        .focusedValue(\.editorCommandScope, .source)
                }
                sourceMonitor.frame(minWidth: 320, maxWidth: .infinity)
                    .focusedValue(\.editorCommandScope, .source)
                if showInspector {
                    ProjectInspector(store: store).frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                }
            }
            .frame(minHeight: 260)
            if showTimeline {
                TimelineView(store: store).frame(minHeight: 220, idealHeight: 320)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !store.isImporting else { return false }
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
                Button(action: store.importMedia) { Label("Import media", systemImage: "plus.rectangle.on.folder") }
                    .disabled(store.isImporting)
                Button(action: store.appendSelectedAsset) { Label("Append to timeline", systemImage: "text.badge.plus") }
                    .disabled(store.selectedAsset == nil || store.isImporting)
                Menu {
                    Button("Append with audio selection…", action: store.beginAudioAppend)
                        .disabled(store.selectedAsset?.streams.contains(where: { $0.kind == .audio }) != true || store.isImporting)
                } label: { Label("Audio placement", systemImage: "waveform.badge.plus") }
                Menu {
                    Toggle("Media bin", isOn: $showMediaBin)
                    Toggle("Inspector", isOn: $showInspector)
                    Toggle("Timeline", isOn: $showTimeline)
                    Divider()
                    Button("Show all panels") {
                        showMediaBin = true; showInspector = true; showTimeline = true
                    }
                } label: { Label("Panels", systemImage: "rectangle.3.group") }
                .help("Show or hide workspace panels")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if store.isImporting { ProgressView().controlSize(.small) }
                Text(store.statusMessage).lineLimit(1)
                Spacer()
                Text("Source preview · timeline playback coming next").foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .sheet(item: $store.audioAppendAsset) { asset in
            AudioSourceEditor(store: store, asset: asset)
        }
        .alert("Unable to complete action", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var mediaBin: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Text("\(store.project.assets.count)").foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if store.project.assets.isEmpty {
                ContentUnavailableView {
                    Label("Import your media", systemImage: "folder.badge.plus")
                } description: {
                    Text("Import or drop video, audio, or still images here to start a sequence.")
                } actions: {
                    Button("Import media…", action: store.importMedia).disabled(store.isImporting)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { store.selectedAssetID }, set: { if let id = $0 { store.selectAsset(id) } })) {
                    ForEach(store.project.assets) { asset in
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
                Button("Import…", action: store.importMedia).disabled(store.isImporting)
                Spacer()
                Button("Append", action: store.appendSelectedAsset).disabled(store.selectedAsset == nil || store.isImporting)
            }.padding(10)
        }
    }

    private var sourceMonitor: some View {
        VStack(spacing: 0) {
            HStack {
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
                        if store.selectedAsset != nil { Button("Relink media…", action: store.relinkSelectedAsset) }
                    }.foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("Original source").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let asset = store.selectedAsset { Text("\(asset.duration.seconds, specifier: "%.2f") seconds").font(.caption.monospacedDigit()) }
            }.padding(10)
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

private struct ProjectInspector: View {
    @ObservedObject var store: EditorStore
    @State private var sourceStart = "0"
    @State private var clipDuration = "0"
    @State private var timelineStart = "0"
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var frameRate = "24"
    @State private var startTimecode = "00:00:00:00"
    @State private var editingAudio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inspector").font(.headline)
                if let clip = store.selectedClip {
                    GroupBox("Selected clip") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.project.assets.first(where: { $0.id == clip.assetID })?.name ?? "Media").font(.subheadline.bold())
                            numericField("Timeline start (s)", text: $timelineStart)
                            Button("Move clip") {
                                guard let value = Double(timelineStart), value.isFinite, value >= 0 else { store.errorMessage = "Enter a valid timeline start in seconds."; return }
                                store.moveSelectedClip(to: value)
                            }
                            Divider()
                            numericField("Source in (s)", text: $sourceStart)
                            numericField("Duration (s)", text: $clipDuration)
                            Button("Apply trim") {
                                guard let start = Double(sourceStart), let duration = Double(clipDuration), start.isFinite, duration.isFinite, start >= 0, duration > 0 else { store.errorMessage = "Enter a nonnegative source in and a positive duration in seconds."; return }
                                store.trimSelectedClip(start: start, duration: duration)
                            }
                            if clip.requiredTrackKind == .video {
                                Picker("Scaling", selection: Binding(get: { clip.scalingMode }, set: store.setScalingMode)) {
                                    Text("Fit").tag(ScalingMode.fit)
                                    Text("Fill").tag(ScalingMode.fill)
                                    Text("Native size").tag(ScalingMode.none)
                                }
                            } else {
                                Button("Audio source channels…") { editingAudio = true }
                                Text("\(clip.requiredAudioLayout?.channels.count ?? 0) selected channels")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(5)
                    }
                } else {
                    Text("Select a timeline clip to edit its timing.").font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Sequence") {
                    VStack(alignment: .leading, spacing: 10) {
                        numericField("Width", text: $width)
                        numericField("Height", text: $height)
                        numericField("Frames / second", text: $frameRate)
                        Button("Apply settings") {
                            guard let w = Int(width), let h = Int(height), let rate = Double(frameRate), rate.isFinite else { store.errorMessage = "Enter valid dimensions and a frame rate."; return }
                            store.updateSequence(width: w, height: h, frameRate: rate)
                        }
                        Divider()
                        numericField("Start timecode", text: $startTimecode)
                        Button("Apply timecode") {
                            do {
                                store.updateStartTimecode(try Timecode(parsing: startTimecode, rate: store.project.settings.frameRate))
                            } catch {
                                store.errorMessage = "Enter valid HH:MM:SS:FF timecode, or HH:MM:SS;FF for drop frame at 29.97/59.94 fps."
                            }
                        }
                        Text("\(store.project.settings.audioSampleRate) Hz · \(store.project.settings.audioLayout.channels.count) output channels")
                            .font(.caption).foregroundStyle(.secondary)
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
    private func refreshClip() {
        guard let clip = store.selectedClip else { return }
        sourceStart = String(clip.sourceRange.start.seconds)
        clipDuration = String(clip.sourceRange.duration.seconds)
        timelineStart = String(clip.timelineStart.seconds)
    }
    private func refreshSettings() {
        width = String(store.project.settings.width)
        height = String(store.project.settings.height)
        frameRate = String(format: "%.6g", store.project.settings.frameRate.value.seconds)
        startTimecode = (try? store.project.settings.startTimecode.formatted(rate: store.project.settings.frameRate)) ?? "00:00:00:00"
    }
}
