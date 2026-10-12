import EditorCore
import Foundation

@main
struct ProjectSaveProtectionSmoke {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var now = Date(timeIntervalSince1970: 1_000)
        let policy = ProjectSaveProtection.Policy(reminderInterval: 300, debounceInterval: 10, maximumWaitInterval: 40, minimumBackupInterval: 20, retainedBackups: 2)
        let protection = ProjectSaveProtection(policy: policy, backupsRoot: root.appendingPathComponent("backups"), clock: { now })
        var document = ProjectDocument(project: try DemoProjectFactory.musicCollision())
        protection.observe(document: document, fileURL: nil, hasChanges: false)
        await protection.checkNow(at: now.addingTimeInterval(1_000))
        check(protection.reminderMessage == nil, "Untouched blank documents must not nag")
        protection.observe(document: document, fileURL: nil)
        await protection.checkNow(at: now.addingTimeInterval(299))
        check(protection.reminderMessage == nil)
        now = now.addingTimeInterval(300)
        await protection.checkNow(at: now)
        check(protection.reminderMessage != nil, "Dirty untitled work reminds after five minutes")
        protection.dismissReminder()
        await protection.checkNow(at: now.addingTimeInterval(299))
        check(protection.reminderMessage == nil)
        await protection.checkNow(at: now.addingTimeInterval(300))
        check(protection.reminderMessage != nil)

        let original = root.appendingPathComponent("Original.afcproject")
        let originalData = try document.encodedData()
        try originalData.write(to: original)
        protection.observe(document: document, fileURL: original, hasChanges: false)
        check(protection.reminderMessage == nil)
        let folder = protection.backupsURL!
        await protection.checkNow(at: now.addingTimeInterval(9))
        check(!FileManager.default.fileExists(atPath: folder.path))
        now = now.addingTimeInterval(10)
        await protection.checkNow(at: now)
        check(protection.backupStatusMessage == nil)
        check(try backupFiles(folder).count == 1)
        // Every file is a standard reopenable document, including its envelope.
        let first = try ProjectDocument(data: Data(contentsOf: backupFiles(folder)[0]))
        check(first.project == document.project)
        await protection.checkNow(at: now.addingTimeInterval(500))
        check(try backupFiles(folder).count == 1, "Unchanged snapshots are never backed up repeatedly")

        now = now.addingTimeInterval(1)
        document.project.preferences.automaticallyRemoveEmptyTracks.toggle()
        protection.observe(document: document, fileURL: original)
        await protection.checkNow(at: now.addingTimeInterval(10))
        check(try backupFiles(folder).count == 1, "Minimum backup interval limits frequent edits")
        now = now.addingTimeInterval(20)
        await protection.checkNow(at: now)
        check(try backupFiles(folder).count == 2)
        now = now.addingTimeInterval(21)
        document.project.assets[0].name = "Newest recoverable state"
        protection.observe(document: document, fileURL: original)
        now = now.addingTimeInterval(10)
        await protection.checkNow(at: now)
        let retained = try backupFiles(folder)
        check(retained.count == 2)
        check(try ProjectDocument(data: Data(contentsOf: retained.last!)).project == document.project)
        check(try Data(contentsOf: original) == originalData, "Protection must never overwrite the source project")

        // Continuous edits eventually trigger a backup even without an idle gap.
        let continuous = ProjectSaveProtection(policy: policy, backupsRoot: root.appendingPathComponent("continuous"), clock: { now })
        continuous.observe(document: document, fileURL: original)
        for step in 1...5 {
            now = now.addingTimeInterval(8)
            document.project.assets[0].name = "Edit \(step)"
            continuous.observe(document: document, fileURL: original)
            await continuous.checkNow(at: now)
        }
        check(try backupFiles(continuous.backupsURL!).count == 1, "Maximum wait bounds continuous-edit backup delay")

        // A preexisting redirected directory cannot receive backup writes.
        let blocked = ProjectSaveProtection(policy: policy, backupsRoot: root.appendingPathComponent("blocked"), clock: { now })
        blocked.observe(document: document, fileURL: original)
        try FileManager.default.createDirectory(at: blocked.backupsURL!.deletingLastPathComponent(), withIntermediateDirectories: true)
        let redirected = root.appendingPathComponent("redirected")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: blocked.backupsURL!, withDestinationURL: redirected)
        now = now.addingTimeInterval(10)
        await blocked.checkNow(at: now)
        check(blocked.backupStatusMessage != nil)
        check(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
        // Fixing an access error allows the next bounded retry to recover.
        try FileManager.default.removeItem(at: blocked.backupsURL!)
        now = now.addingTimeInterval(20)
        await blocked.checkNow(at: now)
        check(blocked.backupStatusMessage == nil)
        check(try backupFiles(blocked.backupsURL!).count == 1)
        let gate = BackupGate()
        let racing = ProjectSaveProtection(policy: policy, backupsRoot: root.appendingPathComponent("racing"), clock: { now },
                                           beforeBackupWrite: { await gate.wait() })
        racing.observe(document: document, fileURL: original)
        let oldFolder = racing.backupsURL!
        now = now.addingTimeInterval(10)
        let writing = Task { await racing.checkNow(at: now) }
        while !(await gate.hasStarted()) { await Task.yield() }
        document.project.assets[0].name = "Edit made during backup"
        let savedAs = root.appendingPathComponent("Save As.afcproject")
        racing.observe(document: document, fileURL: savedAs)
        let newFolder = racing.backupsURL!
        await gate.release()
        await writing.value
        check(racing.lastBackupDate == nil, "An old-location backup must not mark a Save As destination protected")
        check(try backupFiles(oldFolder).count == 1)
        now = now.addingTimeInterval(10)
        await racing.checkNow(at: now)
        check(racing.lastBackupDate != nil)
        check(try ProjectDocument(data: Data(contentsOf: backupFiles(newFolder)[0])).project == document.project,
              "A newer in-flight revision must receive its own current snapshot")
        let editGate = BackupGate()
        let editing = ProjectSaveProtection(policy: policy, backupsRoot: root.appendingPathComponent("editing"), clock: { now },
                                            beforeBackupWrite: { await editGate.wait() })
        editing.observe(document: document, fileURL: original)
        now = now.addingTimeInterval(10)
        let firstRevision = Task { await editing.checkNow(at: now) }
        while !(await editGate.hasStarted()) { await Task.yield() }
        document.project.assets[0].name = "Newer same-location revision"
        editing.observe(document: document, fileURL: original)
        await editGate.release()
        await firstRevision.value
        now = now.addingTimeInterval(20)
        await editing.checkNow(at: now)
        let revisions = try backupFiles(editing.backupsURL!)
        check(revisions.count == 2)
        check(try ProjectDocument(data: Data(contentsOf: revisions.last!)).project == document.project,
              "Completing an older revision must not clear newer edits")
        protection.start(); protection.start(); protection.stop()
        print("PASS: five-minute untitled reminder and snooze, save reset, debounce, minimum/maximum backup intervals, reopenable snapshot fidelity, retention, unchanged deduplication, source preservation, symlink refusal, retry and edits/Save As during in-flight backup")
    }

    static func check(_ condition: Bool, _ message: String = "Save protection assertion failed") {
        precondition(condition, message)
    }

    static func backupFiles(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "afcproject" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private actor BackupGate {
    private var started = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}
