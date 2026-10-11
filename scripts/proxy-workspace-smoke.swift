import AppKit
import AVFoundation
import EditorCore

private enum SmokeError: Error { case failed(String) }

@main
struct ProxyWorkspaceSmoke {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = directory.appendingPathComponent("source.mov")
        let imported = try await MediaImporter.inspect(url: source)
        try check(imported.asset.streams.filter { $0.kind == .audio }.count == 2, "Two original audio streams imported")
        try check(imported.asset.duration.seconds > 2.9, "Audio duration exceeds picture duration")
        let service = ProxyGenerationService(ffmpegURL: URL(fileURLWithPath: CommandLine.arguments[2]), ffprobeURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        let proxy = try await service.generate(asset: imported.asset, preset: .proResProxy, scaleDivisor: 2, to: directory.appendingPathComponent("proxy.mov"))
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(imported)
        try store.registerProxy(proxy, for: imported.asset, epoch: store.mediaEpoch, sourceRevision: nil)
        let grant = store.proxyBookmarks[imported.asset.id]
        try check(grant != nil && store.selectedAsset?.proxy == proxy, "Proxy and sandbox grant register together")
        store.undo()
        try check(store.selectedAsset?.proxy == nil && store.proxyBookmarks.isEmpty, "Undo restores original identity and grants")
        store.redo()
        try check(store.selectedAsset?.proxy == proxy && store.proxyBookmarks[imported.asset.id] == grant, "Redo restores proxy identity and grant")
        let document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks, proxyBookmarks: store.proxyBookmarks)
        let reopened = EditorStore()
        defer { reopened.close() }
        reopened.load(try ProjectDocument(data: document.encodedData()))
        reopened.selectAsset(imported.asset.id)
        try check(reopened.selectedAsset?.proxy?.id == proxy.id && reopened.proxyBookmarks[imported.asset.id] != nil, "Save and reopen proxy identity and access")
        let position = CMTime(seconds: 0.75, preferredTimescale: 60000)
        await reopened.sourcePlayer?.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        reopened.setPlaybackRepresentation(.proxy)
        let player = try await awaitPlayer(reopened)
        try check(abs(player.currentTime().seconds - 0.75) < 0.02 && player.rate == 0, "Proxy switch preserves paused source position")
        guard let composition = player.currentItem?.asset as? AVComposition else { throw SmokeError.failed("Proxy monitor uses AVComposition") }
        let videos = try await composition.loadTracks(withMediaType: .video)
        let audios = try await composition.loadTracks(withMediaType: .audio)
        try check(videos.count == 1 && audios.count == 2, "Proxy picture retains both original audio streams")
        try check(videos[0].segments.contains { $0.sourceURL?.standardizedFileURL == proxy.url.standardizedFileURL }, "Composition picture references proxy URL")
        for audio in audios {
            try check(audio.segments.contains { $0.sourceURL?.standardizedFileURL == source.standardizedFileURL }, "Composition audio references original URL")
            try check(try await audio.load(.timeRange).duration.seconds > 2.9, "Composition keeps longer original audio duration")
        }
        reopened.setPlaybackRepresentation(.original)
        _ = try await awaitPlayer(reopened)
        try check(abs(reopened.sourcePlayer!.currentTime().seconds - 0.75) < 0.02, "Hires switch preserves position")
        reopened.setPlaybackRepresentation(.proxy)
        reopened.setPlaybackRepresentation(.original)
        reopened.setPlaybackRepresentation(.proxy)
        _ = try await awaitPlayer(reopened)
        try check(abs(reopened.sourcePlayer!.currentTime().seconds - 0.75) < 0.02 && reopened.sourcePlayer!.rate == 0, "Rapid switches preserve paused position")
        reopened.sourcePlayer?.play()
        reopened.setPlaybackRepresentation(.original)
        reopened.setPlaybackRepresentation(.proxy)
        reopened.setPlaybackRepresentation(.original)
        let forward = try await awaitPlayer(reopened)
        try check(forward.rate > 0, "Rapid switches preserve forward play intent")
        reopened.pauseSource()
        reopened.sourceRevisions[imported.asset.id] = UUID()
        do {
            try reopened.registerProxy(proxy, for: imported.asset, epoch: reopened.mediaEpoch, sourceRevision: nil)
            throw SmokeError.failed("Changed source revision registration accepted")
        } catch EditorCoreError.invalidModel { }
        reopened.sourceRevisions[imported.asset.id] = nil
        reopened.setPlaybackRepresentation(.proxy)
        _ = try await awaitPlayer(reopened)
        let hidden = directory.appendingPathComponent("hidden.mov")
        try FileManager.default.moveItem(at: proxy.url, to: hidden)
        reopened.refreshSourcePreview(preservingTransport: true)
        try check(reopened.sourcePlayer != nil && reopened.proxyPlaybackMessage.contains("missing"), "Missing proxy falls back immediately")
        let beforeRelink = reopened.project
        let beforeRelinkGrant = reopened.proxyBookmarks[imported.asset.id]
        let expectedRelink = reopened.selectedAsset!
        do {
            try await reopened.relinkProxy(for: expectedRelink, to: source, epoch: reopened.mediaEpoch, sourceRevision: nil)
            throw SmokeError.failed("Unrelated replacement proxy accepted")
        } catch SequenceExportError.verification { }
        try check(reopened.project == beforeRelink && reopened.proxyBookmarks[imported.asset.id] == beforeRelinkGrant, "Rejected relink preserves project and access")
        try await reopened.relinkProxy(for: expectedRelink, to: hidden, epoch: reopened.mediaEpoch, sourceRevision: nil)
        _ = try await awaitPlayer(reopened)
        try check(reopened.selectedAsset?.proxy?.url == hidden && reopened.selectedAsset?.proxy?.id == proxy.id,
                  "Relink preserves identity and restores moved proxy")
        let relinkGrant = reopened.proxyBookmarks[imported.asset.id]
        try check(relinkGrant != nil && relinkGrant != beforeRelinkGrant, "Relink persists replacement sandbox grant")
        try check(reopened.project.tracks == beforeRelink.tracks && reopened.selectedAsset?.originalURL == expectedRelink.originalURL,
                  "Relink preserves original source and timeline")
        reopened.undo()
        try check(reopened.selectedAsset?.proxy == expectedRelink.proxy && reopened.proxyBookmarks[imported.asset.id] == beforeRelinkGrant,
                  "Undo relink restores proxy URL and sandbox grant")
        reopened.redo()
        try check(reopened.selectedAsset?.proxy?.url == hidden && reopened.proxyBookmarks[imported.asset.id] == relinkGrant,
                  "Redo relink restores moved proxy and sandbox grant")
        let relinkedDocument = ProjectDocument(project: reopened.project, mediaBookmarks: reopened.mediaBookmarks, proxyBookmarks: reopened.proxyBookmarks)
        let relinkedStore = EditorStore()
        defer { relinkedStore.close() }
        relinkedStore.load(try ProjectDocument(data: relinkedDocument.encodedData()))
        try check(relinkedStore.project.assets.first?.proxy?.url.resolvingSymlinksInPath() == hidden.resolvingSymlinksInPath() && relinkedStore.proxyBookmarks[imported.asset.id] != nil,
                  "Relink survives save and reopen")
        do {
            try await reopened.relinkProxy(for: reopened.selectedAsset!, to: hidden, epoch: UUID(), sourceRevision: nil)
            throw SmokeError.failed("Old document relink accepted")
        } catch EditorCoreError.invalidModel { }
        var legacy = reopened.selectedAsset!
        legacy.proxy?.outputIntegrity = nil
        do {
            try await reopened.relinkProxy(for: legacy, to: hidden, epoch: reopened.mediaEpoch, sourceRevision: nil)
            throw SmokeError.failed("Legacy unverified proxy relink accepted")
        } catch SequenceExportError.verification { }
        let verifiedBytes = try Data(contentsOf: hidden)
        let handle = try FileHandle(forWritingTo: hidden)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        reopened.refreshSourcePreview(preservingTransport: true)
        _ = try await awaitPlayer(reopened)
        try check(reopened.proxyPlaybackMessage.contains("modified") && reopened.sourcePlayer?.currentItem?.asset is AVURLAsset,
                  "Modified proxy picture falls back to original")
        try verifiedBytes.write(to: hidden)
        reopened.refreshSourcePreview(preservingTransport: true)
        _ = try await awaitPlayer(reopened)
        try check(reopened.proxyPlaybackMessage.contains("original audio"), "Restored exact proxy bytes resume proxy playback")
        reopened.undo()
        try FileManager.default.moveItem(at: hidden, to: proxy.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
        reopened.refreshSourcePreview(preservingTransport: true)
        try check(reopened.sourcePlayer != nil && reopened.proxyPlaybackMessage.contains("stale"), "Changed source falls back to original")
        do {
            try reopened.registerProxy(proxy, for: imported.asset, epoch: reopened.mediaEpoch, sourceRevision: nil)
            throw SmokeError.failed("Stale registration accepted")
        } catch EditorCoreError.invalidModel { }
        let oldEpoch = reopened.mediaEpoch
        reopened.proxyGenerationTask = Task { try? await Task.sleep(for: .seconds(60)) }
        reopened.proxyRelinkTask = Task { try? await Task.sleep(for: .seconds(60)) }
        reopened.isRelinkingProxy = true
        reopened.close()
        try check(reopened.proxyRelinkTask == nil && !reopened.isRelinkingProxy, "Close cancels proxy relink")
        try check(reopened.proxyGenerationTask == nil && reopened.sourceRevisions.isEmpty, "Close clears cancelled jobs and source revisions")
        reopened.load(document)
        try check(reopened.proxyGenerationTask == nil, "Reopen allows new proxy jobs")
        do {
            try reopened.registerProxy(proxy, for: imported.asset, epoch: oldEpoch, sourceRevision: nil)
            throw SmokeError.failed("Old document generation accepted")
        } catch EditorCoreError.invalidModel { }
        print("Proxy workspace smoke passed: composition, original audio, switching, persistence, relink validation and undo, fallback, and stale registration")
    }

    @MainActor private static func awaitPlayer(_ store: EditorStore) async throws -> AVPlayer {
        for _ in 0..<500 {
            if let player = store.sourcePlayer {
                // Original switches install the player before their exact seek completes.
                try await Task.sleep(for: .milliseconds(100))
                return player
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SmokeError.failed("Source preview timed out")
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeError.failed(message) }
    }
}
