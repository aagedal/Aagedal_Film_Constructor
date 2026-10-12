import Combine
import CryptoKit
import EditorCore
import Foundation

/// Complements DocumentGroup's autosave-in-place with untitled reminders and
/// recoverable current snapshots. Backups never replace the document itself.
@MainActor
final class ProjectSaveProtection: ObservableObject {
    nonisolated struct Policy: Sendable {
        var reminderInterval: TimeInterval = 300
        var debounceInterval: TimeInterval = 15
        var maximumWaitInterval: TimeInterval = 120
        var minimumBackupInterval: TimeInterval = 60
        var retainedBackups: Int = 20
    }

    @Published private(set) var reminderMessage: String?
    @Published private(set) var backupStatusMessage: String?
    @Published private(set) var backupsURL: URL?
    @Published private(set) var lastBackupDate: Date?
    private let policy: Policy
    private let clock: () -> Date
    private let writer = ProjectBackupWriter()
    private let backupsRoot: URL
    private let beforeBackupWrite: (@Sendable () async -> Void)?
    private var timer: Task<Void, Never>?
    private var snapshot: ProjectBackupSnapshot?
    private var fileURL: URL?
    private var revision: UInt64 = 0
    private var completedRevision: UInt64?
    private var untitledChangedAt: Date?
    private var pendingSince: Date?
    private var changedAt: Date?
    private var lastAttemptAt: Date?
    private var isWriting = false

    init(policy: Policy = Policy(), backupsRoot: URL? = nil, clock: @escaping () -> Date = Date.init,
         beforeBackupWrite: (@Sendable () async -> Void)? = nil) {
        self.policy = policy
        self.clock = clock
        self.beforeBackupWrite = beforeBackupWrite
        self.backupsRoot = backupsRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aagedal Film Constructor/Project Backups", isDirectory: true)
    }

    /// Taking a value snapshot is cheap; encoding and file I/O happen on the worker
    /// only when the debounce/maximum-wait deadline is reached.
    func observe(document: ProjectDocument, fileURL: URL?, hasChanges: Bool = true) {
        let now = clock()
        let next = ProjectBackupSnapshot(document)
        let locationChanged = self.fileURL != fileURL
        if snapshot != next || locationChanged {
            snapshot = next
            revision &+= 1
            changedAt = now
            if pendingSince == nil || locationChanged { pendingSince = now }
        }
        self.fileURL = fileURL
        if let fileURL {
            let digest = SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            backupsURL = backupsRoot.appendingPathComponent(digest, isDirectory: true)
        } else { backupsURL = nil }
        if locationChanged {
            completedRevision = nil
            lastAttemptAt = nil
            backupStatusMessage = nil
            lastBackupDate = nil
        }
        if fileURL == nil && hasChanges {
            if untitledChangedAt == nil { untitledChangedAt = now }
        } else {
            untitledChangedAt = nil
            reminderMessage = nil
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.checkNow(at: self.clock())
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Snooze preserves the dirty state and reminds again after another interval.
    func dismissReminder() {
        reminderMessage = nil
        if untitledChangedAt != nil { untitledChangedAt = clock() }
    }

    /// Explicit time makes reminder/debounce behavior testable without long sleeps.
    func checkNow(at now: Date) async {
        if fileURL == nil {
            if let changed = untitledChangedAt, now.timeIntervalSince(changed) >= policy.reminderInterval {
                reminderMessage = "Save your project to enable autosave and automatic backups."
            }
            return
        }
        guard !isWriting, completedRevision != revision, let fileURL, let folder = backupsURL, let snapshot,
              let changedAt, let pendingSince,
              now.timeIntervalSince(changedAt) >= policy.debounceInterval || now.timeIntervalSince(pendingSince) >= policy.maximumWaitInterval,
              lastAttemptAt == nil || now.timeIntervalSince(lastAttemptAt!) >= policy.minimumBackupInterval else { return }
        isWriting = true
        lastAttemptAt = now
        let capturedRevision = revision
        do {
            // Test synchronization can hold this boundary while a newer edit or
            // Save As changes the observed revision; captured snapshots stay immutable.
            if let beforeBackupWrite { await beforeBackupWrite() }
            _ = try await writer.write(snapshot, folder: folder, date: now, retention: max(1, policy.retainedBackups))
            if self.fileURL == fileURL {
                completedRevision = capturedRevision
                if revision == capturedRevision { self.pendingSince = nil }
                backupStatusMessage = nil
                lastBackupDate = now
            }
        } catch {
            if self.fileURL == fileURL {
                backupStatusMessage = "Automatic backup failed: \(error.localizedDescription)"
            }
        }
        isWriting = false
    }
}

private nonisolated struct ProjectBackupSnapshot: Equatable, Sendable {
    let project: Project
    let mediaBookmarks: [UUID: Data]
    let proxyBookmarks: [UUID: Data]
    let proxyJobs: [ProxyGenerationJob]
    init(_ document: ProjectDocument) {
        project = document.project
        mediaBookmarks = document.mediaBookmarks
        proxyBookmarks = document.proxyBookmarks
        proxyJobs = document.proxyJobs
    }
    func encodedData() throws -> Data {
        try ProjectDocument(project: project, mediaBookmarks: mediaBookmarks,
                            proxyBookmarks: proxyBookmarks, proxyJobs: proxyJobs).encodedData()
    }
}

private actor ProjectBackupWriter {
    func write(_ snapshot: ProjectBackupSnapshot, folder: URL, date: Date, retention: Int) throws -> URL {
        guard folder.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let manager = FileManager.default
        // A preexisting symlink could redirect writes or retention outside the
        // project's backup directory. Reject it before inspecting its children.
        if (try? manager.attributesOfItem(atPath: folder.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("backup-\(timestamp)-\(UUID().uuidString).afcproject")
        let staging = folder.appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try snapshot.encodedData().write(to: staging, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: staging)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // Same-directory rename publishes only a complete synced snapshot; moveItem
        // refuses existing destinations rather than overwriting any project file.
        try manager.moveItem(at: staging, to: destination)
        let backups = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "afcproject" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in backups.prefix(max(0, backups.count - retention)) { try manager.removeItem(at: old) }
        return destination
    }
}
