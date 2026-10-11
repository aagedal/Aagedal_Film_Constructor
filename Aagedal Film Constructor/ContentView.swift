import SwiftUI
import AVKit
import EditorCore

struct ContentView: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        VSplitView {
            HSplitView {
                mediaBin.frame(minWidth: 210, idealWidth: 260, maxWidth: 380)
                sourceMonitor.frame(minWidth: 320, maxWidth: .infinity)
                ProjectInspector(store: store).frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            }
            .frame(minHeight: 260)
            TimelineView(store: store).frame(minHeight: 220, idealHeight: 320)
        }
        .frame(minWidth: 960, minHeight: 600)
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.importMedia) { Label("Import media", systemImage: "plus.rectangle.on.folder") }
                    .disabled(store.isImporting)
                Button(action: store.appendSelectedAsset) { Label("Append to timeline", systemImage: "text.badge.plus") }
                    .disabled(store.selectedAsset == nil || store.isImporting)
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
                    Text("Add video, audio, or still images to start a sequence.")
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
                        Text("\(store.project.settings.audioSampleRate) Hz · \(store.project.settings.audioLayout.channels.count) output channels")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(5)
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
    }
}
