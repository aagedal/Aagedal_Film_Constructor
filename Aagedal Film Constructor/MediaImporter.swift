import AudioToolbox
import AVFoundation
import CoreMedia
import EditorCore
import ImageIO
import UniformTypeIdentifiers
#if canImport(NativePlaybackRuntime)
import NativePlaybackRuntime
#endif

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

/// FFmpeg, which renders exports, decodes multichannel audio in WAVE/SMPTE order
/// (L R C LFE Ls Rs). AVFoundation decodes compressed audio in the stream's own order
/// instead (AAC 5.1 as C L R Ls Rs LFE). Source channel indices follow FFmpeg's order;
/// AVFoundation readers that address single channels request that order explicitly.
nonisolated enum SourceChannelOrder {
    private static let smpte51: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]

    /// Mono, stereo and recognised 5.1 streams are labelled; other layouts keep unknown positions.
    static func layout(of description: CMAudioFormatDescription) -> ChannelLayout {
        let count = Int(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame ?? 0)
        if count == 1 { return .mono }
        if count == 2 { return .stereo }
        if count == 6, let labels = labels(of: description) {
            // Rear and side surrounds (5.1 back/side) both play on the surround speakers.
            let normalized = labels.map { label -> AudioChannelLabel in
                switch label {
                case kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftSurroundDirect: kAudioChannelLabel_LeftSurround
                case kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightSurroundDirect: kAudioChannelLabel_RightSurround
                default: label
                }
            }
            // Both decoders keep PCM in file order; compressed 5.1 decodes in FFmpeg's order.
            let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID == kAudioFormatLinearPCM
            if pcm ? normalized == smpte51 : Set(normalized) == Set(smpte51) { return .surround51 }
        }
        return ChannelLayout(channels: Array(repeating: nil, count: max(count, 1)))
    }

    /// Reader output settings that decode a compressed 5.1 stream in FFmpeg's order.
    static func readerSettings(for description: CMAudioFormatDescription) -> [String: Any] {
        guard layout(of: description) == .surround51,
              CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID != kAudioFormatLinearPCM else { return [:] }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        return [AVNumberOfChannelsKey: 6, AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
    }

    private static func labels(of description: CMAudioFormatDescription) -> [AudioChannelLabel]? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size) else { return nil }
        return labels(of: layout)
    }

    /// Channel labels in stream order; layout tags and speaker bitmaps (WAVE-style PCM) are expanded.
    private static func labels(of layout: UnsafePointer<AudioChannelLayout>, depth: Int = 0) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag
        // Expansions keep their tag and fill in the descriptions.
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions || (depth > 0 && layout.pointee.mNumberChannelDescriptions > 0) {
            let base = UnsafeRawPointer(layout) + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            return (0..<Int(layout.pointee.mNumberChannelDescriptions)).map {
                base.load(fromByteOffset: $0 * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelDescription.self).mChannelLabel
            }
        }
        guard depth < 2 else { return nil }
        let bitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
        let property = bitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        var specifier: UInt32 = bitmap ? layout.pointee.mChannelBitmap.rawValue : tag
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var bytes: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &bytes) == noErr, bytes > 0 else { return nil }
        let expanded = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { expanded.deallocate() }
        guard AudioFormatGetProperty(property, specifierSize, &specifier, &bytes, expanded) == noErr else { return nil }
        // A bitmap may expand to a tag, which expands once more.
        return labels(of: expanded.assumingMemoryBound(to: AudioChannelLayout.self), depth: depth + 1)
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
                let layout = SourceChannelOrder.layout(of: description)
                streams.append(MediaStream(index: index, kind: .audio, label: "Audio \(index + 1)", audioLayout: layout, timeOffset: offset))
            }
        }
        guard !streams.isEmpty else { throw MediaImportError.unsupportedMedia }
        var asset = MediaAsset(name: displayName ?? url.lastPathComponent, originalURL: url,
                               duration: try RationalTime(duration.value, Int64(duration.timescale)), streams: streams)
        asset.sourceTimecodeStart = await sourceTimecodeStart(asset: source)
        return ImportedMedia(asset: asset, bookmark: bookmark)
    }

    /// AVFoundation first. With the native runtime, movies AVFoundation cannot open import
    /// unconverted when FFmpeg reads them and the sequence monitor's decoder can play every
    /// stream; other formats are converted with the bundled FFmpeg. MPEG program/transport
    /// streams always convert (AVFoundation would number their streams for previews).
    /// Animated GIF and APNG import as video through the same conversion; other images are stills.
    /// `converting` is called before a conversion starts so the UI can report it.
    static func inspectOrConvert(url: URL, using service: MediaConversionService = .shared,
                                 converting: @MainActor () -> Void) async throws -> ImportedMedia {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) == true
        if !(isImage && isAnimatedImage(url)),
           !MediaConversionService.alwaysConvertedExtensions.contains(url.pathExtension.lowercased()) {
            do {
                return try await inspect(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isImage { throw error }
            }
            #if canImport(NativePlaybackRuntime)
            do {
                return try await inspectNative(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not natively playable (or not readable by FFmpeg): convert as before.
            }
            #endif
        }
        await converting()
        let converted = try await service.convert(url)
        do {
            return try await inspect(url: converted, displayName: url.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: converted)
            throw error
        }
    }

    #if canImport(NativePlaybackRuntime)
    /// FFmpeg's reading of an original, referenced unconverted: FFmpeg stream indices, exact
    /// durations, offsets and cadence from packet timing, layouts in FFmpeg's channel order and
    /// embedded timecode. With `requiresNativePlayback`, every stream must also open in the
    /// sequence monitor's decoder, since AVFoundation previews cannot stand in for it.
    @concurrent
    static func inspectNative(url: URL, displayName: String? = nil, requiresNativePlayback: Bool = true) async throws -> ImportedMedia {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let probe = try NativeMediaProbe(url: url)
        try Task.checkCancellation()
        if requiresNativePlayback { try probe.verifyNativePlayback(url: url) }
        try Task.checkCancellation()
        var asset = MediaAsset(name: displayName ?? url.lastPathComponent, originalURL: url,
                               duration: probe.duration, streams: probe.streams)
        asset.sourceTimecodeStart = probe.sourceTimecodeStart
        return ImportedMedia(asset: asset, bookmark: bookmark)
    }

    /// One picture of an original AVFoundation cannot read, for the Source viewer.
    @concurrent
    static func nativeFrame(url: URL, streamIndex: Int, seconds: Double) async -> CGImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? NativeMediaPreview.thumbnails(url: url, streamIndex: streamIndex, times: [max(0, seconds)],
                                                  maximumWidth: 2048, maximumHeight: 2048).first
    }
    #endif

    /// GIF or PNG files with more than one image are animations. Multi-page TIFF and other
    /// image collections stay stills of their first image.
    nonisolated static func isAnimatedImage(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.gif.identifier, UTType.png.identifier].contains(type) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// First-frame embedded timecode as exact seconds, from a QuickTime timecode track.
    /// Absent or unreadable timecode leaves media at zero, as before.
    @concurrent
    static func sourceTimecodeStart(asset: AVAsset) async -> RationalTime? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // The reader can emit marker buffers without samples before the first timecode sample.
        var first: CMSampleBuffer?
        for _ in 0..<8 {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetNumSamples(buffer) > 0, CMSampleBufferGetDataBuffer(buffer) != nil { first = buffer; break }
        }
        guard let sample = first, let data = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        guard frameDuration.isNumeric, frameDuration.value > 0, frameDuration.timescale > 0 else { return nil }
        let frames: Int64
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMTimeCodeFormatType_TimeCode32:
            var value: Int32 = 0
            guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 4, destination: &value) == noErr else { return nil }
            frames = Int64(Int32(bigEndian: value))
        case kCMTimeCodeFormatType_TimeCode64:
            var value: Int64 = 0
            guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 8, destination: &value) == noErr else { return nil }
            frames = Int64(bigEndian: value)
        default: return nil
        }
        guard frames > 0 else { return nil }
        return try? RationalTime(frames).multiplied(by: RationalTime(frameDuration.value, Int64(frameDuration.timescale)))
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
