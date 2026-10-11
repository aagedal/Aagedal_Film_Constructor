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

    private var helpers: SequenceExportHelperAvailability {
        SequenceExportService.helperAvailability()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Render sequence").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Format"); Text("QuickTime MOV · ProRes 422 HQ · PCM 24-bit") }
                GridRow {
                    Text("Picture")
                    Text("\(draft.plan.settings.width) × \(draft.plan.settings.height) · \(draft.plan.settings.frameRate.value.numerator)/\(draft.plan.settings.frameRate.value.denominator) fps")
                }
                GridRow {
                    Text("Audio")
                    Text("\(draft.plan.settings.audioSampleRate) Hz · \(draft.plan.settings.audioLayout.channels.count) channels")
                }
                GridRow {
                    Text("Start timecode")
                    Text((try? draft.plan.settings.startTimecode.formatted(rate: draft.plan.settings.frameRate)) ?? "")
                        .monospacedDigit()
                }
            }
            Text("Renders the sequence as it was when this window opened, using original media and its saved audio settings. Set resolution, frame rate, and start timecode in the sequence inspector before exporting.")
                .foregroundStyle(.secondary)
            Text(FFmpegRenderCompiler.qualificationLimitations)
                .font(.caption).foregroundStyle(.secondary)
            if (try? draft.plan.duration.multiplied(by: draft.plan.settings.frameRate.value).denominator) != 1 {
                Text("The sequence ends between video frames. Video covers the final partial frame; audio keeps its exact sample duration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if exportTask == nil && completedURL == nil {
                TextField("Filename", text: $filename)
                    .textFieldStyle(.roundedBorder)
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
                        Button("Choose export folder…", action: startExport)
                            .disabled(!helpers.isAvailable)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24).frame(width: 570)
        .interactiveDismissDisabled(exportTask != nil)
        .onDisappear { exportTask?.cancel() }
    }

    private func startExport() {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains(":"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              filename.lowercased().hasSuffix(".mov") else {
            errorMessage = "Enter a MOV filename without path separators."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Exports \(filename). Existing files are protected from replacement."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = folder.appendingPathComponent(filename)
        errorMessage = nil; completedURL = nil; fraction = 0; stage = "Preparing"; isCancelling = false
        exportTask = Task { @MainActor in
            let folderAccess = folder.startAccessingSecurityScopedResource()
            defer { if folderAccess { folder.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await SequenceExportService.shared.export(plan: draft.plan, to: destination) { progress in
                    Task { @MainActor in
                        fraction = progress.fraction
                        stage = progress.stage
                    }
                }
                completedURL = result.outputURL
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
