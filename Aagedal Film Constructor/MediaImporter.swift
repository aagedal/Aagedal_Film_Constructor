import AVFoundation
import CoreMedia
import EditorCore
import ImageIO
import UniformTypeIdentifiers

struct ImportedMedia: Sendable {
    let asset: MediaAsset
    let bookmark: Data?
}

enum MediaImportError: LocalizedError {
    case unsupportedMedia, invalidDuration, invalidImage, invalidAudioChannels

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: "This file has no supported video or audio tracks."
        case .invalidDuration: "The media does not have a finite, positive duration."
        case .invalidImage: "This image could not be read."
        case .invalidAudioChannels: "The audio channel layout is unsupported."
        }
    }
}

/// Serial image decoding prevents rapid source switches from running multiple
/// uncancellable ImageIO calls simultaneously. Queued cancelled requests exit
/// before touching the source; actor work runs independently of the main actor.
private actor StillPreviewDecoder {
    static let shared = StillPreviewDecoder()

    func decode(url: URL, maximumDimension: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard (1...2048).contains(maximumDimension) else { throw MediaImportError.invalidImage }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= maximumDimension, image.height <= maximumDimension else {
            throw MediaImportError.invalidImage
        }
        try Task.checkCancellation()
        return image
    }
}

enum MediaImporter {
    /// Decode an oriented monitor-sized image off the main actor. ImageIO may
    /// still use codec scratch memory, but retained pixels never exceed this bound.
    @concurrent
    static func stillPreview(url: URL, maximumDimension: Int = 2048) async throws -> CGImage {
        try await StillPreviewDecoder.shared.decode(url: url, maximumDimension: maximumDimension)
    }

    /// Inspect while the import-panel grant is active. The editor retains access for playback.
    @concurrent
    static func inspect(url: URL, displayName: String? = nil) async throws -> ImportedMedia {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            // Validate decode without allocating the full original raster.
            _ = try await stillPreview(url: url, maximumDimension: 64)
            // Stills can be trimmed up to an hour; Append places the five-second default.
            return ImportedMedia(asset: MediaAsset(name: displayName ?? url.lastPathComponent, originalURL: url,
                                                   duration: try MediaAsset.stillSourceExtent()), bookmark: bookmark)
        }

        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration)
        guard duration.isNumeric, duration.timescale > 0, duration.value > 0 else {
            throw MediaImportError.invalidDuration
        }
        let tracks = try await source.load(.tracks)
        var streams: [MediaStream] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            guard track.mediaType == .video || track.mediaType == .audio else { continue }
            let range = try await track.load(.timeRange)
            let offset = range.start.isNumeric && range.start.timescale > 0
                ? try RationalTime(range.start.value, Int64(range.start.timescale)) : .zero
            if track.mediaType == .video {
                let format = try await qualifiedVideoFormat(asset: source, track: track)
                streams.append(MediaStream(index: index, kind: .video, label: "Video \(index + 1)", timeOffset: offset, videoFormat: format))
            } else {
                let descriptions = try await track.load(.formatDescriptions)
                guard let description = descriptions.first,
                      let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                    throw MediaImportError.invalidAudioChannels
                }
                let count = Int(audio.pointee.mChannelsPerFrame)
                guard (1...64).contains(count) else { throw MediaImportError.invalidAudioChannels }
                let layout: ChannelLayout = count == 1 ? .mono : count == 2 ? .stereo
                    : ChannelLayout(channels: Array(repeating: nil, count: count))
                streams.append(MediaStream(index: index, kind: .audio, label: "Audio \(index + 1)", audioLayout: layout, timeOffset: offset))
            }
        }
        guard !streams.isEmpty else { throw MediaImportError.unsupportedMedia }
        return ImportedMedia(asset: MediaAsset(name: displayName ?? url.lastPathComponent, originalURL: url,
                                               duration: try RationalTime(duration.value, Int64(duration.timescale)),
                                               streams: streams), bookmark: bookmark)
    }

    /// AVFoundation first; formats it cannot open are converted with the bundled FFmpeg.
    /// `converting` is called before a conversion starts so the UI can report it.
    static func inspectOrConvert(url: URL, converting: @MainActor () -> Void) async throws -> ImportedMedia {
        do {
            return try await inspect(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .image) != true else { throw error }
            converting()
            let converted = try await MediaConversionService.shared.convert(url)
            do {
                return try await inspect(url: converted, displayName: url.lastPathComponent)
            } catch {
                try? FileManager.default.removeItem(at: converted)
                throw error
            }
        }
    }

    /// Read compressed sample timing rather than approximating nominalFrameRate.
    /// Qualification is optional: unsupported timing or an exhausted work budget
    /// leaves the file importable. The full bounded track must prove one cadence.
    @concurrent
    static func qualifiedVideoFormat(asset: AVAsset, track: AVAssetTrack) async throws -> VideoSourceFormat? {
        try Task.checkCancellation()
        do {
            guard try await track.load(.preferredTransform) == .identity else { return nil }
            let segments = try await track.load(.segments)
            guard segments.count == 1, let segment = segments.first, !segment.isEmpty else { return nil }
            let mapping = segment.timeMapping
            guard mapping.source.isValid, mapping.target.isValid,
                  mapping.source.duration.isNumeric, mapping.target.duration.isNumeric,
                  CMTimeCompare(mapping.source.duration, mapping.target.duration) == 0 else { return nil }
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let description = descriptions.first else { return nil }
            let raster = CMVideoFormatDescriptionGetDimensions(description)
            let presentation = CMVideoFormatDescriptionGetPresentationDimensions(description,
                usePixelAspectRatio: true, useCleanAperture: true)
            guard raster.width > 0, raster.height > 0,
                  presentation.width == CGFloat(raster.width),
                  presentation.height == CGFloat(raster.height) else { return nil }
            // Explicitly refuse non-square pixels even if other aperture metadata
            // happens to compensate for their presentation dimensions.
            if let aspect = CMFormatDescriptionGetExtension(description,
                extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any] {
                guard let horizontal = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber,
                      let vertical = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber,
                      horizontal.doubleValue > 0, horizontal == vertical else { return nil }
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var samples: [(time: CMTime, duration: CMTime)] = []
            var bufferCount = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                bufferCount += 1
                guard bufferCount <= 100_000, clock.now < deadline else { return nil }
                // Reader also emits edit/reset/end markers containing no frames.
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                guard CMSampleBufferGetNumSamples(sample) == 1,
                      let sampleDescription = CMSampleBufferGetFormatDescription(sample),
                      CMFormatDescriptionEqual(description, otherFormatDescription: sampleDescription) else { return nil }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                guard time.isNumeric, time.timescale > 0, time.epoch == 0,
                      !time.flags.contains(.hasBeenRounded),
                      duration.isNumeric, duration.timescale > 0, duration.epoch == 0,
                      !duration.flags.contains(.hasBeenRounded),
                      CMTimeCompare(duration, .zero) > 0 else { return nil }
                samples.append((time, duration))
            }
            try Task.checkCancellation()
            guard reader.status == .completed, samples.count >= 2, clock.now < deadline else { return nil }
            // Compressed B-frame samples can arrive in decode order.
            samples.sort { CMTimeCompare($0.time, $1.time) < 0 }
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            let cadence = CMTimeSubtract(samples[1].time, samples[0].time)
            guard cadence.isNumeric, cadence.timescale > 0, cadence.value > 0,
                  !cadence.flags.contains(.hasBeenRounded) else { return nil }
            for index in samples.indices {
                try Task.checkCancellation()
                guard clock.now < deadline else { return nil }
                guard CMTimeCompare(samples[index].duration, cadence) == 0 else { return nil }
                if index > 0 {
                    let delta = CMTimeSubtract(samples[index].time, samples[index - 1].time)
                    guard delta.isNumeric, !delta.flags.contains(.hasBeenRounded),
                          CMTimeCompare(delta, cadence) == 0 else { return nil }
                }
            }
            let end = CMTimeAdd(samples[samples.count - 1].time, cadence)
            guard end.isNumeric, !end.flags.contains(.hasBeenRounded),
                  CMTimeCompare(samples[0].time, mapping.source.start) == 0,
                  CMTimeCompare(end, CMTimeRangeGetEnd(mapping.source)) == 0 else { return nil }
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            return try VideoSourceFormat(width: Int(raster.width), height: Int(raster.height),
                frameRate: FrameRate(Int64(cadence.timescale), cadence.value))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}
