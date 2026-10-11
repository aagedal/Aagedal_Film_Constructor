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
    static func inspect(url: URL) async throws -> ImportedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            // Validate decode without allocating the full original raster.
            _ = try await stillPreview(url: url, maximumDimension: 64)
            // Stills have a default five-second source extent until editable still durations arrive.
            return ImportedMedia(asset: MediaAsset(name: url.lastPathComponent, originalURL: url,
                                                   duration: try RationalTime(5)), bookmark: bookmark)
        }

        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration)
        guard duration.isNumeric, duration.timescale > 0, duration.value > 0 else {
            throw MediaImportError.invalidDuration
        }
        let tracks = try await source.load(.tracks)
        var streams: [MediaStream] = []
        for (index, track) in tracks.enumerated() {
            guard track.mediaType == .video || track.mediaType == .audio else { continue }
            let range = try await track.load(.timeRange)
            let offset = range.start.isNumeric && range.start.timescale > 0
                ? try RationalTime(range.start.value, Int64(range.start.timescale)) : .zero
            if track.mediaType == .video {
                streams.append(MediaStream(index: index, kind: .video, label: "Video \(index + 1)", timeOffset: offset))
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
        return ImportedMedia(asset: MediaAsset(name: url.lastPathComponent, originalURL: url,
                                               duration: try RationalTime(duration.value, Int64(duration.timescale)),
                                               streams: streams), bookmark: bookmark)
    }
}
