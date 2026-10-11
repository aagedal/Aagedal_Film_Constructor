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
        recovery.runProxyQueue(service: service)
        await recovery.proxyGenerationTask?.value
        try check(recovery.proxyJobs[0].state == .completed, "Cancelled job resumes manually")
        recovery.clearFinishedProxyJobs()
        try check(recovery.proxyJobs.isEmpty && recovery.project.assets[0].proxy != nil, "Clearing completed queue preserves registered proxies")
        var malformed = try JSONSerialization.jsonObject(with: queuedDocument.encodedData()) as! [String: Any]
        let jobs = malformed["proxyJobs"] as! [[String: Any]]
        malformed["proxyJobs"] = jobs + jobs
        do {
            _ = try ProjectDocument(data: JSONSerialization.data(withJSONObject: malformed))
            throw QueueSmokeError.failed("Duplicate queue job identity accepted")
        } catch EditorCoreError.invalidModel { }
        malformed.removeValue(forKey: "proxyJobs")
        try check(try ProjectDocument(data: JSONSerialization.data(withJSONObject: malformed)).proxyJobs.isEmpty, "Legacy documents load with empty queue")
        print("Proxy queue smoke passed: persistence, manual resume, interruption recovery, collision preservation, fresh retry, stale source, cancellation, undo separation, legacy documents")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw QueueSmokeError.failed(message) }
    }
}
