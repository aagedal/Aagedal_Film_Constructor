import AppKit
import AVFoundation
import EditorCore

enum PreviewSmokeError: Error { case failed(String) }

@main
struct TimelinePreviewSmoke {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PreviewSmokeError.failed(message) }
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let audioURL = directory.appendingPathComponent("stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for frame in 0..<96_000 {
            let wave = Float(sin(Double(frame) * 2 * .pi * 200 / 48_000))
            buffer.floatChannelData![0][frame] = wave * (frame < 48_000 ? 0.8 : 0.1)
            buffer.floatChannelData![1][frame] = wave * (frame < 48_000 ? 0.1 : 0.8)
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let map = AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 1), SourceChannel(streamIndex: 0, channelIndex: 0)], layout: .stereo)
        let first = TimelinePreviewRequest(url: audioURL, selection: .audio(map), start: 0, duration: 0.8, thumbnailCount: 1, waveformBins: 32)
        let second = TimelinePreviewRequest(url: audioURL, selection: .audio(map), start: 1.1, duration: 0.8, thumbnailCount: 1, waveformBins: 32)
        let a = try await TimelinePreviewService.shared.preview(for: first)
        let b = try await TimelinePreviewService.shared.preview(for: second)
        try check(a.peaks.count == 2 && a.peaks.allSatisfy { $0.count == 32 }, "Bounded channel waveform shape")
        try check((a.peaks[0].max() ?? 0) < 0.2 && (a.peaks[1].max() ?? 0) > 0.7, "Source channel map respected")
        try check((b.peaks[0].max() ?? 0) > 0.7 && (b.peaks[1].max() ?? 0) < 0.2, "Trim source range respected")
        let repeatA = try await TimelinePreviewService.shared.preview(for: first)
        try check(repeatA.peaks == a.peaks, "Cached waveform stable")
        let duplicateService = TimelinePreviewService()
        let duplicateResults = try await withThrowingTaskGroup(of: TimelinePreview.self) { group in
            for _ in 0..<10 { group.addTask { try await duplicateService.preview(for: first) } }
            var results: [TimelinePreview] = []
            for try await value in group { results.append(value) }
            return results
        }
        let duplicateUsage = await duplicateService.resourceUsage()
        try check(duplicateResults.count == 10 && duplicateUsage.entries == 1 && duplicateUsage.bytes == a.byteCost,
                  "Concurrent identical misses keep cache accounting exact")
        let saturationService = TimelinePreviewService()
        let rejected = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<80 {
                group.addTask {
                    do {
                        _ = try await saturationService.preview(for: .init(url: audioURL, selection: .audio(map), start: Double(index) / 1000, duration: 0.8, thumbnailCount: 1, waveformBins: 32))
                        let usage = await saturationService.resourceUsage()
                        try check(usage.active <= 2 && usage.pending <= 12 && usage.entries <= 32 && usage.bytes <= 24 * 1024 * 1024, "Decoder admission and cache budgets")
                        return 0
                    } catch TimelinePreviewError.queueFull { return 1 }
                }
            }
            var rejected = 0
            for try await value in group { rejected += value }
            return rejected
        }
        try check(rejected > 0, "Saturated decoder queue rejects excess work")
        let cancellationService = TimelinePreviewService()
        let manyChannels = AudioSourceSelection(channels: Array(repeating: SourceChannel(streamIndex: 0, channelIndex: 0), count: 64), layout: ChannelLayout(channels: Array(repeating: nil, count: 64)))
        let activeCancellation = Task {
            try await cancellationService.preview(for: .init(url: audioURL, selection: .audio(manyChannels), start: 0, duration: 2, thumbnailCount: 1, waveformBins: 512))
        }
        var observedActive = false
        for _ in 0..<500 {
            if await cancellationService.resourceUsage().active > 0 { observedActive = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(observedActive, "Cancellation fixture reached active decoder")
        activeCancellation.cancel()
        do { _ = try await activeCancellation.value; throw PreviewSmokeError.failed("Active decoder ignored cancellation") }
        catch is CancellationError { }
        let cancelledUsage = await cancellationService.resourceUsage()
        try check(cancelledUsage.active == 0 && cancelledUsage.pending == 0 && cancelledUsage.entries == 0, "Cancelled decoder releases slot and never caches partial data")
        // Replace bytes at the same path and force a distinct modification date.
        for frame in 0..<96_000 {
            buffer.floatChannelData![0][frame] *= 0.05
            buffer.floatChannelData![1][frame] *= 5
        }
        do {
            let replacement = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try replacement.write(from: buffer)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: audioURL.path)
        let replacementPreview = try await TimelinePreviewService.shared.preview(for: first)
        try check(replacementPreview.peaks != a.peaks, "Same-path media replacement invalidates fingerprint cache")
        do {
            _ = try await TimelinePreviewService.shared.preview(for: .init(url: audioURL, selection: .audio(map), start: -1, duration: .infinity, thumbnailCount: 1, waveformBins: 16))
            throw PreviewSmokeError.failed("Invalid source range accepted")
        } catch TimelinePreviewError.invalidRequest { }
        let cancelled = Task {
            try await Task.sleep(for: .milliseconds(20))
            return try await TimelinePreviewService.shared.preview(for: second)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw PreviewSmokeError.failed("Cancelled request completed") }
        catch is CancellationError { }

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let stillURL = directory.appendingPathComponent("still.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: stillURL)
        let still = try await TimelinePreviewService.shared.preview(for: .init(url: stillURL, selection: .still, start: 0, duration: 5, thumbnailCount: 12, waveformBins: 16))
        try check(still.images.count == 1 && still.images[0].width <= 180, "Still thumbnail bounded")
        // Small configurable budgets exercise actual eviction with decoded images.
        let evictionService = TimelinePreviewService(maximumCacheBytes: still.byteCost * 3, maximumCacheEntries: 2)
        let stillRequests = (0..<3).map { _ in
            TimelinePreviewRequest(url: stillURL, selection: .still, start: 0, duration: 5, thumbnailCount: 1, waveformBins: 16, revision: UUID())
        }
        let oldest = try await evictionService.preview(for: stillRequests[0])
        let evicted = try await evictionService.preview(for: stillRequests[1])
        let touched = try await evictionService.preview(for: stillRequests[0])
        try check(oldest.images[0] === touched.images[0], "Cache hit reuses the retained image")
        _ = try await evictionService.preview(for: stillRequests[2])
        let retained = try await evictionService.preview(for: stillRequests[0])
        try check(oldest.images[0] === retained.images[0], "LRU keeps the recently touched image")
        let regenerated = try await evictionService.preview(for: stillRequests[1])
        try check(evicted.images[0] !== regenerated.images[0], "LRU evicts the oldest image")
        let evictionUsage = await evictionService.resourceUsage()
        try check(evictionUsage.entries == 2 && evictionUsage.bytes == still.byteCost * 2, "Entry eviction accounts exact retained bytes")
        let byteService = TimelinePreviewService(maximumCacheBytes: still.byteCost + still.byteCost / 2)
        for request in stillRequests { _ = try await byteService.preview(for: request) }
        let byteUsage = await byteService.resourceUsage()
        try check(byteUsage.entries == 1 && byteUsage.bytes == still.byteCost, "Byte budget evicts images before entry limit")
        let oversizedService = TimelinePreviewService(maximumCacheBytes: still.byteCost - 1)
        _ = try await oversizedService.preview(for: stillRequests[0])
        let oversizedUsage = await oversizedService.resourceUsage()
        try check(oversizedUsage.entries == 0 && oversizedUsage.bytes == 0, "Oversized result is returned without exceeding retained budget")

        // Hold both slots with long channel-mapped reads, then cancel a queued request.
        let longURL = directory.appendingPathComponent("long.wav")
        do {
            let file = try AVAudioFile(forWriting: longURL, settings: format.settings)
            for _ in 0..<15 { try file.write(from: buffer) }
        }
        let queuedService = TimelinePreviewService()
        let longRequest = TimelinePreviewRequest(url: longURL, selection: .audio(manyChannels), start: 0, duration: 30, thumbnailCount: 1, waveformBins: 512)
        let holders = (0..<2).map { _ in Task { try await queuedService.preview(for: longRequest) } }
        for _ in 0..<500 {
            if await queuedService.resourceUsage().active == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(await queuedService.resourceUsage().active == 2, "Queued cancellation fixture occupies both admission slots")
        let waiting = Task { try await queuedService.preview(for: first) }
        for _ in 0..<500 {
            if await queuedService.resourceUsage().pending == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try check(await queuedService.resourceUsage().pending == 1, "Request waits for admission")
        waiting.cancel()
        do { _ = try await waiting.value; throw PreviewSmokeError.failed("Queued request ignored cancellation") }
        catch is CancellationError { }
        try check(await queuedService.resourceUsage().pending == 0, "Queued cancellation removes the waiter immediately")
        for holder in holders { holder.cancel() }
        for holder in holders {
            do { _ = try await holder.value; throw PreviewSmokeError.failed("Holder ignored cancellation") }
            catch is CancellationError { }
        }
        let queuedUsage = await queuedService.resourceUsage()
        try check(queuedUsage.active == 0 && queuedUsage.pending == 0 && queuedUsage.entries == 0, "Cancellation drains admission and keeps stale results out of cache")
        let videoURL = directory.appendingPathComponent("colors.mp4")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let red = try await TimelinePreviewService.shared.preview(for: .init(url: videoURL, selection: .video(streamIndex: 0), start: 0, duration: 0.8, thumbnailCount: 2, waveformBins: 16))
            let blue = try await TimelinePreviewService.shared.preview(for: .init(url: videoURL, selection: .video(streamIndex: 0), start: 1.1, duration: 0.8, thumbnailCount: 2, waveformBins: 16))
            try check(red.images.count == 2 && blue.images.count == 2, "Filmstrip count")
            try check(red.images.allSatisfy { $0.width <= 180 && $0.height <= 100 }, "Filmstrip image dimensions bounded")
            let redPixel = pixel(red.images[0])
            let bluePixel = pixel(blue.images[0])
            try check(redPixel[0] > redPixel[2] && bluePixel[2] > bluePixel[0], "Video trim samples correct source range")
        } else {
            print("Video fixture skipped: ffmpeg unavailable")
        }
        print("Timeline preview smoke passed: source ranges, channel mapping, LRU/byte eviction, bounded admission, queued/active cancellation, and imagery")
    }

    static func pixel(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
