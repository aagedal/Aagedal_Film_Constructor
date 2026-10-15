import AppKit
import AVFoundation
import EditorCore

struct ProxyCreationDraft: Identifiable {
    let id = UUID()
    let assets: [MediaAsset]
}

extension EditorStore {
    /// Sequence playback always needs original picture/audio access. Proxy checks
    /// are transient playback choices and never rewrite the project's media records.
    @MainActor static func resolveSequenceProxies(project: Project, representation: PlaybackRepresentation) async throws -> SequenceProxySelection {
        try Task.checkCancellation()
        guard representation == .proxy else { return SequenceProxySelection() }
        let clips = project.tracks.flatMap(\.clips)
        let usedIDs = Set(clips.map(\.assetID))
        let assets = project.assets.filter { usedIDs.contains($0.id) }
        var scopedURLs: [URL] = []
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        for asset in assets {
            if let url = asset.originalURL, url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        }
        let videoClips = Dictionary(grouping: clips.filter { if case .video = $0.selection { return true }; return false }, by: \.assetID)
        var selected: [UUID: MediaProxy] = [:]
        var fallbacks: [String: Int] = [:]
        func fallback(_ reason: String) { fallbacks[reason, default: 0] += 1 }
        // One integrity read at a time bounds I/O and memory, and each iteration
        // observes cancellation before starting the next potentially large file.
        for asset in assets {
            guard let uses = videoClips[asset.id] else { continue }
            try Task.checkCancellation()
            guard let source = asset.originalURL, FileManager.default.isReadableFile(atPath: source.path) else {
                fallback("original unavailable"); continue
            }
            guard let proxy = asset.proxy else { fallback("unavailable"); continue }
            guard proxy.outputIntegrity != nil else { fallback("unverified"); continue }
            if proxy.url.startAccessingSecurityScopedResource() { scopedURLs.append(proxy.url) }
            guard FileManager.default.isReadableFile(atPath: proxy.url.path) else { fallback("missing"); continue }
            guard let before = try? ProxyGenerationService.fingerprint(for: source), before == proxy.sourceFingerprint else {
                fallback("stale"); continue
            }
            // Qualification uses original stream metadata and coordinates; a
            // verified file alone cannot establish a clip's stream or cadence.
            let qualified: Bool
            do {
                try proxy.validate()
                qualified = try uses.allSatisfy { clip in
                    guard case .video(let index) = clip.selection,
                          index == proxy.videoStreamIndex,
                          let stream = asset.streams.first(where: { $0.kind == .video && $0.index == index }),
                          let format = stream.videoFormat, format.frameRate.value == proxy.frameRate,
                          proxy.frameRate == project.settings.frameRate.value,
                          format.width <= 4096, format.height <= 4096,
                          proxy.width <= 4096, proxy.height <= 4096,
                          Int64(format.width) * Int64(proxy.height) == Int64(format.height) * Int64(proxy.width) else { return false }
                    let endFrame = try clip.sourceRange.end().multiplied(by: proxy.frameRate)
                    return endFrame.denominator == 1 && endFrame.numerator <= proxy.frameCount
                }
            } catch { qualified = false }
            guard qualified else { fallback("unqualified"); continue }
            do {
                _ = try await ProxyGenerationService.validateProxyFile(proxy)
                try Task.checkCancellation()
                guard try ProxyGenerationService.fingerprint(for: source) == before else { fallback("stale"); continue }
                selected[asset.id] = proxy
            } catch {
                try Task.checkCancellation()
                fallback("modified or unreadable")
            }
        }
        try Task.checkCancellation()
        // An original disappearing during another asset's verification cannot
        // turn the sequence into silent, proxy-only playback.
        for asset in assets where selected[asset.id] != nil {
            guard let source = asset.originalURL, FileManager.default.isReadableFile(atPath: source.path),
                  let proxy = selected[asset.id], (try? ProxyGenerationService.fingerprint(for: source)) == proxy.sourceFingerprint else {
                selected[asset.id] = nil
                fallback("original unavailable or changed")
                continue
            }
        }
        let picture = selected.isEmpty ? "original media" : "proxy picture · original audio"
        let reasons = fallbacks.keys.sorted().map { "\(fallbacks[$0]!) \($0)" }.joined(separator: ", ")
        let fallbackMessage = reasons.isEmpty ? "" : " · using originals for \(reasons) proxy assets"
        return SequenceProxySelection(videoProxies: selected,
            message: "Native sequence · \(picture)\(fallbackMessage) · development output")
    }

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
        let time = preservingTransport ? pendingSourceTransport?.time ?? sourcePlayback?.currentTime ?? .zero : .zero
        let playing = preservingTransport && (pendingSourceTransport?.playing ?? (sourcePlayback?.isPlaying ?? false))
        sourcePreviewTask?.cancel()
        pauseSource()
        pendingSourceTransport = preservingTransport ? (time, playing) : nil
        sourcePlayback = nil; previewImage = nil
        guard let asset = selectedAsset, let originalURL = asset.originalURL else { pendingSourceTransport = nil; return }
        holdAccess(originalURL)
        let originalExists = FileManager.default.isReadableFile(atPath: originalURL.path)
        if asset.streams.isEmpty {
            guard originalExists else {
                proxyPlaybackMessage = "HiRes still image missing"
                statusMessage = "Missing media: \(asset.name). Choose Relink in the inspector."
                pendingSourceTransport = nil
                return
            }
            pendingSourceTransport = nil
            proxyPlaybackMessage = "Loading still image…"
            let epoch = mediaEpoch
            sourcePreviewTask = Task {
                do {
                    let image = try await MediaImporter.stillPreview(url: originalURL)
                    guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset else { return }
                    previewImage = NSImage(cgImage: image, size: .zero)
                    proxyPlaybackMessage = "Original still image"
                    statusMessage = "Source preview: \(asset.name)"
                } catch {
                    guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset else { return }
                    proxyPlaybackMessage = "Still preview unavailable"
                    statusMessage = "Cannot preview \(asset.name): \(error.localizedDescription)"
                }
            }
            return
        }
        if let url = asset.proxy?.url { holdAccess(url) }
        let fingerprint = originalExists ? try? ProxyGenerationService.fingerprint(for: originalURL) : nil
        let proxyExists = asset.proxy.map { FileManager.default.isReadableFile(atPath: $0.url.path) } ?? false
        if let proxy = asset.proxy, proxy.outputIntegrity != nil, proxyExists,
           (originalExists ? fingerprint == proxy.sourceFingerprint : true) {
            let representation = playbackRepresentation
            let epoch = mediaEpoch
            pendingSourceTransport = (time, playing)
            proxyPlaybackMessage = "Verifying proxy…"
            sourcePreviewTask = Task {
                // A readable source can still use a codec unsupported by AVFoundation.
                // Probe only when a verified generated proxy could be a useful fallback.
                let originalPlayable = originalExists
                    ? (try? await AVURLAsset(url: originalURL).load(.isPlayable)) ?? false : false
                guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset,
                      representation == playbackRepresentation else { return }
                let matches = representation == .original && originalPlayable
                    ? false : (try? await ProxyGenerationService.validateProxyFile(proxy)) != nil
                guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset,
                      representation == playbackRepresentation else { return }
                let resolution = asset.resolvePlayback(representation: representation, sourceFingerprint: try? ProxyGenerationService.fingerprint(for: originalURL),
                    proxyExists: FileManager.default.isReadableFile(atPath: proxy.url.path), proxyIntegrityMatches: matches,
                    originalExists: originalPlayable && FileManager.default.isReadableFile(atPath: originalURL.path))
                installSourcePreview(asset: asset, originalURL: originalURL, resolution: resolution,
                    time: time, playing: playing, preservingTransport: preservingTransport)
            }
            return
        }
        let resolution = asset.resolvePlayback(representation: playbackRepresentation, sourceFingerprint: fingerprint, proxyExists: proxyExists, originalExists: originalExists)
        installSourcePreview(asset: asset, originalURL: originalURL, resolution: resolution,
            time: time, playing: playing, preservingTransport: preservingTransport)
    }

    private func installSourcePreview(asset: MediaAsset, originalURL: URL, resolution: ProxyPlaybackResolution,
                                      time: CMTime, playing: Bool, preservingTransport: Bool) {
        guard let playbackURL = resolution.url else {
            proxyPlaybackMessage = "HiRes unavailable · no verified proxy available"
            statusMessage = "Missing media: \(asset.name). Choose Relink in the inspector."
            pendingSourceTransport = nil
            return
        }
        switch resolution.status {
        case .original: proxyPlaybackMessage = "HiRes source"
        case .originalUnavailable: proxyPlaybackMessage = "HiRes unavailable · proxy picture · original audio unavailable"
        case .available: proxyPlaybackMessage = "Proxy picture · original audio"
        case .modified: proxyPlaybackMessage = "Proxy modified · using original"
        case .missing: proxyPlaybackMessage = "Proxy missing · using original"
        case .stale: proxyPlaybackMessage = "Proxy stale · using original"
        case .unavailable: proxyPlaybackMessage = "No usable proxy · using original"
        }
        let representation = playbackRepresentation
        let epoch = mediaEpoch
        if !resolution.usesProxy {
            let player = AVFoundationSourceBackend(player: AVPlayer(url: playbackURL))
            sourcePlayback = player
            statusMessage = "Source preview: \(asset.name)"
            if pendingSourceTransport != nil || preservingTransport {
                restoreSourceTransport(backend: player, time: time, playing: playing)
            }
            return
        }
        if pendingSourceTransport == nil { pendingSourceTransport = (time, playing) }
        if resolution.status == .originalUnavailable, let proxy = asset.proxy,
           let pictureDuration = try? RationalTime(proxy.frameCount).divided(by: proxy.frameRate),
           (pendingSourceTransport?.time ?? time).seconds >= pictureDuration.seconds {
            // AVFoundation discards trailing empty video segments. Keep the source
            // coordinate rather than silently clamping an original audio-tail seek.
            proxyPlaybackMessage = "HiRes unavailable · outside proxy picture · original audio unavailable"
            statusMessage = "Source position preserved. Relink HiRes media to preview this audio tail."
            return
        }
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
                    // Verified generated proxies are unrotated square-pixel media,
                    // so offline picture needs no source transform or guessed audio.
                    if resolution.status != .originalUnavailable {
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
                    }
                    player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
                } catch {
                    guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
                    guard resolution.status != .originalUnavailable,
                          FileManager.default.isReadableFile(atPath: originalURL.path) else {
                        proxyPlaybackMessage = "HiRes unavailable · proxy preview unavailable · original audio unavailable"
                        statusMessage = "Cannot preview \(asset.name). Relink original media or regenerate its proxy."
                        pendingSourceTransport = nil
                        return
                    }
                    player = AVPlayer(url: originalURL)
                    if !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation {
                        proxyPlaybackMessage = "Proxy preview unavailable · using original picture and audio"
                    }
                }
            } else { player = AVPlayer(url: originalURL) }
            guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
            let backend = AVFoundationSourceBackend(player: player)
            do {
                try await backend.seek(to: pendingSourceTransport?.time ?? time)
            } catch {
                backend.close()
                guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else { return }
                reportSourceSeekFailure(error)
                return
            }
            guard !Task.isCancelled, epoch == mediaEpoch, selectedAsset == asset, representation == playbackRepresentation else {
                backend.close()
                return
            }
            sourcePlayback = backend
            if pendingSourceTransport?.playing ?? playing { backend.play() }
            pendingSourceTransport = nil
            statusMessage = "Source preview: \(asset.name)"
        }
    }
}
