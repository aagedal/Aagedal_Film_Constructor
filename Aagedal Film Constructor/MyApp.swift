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
            .focusedSceneValue(\.editorStore, store)
            .onAppear {
                saveProtection.start()
                guard !storeActive else { return }
                storeActive = true
                if !loaded {
                    store.load(document)
                    loaded = true
                    observeDocumentBaseline()
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
