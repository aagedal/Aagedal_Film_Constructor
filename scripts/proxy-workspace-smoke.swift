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
        let audioStreams = imported.asset.streams.filter { $0.kind == .audio }
        try check(audioStreams.map { $0.audioLayout?.channels.count } == [1, 2], "Distinct mono and stereo layouts imported")
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
        let original = AVURLAsset(url: source)
        let originalAudios = try await original.loadTracks(withMediaType: .audio)
        let delayedSegments = try await originalAudios[1].load(.segments).filter { !$0.isEmpty }
        try check(delayedSegments.first?.timeMapping.target.start == CMTime(value: 1, timescale: 4),
                  "Original stereo fixture has a quarter-second delayed nonempty edit")
        for (audio, originalAudio) in zip(audios, originalAudios) {
            let originalRange = try await originalAudio.load(.timeRange)
            try check(try await audio.load(.timeRange) == originalRange, "Composition preserves exact original audio extent and offset")
            let segments = audio.segments.filter { !$0.isEmpty }
            // Composition segments reference original asset coordinates, whose
            // edit list contains the delayed samples; their source range is not
            // the source track's sample-media mapping.
            try check(segments.count == 1 && segments[0].timeMapping.source == originalRange && segments[0].timeMapping.target == originalRange,
                      "Composition preserves exact audio asset-to-monitor mapping")
            let descriptions = try await audio.load(.formatDescriptions)
            let originals = try await originalAudio.load(.formatDescriptions)
            try check(descriptions.first.map { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
                      == originals.first.map { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame },
                      "Composition preserves original mono/stereo channel count")
            guard let description = originals.first, let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                throw SmokeError.failed("Original audio format unavailable")
            }
            let sourceSamples = try decodedAudio(asset: original, track: originalAudio, format: format.pointee, end: originalRange.end)
            let proxySamples = try decodedAudio(asset: composition, track: audio, format: format.pointee, end: originalRange.end)
            try check(sourceSamples == proxySamples, "Native composition retains exact original PCM samples and timestamps")
        }
        try await verifyPictures(original: original, proxyComposition: composition, size: CGSize(width: proxy.width, height: proxy.height))
        reopened.setPlaybackRepresentation(.original)
        _ = try await awaitPlayer(reopened)
        try check(abs(reopened.sourcePlayer!.currentTime().seconds - 0.75) < 0.02, "Hires switch preserves position")
        let tailPosition = CMTime(value: 11, timescale: 4)
        await reopened.sourcePlayer?.seek(to: tailPosition, toleranceBefore: .zero, toleranceAfter: .zero)
        reopened.setPlaybackRepresentation(.proxy)
        let audioTail = try await awaitPlayer(reopened)
        try check(abs(audioTail.currentTime().seconds - tailPosition.seconds) < 0.02,
                  "Proxy switching preserves nonzero position beyond proxy picture in original audio tail")
        reopened.setPlaybackRepresentation(.original)
        let originalTail = try await awaitPlayer(reopened)
        try check(abs(originalTail.currentTime().seconds - tailPosition.seconds) < 0.02,
                  "Hires switching preserves original audio-tail position")
        await originalTail.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
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
        reopened.setPlaybackRepresentation(.proxy)
        try check(reopened.sourcePlayer == nil && reopened.canControlSourceTransport, "Loading proxy keeps forward/pause transport available")
        reopened.playSourceForwards()
        try check(reopened.pendingSourceTransport?.playing == true, "Forward during verification records play intent")
        reopened.pauseSource()
        try check(reopened.pendingSourceTransport?.playing == false, "Pause during verification clears play intent")
        let pausedAfterVerification = try await awaitPlayer(reopened)
        try check(pausedAfterVerification.rate == 0, "Pause during verification prevents auto-resume")
        reopened.setPlaybackRepresentation(.original)
        _ = try await awaitPlayer(reopened)
        reopened.setPlaybackRepresentation(.proxy)
        reopened.playSourceForwards()
        let resumedAfterVerification = try await awaitPlayer(reopened)
        try check(resumedAfterVerification.rate > 0, "Forward during verification resumes playback")
        reopened.pauseSource()
        // Removing selected media cancels pending preview work and transport intent.
        let removed = EditorStore()
        try removed.registerImportedMedia(imported)
        let pending = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(60)) } catch { }
        }
        removed.sourcePreviewTask = pending
        removed.pendingSourceTransport = (position, true)
        removed.undo()
        try check(pending.isCancelled && removed.sourcePreviewTask == nil && removed.pendingSourceTransport == nil,
                  "Undo removing selected media cancels pending seeks and playback intent")
        try check(removed.sourcePlayer == nil && removed.selectedAssetIDs.isEmpty,
                  "Undo removing selected media clears player and bin selection")
        removed.close()
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
        print("Proxy workspace smoke passed: native decoded picture geometry/frame correspondence, original mono/stereo audio offsets, switching, persistence, relink validation and undo, fallback, and stale registration")
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

    /// Capture through the native source-monitor composition, rather than testing
    /// only FFmpeg's generated file. Motion plus asymmetric spatial color detects
    /// a wrong frame, flip, crop, or changed display geometry after save/reopen.
    private static func verifyPictures(original: AVAsset, proxyComposition: AVAsset, size: CGSize) async throws {
        let hires = AVAssetImageGenerator(asset: original)
        let proxy = AVAssetImageGenerator(asset: proxyComposition)
        for generator in [hires, proxy] {
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for frame in [0, 7, 18, 35, 47] {
            let time = CMTime(value: Int64(frame), timescale: 24)
            let a = try await hires.image(at: time)
            let b = try await proxy.image(at: time)
            try check(a.actualTime == time && b.actualTime == time, "Native monitor captures corresponding exact frame \(frame)")
            try check(a.image.width == Int(size.width) && a.image.height == Int(size.height)
                      && b.image.width == a.image.width && b.image.height == a.image.height,
                      "Native monitor preserves scaled display raster")
            let lhs = try pixels(a.image), rhs = try pixels(b.image)
            var squaredError = 0.0
            for index in lhs.indices where index % 4 != 3 {
                let difference = Double(lhs[index]) - Double(rhs[index])
                squaredError += difference * difference
            }
            let mse = squaredError / Double(a.image.width * a.image.height * 3)
            let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
            try check(psnr > 28, "Native monitor geometry/frame correspondence at frame \(frame): PSNR \(psnr)")
        }
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try check(success, "Capture pixels readable")
        return data
    }

    private static func decodedAudio(asset: AVAsset, track: AVAssetTrack, format: AudioStreamBasicDescription, end: CMTime) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try check(reader.startReading(), "Native audio decoding starts")
        // Readers may choose different chunk boundaries and synthesize silence
        // for empty edits. Compare samples at their absolute monitor timestamps.
        let channels = Int(format.mChannelsPerFrame)
        var samples = [Float](repeating: 0, count: Int((end.seconds * format.mSampleRate).rounded()) * channels)
        var decodedCount = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw SmokeError.failed("Decoded audio has no sample buffer") }
            let count = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: count)
            let result = bytes.withUnsafeMutableBytes { storage in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: storage.baseAddress!)
            }
            try check(result == kCMBlockBufferNoErr, "Native audio samples readable")
            let decoded = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let start = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * format.mSampleRate).rounded()) * channels
            try check(start >= 0 && start + decoded.count <= samples.count, "Decoded audio fits original extent")
            samples.replaceSubrange(start..<(start + decoded.count), with: decoded)
            decodedCount += decoded.count
        }
        try check(reader.status == .completed && decodedCount > 0, "Native audio decoding completes")
        return samples
    }
}
