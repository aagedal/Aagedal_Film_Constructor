import AppKit
import AVFoundation
import EditorCore

private enum QueueSmokeError: Error { case failed(String) }
@main struct ProxyQueueSmoke {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let imported = try await MediaImporter.inspect(url: directory.appendingPathComponent("source.mov"))
        let service = ProxyGenerationService(ffmpegURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                                             ffprobeURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(imported)
        try store.enqueueProxyJobs(assets: [imported.asset], preset: .h264, scaleDivisor: 2, directory: directory)
        try check(store.proxyGenerationTask == nil && store.proxyJobs.count == 1, "Enqueue does not start rendering")
        let output = store.proxyJobs[0].outputURL
        let queuedDocument = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks,
                                             proxyBookmarks: store.proxyBookmarks, proxyJobs: store.proxyJobs)
        let reopened = EditorStore()
        defer { reopened.close() }
        reopened.load(try ProjectDocument(data: queuedDocument.encodedData()))
        try check(reopened.proxyGenerationTask == nil && reopened.proxyJobs[0].outputURL == output, "Reopen retains stable destination without automatic resume")
        reopened.runProxyQueue(service: service)
        await reopened.proxyGenerationTask?.value
        try check(reopened.proxyJobs[0].state == .completed && reopened.project.assets[0].proxy?.url.resolvingSymlinksInPath() == output.resolvingSymlinksInPath(),
                  "Manual resume registers verified result: \(reopened.proxyJobs[0].state), \(reopened.proxyJobs[0].message ?? "no message"), \(reopened.proxyJobs[0].outputURL)")
        let completed = reopened.proxyJobs[0]
        reopened.undo()
        try check(reopened.proxyJobs[0].state == .completed, "Queue state remains outside edit undo")
        reopened.redo()
        // Simulate a successful atomic publication followed by interruption before registration.
        var interrupted = completed; interrupted.state = .running
        let recovery = EditorStore()
        defer { recovery.close() }
        recovery.load(ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks, proxyJobs: [interrupted]))
        try check(recovery.proxyJobs[0].state == .interrupted && recovery.proxyGenerationTask == nil, "Running job becomes manually resumable interrupted job")
        let before = try Data(contentsOf: output)
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .completed && recovery.project.assets[0].proxy?.id == completed.verifiedProxy?.id,
                  "Published result recovered by exact-byte verification")
        try check(try Data(contentsOf: output) == before, "Recovery never overwrites publication")
        // An unrecorded destination collision requires an explicit new destination.
        var collision = completed; collision.id = UUID(); collision.state = .queued; collision.verifiedProxy = nil
        recovery.proxyJobs = [collision]
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .failed && recovery.proxyJobs[0].outputURL.resolvingSymlinksInPath() == output.resolvingSymlinksInPath(),
                  "Unverified orphan output is preserved and fails safely")
        recovery.retryProxyJob(id: collision.id, freshDestination: true, service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .completed && recovery.proxyJobs[0].outputURL != output,
                  "Explicit retry uses a fresh filename")
        try check(try Data(contentsOf: output) == before, "Explicit retry retains orphan file")
        // Stale source metadata fails before generation.
        var stale = collision; stale.id = UUID(); stale.outputURL = directory.appendingPathComponent("stale.mov")
        stale.sourceFingerprint.fileSize += 1
        recovery.proxyJobs = [stale]
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .failed && !FileManager.default.fileExists(atPath: stale.outputURL.path), "Stale source never renders")
        recovery.removeProxyJob(id: stale.id)
        try check(recovery.proxyJobs.isEmpty && FileManager.default.fileExists(atPath: output.path), "Removing failed jobs preserves files")
        recovery.proxyJobs = [stale]
        recovery.proxyJobs[0].state = .failed
        let failedSaved = try ProjectDocument(project: recovery.project, mediaBookmarks: recovery.mediaBookmarks,
                                              proxyBookmarks: recovery.proxyBookmarks, proxyJobs: recovery.proxyJobs).encodedData()
        try check(try ProjectDocument(data: failedSaved).proxyJobs[0].state == .failed, "Failed state persists")
        // Cancellation leaves the stable destination and a manually resumable job.
        let helper = directory.appendingPathComponent("slow-helper")
        try "#!/bin/bash\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let slowService = ProxyGenerationService(ffmpegURL: helper, ffprobeURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        var cancelled = collision; cancelled.id = UUID(); cancelled.outputURL = directory.appendingPathComponent("cancelled-queue.mov")
        recovery.proxyJobs = [cancelled]
        recovery.runProxyQueue(service: slowService)
        try await Task.sleep(for: .milliseconds(300))
        recovery.cancelProxyQueue()
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .cancelled && !FileManager.default.fileExists(atPath: cancelled.outputURL.path), "Cancelled queue remains resumable and never publishes")
        // Individual retry must not start another queued job in the same document.
        var waiting = cancelled; waiting.id = UUID(); waiting.outputURL = directory.appendingPathComponent("waiting-queue.mov")
        waiting.state = .queued
        recovery.proxyJobs.append(waiting)
        recovery.retryProxyJob(id: cancelled.id, service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .completed && recovery.proxyJobs[1].state == .queued &&
                  !FileManager.default.fileExists(atPath: waiting.outputURL.path), "Individual retry leaves other queued jobs untouched")
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs.allSatisfy { $0.state == .completed }, "Resume finishes remaining queued jobs")
        recovery.clearFinishedProxyJobs()
        try check(recovery.proxyJobs.isEmpty && recovery.project.assets[0].proxy != nil, "Clearing completed queue preserves registered proxies")
        // Closing/reloading while a cancelled task unwinds cannot mutate the replacement document or clear its task.
        var closing = cancelled; closing.id = UUID(); closing.state = .queued
        closing.outputURL = directory.appendingPathComponent("closing-queue.mov")
        recovery.proxyJobs = [closing]
        recovery.runProxyQueue(service: slowService)
        try await Task.sleep(for: .milliseconds(300))
        let oldTask = recovery.proxyGenerationTask
        let runningSaved = try ProjectDocument(project: recovery.project, mediaBookmarks: recovery.mediaBookmarks,
                                               proxyBookmarks: recovery.proxyBookmarks, proxyJobs: recovery.proxyJobs).encodedData()
        try check(try ProjectDocument(data: runningSaved).proxyJobs[0].state == .running, "Saving an active job preserves its resumable running snapshot")
        recovery.load(try ProjectDocument(data: runningSaved))
        try check(recovery.proxyGenerationTask == nil && recovery.proxyJobs[0].state == .interrupted &&
                  recovery.proxyQueueProgress.isEmpty, "Document replacement cancels the old queue and restores interrupted state without starting it")
        recovery.runProxyQueue(service: slowService)
        await oldTask?.value
        try await Task.sleep(for: .milliseconds(50))
        try check(recovery.proxyGenerationTask != nil && recovery.proxyJobs[0].state == .running,
                  "Old queue cleanup cannot clear a replacement document's active task or state")
        recovery.cancelProxyQueue()
        await recovery.proxyGenerationTask?.value
        try check(!FileManager.default.fileExists(atPath: closing.outputURL.path), "Closed queue never publishes its unfinished output")
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .completed, "Interrupted document replacement remains manually resumable")
        var malformed = try JSONSerialization.jsonObject(with: queuedDocument.encodedData()) as! [String: Any]
        let jobs = malformed["proxyJobs"] as! [[String: Any]]
        malformed["proxyJobs"] = jobs + jobs
        do {
            _ = try ProjectDocument(data: JSONSerialization.data(withJSONObject: malformed))
            throw QueueSmokeError.failed("Duplicate queue job identity accepted")
        } catch EditorCoreError.invalidModel { }
        malformed.removeValue(forKey: "proxyJobs")
        try check(try ProjectDocument(data: JSONSerialization.data(withJSONObject: malformed)).proxyJobs.isEmpty, "Legacy documents load with empty queue")
        print("Proxy queue smoke passed: persistence, manual resume, interruption recovery, collision preservation, fresh retry, stale source, cancellation, individual retry isolation, active save/reload, stale task cleanup, undo separation, legacy documents")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw QueueSmokeError.failed(message) }
    }
}
