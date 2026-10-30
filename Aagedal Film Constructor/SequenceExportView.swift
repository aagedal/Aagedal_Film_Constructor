import SwiftUI
import AppKit
import EditorCore
import UniformTypeIdentifiers

struct SequenceExportView: View {
    let draft: SequenceExportDraft
    @Environment(\.dismiss) private var dismiss
    @State private var exportTask: Task<Void, Never>?
    @State private var fraction = 0.0
    @State private var stage = ""
    @State private var errorMessage: String?
    @State private var completedURL: URL?
    @State private var isCancelling = false
    @State private var filename = "Sequence.mov"
    @AppStorage("exportFormat") private var format: RenderOutputFormat = .proRes422HQ
    @AppStorage("exportStrictQualification") private var strictQualification = false
    @AppStorage("exportAudioStreams") private var audioStreams: RenderAudioStreams = .main
    @State private var warnings: [String] = []
    @State private var isAssessing = false
    @State private var useMarkedRange = true
    /// The last export folder, kept as a security-scoped bookmark so the next export is one key press.
    @AppStorage("exportFolderBookmark") private var folderBookmark: Data?
    @State private var lastFolder: URL?

    private var helpers: SequenceExportHelperAvailability {
        SequenceExportService.helperAvailability()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Render sequence").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $format) {
                        ForEach(RenderOutputFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(exportTask != nil || completedURL != nil)
                }
                GridRow {
                    Text("Picture")
                    Text("\(draft.plan.settings.width) × \(draft.plan.settings.height) · \(draft.plan.settings.frameRate.value.numerator)/\(draft.plan.settings.frameRate.value.denominator) fps")
                }
                GridRow {
                    Text("Audio")
                    Text("\(draft.plan.settings.audioSampleRate) Hz · \(draft.plan.settings.audioLayout.channels.count) channels")
                }
                GridRow {
                    Text("Audio tracks")
                    Picker("Audio tracks", selection: $audioStreams) {
                        ForEach(RenderAudioStreams.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(exportTask != nil || completedURL != nil)
                    .help("Write one mix, every main bus, or the main mix plus a stem per track as separate audio streams")
                }
                if let marked = draft.markedRange {
                    GridRow {
                        Text("Range")
                        Picker("Range", selection: $useMarkedRange) {
                            Text("In to Out · \(seconds(marked.duration))").tag(true)
                            Text("Entire sequence · \(seconds(draft.plan.duration))").tag(false)
                        }
                        .labelsHidden().fixedSize()
                        .disabled(exportTask != nil || completedURL != nil)
                    }
                }
                GridRow {
                    Text("Start timecode")
                    Text((try? draft.plan.settings.formattedTimecode(at: range?.start ?? .zero)) ?? "")
                        .monospacedDigit()
                }
            }
            Text("Renders the sequence as it was when this window opened, using original media and its saved audio settings. Set resolution, frame rate, and start timecode in the sequence inspector before exporting.")
                .foregroundStyle(.secondary)
            Text(FFmpegRenderCompiler.qualificationLimitations)
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Strict source qualification (refuse sources that would be approximated)", isOn: $strictQualification)
                .font(.caption)
                .disabled(exportTask != nil || completedURL != nil)
            if isAssessing {
                ProgressView().controlSize(.small)
            } else if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }
                .foregroundStyle(.orange).textSelection(.enabled)
            }
            if (try? draft.plan.duration.multiplied(by: draft.plan.settings.frameRate.value).denominator) != 1 {
                Text("The sequence ends between video frames. Video covers the final partial frame; audio keeps its exact sample duration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if exportTask == nil && completedURL == nil {
                TextField("Filename", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    // Return in the focused filename field continues like the default button.
                    .onSubmit { if helpers.isAvailable { exportToDefault() } }
            }
            if !helpers.isAvailable {
                Label(helpers.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if exportTask != nil {
                ProgressView(value: fraction)
                Text(isCancelling ? "Cancelling…" : "\(stage) · \(Int(fraction * 100))%")
                    .font(.caption).monospacedDigit()
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if let completedURL {
                Label("Exported \(completedURL.lastPathComponent)", systemImage: "checkmark.circle")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([completedURL]) }
            }
            HStack {
                Spacer()
                if exportTask != nil {
                    Button("Cancel export") { isCancelling = true; exportTask?.cancel() }
                        .disabled(isCancelling)
                } else {
                    Button(completedURL == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if completedURL == nil {
                        if let lastFolder {
                            Button("Choose folder…", action: chooseFolderAndExport)
                                .disabled(!helpers.isAvailable)
                            Button("Export to “\(lastFolder.lastPathComponent)”") { export(to: lastFolder) }
                                .disabled(!helpers.isAvailable)
                                .keyboardShortcut(.defaultAction)
                                .help(lastFolder.path)
                        } else {
                            Button("Choose export folder…", action: chooseFolderAndExport)
                                .disabled(!helpers.isAvailable)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
        }
        .padding(24).frame(width: 570)
        .interactiveDismissDisabled(exportTask != nil)
        .onDisappear { exportTask?.cancel() }
        .onAppear {
            let name = draft.sequenceName.components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters)).joined(separator: "-")
                .trimmingCharacters(in: .whitespaces)
            filename = (name.isEmpty || name.hasPrefix(".") ? "Sequence" : name) + "." + format.fileExtension
            lastFolder = resolveLastFolder()
        }
        .onChange(of: format, initial: true) { _, format in
            let stem = (filename as NSString).deletingPathExtension
            filename = (stem.isEmpty ? "Sequence" : stem) + "." + format.fileExtension
        }
        .task(id: "\(strictQualification) \(useMarkedRange)") { await assess() }
    }

    /// Probe sources up front so approximations or refusals are visible before choosing a folder.
    private func assess() async {
        guard helpers.isAvailable else { return }
        isAssessing = true
        defer { isAssessing = false }
        do {
            warnings = try await SequenceExportService.shared.assess(plan: draft.plan, options: options)
            if errorMessage != nil, completedURL == nil, exportTask == nil { errorMessage = nil }
        } catch is CancellationError {
        } catch {
            warnings = []
            errorMessage = error.localizedDescription
        }
    }

    private var range: TimeRange? { useMarkedRange ? draft.markedRange : nil }
    private var options: SequenceExportOptions {
        .init(format: format, strictQualification: strictQualification, audioStreams: audioStreams, range: range)
    }
    private func seconds(_ time: RationalTime) -> String {
        let total = time.seconds
        return total >= 60 ? String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60)) : String(format: "%.1f s", total)
    }

    private func validateFilename() -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains(":"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              filename.lowercased().hasSuffix("." + format.fileExtension) else {
            errorMessage = "Enter a .\(format.fileExtension) filename without path separators."
            return false
        }
        return true
    }

    private func resolveLastFolder() -> URL? {
        guard let folderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folderBookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }

    private func exportToDefault() {
        if let lastFolder { export(to: lastFolder) } else { chooseFolderAndExport() }
    }

    private func chooseFolderAndExport() {
        guard validateFilename() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Exports \(filename). A file already there is kept; the export gets a numbered name."
        if let lastFolder { panel.directoryURL = lastFolder }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            folderBookmark = bookmark
            lastFolder = folder
        }
        export(to: folder)
    }

    /// Exports into the folder, numbering the name ("Sequence 2.mov") rather than replacing a file.
    private func export(to folder: URL) {
        guard validateFilename(), exportTask == nil else { return }
        errorMessage = nil; completedURL = nil; fraction = 0; stage = "Preparing"; isCancelling = false
        exportTask = Task { @MainActor in
            let folderAccess = folder.startAccessingSecurityScopedResource()
            defer { if folderAccess { folder.stopAccessingSecurityScopedResource() } }
            let stem = (filename as NSString).deletingPathExtension
            var destination = folder.appendingPathComponent(filename)
            var number = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(stem) \(number).\(format.fileExtension)")
                number += 1
            }
            do {
                let result = try await SequenceExportService.shared.export(plan: draft.plan, to: destination, options: options) { progress in
                    Task { @MainActor in
                        fraction = progress.fraction
                        stage = progress.stage
                    }
                }
                completedURL = result.outputURL
                warnings = result.warnings
            } catch is CancellationError {
                stage = "Export cancelled"
            } catch {
                errorMessage = error.localizedDescription
            }
            exportTask = nil
            isCancelling = false
        }
    }
}

/// Source timing is supplied explicitly until import has a qualified timecode probe.
struct EDLExportView: View {
    @ObservedObject var store: EditorStore
    let draft: EDLExportDraft
    @Environment(\.dismiss) private var dismiss
    @State private var trackID: UUID
    @State private var entries: [UUID: SourceEntry] = [:]
    @State private var verifiedTiming = false
    @State private var errorMessage: String?

    private struct SourceEntry {
        var reel = ""
        var rate = ""
        var timecode = ""
    }

    init(store: EditorStore, draft: EDLExportDraft) {
        self.store = store
        self.draft = draft
        _trackID = State(initialValue: draft.initialTrackID)
    }

    private var tracks: [TimelineTrack] { draft.project.tracks.filter { !$0.clips.isEmpty } }
    private var track: TimelineTrack? { tracks.first { $0.id == trackID } }
    private var assets: [MediaAsset] {
        let ids = Set(track?.clips.map(\.assetID) ?? [])
        return draft.project.assets.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export track EDL").font(.title2.bold())
            Text("Exports cuts and gaps from one track as CMX 3600. Other tracks are omitted; this is not a flattened sequence. Scaling, compositing, fades, and channel processing cannot be carried in an EDL.")
                .foregroundStyle(.secondary)
            Picker("Track", selection: $trackID) {
                ForEach(tracks) { track in
                    Text(track.displayName(in: draft.project)).tag(track.id)
                }
            }
            Text("Source timing is not probed automatically. Enter each original's exact frame rate (for example 24000/1001), start timecode, and a unique reel name of up to eight uppercase ASCII letters or digits. The source rate and timecode mode must match the sequence.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sequence: \(draft.project.settings.frameRate.value.numerator)/\(draft.project.settings.frameRate.value.denominator) fps · \((try? draft.project.settings.startTimecode.formatted(rate: draft.project.settings.frameRate)) ?? "")")
                .font(.caption).monospacedDigit()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(asset.name).font(.headline)
                            HStack {
                                TextField("Reel", text: entry(asset.id, \.reel)).frame(width: 100)
                                TextField("Exact fps", text: entry(asset.id, \.rate)).frame(width: 130)
                                TextField("Start HH:MM:SS:FF or HH:MM:SS;FF", text: entry(asset.id, \.timecode))
                            }.textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }.frame(maxHeight: 260)
            Toggle("I verified the source rates and timecodes, and every video source has a constant frame rate.", isOn: $verifiedTiming)
            if let errorMessage {
                ScrollView { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 130)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose EDL file…", action: export)
                    .disabled(!verifiedTiming || assets.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 680)
        .onChange(of: trackID) { _, _ in verifiedTiming = false; errorMessage = nil }
    }

    private func entry(_ id: UUID, _ keyPath: WritableKeyPath<SourceEntry, String>) -> Binding<String> {
        Binding(get: { entries[id, default: SourceEntry()][keyPath: keyPath] }, set: { value in
            var updated = entries[id, default: SourceEntry()]
            updated[keyPath: keyPath] = value
            entries[id] = updated
            verifiedTiming = false
            errorMessage = nil
        })
    }

    private func export() {
        guard verifiedTiming, let track else { return }
        do {
            var timing: [UUID: CMX3600SourceTiming] = [:]
            for asset in assets {
                let fields = entries[asset.id, default: SourceEntry()]
                let parts = fields.rate.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count), let numerator = Int64(parts[0]),
                      let denominator = parts.count == 2 ? Int64(parts[1]) : 1 else {
                    throw EditorCoreError.invalidModel("Enter an exact source frame rate for \(asset.name).")
                }
                let rate = try FrameRate(numerator, denominator)
                let start = try Timecode(parsing: fields.timecode.trimmingCharacters(in: .whitespacesAndNewlines), rate: rate)
                let indices = Set(track.clips.filter { $0.assetID == asset.id }.flatMap { clip -> [Int] in
                    switch clip.selection {
                    case .video(let index): return [index]
                    case .audio(let selection): return selection.channels.map(\.streamIndex)
                    case .still: return []
                    }
                })
                guard indices.count == 1, let streamIndex = indices.first else {
                    throw EditorCoreError.invalidModel("EDL requires one selected source stream per original: \(asset.name).")
                }
                timing[asset.id] = CMX3600SourceTiming(frameRate: rate, startTimecode: start,
                    reelName: fields.reel.trimmingCharacters(in: .whitespacesAndNewlines), streamIndex: streamIndex, constantFrameRate: true)
            }
            let result = try CMX3600Exporter.export(project: draft.project, trackID: trackID, sourceTiming: timing)
            if try store.saveEDL(result, snapshot: draft.project) { dismiss() }
        } catch { errorMessage = error.localizedDescription }
    }
}
