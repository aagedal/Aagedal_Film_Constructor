import AVFoundation
import AppKit
import EditorCore
import ImageIO
#if canImport(NativePlaybackRuntime)
import NativePlaybackRuntime
#endif

/// Requests include the source range and channel map, so trims and zoom never reuse stale imagery.
nonisolated struct TimelinePreviewRequest: Hashable, Sendable {
    let url: URL
    let selection: ClipSelection
    let start: Double
    let duration: Double
    let thumbnailCount: Int
    let waveformBins: Int
    let revision: UUID?

    init(url: URL, selection: ClipSelection, start: Double, duration: Double, thumbnailCount: Int, waveformBins: Int, revision: UUID? = nil) {
        self.url = url
        self.revision = revision
        self.selection = selection
        self.start = start
        self.duration = duration
        self.thumbnailCount = min(12, max(1, thumbnailCount))
        self.waveformBins = min(512, max(1, waveformBins))
    }
}

nonisolated private struct TimelinePreviewCacheKey: Hashable, Sendable {
    let request: TimelinePreviewRequest
    let modificationDate: Date?
    let fileSize: Int?
}

nonisolated enum TimelinePreviewError: Error {
    case invalidRequest, queueFull
}

nonisolated struct TimelinePreview: Sendable {
    var images: [CGImage] = []
    var peaks: [[Float]] = []
    var byteCost: Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } + peaks.reduce(0) { $0 + $1.count * 4 } }
}

/// Two admitted media jobs, twelve FIFO waiters, and a 24 MB LRU bound timeline work.
actor TimelinePreviewService {
    static let shared = TimelinePreviewService()
    private var cache: [TimelinePreviewCacheKey: TimelinePreview] = [:]
    private var recency: [TimelinePreviewCacheKey] = []
    private var activeDecoders = 0
    private struct WaitingRequest {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waitingRequests: [WaitingRequest] = []
    private let maximumCacheBytes: Int
    private let maximumCacheEntries: Int
    private var cacheBytes = 0

    init(maximumCacheBytes: Int = 24 * 1_024 * 1_024, maximumCacheEntries: Int = 32) {
        self.maximumCacheBytes = max(0, maximumCacheBytes)
        self.maximumCacheEntries = max(0, maximumCacheEntries)
    }

    func preview(for request: TimelinePreviewRequest) async throws -> TimelinePreview {
        try Task.checkCancellation()
        guard request.start.isFinite, request.start >= 0, request.duration.isFinite, request.duration > 0 else {
            throw TimelinePreviewError.invalidRequest
        }
        if case .audio(let selection) = request.selection {
            guard (1...64).contains(selection.channels.count), selection.channels.allSatisfy({ $0.streamIndex >= 0 && $0.channelIndex >= 0 }) else {
                throw TimelinePreviewError.invalidRequest
            }
        }
        // Admission includes filesystem fingerprinting: even cache lookups cannot fan
        // out unbounded metadata work while a large timeline becomes visible.
        try await acquireAdmission()
        defer { releaseAdmission() }
        try Task.checkCancellation()
        let key = await Self.cacheKey(for: request)
        try Task.checkCancellation()
        if let value = cached(key) { return value }
        let value: TimelinePreview
        do {
            value = try await Self.decode(request)
        } catch {
            // AVFoundation can report its own reader/generator error when cancelled.
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        if let replaced = cache.updateValue(value, forKey: key) { cacheBytes -= replaced.byteCost }
        recency.removeAll { $0 == key }
        recency.append(key)
        cacheBytes += value.byteCost
        while cacheBytes > maximumCacheBytes || recency.count > maximumCacheEntries {
            let oldest = recency.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.byteCost }
        }
        return value
    }

    private func acquireAdmission() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeDecoders < 2 {
                    activeDecoders += 1
                    continuation.resume()
                } else if waitingRequests.count < 12 {
                    waitingRequests.append(WaitingRequest(id: id, continuation: continuation))
                } else {
                    continuation.resume(throwing: TimelinePreviewError.queueFull)
                }
            }
        } onCancel: {
            Task { await self.cancelAdmission(id) }
        }
    }

    private func cancelAdmission(_ id: UUID) {
        guard let index = waitingRequests.firstIndex(where: { $0.id == id }) else { return }
        waitingRequests.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseAdmission() {
        if waitingRequests.isEmpty {
            activeDecoders -= 1
        } else {
            // Transfer the occupied slot directly to the oldest queued request.
            waitingRequests.removeFirst().continuation.resume()
        }
    }

    private func cached(_ request: TimelinePreviewCacheKey) -> TimelinePreview? {
        guard let value = cache[request] else { return nil }
        recency.removeAll { $0 == request }
        recency.append(request)
        return value
    }

    @concurrent
    private static func cacheKey(for request: TimelinePreviewRequest) async -> TimelinePreviewCacheKey {
        let scoped = request.url.startAccessingSecurityScopedResource()
        defer { if scoped { request.url.stopAccessingSecurityScopedResource() } }
        var url = request.url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return TimelinePreviewCacheKey(request: request, modificationDate: values?.contentModificationDate, fileSize: values?.fileSize)
    }

    // Exposes resource accounting to the generated-media smoke check.
    func resourceUsage() -> (active: Int, pending: Int, entries: Int, bytes: Int) {
        (activeDecoders, waitingRequests.count, cache.count, cacheBytes)
    }

    @concurrent
    private static func decode(_ request: TimelinePreviewRequest) async throws -> TimelinePreview {
        let scoped = request.url.startAccessingSecurityScopedResource()
        defer { if scoped { request.url.stopAccessingSecurityScopedResource() } }
        switch request.selection {
        case .still:
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 180,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return TimelinePreview() }
            return TimelinePreview(images: [image])
        case .video(let streamIndex):
            let asset = AVURLAsset(url: request.url)
            #if canImport(NativePlaybackRuntime)
            // Originals imported unconverted through FFmpeg (FFmpeg stream indices), or movies
            // AVFoundation reads but cannot decode, whose track order FFmpeg shares.
            if !((try? await asset.load(.isPlayable)) ?? false) {
                let times = (0..<request.thumbnailCount).map { request.start + request.duration * (Double($0) + 0.5) / Double(request.thumbnailCount) }
                return TimelinePreview(images: try NativeMediaPreview.thumbnails(url: request.url, streamIndex: streamIndex, times: times,
                                                                                  maximumWidth: 180, maximumHeight: 100))
            }
            #endif
            let tracks = try await asset.load(.tracks)
            guard tracks.indices.contains(streamIndex), tracks[streamIndex].mediaType == .video else { return TimelinePreview() }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return TimelinePreview() }
            let sourceTrack = tracks[streamIndex]
            let range = CMTimeRange(start: CMTime(seconds: request.start, preferredTimescale: 60_000), duration: CMTime(seconds: request.duration, preferredTimescale: 60_000))
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            track.preferredTransform = try await sourceTrack.load(.preferredTransform)
            let generator = AVAssetImageGenerator(asset: composition)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 100)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            defer { generator.cancelAllCGImageGeneration() }
            return try await withTaskCancellationHandler {
                var images: [CGImage] = []
                for index in 0..<request.thumbnailCount {
                    try Task.checkCancellation()
                    let seconds = request.duration * (Double(index) + 0.5) / Double(request.thumbnailCount)
                    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000)).image
                    images.append(image)
                }
                return TimelinePreview(images: images)
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
        case .audio(let selection):
            let asset = AVURLAsset(url: request.url)
            var peaks = Array(repeating: Array(repeating: Float(0), count: request.waveformBins), count: selection.channels.count)
            #if canImport(NativePlaybackRuntime)
            if !((try? await asset.load(.isReadable)) ?? false) {
                for streamIndex in Set(selection.channels.map(\.streamIndex)).sorted() {
                    try Task.checkCancellation()
                    let channelMap = selection.channels.enumerated().filter { $0.element.streamIndex == streamIndex }
                    let streamPeaks = try NativeMediaPreview.peaks(url: request.url, streamIndex: streamIndex,
                        channels: channelMap.map(\.element.channelIndex), start: request.start,
                        duration: request.duration, bins: request.waveformBins)
                    for (position, channel) in channelMap.enumerated() { peaks[channel.offset] = streamPeaks[position] }
                }
                return TimelinePreview(peaks: peaks)
            }
            #endif
            let tracks = try await asset.load(.tracks)
            for streamIndex in Set(selection.channels.map(\.streamIndex)).sorted() {
                try Task.checkCancellation()
                guard tracks.indices.contains(streamIndex), tracks[streamIndex].mediaType == .audio else { continue }
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: request.start, preferredTimescale: 60_000), duration: CMTime(seconds: request.duration, preferredTimescale: 60_000))
                // Channel indices follow FFmpeg's order, which compressed 5.1 must be decoded into.
                let order = try await tracks[streamIndex].load(.formatDescriptions).first.map(SourceChannelOrder.readerSettings) ?? [:]
                let output = AVAssetReaderTrackOutput(track: tracks[streamIndex], outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ].merging(order) { _, new in new })
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { continue }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
                defer { reader.cancelReading() }
                let channelMap = selection.channels.enumerated().filter { $0.element.streamIndex == streamIndex }
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let description = CMSampleBufferGetFormatDescription(sample),
                          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                          let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let channels = Int(format.pointee.mChannelsPerFrame)
                    let rate = format.pointee.mSampleRate
                    guard channels > 0, rate.isFinite, rate > 0 else { continue }
                    let byteCount = CMBlockBufferGetDataLength(block)
                    guard byteCount >= MemoryLayout<Float>.size, byteCount.isMultiple(of: MemoryLayout<Float>.size) else { continue }
                    // Copy only this decoder buffer; never retain PCM for the entire clip.
                    var samples = Array(repeating: Float(0), count: byteCount / MemoryLayout<Float>.size)
                    let copied = samples.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: bytes.baseAddress!)
                    }
                    guard copied == kCMBlockBufferNoErr else { continue }
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard timestamp.isFinite else { continue }
                    for frame in 0..<(samples.count / channels) {
                        let relative = timestamp + Double(frame) / rate - request.start
                        guard relative >= 0, relative < request.duration else { continue }
                        let bin = min(request.waveformBins - 1, Int(relative / request.duration * Double(request.waveformBins)))
                        for (destination, channel) in channelMap where channel.channelIndex < channels {
                            let amplitude = abs(samples[frame * channels + channel.channelIndex])
                            if amplitude.isFinite { peaks[destination][bin] = max(peaks[destination][bin], min(1, amplitude)) }
                        }
                    }
                }
                if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
            }
            return TimelinePreview(peaks: peaks)
        }
    }
}
