import AppKit

/// Creates an ordinary untitled DocumentGroup document when AppKit requests an
/// empty launch. File opening, restoration, saving and autosaving stay with the
/// SwiftUI document controller.
@MainActor
final class LaunchWorkspaceCoordinator {
    private let documentCount: @MainActor () -> Int
    private let openUntitledDocument: @MainActor () throws -> Void
    private let enqueue: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let presentError: @MainActor (Error) -> Void
    private var pending = false

    init(documentCount: @escaping @MainActor () -> Int = { NSDocumentController.shared.documents.count },
         openUntitledDocument: @escaping @MainActor () throws -> Void = {
             _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
         },
         enqueue: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { action in
             DispatchQueue.main.async { action() }
         },
         presentError: @escaping @MainActor (Error) -> Void = { NSApplication.shared.presentError($0) }) {
        self.documentCount = documentCount
        self.openUntitledDocument = openUntitledDocument
        self.enqueue = enqueue
        self.presentError = presentError
    }

    func requestEmptyWorkspace() {
        guard documentCount() == 0, !pending else { return }
        pending = true
        // Let SwiftUI finish registering its document type, and give any queued
        // Finder-open/restoration operation precedence over the empty workspace.
        enqueue { [weak self] in
            guard let self else { return }
            defer { self.pending = false }
            guard self.documentCount() == 0 else { return }
            do { try self.openUntitledDocument() }
            catch { self.presentError(error) }
        }
    }
}

@MainActor
final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    private let workspace = LaunchWorkspaceCoordinator()

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        workspace.requestEmptyWorkspace()
        // Suppress DocumentGroup's default launch Open panel. The coordinator
        // opens a real untitled document rather than an independent WindowGroup.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, NSDocumentController.shared.documents.isEmpty else { return true }
        workspace.requestEmptyWorkspace()
        return false
    }
}
