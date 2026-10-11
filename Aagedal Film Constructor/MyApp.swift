import SwiftUI

@main struct MyApp: App {
    @StateObject private var commandRegistry = EditorCommandRegistry()
    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { configuration in
            DocumentWorkspace(document: configuration.$document)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { EditorCommands(registry: commandRegistry) }

        Settings { KeyboardShortcutSettings(registry: commandRegistry) }
    }
}

private struct DocumentWorkspace: View {
    @Binding var document: ProjectDocument
    @StateObject private var store = EditorStore()
    @State private var loaded = false

    var body: some View {
        ContentView(store: store)
            .focusedSceneValue(\.editorStore, store)
            .onAppear {
                guard !loaded else { return }
                store.load(document)
                loaded = true
            }
            .onChange(of: store.project) { _, project in
                if loaded { document = ProjectDocument(project: project, mediaBookmarks: store.mediaBookmarks, proxyBookmarks: store.proxyBookmarks, proxyJobs: store.proxyJobs) }
            }
            .onChange(of: store.mediaBookmarks) { _, bookmarks in
                if loaded { document = ProjectDocument(project: store.project, mediaBookmarks: bookmarks, proxyBookmarks: store.proxyBookmarks, proxyJobs: store.proxyJobs) }
            }
            .onChange(of: store.proxyBookmarks) { _, bookmarks in
                if loaded { document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks, proxyBookmarks: bookmarks, proxyJobs: store.proxyJobs) }
            }
            .onChange(of: store.proxyJobs) { _, jobs in
                if loaded { document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks, proxyBookmarks: store.proxyBookmarks, proxyJobs: jobs) }
            }
            .onChange(of: document.proxyJobs) { _, jobs in
                if loaded && jobs != store.proxyJobs { store.load(document) }
            }
            .onChange(of: document.project) { _, project in
                if loaded && project != store.project { store.load(document) }
            }
            .onChange(of: document.mediaBookmarks) { _, bookmarks in
                if loaded && bookmarks != store.mediaBookmarks { store.load(document) }
            }
            .onChange(of: document.proxyBookmarks) { _, bookmarks in
                if loaded && bookmarks != store.proxyBookmarks { store.load(document) }
            }
            .onDisappear { store.close() }
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
