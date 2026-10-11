import AppKit
import AVFoundation
import EditorCore

struct ProxyCreationDraft: Identifiable {
    let id = UUID()
    let assets: [MediaAsset]
}

extension EditorStore {
    func beginProxyCreation(assetID: UUID? = nil) {
        if let assetID, !selectedAssetIDs.contains(assetID) { selectAsset(assetID) }
        let assets = project.assets.filter { selectedAssetIDs.contains($0.id) && $0.streams.contains(where: { $0.kind == .video }) }
        guard !assets.isEmpty, proxyGenerationTask == nil, !isRelinkingProxy, audioAppendAsset == nil, renderExportDraft == nil else { return }
        proxyCreationDraft = ProxyCreationDraft(assets: assets)
    }

    func beginProxyRelink(assetID: UUID) {
        guard !isRelinkingProxy, proxyGenerationTask == nil,
              let expected = project.assets.first(where: { $0.id == assetID }), expected.proxy != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink proxy for \(expected.name)"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let epoch = mediaEpoch
        let revision = sourceRevisions[assetID]
        isRelinkingProxy = true
        proxyRelinkTask = Task {
            defer {
                if epoch == mediaEpoch { isRelinkingProxy = false; proxyRelinkTask = nil }
            }
            do {
                try await relinkProxy(for: expected, to: url, epoch: epoch, sourceRevision: revision)
            } catch {
                if !Task.isCancelled, epoch == mediaEpoch { errorMessage = audioEditErrorMessage(error) }
            }
        }
    }

    /// Only the proxy URL and its sandbox grant change; source identities and timeline coordinates stay intact.
    func relinkProxy(for expected: MediaAsset, to url: URL, epoch: UUID, sourceRevision: UUID?) async throws {
        guard let proxy = expected.proxy, let originalURL = expected.originalURL else {
            throw EditorCoreError.invalidModel("Create a proxy before relinking it.")
        }
        let scoped = [url, originalURL].filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard try ProxyGenerationService.fingerprint(for: originalURL) == proxy.sourceFingerprint else {
            throw EditorCoreError.invalidModel("The original source changed. Create a new proxy before relinking.")
        }
        _ = try await ProxyGenerationService.validateProxyFile(proxy, at: url)
        try Task.checkCancellation()
        guard epoch == mediaEpoch, sourceRevisions[expected.id] == sourceRevision,
              project.assets.first(where: { $0.id == expected.id }) == expected,
              try ProxyGenerationService.fingerprint(for: originalURL) == proxy.sourceFingerprint else {
            throw EditorCoreError.invalidModel("The source or proxy changed while relinking. The existing proxy reference was preserved.")
        }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var replacement = proxy
        replacement.url = url
        try change(proxyBookmarkUpdates: [expected.id: bookmark]) { project in
            guard let index = project.assets.firstIndex(where: { $0.id == expected.id }) else { return }
            project.assets[index].proxy = replacement
        }
        holdAccess(url)
        if selectedAssetID == expected.id { refreshSourcePreview(preservingTransport: true) }
        statusMessage = "Relinked proxy for \(expected.name)."
    }

    func resolveProxyBookmarks() {
        for index in project.assets.indices {
            let id = project.assets[index].id
            guard let bookmark = proxyBookmarks[id], project.assets[index].proxy != nil else { continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                holdAccess(url)
                project.assets[index].proxy?.url = url
                if stale { proxyBookmarks[id] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
            } catch { statusMessage = "Some proxies are unavailable. Playback falls back to originals." }
        }
    }

    func registerProxy(_ proxy: MediaProxy, for expected: MediaAsset, epoch: UUID, sourceRevision: UUID?) throws {
        guard epoch == mediaEpoch, sourceRevisions[expected.id] == sourceRevision,
              let current = project.assets.first(where: { $0.id == expected.id }),
              current.originalURL == expected.originalURL, current.streams == expected.streams,
              current.duration == expected.duration,
              let originalURL = current.originalURL,
              try ProxyGenerationService.fingerprint(for: originalURL) == proxy.sourceFingerprint else {
            throw EditorCoreError.invalidModel("The source changed while creating its proxy. The existing proxy reference was preserved.")
        }
        holdAccess(proxy.url)
        let bookmark = try proxy.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try change(proxyBookmarkUpdates: [expected.id: bookmark]) { project in
            guard let index = project.assets.firstIndex(where: { $0.id == expected.id }) else { return }
            project.assets[index].proxy = proxy
        }
        if selectedAssetID == expected.id { refreshSourcePreview(preservingTransport: true) }
    }

    func setPlaybackRepresentation(_ representation: PlaybackRepresentation) {
        guard representation != playbackRepresentation else { return }
        playbackRepresentation = representation
        refreshSourcePreview(preservingTransport: true)
    }

    func refreshSourcePreview(preservingTransport: Bool = false) {
        let time = preservingTransport ? pendingSourceTransport?.time ?? sourcePlayer?.currentTime() ?? .zero : .zero
        let playing = preservingTransport && (pendingSourceTransport?.playing ?? ((sourcePlayer?.rate ?? 0) > 0))
        sourcePreviewTask?.cancel()
        pauseSource()
        pendingSourceTransport = preservingTransport ? (time, playing) : nil
        sourcePlayer = nil; previewImage = nil
        guard let asset = selectedAsset, let originalURL = asset.originalURL else { pendingSourceTransport = nil; return }
        holdAccess(originalURL)
        guard FileManager.default.isReadableFile(atPath: originalURL.path) else {
            proxyPlaybackMessage = "Original media missing"
            statusMessage = "Missing media: \(asset.name). Choose Relink in the inspector."
            pendingSourceTransport = nil
            return
        }
        if asset.streams.isEmpty {
            pendingSourceTransport = nil
            previewImage = NSImage(contentsOf: originalURL)
            proxyPlaybackMessage = "Original still image"
            return
        }
        if let url = asset.proxy?.url { holdAccess(url) }
        let fingerprint = try? ProxyGenerationService.fingerprint(for: originalURL)
        let proxyExists = asset.proxy.map { FileManager.default.isReadableFile(atPath: $0.url.path) } ?? false
        if let proxy = asset.proxy, proxy.outputIntegrity != nil, proxyExists, fingerprint == proxy.sourceFingerprint, playbackRepresentation == .proxy {
            let representation = playbackRepresentation
            let epoch = mediaEpoch
            pendingSourceTransport = (time, playing)
            proxyPlaybackMessage = "Verifying proxy…"
            sourcePreviewTask = Task {
                let matches = (try? await ProxyGenerationService.validateProxyFile(proxy)) != nil
                guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset,
                      representation == playbackRepresentation else { return }
                let resolution = asset.resolvePlayback(representation: representation, sourceFingerprint: try? ProxyGenerationService.fingerprint(for: originalURL),
                    proxyExists: proxyExists, proxyIntegrityMatches: matches)
                installSourcePreview(asset: asset, originalURL: originalURL, resolution: resolution,
                    time: time, playing: playing, preservingTransport: preservingTransport)
            }
            return
        }
        let resolution = asset.resolvePlayback(representation: playbackRepresentation, sourceFingerprint: fingerprint, proxyExists: proxyExists)
        installSourcePreview(asset: asset, originalURL: originalURL, resolution: resolution,
            time: time, playing: playing, preservingTransport: preservingTransport)
    }

    private func installSourcePreview(asset: MediaAsset, originalURL: URL, resolution: ProxyPlaybackResolution,
                                      time: CMTime, playing: Bool, preservingTransport: Bool) {
        switch resolution.status {
        case .original: proxyPlaybackMessage = "Original source"
        case .available: proxyPlaybackMessage = "Proxy picture · original audio"
        case .modified: proxyPlaybackMessage = "Proxy modified · using original"
        case .missing: proxyPlaybackMessage = "Proxy missing · using original"
        case .stale: proxyPlaybackMessage = "Proxy stale · using original"
        case .unavailable: proxyPlaybackMessage = "No usable proxy · using original"
        }
        let representation = playbackRepresentation
        let epoch = mediaEpoch
        if !resolution.usesProxy {
            let player = AVPlayer(url: originalURL)
            sourcePlayer = player
            statusMessage = "Source preview: \(asset.name)"
            if pendingSourceTransport != nil || preservingTransport {
                sourcePreviewTask = Task {
                    await player.seek(to: pendingSourceTransport?.time ?? time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
                    if pendingSourceTransport?.playing ?? playing { player.play() }
                    pendingSourceTransport = nil
                }
            }
            return
        }
        if pendingSourceTransport == nil { pendingSourceTransport = (time, playing) }
        sourcePreviewTask = Task {
            var player: AVPlayer
            if resolution.usesProxy, let proxyURL = resolution.url {
                do {
                    let composition = AVMutableComposition()
                    let proxy = AVURLAsset(url: proxyURL)
                    let original = AVURLAsset(url: originalURL)
                    guard let picture = try await proxy.loadTracks(withMediaType: .video).first,
                          let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw EditorCoreError.invalidModel("Proxy picture unavailable.")
                    }
                    // Use the track's exact time base rather than rounding a rational
                    // frame duration to a fixed CMTime scale.
                    let range = try await picture.load(.timeRange)
                    try video.insertTimeRange(range, of: picture, at: .zero)
                    // The generated proxy keeps the unrotated source raster. Preserve the
                    // original display transform instead of the proxy container metadata.
                    guard let sourcePicture = try await original.loadTracks(withMediaType: .video).first else {
                        throw EditorCoreError.invalidModel("Original picture unavailable.")
                    }
                    var transform = try await sourcePicture.load(.preferredTransform)
                    let sourceSize = try await sourcePicture.load(.naturalSize)
                    if let proxy = asset.proxy, sourceSize.width > 0 {
                        let scale = CGFloat(proxy.width) / sourceSize.width
                        transform.tx *= scale; transform.ty *= scale
                    }
                    video.preferredTransform = transform
                    for sourceAudio in try await original.loadTracks(withMediaType: .audio) {
                        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                            throw EditorCoreError.invalidModel("Original audio unavailable.")
                        }
                        let audioRange = try await sourceAudio.load(.timeRange)
                        let end = audioRange.end
                        if end > audioRange.start {
                            try audio.insertTimeRange(CMTimeRange(start: audioRange.start, end: end), of: sourceAudio, at: audioRange.start)
                        }
                    }
                    player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
                } catch {
                    player = AVPlayer(url: originalURL)
                    if !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation {
                        proxyPlaybackMessage = "Proxy preview unavailable · using original picture and audio"
                    }
                }
            } else { player = AVPlayer(url: originalURL) }
            guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
            await player.seek(to: pendingSourceTransport?.time ?? time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
            sourcePlayer = player
            if pendingSourceTransport?.playing ?? playing { player.play() }
            pendingSourceTransport = nil
            statusMessage = "Source preview: \(asset.name)"
        }
    }
}
