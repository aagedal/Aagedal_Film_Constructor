import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { configuration in
            DocumentWorkspace(document: configuration.$document)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { EditorCommands() }
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
                if loaded { document = ProjectDocument(project: project, mediaBookmarks: store.mediaBookmarks) }
            }
            .onChange(of: store.mediaBookmarks) { _, bookmarks in
                if loaded { document = ProjectDocument(project: store.project, mediaBookmarks: bookmarks) }
            }
            .onChange(of: document.project) { _, project in
                if loaded && project != store.project { store.load(document) }
            }
            .onChange(of: document.mediaBookmarks) { _, bookmarks in
                if loaded && bookmarks != store.mediaBookmarks { store.load(document) }
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
    @FocusedValue(\.editorStore) private var store
    @AppStorage("workspace.showMediaBin") private var showMediaBin = true
    @AppStorage("workspace.showInspector") private var showInspector = true
    @AppStorage("workspace.showTimeline") private var showTimeline = true

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(store?.canUndo != true)
            Button("Redo") { store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(store?.canRedo != true)
        }
        CommandGroup(after: .newItem) {
            Button("Import Media…") { store?.importMedia() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store == nil || store?.isImporting == true)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Media Bin", isOn: $showMediaBin)
            Toggle("Show Inspector", isOn: $showInspector)
            Toggle("Show Timeline", isOn: $showTimeline)
            Button("Show All Workspace Panels") {
                showMediaBin = true; showInspector = true; showTimeline = true
            }
        }
        CommandMenu("Timeline") {
            Button("Append Selected Source") { store?.appendSelectedAsset() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store?.selectedAsset == nil || store?.isImporting == true)
            Button("Split at Playhead") { store?.splitSelectedClip() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(store?.selectedClip == nil)
            Divider()
            Button("Previous Frame") { store?.stepPlayhead(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Next Frame") { store?.stepPlayhead(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store == nil)
            Divider()
            Button("Delete Selected Clip") { store?.deleteSelectedClip() }
                .disabled(store?.selectedClip == nil)
        }
    }
}
