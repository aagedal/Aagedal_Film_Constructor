import AppKit
import EditorCore

extension EditorStore {
    func enqueueProxyJobs(assets: [MediaAsset], preset: ProxyPreset, scaleDivisor: Int, directory: URL) throws {
        guard proxyGenerationTask == nil, !isRelinkingProxy else { throw EditorCoreError.invalidModel("Wait for the current proxy queue to finish.") }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let jobs = try assets.map { asset in
            guard let current = project.assets.first(where: { $0.id == asset.id }),
                  current.originalURL == asset.originalURL, current.streams == asset.streams,
                  current.duration == asset.duration, let source = asset.originalURL else {
                throw EditorCoreError.invalidModel("Source changed before its proxy job was queued.")
            }
            holdAccess(source)
            let base = source.deletingPathExtension().lastPathComponent
            let output = directory.appendingPathComponent("\(base)-\(UUID().uuidString)-proxy.mov")
            let job = ProxyGenerationJob(sourceSnapshot: asset, sourceFingerprint: try ProxyGenerationService.fingerprint(for: source),
                                         preset: preset, scaleDivisor: scaleDivisor, outputURL: output, outputFolderBookmark: bookmark)
            try job.validate()
            return job
        }
        proxyJobs.append(contentsOf: jobs)
    }

    func removeProxyJob(id: UUID) {
        guard proxyGenerationTask == nil else { return }
        proxyJobs.removeAll { $0.id == id }
        proxyQueueProgress[id] = nil
    }

    func cancelProxyQueue() { proxyGenerationTask?.cancel() }

    func clearFinishedProxyJobs() {
        proxyJobs.removeAll { $0.state == .completed }
    }

    func retryProxyJob(id: UUID, freshDestination: Bool = false, service: ProxyGenerationService = .shared) {
        guard proxyGenerationTask == nil, !isRelinkingProxy, let index = proxyJobs.firstIndex(where: { $0.id == id }),
              proxyJobs[index].state.canResume else { return }
        if freshDestination {
            let base = proxyJobs[index].sourceSnapshot.originalURL?.deletingPathExtension().lastPathComponent ?? "Media"
            proxyJobs[index].outputURL = proxyJobs[index].outputURL.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(UUID().uuidString)-proxy.mov")
            proxyJobs[index].verifiedProxy = nil
        }
        proxyJobs[index].state = .queued
        proxyJobs[index].message = nil
        runProxyQueue(service: service, jobIDs: [id])
    }

    func runProxyQueue(service: ProxyGenerationService = .shared, jobIDs: Set<UUID>? = nil) {
        guard proxyGenerationTask == nil, !isRelinkingProxy,
              proxyJobs.contains(where: { $0.state.canResume && (jobIDs?.contains($0.id) ?? true) }) else { return }
        let epoch = mediaEpoch
        let ids = proxyJobs.filter { $0.state.canResume && (jobIDs?.contains($0.id) ?? true) }.map(\.id)
        proxyGenerationTask = Task { @MainActor in
            defer {
                if epoch == mediaEpoch { proxyGenerationTask = nil; proxyQueueProgress = [:] }
            }
            for id in ids {
                guard !Task.isCancelled, epoch == mediaEpoch,
                      let index = proxyJobs.firstIndex(where: { $0.id == id }) else { break }
                proxyJobs[index].state = .running
                proxyJobs[index].message = nil
                do {
                    try resolveProxyJobFolder(id: id)
                    guard let job = proxyJobs.first(where: { $0.id == id }),
                          let current = project.assets.first(where: { $0.id == job.sourceSnapshot.id }),
                          let source = current.originalURL else {
                        throw EditorCoreError.invalidModel("The queued source no longer exists. Create a new proxy job.")
                    }
                    holdAccess(source)
                    let fingerprint = try ProxyGenerationService.fingerprint(for: source)
                    var comparisonJob = job, comparisonAsset = current
                    comparisonJob.sourceSnapshot.originalURL = job.sourceSnapshot.originalURL?.resolvingSymlinksInPath().standardizedFileURL
                    comparisonAsset.originalURL = source.resolvingSymlinksInPath().standardizedFileURL
                    guard comparisonJob.matchesSource(comparisonAsset, fingerprint: fingerprint) else {
                        throw EditorCoreError.invalidModel("The queued source changed. Create a new proxy job for the current media.")
                    }
                    let revision = sourceRevisions[current.id]
                    let proxy: MediaProxy
                    if FileManager.default.fileExists(atPath: job.outputURL.path) {
                        guard let candidate = job.verifiedProxy else {
                            throw EditorCoreError.invalidModel("Output already exists without verified queue metadata. Retry to a new file to preserve it.")
                        }
                        _ = try await ProxyGenerationService.validateProxyFile(candidate)
                        proxy = candidate
                    } else {
                        proxy = try await service.generate(asset: current, preset: job.preset, scaleDivisor: job.scaleDivisor,
                            to: job.outputURL, verified: { candidate in
                                try await MainActor.run {
                                    guard epoch == self.mediaEpoch,
                                          let index = self.proxyJobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                                    self.proxyJobs[index].verifiedProxy = candidate
                                }
                            }, progress: { progress in
                                Task { @MainActor in
                                    guard epoch == self.mediaEpoch, self.proxyJobs.contains(where: { $0.id == id && $0.state == .running }) else { return }
                                    self.proxyQueueProgress[id] = progress
                                }
                            })
                    }
                    try Task.checkCancellation()
                    guard epoch == mediaEpoch else { break }
                    try registerProxy(proxy, for: current, epoch: epoch, sourceRevision: revision)
                    updateProxyJob(id: id, state: .completed, message: "Registered verified proxy.")
                } catch {
                    guard epoch == mediaEpoch else { break }
                    updateProxyJob(id: id, state: Task.isCancelled ? .cancelled : .failed,
                                   message: Task.isCancelled ? "Cancelled. Resume manually when ready." : audioEditErrorMessage(error))
                    if Task.isCancelled { break }
                }
            }
        }
    }

    private func updateProxyJob(id: UUID, state: ProxyGenerationJobState, message: String) {
        guard let index = proxyJobs.firstIndex(where: { $0.id == id }) else { return }
        proxyJobs[index].state = state; proxyJobs[index].message = message
    }

    private func resolveProxyJobFolder(id: UUID) throws {
        guard let index = proxyJobs.firstIndex(where: { $0.id == id }),
              let bookmark = proxyJobs[index].outputFolderBookmark else { return }
        var stale = false
        let directory = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        holdAccess(directory)
        let output = directory.appendingPathComponent(proxyJobs[index].outputURL.lastPathComponent)
        proxyJobs[index].outputURL = output
        proxyJobs[index].verifiedProxy?.url = output
        if stale {
            proxyJobs[index].outputFolderBookmark = try directory.bookmarkData(options: [.withSecurityScope],
                                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
}
