import Foundation

/// An absolute source frame on the sequence frame grid, with its container stream identity.
/// A decoder must separately qualify the source's frame rate, timestamps and geometry.
public struct NativeVideoFrameRequest: Equatable, Codable, Sendable {
    public let clipID: UUID
    public let url: URL
    public let streamIndex: Int
    public let sourceFrame: Int64
    public let scalingMode: ScalingMode

    public init(clipID: UUID, url: URL, streamIndex: Int, sourceFrame: Int64, scalingMode: ScalingMode) {
        self.clipID = clipID; self.url = url; self.streamIndex = streamIndex
        self.sourceFrame = sourceFrame; self.scalingMode = scalingMode
    }
}

/// One additive channel contribution to an audio block. Samples outside the
/// returned contributions remain silent. The decoder must qualify source sample rate.
public struct NativeAudioReadRequest: Equatable, Codable, Sendable {
    public let clipID: UUID
    public let url: URL
    public let streamIndex: Int
    public let sourceChannel: Int
    public let destinationChannel: Int
    public let sourceStartSample: Int64
    public let destinationOffset: Int
    public let sampleCount: Int
    public let gain: Double

    public init(clipID: UUID, url: URL, streamIndex: Int, sourceChannel: Int, destinationChannel: Int,
                sourceStartSample: Int64, destinationOffset: Int, sampleCount: Int, gain: Double) {
        self.clipID = clipID; self.url = url; self.streamIndex = streamIndex
        self.sourceChannel = sourceChannel; self.destinationChannel = destinationChannel
        self.sourceStartSample = sourceStartSample; self.destinationOffset = destinationOffset
        self.sampleCount = sampleCount; self.gain = gain
    }
}

/// Stateless, exact requests for the development playback subset: frame-aligned
/// video, sample-aligned audio, zero selected-stream offsets, local originals,
/// even raster dimensions and mono/stereo output. This performs no media I/O or
/// FFmpeg compilation. The decoder still has to qualify rates, CFR and geometry.
public struct NativePlaybackPlan: Equatable, Sendable {
    public let settings: SequenceSettings
    public let videoFrames: Int64
    /// Ceiling of the exact sequence duration in samples, including a possible silent tail.
    public let audioSamples: Int64
    private let video: [VideoClip]
    private let audio: [AudioClip]

    private struct VideoClip: Equatable, Sendable {
        let request: NativeVideoFrameRequest
        let start: Int64
        let end: Int64
    }
    private struct AudioClip: Equatable, Sendable {
        let clipID: UUID
        let url: URL
        let channels: [SourceChannel]
        let routing: [Int]
        let sourceStart: Int64
        let start: Int64
        let end: Int64
        let gain: Double
    }

    public init(_ renderPlan: TimelineRenderPlan) throws {
        let settings = renderPlan.settings
        try settings.validate()
        guard settings.width % 2 == 0, settings.height % 2 == 0,
              settings.audioLayout == .mono || settings.audioLayout == .stereo else {
            throw EditorCoreError.invalidModel("Native prototype requires even raster dimensions and mono/stereo output")
        }
        let frames = try Self.integral(renderPlan.duration.multiplied(by: settings.frameRate.value),
                                       "Sequence duration must align to frames")
        guard frames > 0 else { throw EditorCoreError.invalidModel("Cannot play an empty sequence") }
        let exactSamples = try renderPlan.duration.multiplied(by: Int64(settings.audioSampleRate))
        let samples = try Self.add(exactSamples.numerator / exactSamples.denominator,
                                   exactSamples.numerator % exactSamples.denominator == 0 ? 0 : 1)
        var video: [VideoClip] = []
        var audio: [AudioClip] = []
        // Track zero is explicitly frontmost. UUID order breaks ties deterministically.
        let components = renderPlan.components.sorted {
            if $0.layerOrder != $1.layerOrder { return $0.layerOrder < $1.layerOrder }
            return $0.clipID.uuidString < $1.clipID.uuidString
        }
        guard Set(components.map(\.clipID)).count == components.count else {
            throw EditorCoreError.invalidModel("Duplicate native playback clip identity")
        }
        for component in components {
            guard let url = component.originalURL, Self.isLocalOriginal(url) else {
                throw EditorCoreError.invalidModel("Native playback requires an absolute local original URL")
            }
            try component.sourceRange.validate()
            try component.timelineRange.validate()
            guard component.layerOrder >= 0,
                  component.sourceRange.duration == component.timelineRange.duration,
                  try component.timelineRange.end().compared(to: renderPlan.duration) != .orderedDescending,
                  component.gain.isFinite, component.gain >= 0 else {
                throw EditorCoreError.invalidModel("Invalid native playback component")
            }
            guard Set(component.sourceStreams.map(\.index)).count == component.sourceStreams.count else {
                throw EditorCoreError.invalidModel("Ambiguous source stream identity")
            }
            for stream in component.sourceStreams {
                guard stream.index >= 0, (stream.kind == .audio) == (stream.audioLayout != nil) else {
                    throw EditorCoreError.invalidModel("Invalid native source stream")
                }
                try stream.audioLayout?.validate()
            }
            func sourceStream(_ index: Int, kind: MediaStreamKind) throws -> MediaStream {
                guard let stream = component.sourceStreams.first(where: { $0.index == index && $0.kind == kind }),
                      stream.timeOffset == .zero else {
                    throw EditorCoreError.invalidModel("Missing source stream or unsupported nonzero stream offset")
                }
                return stream
            }
            switch component.selection {
            case .still:
                throw EditorCoreError.invalidModel("Still-image playback is not qualified by this prototype")
            case .video(let streamIndex):
                guard component.routing.outputChannels.isEmpty else {
                    throw EditorCoreError.invalidModel("Video component has audio routing")
                }
                _ = try sourceStream(streamIndex, kind: .video)
                let sourceStart = try Self.integral(component.sourceRange.start.multiplied(by: settings.frameRate.value),
                                                    "Video source in must align to sequence frames")
                let count = try Self.integral(component.sourceRange.duration.multiplied(by: settings.frameRate.value),
                                              "Video duration must align to sequence frames")
                let start = try Self.integral(component.timelineRange.start.multiplied(by: settings.frameRate.value),
                                              "Video placement must align to frames")
                _ = try Self.add(sourceStart, count)
                let end = try Self.add(start, count)
                guard end <= frames else { throw EditorCoreError.invalidModel("Video range exceeds sequence") }
                video.append(VideoClip(request: .init(clipID: component.clipID, url: url, streamIndex: streamIndex,
                                                       sourceFrame: sourceStart, scalingMode: component.scalingMode),
                                       start: start, end: end))
            case .audio(let selection):
                try selection.layout.validate()
                guard selection.channels.count == selection.layout.channels.count else {
                    throw EditorCoreError.invalidModel("Incomplete source channel map")
                }
                let routing = component.routing.outputChannels.isEmpty ? Array(selection.channels.indices) : component.routing.outputChannels
                guard routing.count == selection.channels.count,
                      routing.allSatisfy({ settings.audioLayout.channels.indices.contains($0) }),
                      !component.routing.outputChannels.isEmpty || selection.layout == settings.audioLayout else {
                    throw EditorCoreError.invalidModel("Invalid native audio output map")
                }
                for channel in selection.channels {
                    let stream = try sourceStream(channel.streamIndex, kind: .audio)
                    guard let layout = stream.audioLayout, layout.channels.indices.contains(channel.channelIndex) else {
                        throw EditorCoreError.invalidModel("Invalid source audio channel")
                    }
                }
                let sampleRate = Int64(settings.audioSampleRate)
                let sourceStart = try Self.integral(component.sourceRange.start.multiplied(by: sampleRate),
                                                    "Audio in must align to samples")
                let sourceEnd = try Self.integral(component.sourceRange.end().multiplied(by: sampleRate),
                                                  "Audio out must align to samples")
                let start = try Self.integral(component.timelineRange.start.multiplied(by: sampleRate),
                                              "Audio placement must align to samples")
                let end = try Self.add(start, sourceEnd - sourceStart)
                guard end <= samples else { throw EditorCoreError.invalidModel("Audio range exceeds sequence") }
                audio.append(AudioClip(clipID: component.clipID, url: url, channels: selection.channels, routing: routing,
                                       sourceStart: sourceStart, start: start, end: end, gain: component.gain))
            }
        }
        self.settings = settings; videoFrames = frames; audioSamples = samples
        self.video = video; self.audio = audio
    }

    /// Half-open visibility prevents a layer from holding its last frame after a cut.
    /// Returns nil for a black gap. Every request is independent of previous seeks.
    public func videoFrame(at frame: Int64) throws -> NativeVideoFrameRequest? {
        guard frame >= 0, frame < videoFrames else {
            throw EditorCoreError.invalidModel("Video frame is outside sequence")
        }
        guard let clip = video.first(where: { $0.start <= frame && frame < $0.end }) else { return nil }
        let request = clip.request
        return NativeVideoFrameRequest(clipID: request.clipID, url: request.url, streamIndex: request.streamIndex,
                                        sourceFrame: try Self.add(request.sourceFrame, frame - clip.start),
                                        scalingMode: request.scalingMode)
    }

    /// Intersects every audio clip with a positive block wholly inside the sequence.
    /// Order is track front to back, then clip UUID, then selected source channel.
    public func audioBlock(startSample: Int64, sampleCount: Int) throws -> [NativeAudioReadRequest] {
        guard startSample >= 0, sampleCount > 0, let count = Int64(exactly: sampleCount) else {
            throw EditorCoreError.invalidModel("Invalid audio block range")
        }
        let blockEnd = try Self.add(startSample, count)
        guard blockEnd <= audioSamples else { throw EditorCoreError.invalidModel("Audio block exceeds sequence") }
        var result: [NativeAudioReadRequest] = []
        for clip in audio {
            let start = max(startSample, clip.start)
            let end = min(blockEnd, clip.end)
            guard start < end else { continue }
            // Both differences are bounded by the caller's representable Int block count.
            let destinationOffset = Int(start - startSample)
            let count = Int(end - start)
            let sourceStart = try Self.add(clip.sourceStart, start - clip.start)
            for (index, channel) in clip.channels.enumerated() {
                result.append(.init(clipID: clip.clipID, url: clip.url, streamIndex: channel.streamIndex,
                                    sourceChannel: channel.channelIndex, destinationChannel: clip.routing[index],
                                    sourceStartSample: sourceStart, destinationOffset: destinationOffset,
                                    sampleCount: count, gain: clip.gain))
            }
        }
        return result
    }

    private static func integral(_ time: RationalTime, _ message: String) throws -> Int64 {
        guard time.denominator == 1, time.numerator >= 0 else { throw EditorCoreError.invalidModel(message) }
        return time.numerator
    }
    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else { throw EditorCoreError.overflow }
        return sum.partialValue
    }
    private static func isLocalOriginal(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return url.isFileURL && url.path.hasPrefix("/") && (host == nil || host == "" || host == "localhost")
            && url.query == nil && url.fragment == nil
    }
}
