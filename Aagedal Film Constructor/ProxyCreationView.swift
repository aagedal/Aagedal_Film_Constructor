import SwiftUI
import AppKit
import EditorCore

struct ProxyCreationView: View {
    @ObservedObject var store: EditorStore
    let draft: ProxyCreationDraft
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ProxyPreset = .proResProxy
    @State private var scaleDivisor = 2
    @State private var fraction = 0.0
    @State private var stage = ""
    @State private var failures: [String] = []
    @State private var completed = 0
    @State private var running = false
    @State private var cancelling = false
    @State private var finished = false

    var body: some View {
        let availablePresets = ProxyGenerationService.availablePresets()
        VStack(alignment: .leading, spacing: 16) {
            Text("Create proxies").font(.title2.bold())
            Text("\(draft.assets.count) video source\(draft.assets.count == 1 ? "" : "s"). Proxy picture uses original audio in the source monitor. Timeline previews and exports use originals.")
                .foregroundStyle(.secondary)
            Picker("Codec", selection: $preset) {
                Text("ProRes Proxy").tag(ProxyPreset.proResProxy)
                Text("H.264").tag(ProxyPreset.h264).disabled(!availablePresets.contains(.h264))
            }.disabled(running || finished)
            Picker("Resolution", selection: $scaleDivisor) {
                Text("Full").tag(1)
                Text("Half").tag(2)
                Text("Quarter").tag(4)
            }.disabled(running || finished)
            Text("Proxies use the first video stream. Sources with variable frame rates or nonzero video start offsets require conforming first. Existing proxies remain registered until a replacement finishes successfully.")
                .font(.caption).foregroundStyle(.secondary)
            let helpers = SequenceExportService.helperAvailability()
            if !helpers.isAvailable { Label(helpers.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            else if !availablePresets.contains(.h264) {
                Text("This helper build does not include the H.264 proxy encoder.").font(.caption).foregroundStyle(.secondary)
            }
            if running {
                ProgressView(value: fraction)
                Text(cancelling ? "Cancelling…" : stage).font(.caption)
            }
            if finished { Text("Created \(completed) of \(draft.assets.count) proxies.") }
            if !failures.isEmpty {
                ScrollView { Text(failures.joined(separator: "\n\n")).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                if running {
                    Button("Cancel jobs") { cancelling = true; store.proxyGenerationTask?.cancel() }.disabled(cancelling)
                } else {
                    Button(finished ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if !finished {
                        Button("Choose output folder…", action: start)
                            .disabled(!helpers.isAvailable || !availablePresets.contains(preset)).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(24).frame(width: 550)
        .interactiveDismissDisabled(running)
        .onDisappear { store.proxyGenerationTask?.cancel() }
    }

    private func start() {
        let panel = NSOpenPanel()
        panel.title = "Choose Proxy Output Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        let epoch = store.mediaEpoch
        let sourceRevisions = store.sourceRevisions
        running = true
        store.proxyGenerationTask = Task { @MainActor in
            defer {
                if scoped { directory.stopAccessingSecurityScopedResource() }
                running = false; finished = true
                if epoch == store.mediaEpoch { store.proxyGenerationTask = nil }
            }
            for (index, asset) in draft.assets.enumerated() {
                guard !Task.isCancelled, epoch == store.mediaEpoch else { break }
                let base = asset.originalURL?.deletingPathExtension().lastPathComponent ?? "Media"
                let output = directory.appendingPathComponent("\(base)-\(UUID().uuidString)-proxy.mov")
                do {
                    let proxy = try await ProxyGenerationService.shared.generate(asset: asset, preset: preset, scaleDivisor: scaleDivisor, to: output) { progress in
                        Task { @MainActor in
                            guard running, !Task.isCancelled else { return }
                            fraction = (Double(index) + progress.fraction) / Double(draft.assets.count)
                            stage = "\(asset.name) · \(progress.stage) (\(index + 1)/\(draft.assets.count))"
                        }
                    }
                    guard !Task.isCancelled, epoch == store.mediaEpoch else { break }
                    try store.registerProxy(proxy, for: asset, epoch: epoch, sourceRevision: sourceRevisions[asset.id])
                    completed += 1
                } catch {
                    if !Task.isCancelled { failures.append("\(asset.name): \(error.localizedDescription)") }
                }
                fraction = Double(index + 1) / Double(draft.assets.count)
            }
        }
    }
}
