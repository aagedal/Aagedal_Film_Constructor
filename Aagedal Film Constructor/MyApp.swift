import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var applicationDelegate
    @StateObject private var commandRegistry = EditorCommandRegistry()
    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { configuration in
            DocumentWorkspace(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { EditorCommands(registry: commandRegistry) }

        Settings { KeyboardShortcutSettings(registry: commandRegistry) }
    }
}

private struct DocumentWorkspace: View {
    @Binding var document: ProjectDocument
    var fileURL: URL?
    @StateObject private var store = EditorStore()
    @StateObject private var saveProtection = ProjectSaveProtection()
    @State private var loaded = false
    @State private var storeActive = false

    var body: some View {
        ContentView(store: store, saveProtection: saveProtection)
            .overlay(alignment: .bottomTrailing) {
                if loaded, LaunchInteractionProbe.enabled {
                    LaunchInteractionProbe().frame(width: 110, height: 24)
                }
            }
            .focusedSceneValue(\.editorStore, store)
            .onAppear {
                saveProtection.start()
                guard !storeActive else { return }
                storeActive = true
                if !loaded {
                    store.load(document)
                    loaded = true
                    observeDocumentBaseline()
                    LaunchPerformanceEvents.record("workspace_loaded")
                } else {
                    store.resumeMediaAccess()
                }
            }
            .onChange(of: store.project) { _, project in
                syncDocumentFromStore()
            }
            .onChange(of: store.mediaBookmarks) { _, bookmarks in
                syncDocumentFromStore()
            }
            .onChange(of: store.proxyBookmarks) { _, bookmarks in
                syncDocumentFromStore()
            }
            .onChange(of: store.proxyJobs) { _, jobs in
                syncDocumentFromStore()
            }
            .onChange(of: document.proxyJobs) { _, jobs in
                if loaded && jobs != store.proxyJobs { reloadDocument() }
            }
            .onChange(of: document.project) { _, project in
                if loaded && project != store.project { reloadDocument() }
            }
            .onChange(of: document.mediaBookmarks) { _, bookmarks in
                if loaded && bookmarks != store.mediaBookmarks { reloadDocument() }
            }
            .onChange(of: document.proxyBookmarks) { _, bookmarks in
                if loaded && bookmarks != store.proxyBookmarks { reloadDocument() }
            }
            .onChange(of: fileURL) { _, _ in
                if loaded { observeDocumentBaseline() }
            }
            .onDisappear {
                saveProtection.stop()
                storeActive = false
                store.close()
            }
    }

    private func syncDocumentFromStore() {
        guard loaded,
              document.project != store.project || document.mediaBookmarks != store.mediaBookmarks
                || document.proxyBookmarks != store.proxyBookmarks || document.proxyJobs != store.proxyJobs else { return }
        document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks,
                                   proxyBookmarks: store.proxyBookmarks, proxyJobs: store.proxyJobs)
        saveProtection.observe(document: document, fileURL: fileURL, hasChanges: true)
    }

    private func reloadDocument() {
        // A saved document establishes a clean baseline; restored untitled work
        // still needs saving even before another user edit arrives.
        store.load(document)
        observeDocumentBaseline()
    }

    private func observeDocumentBaseline() {
        saveProtection.observe(document: document, fileURL: fileURL,
                               hasChanges: fileURL == nil && document.differsFromNewDocument)
    }
}

/// Opt-in Release launch evidence. Never runs in ordinary application sessions.
/// The probe waits for the loaded workspace's real window, then routes mouse
/// events through that window to a native control. This measures scripted UI
/// responsiveness, not physical input latency or compositor presentation.
private struct LaunchInteractionProbe: NSViewRepresentable {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AFC_LAUNCH_PROBE_LOG"] != nil }

    func makeNSView(context: Context) -> ProbeButton { ProbeButton() }
    func updateNSView(_ nsView: ProbeButton, context: Context) {}

    final class ProbeButton: NSButton {
        private var timer: Timer?
        private var recorded = false

        init() {
            super.init(frame: .zero)
            title = "Launch probe"
            bezelStyle = .rounded
            target = self
            action = #selector(interacted)
            setAccessibilityIdentifier("AFCLaunchInteractionProbe")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil, !recorded else { return }
            LaunchPerformanceEvents.record("probe_attached", windowNumber: window?.windowNumber ?? -1)
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkWindow() }
            }
        }

        private func checkWindow() {
            guard let window, window.isVisible, window.isKeyWindow,
                  NSDocumentController.shared.document(for: window) != nil,
                  bounds.width > 0, bounds.height > 0 else { return }
            timer?.invalidate()
            timer = nil
            recorded = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            record("workspace_visible")
            // A later main-loop turn verifies that the loaded workspace can
            // handle input, rather than treating onAppear as interaction.
            DispatchQueue.main.async { [weak self] in self?.sendProbeClick() }
        }

        private func sendProbeClick() {
            guard let window, window.isVisible, window.isKeyWindow else { return }
            let point = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            // Queue mouse-up before dispatching mouse-down: NSButton's tracking
            // loop consumes the queued release just as it consumes user input.
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                    clickCount: 1, pressure: 0) else { return }
            NSApplication.shared.postEvent(up, atStart: true)
            window.sendEvent(down)
        }

        @objc private func interacted() { record("scripted_interaction_processed") }

        private func record(_ event: String) {
            LaunchPerformanceEvents.record(event, windowNumber: window?.windowNumber ?? -1)
        }
    }
}

private struct EditorStoreKey: FocusedValueKey {
    typealias Value = EditorStore
}

extension FocusedValues {
    var editorStore: EditorStore? {
        get { self[EditorStoreKey.self] }
        set { self[EditorStoreKey.self] = newValue }
    }
}

private struct EditorCommands: Commands {
    @ObservedObject var registry: EditorCommandRegistry
    @FocusedValue(\.editorStore) private var store
    @FocusedValue(\.editorCommandScope) private var focusedScope
    @AppStorage("workspace.showMediaBin") private var showMediaBin = true
    @AppStorage("workspace.showInspector") private var showInspector = true
    @AppStorage("workspace.showTimeline") private var showTimeline = true

    private var scope: EditorCommandScope { focusedScope ?? .document }
    private func command(_ id: EditorCommandID) -> some View {
        let binding = registry.binding(for: id)
        return Button(id.title) { registry.perform(id, store: store, scope: scope) }
            .keyboardShortcut(binding.keyEquivalent.map { KeyboardShortcut($0, modifiers: binding.eventModifiers) })
            .disabled(!registry.isEnabled(id, store: store, scope: scope))
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            command(.undo)
            command(.redo)
        }
        CommandGroup(after: .newItem) {
            command(.importMedia)
            Divider()
            command(.exportSequence)
            command(.exportFCPXML)
            command(.exportEDL)
            command(.exportOTIO)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Media Bin", isOn: $showMediaBin)
            Toggle("Show Inspector", isOn: $showInspector)
            Toggle("Show Timeline", isOn: $showTimeline)
            Button("Show All Workspace Panels") {
                showMediaBin = true; showInspector = true; showTimeline = true
            }
        }
        CommandMenu("Playback") {
            command(.playReverse)
            command(.pausePlayback)
            command(.playForward)
        }
        CommandMenu("Timeline") {
            command(.appendSource)
            command(.splitClip)
            Divider()
            command(.previousFrame)
            command(.nextFrame)
            Divider()
            command(.deleteClip)
        }
    }
}
