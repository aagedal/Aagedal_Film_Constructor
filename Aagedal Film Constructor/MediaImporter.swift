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

enum MediaImporter {
    /// Inspect while the import-panel grant is active. The editor retains access for playback.
    @concurrent
    static func inspect(url: URL) async throws -> ImportedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw MediaImportError.invalidImage
            }
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
