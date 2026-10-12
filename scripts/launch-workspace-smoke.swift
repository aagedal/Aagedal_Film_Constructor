import AppKit

enum LaunchSmokeError: Error { case failed(String), creationFailed }

@main
struct LaunchWorkspaceSmoke {
    @MainActor
    static func main() throws {
        var documents = 0
        var opened = 0
        var errors = 0
        var queued: [@MainActor () -> Void] = []
        var failCreation = false
        let coordinator = LaunchWorkspaceCoordinator(documentCount: { documents }, openUntitledDocument: {
            if failCreation { throw LaunchSmokeError.creationFailed }
            opened += 1
            documents += 1
        }, enqueue: { queued.append($0) }, presentError: { _ in errors += 1 })

        coordinator.requestEmptyWorkspace()
        coordinator.requestEmptyWorkspace()
        try check(queued.count == 1 && opened == 0, "Cold launch is deferred and duplicate requests coalesce")
        queued.removeFirst()()
        try check(opened == 1 && documents == 1, "Cold launch opens one ordinary untitled document")
        coordinator.requestEmptyWorkspace()
        try check(queued.isEmpty, "An existing document is preserved")

        documents = 0
        coordinator.requestEmptyWorkspace()
        documents = 1 // Finder-open or restoration wins before deferred launch.
        queued.removeFirst()()
        try check(opened == 1, "Queued file open/restoration suppresses a redundant workspace")

        documents = 0
        coordinator.requestEmptyWorkspace()
        queued.removeFirst()()
        try check(opened == 2 && documents == 1, "Reopening with all documents closed creates a workspace")

        documents = 0
        failCreation = true
        coordinator.requestEmptyWorkspace()
        queued.removeFirst()()
        try check(errors == 1 && opened == 2, "Creation errors reach the standard error presenter")
        failCreation = false
        coordinator.requestEmptyWorkspace()
        queued.removeFirst()()
        try check(opened == 3, "A failed request does not block future reopening")
        print("PASS: empty launch, coalescing, existing/Finder/restored documents, reopen and creation failure")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw LaunchSmokeError.failed(message) }
    }
}
