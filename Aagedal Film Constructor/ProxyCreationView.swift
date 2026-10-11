import SwiftUI
import AppKit
import EditorCore

struct ProxyCreationView: View {
    @ObservedObject var store: EditorStore
    let draft: ProxyCreationDraft
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ProxyPreset = .proResProxy
    @State private var scaleDivisor = 2
    @State private var queued = false
    @State private var errorMessage: String?

    var body: some View {
        let availablePresets = ProxyGenerationService.availablePresets()
        if queued {
            ProxyQueueView(store: store)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create proxies").font(.title2.bold())
                Text("\(draft.assets.count) video source\(draft.assets.count == 1 ? "" : "s"). Proxy picture uses original audio in the source monitor. Timeline previews and exports use originals.")
                    .foregroundStyle(.secondary)
                Picker("Codec", selection: $preset) {
                    Text("ProRes Proxy").tag(ProxyPreset.proResProxy)
                    Text("H.264").tag(ProxyPreset.h264).disabled(!availablePresets.contains(.h264))
                }
                Picker("Resolution", selection: $scaleDivisor) {
                    Text("Full").tag(1)
                    Text("Half").tag(2)
                    Text("Quarter").tag(4)
                }
                Text("Proxies use the first video stream. Sources with variable frame rates or nonzero video start offsets require conforming first. Existing proxies remain registered until a replacement finishes successfully.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Jobs are saved with the project. You can close the queue while generation continues, and resume unfinished jobs after reopening.")
                    .font(.caption).foregroundStyle(.secondary)
                let helpers = SequenceExportService.helperAvailability()
                if !helpers.isAvailable {
                    Label(helpers.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !availablePresets.contains(.h264) {
                    Text("This helper build does not include the H.264 proxy encoder.").font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Choose output folder…", action: enqueue)
                        .disabled(!helpers.isAvailable || !availablePresets.contains(preset) || store.proxyGenerationTask != nil || store.isRelinkingProxy)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 550)
        }
    }

    private func enqueue() {
        let panel = NSOpenPanel()
        panel.title = "Choose Proxy Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            try store.enqueueProxyJobs(assets: draft.assets, preset: preset, scaleDivisor: scaleDivisor, directory: directory)
            queued = true
            store.runProxyQueue()
        } catch { errorMessage = store.audioEditErrorMessage(error) }
    }
}
