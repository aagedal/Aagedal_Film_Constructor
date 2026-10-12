import Foundation
import Testing
@testable import EditorCore

struct NativePlaybackPlanTests {
    private let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let upperID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let toneID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// The same exact timing and separate mono-stream selection used by RenderPlanProof.
    private func fixture() throws -> Project {
        let rate = try FrameRate(30000, 1001)
        let settings = try SequenceSettings(width: 160, height: 90, frameRate: rate)
        let video = TrackTemplate(kind: .video)
        let audio = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.5)
        let vf = TrackFamily(baseName: "Video", template: video)
        let af = TrackFamily(baseName: "Audio", template: audio)
        let a = MediaAsset(name: "A", originalURL: URL(fileURLWithPath: "/private/tmp/native source 'a'; $(literal).mov"),
                           duration: try rate.time(forFrames: 300), streams: [
                            .init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .mono),
                            .init(index: 2, kind: .audio, audioLayout: .mono)])
        let b = MediaAsset(name: "B", originalURL: URL(fileURLWithPath: "/private/tmp/native-b.mov"),
                           duration: try rate.time(forFrames: 300), streams: [.init(index: 0, kind: .video)])
        func range(_ start: Int64, _ count: Int64) throws -> TimeRange {
            try TimeRange(start: rate.time(forFrames: start), duration: rate.time(forFrames: count))
        }
        let lower = TimelineClip(id: lowerID, assetID: a.id, sourceRange: try range(30, 180), selection: .video(streamIndex: 0))
        let upper = TimelineClip(id: upperID, assetID: b.id, sourceRange: try range(60, 117),
                                 timelineStart: try rate.time(forFrames: 3), selection: .video(streamIndex: 0), scalingMode: .fill)
        let tone = TimelineClip(id: toneID, assetID: a.id, sourceRange: try range(30, 120),
                                timelineStart: try rate.time(forFrames: 30), selection: .audio(.init(channels: [
                                    .init(streamIndex: 2, channelIndex: 0), .init(streamIndex: 1, channelIndex: 0)], layout: .stereo)))
        return Project(settings: settings, assets: [a, b], families: [vf, af], tracks: [
            .init(familyID: vf.id, template: video, clips: [upper]),
            .init(familyID: vf.id, template: video, clips: [lower]),
            .init(familyID: af.id, template: audio, clips: [tone])])
    }

    private func compile(_ project: Project) throws -> NativePlaybackPlan {
        try NativePlaybackPlan(TimelineRenderPlan(project: project))
    }

    @Test func exactFractionalTimingAndHalfOpenVideoLayers() throws {
        let project = try fixture()
        let plan = try compile(project)
        #expect(plan.settings == project.settings)
        #expect(plan.videoFrames == 180)
        #expect(plan.audioSamples == 288288)
        for (frame, clipID, sourceFrame) in [(Int64(2), lowerID, Int64(32)), (3, upperID, 60),
                                            (119, upperID, 176), (120, lowerID, 150)] {
            let request = try #require(try plan.videoFrame(at: frame))
            #expect(request.clipID == clipID)
            #expect(request.sourceFrame == sourceFrame)
            #expect(request.streamIndex == 0)
            #expect(request.url == project.assets[clipID == lowerID ? 0 : 1].originalURL)
            #expect(request.scalingMode == (clipID == lowerID ? .fit : .fill))
        }
        #expect(throws: (any Error).self) { try plan.videoFrame(at: -1) }
        #expect(throws: (any Error).self) { try plan.videoFrame(at: 180) }
        #expect(throws: (any Error).self) { try plan.videoFrame(at: .max) }
    }

    @Test func reverseAndRepeatedSeeksHaveNoSchedulingState() throws {
        let plan = try compile(fixture())
        for frame: Int64 in [179, 3, 120, 2, 119, 3, 0, 60, 179] {
            let request = try #require(try plan.videoFrame(at: frame))
            #expect(request.clipID == (3 <= frame && frame < 120 ? upperID : lowerID))
            #expect(request.sourceFrame == (3 <= frame && frame < 120 ? frame + 57 : frame + 30))
        }
        let first = try plan.audioBlock(startSample: 48047, sampleCount: 3)
        _ = try plan.audioBlock(startSample: 240240, sampleCount: 1)
        #expect(try plan.audioBlock(startSample: 48047, sampleCount: 3) == first)
    }

    @Test func uncoveredVideoAndAudioRemainBlackAndSilent() throws {
        var project = try fixture()
        project.tracks.remove(at: 1)
        project.tracks[1].clips[0].sourceRange.duration = try project.settings.frameRate.time(forFrames: 150)
        let plan = try compile(project)
        #expect(plan.videoFrames == 180)
        #expect(try plan.videoFrame(at: 2) == nil)
        #expect(try plan.videoFrame(at: 120) == nil)
        #expect(try plan.videoFrame(at: 179) == nil)
        #expect(try plan.audioBlock(startSample: 0, sampleCount: 48048).isEmpty)
        #expect(try plan.audioBlock(startSample: 48048, sampleCount: 1).count == 2)
    }

    @Test func fractionalFinalAudioSampleIsCeiledWithoutDrift() throws {
        var project = try fixture()
        project.tracks = [project.tracks[0]]
        project.tracks[0].clips[0].timelineStart = .zero
        project.tracks[0].clips[0].sourceRange = try TimeRange(start: project.settings.frameRate.time(forFrames: 5),
                                                           duration: project.settings.frameRate.time(forFrames: 1))
        let plan = try compile(project)
        #expect(plan.videoFrames == 1)
        #expect(plan.audioSamples == 1602) // Exact length is 1601.6 samples.
        #expect(try plan.videoFrame(at: 0)?.sourceFrame == 5)
        #expect(try plan.audioBlock(startSample: 1601, sampleCount: 1).isEmpty)
        #expect(throws: (any Error).self) { try plan.audioBlock(startSample: 1602, sampleCount: 1) }
    }

    @Test func sampleAlignedAudioTailCoversPartialVideoFrameWithoutExtendingTransport() throws {
        for rate in [try FrameRate(24), try FrameRate(24000, 1001), try FrameRate(30000, 1001)] {
            var project = try fixture()
            project.settings.frameRate = rate
            project.tracks = [project.tracks[1], project.tracks[2]]
            project.tracks[0].clips[0].sourceRange = try TimeRange(start: .zero, duration: rate.time(forFrames: 1))
            // End one sample after the first complete output-frame interval.
            let firstFrameSamples = try rate.time(forFrames: 1).multiplied(by: 48000)
            let endSample = firstFrameSamples.numerator / firstFrameSamples.denominator + 1
            project.tracks[1].clips[0].timelineStart = .zero
            project.tracks[1].clips[0].sourceRange = try TimeRange(start: .zero, duration: RationalTime(endSample, 48000))
            let renderPlan = try TimelineRenderPlan(project: project)
            let native = try NativePlaybackPlan(renderPlan)
            let command = try FFmpegRenderCompiler.compile(renderPlan, outputURL: URL(fileURLWithPath: "/private/tmp/partial-frame.mov"))
            #expect(native.duration == renderPlan.duration)
            #expect(native.videoFrames == 2)
            #expect(native.videoFrames == command.videoFrames)
            #expect(native.audioSamples == endSample)
            #expect(native.audioSamples == command.audioSamples)
            #expect(try native.videoFrame(at: 0)?.sourceFrame == 0)
            #expect(try native.videoFrame(at: 1) == nil) // The picture ended; the audio tail stays black.
            #expect(try native.audioBlock(startSample: endSample - 1, sampleCount: 1).count == 2)
            #expect(throws: (any Error).self) { try native.audioBlock(startSample: endSample, sampleCount: 1) }
            var transport = try NativePlaybackTransport(plan: native)
            #expect(transport.duration == renderPlan.duration)
            let token = try transport.play()
            try transport.update(clockSample: endSample - 1, generation: token)
            #expect(transport.isPlaying)
            let penultimateFrame = try RationalTime(endSample - 1, 48000).multiplied(by: rate.value)
            #expect(transport.frameIndex == penultimateFrame.numerator / penultimateFrame.denominator)
            try transport.update(clockSample: endSample, generation: token)
            #expect(!transport.isPlaying)
            #expect(transport.position == native.duration)
            #expect(transport.frameIndex == nil)
            #expect(transport.sampleIndex == endSample)
            try transport.seek(toFrame: 1)
            #expect(transport.frameIndex == 1)
            try transport.seek(toFrame: 2)
            #expect(transport.position == native.duration)
            #expect(transport.frameIndex == nil)
        }
    }

    @Test func oneSampleAudioOnlySequenceHasOneBlackFrameAndExactEnd() throws {
        var project = try fixture()
        project.tracks = [project.tracks[2]]
        project.tracks[0].clips[0].timelineStart = .zero
        project.tracks[0].clips[0].sourceRange = try TimeRange(start: RationalTime(5, 48000), duration: RationalTime(1, 48000))
        let plan = try compile(project)
        #expect(plan.videoFrames == 1)
        #expect(plan.audioSamples == 1)
        #expect(try plan.videoFrame(at: 0) == nil)
        #expect(try plan.audioBlock(startSample: 0, sampleCount: 1).allSatisfy { $0.sourceStartSample == 5 && $0.sampleCount == 1 })
        var transport = try NativePlaybackTransport(plan: plan)
        let token = try transport.play()
        try transport.update(clockSample: .max, generation: token)
        #expect(transport.position == plan.duration)
        #expect(transport.frameIndex == nil)
        #expect(transport.sampleIndex == 1)
        #expect(!transport.isPlaying)
        try transport.play()
        #expect(transport.position == .zero)
    }

    @Test func fixtureAudioPreservesAbsoluteSamplesSeparateStreamsAndGain() throws {
        let project = try fixture()
        let plan = try compile(project)
        let reads = try plan.audioBlock(startSample: 48047, sampleCount: 5)
        #expect(reads.count == 2)
        for (index, read) in reads.enumerated() {
            #expect(read.clipID == toneID)
            #expect(read.url == project.assets[0].originalURL)
            #expect(read.streamIndex == 2 - index)
            #expect(read.sourceChannel == 0)
            #expect(read.destinationChannel == index)
            #expect(read.sourceStartSample == 48048)
            #expect(read.destinationOffset == 1)
            #expect(read.sampleCount == 4)
            #expect(read.gain == 0.5)
        }
        let end = try plan.audioBlock(startSample: 240238, sampleCount: 4)
        #expect(end.count == 2)
        #expect(end.allSatisfy { $0.sourceStartSample == 240238 && $0.sampleCount == 2 && $0.destinationOffset == 0 })
        #expect(try plan.audioBlock(startSample: 240240, sampleCount: 1).isEmpty)
    }

    @Test func audioBlockSpansTwoCutsAndASilentGapWithExplicitSwap() throws {
        var project = try fixture()
        project.settings.frameRate = try FrameRate(24)
        project.tracks = [project.tracks[1], project.tracks[2]]
        project.tracks[0].clips[0].sourceRange = try TimeRange(start: .zero, duration: RationalTime(1, 8))
        project.tracks[1].template.gain = 0.25
        project.tracks[1].template.routing = .init(outputChannels: [1, 0])
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let first = TimelineClip(id: firstID, assetID: project.assets[0].id,
                                 sourceRange: try TimeRange(start: RationalTime(1000, 48000), duration: RationalTime(20, 48000)),
                                 timelineStart: try RationalTime(10, 48000), selection: project.tracks[1].clips[0].selection)
        let second = TimelineClip(id: secondID, assetID: project.assets[0].id,
                                  sourceRange: try TimeRange(start: RationalTime(2000, 48000), duration: RationalTime(20, 48000)),
                                  timelineStart: try RationalTime(40, 48000), selection: first.selection)
        // Insertion order is deliberately reversed; output order remains deterministic.
        project.tracks[1].clips = [second, first]
        let plan = try compile(project)
        let reads = try plan.audioBlock(startSample: 25, sampleCount: 30)
        #expect(reads.count == 4)
        #expect(reads.map(\.clipID) == [firstID, firstID, secondID, secondID])
        #expect(reads.map(\.streamIndex) == [2, 1, 2, 1])
        #expect(reads.map(\.destinationChannel) == [1, 0, 1, 0])
        #expect(reads.map(\.sourceStartSample) == [1015, 1015, 2000, 2000])
        #expect(reads.map(\.destinationOffset) == [0, 0, 15, 15])
        #expect(reads.map(\.sampleCount) == [5, 5, 15, 15])
        #expect(reads.allSatisfy { $0.gain == 0.25 })
        #expect(try plan.audioBlock(startSample: 30, sampleCount: 10).isEmpty)
        #expect(try plan.audioBlock(startSample: 60, sampleCount: 1).isEmpty)
    }

    @Test func sourceChannelIndicesAndAdditiveRoutingArePreserved() throws {
        var project = try fixture()
        project.assets[0].streams[1].audioLayout = .stereo
        project.tracks[2].clips[0].selection = .audio(.init(channels: [
            .init(streamIndex: 1, channelIndex: 1), .init(streamIndex: 1, channelIndex: 0)], layout: .stereo))
        project.tracks[2].template.routing.outputChannels = [0, 0]
        let reads = try compile(project).audioBlock(startSample: 48048, sampleCount: 2)
        #expect(reads.map(\.sourceChannel) == [1, 0])
        #expect(reads.map(\.destinationChannel) == [0, 0])
        #expect(reads.map(\.streamIndex) == [1, 1])
        project.settings.audioLayout = .mono
        project.families[1].template.routing.outputChannels = [0, 0]
        let mono = try compile(project)
        #expect(mono.settings.audioLayout == .mono)
        #expect(try mono.audioBlock(startSample: 48048, sampleCount: 2).map(\.destinationChannel) == [0, 0])
    }

    @Test func overlappingAudioTracksReturnEveryContributionInLayerOrder() throws {
        var project = try fixture()
        var overlapping = project.tracks[2]
        overlapping.id = UUID()
        overlapping.clips[0].id = lowerID
        project.tracks[1].clips[0].id = UUID()
        overlapping.template.gain = 0.125
        project.tracks.append(overlapping)
        let reads = try compile(project).audioBlock(startSample: 48048, sampleCount: 3)
        #expect(reads.count == 4)
        // Layer order takes precedence over the deliberately earlier UUID on the added track.
        #expect(reads.map(\.clipID) == [toneID, toneID, lowerID, lowerID])
        #expect(reads.map(\.gain) == [0.5, 0.5, 0.125, 0.125])
        #expect(reads.allSatisfy { $0.destinationOffset == 0 && $0.sampleCount == 3 && $0.sourceStartSample == 48048 })
    }

    @Test func requestPayloadsRoundTripThroughCodable() throws {
        let plan = try compile(fixture())
        let frame = try #require(try plan.videoFrame(at: 119))
        let reads = try plan.audioBlock(startSample: 48047, sampleCount: 5)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(NativeVideoFrameRequest.self, from: encoder.encode(frame)) == frame)
        #expect(try decoder.decode([NativeAudioReadRequest].self, from: encoder.encode(reads)) == reads)
    }

    @Test func rejectsInvalidAudioBlockRangesAndOverflow() throws {
        let plan = try compile(fixture())
        for (start, count) in [(Int64(-1), 1), (0, 0), (0, -1), (288288, 1), (288287, 2)] {
            #expect(throws: (any Error).self) { try plan.audioBlock(startSample: start, sampleCount: count) }
        }
        #expect(throws: EditorCoreError.overflow) { try plan.audioBlock(startSample: .max, sampleCount: 1) }
        #expect(try plan.audioBlock(startSample: 288287, sampleCount: 1).isEmpty)
    }

    @Test func validatesHiddenSourcesAndRejectsInvalidStillsAndNonlocalOriginals() throws {
        for url in [nil, URL(string: "https://example.com/a.mov"), URL(string: "file://remote-host/a.mov"),
                    URL(string: "file:///private/tmp/a.mov?stream=1")] as [URL?] {
            var project = try fixture()
            project.tracks[0].clips[0].timelineStart = .zero
            project.tracks[0].clips[0].sourceRange.duration = try project.settings.frameRate.time(forFrames: 180)
            project.assets[0].originalURL = url
            #expect(throws: (any Error).self) { try compile(project) }
        }
        var project = try fixture()
        project.tracks[1].clips[0].selection = .still
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[0].clips[0].timelineStart = .zero
        project.tracks[0].clips[0].sourceRange.duration = try project.settings.frameRate.time(forFrames: 180)
        project.assets[0].streams[0].timeOffset = try RationalTime(1, 2)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.assets[0].streams[2].timeOffset = try RationalTime(-1, 48000)
        #expect(throws: (any Error).self) { try compile(project) }
    }

    @Test func stillLayersPreserveSyntheticTrimsAndHalfOpenVisibility() throws {
        var project = try fixture()
        project.assets[1].originalURL = URL(fileURLWithPath: "/private/tmp/image.png")
        project.assets[1].streams = []
        project.tracks[0].clips[0].selection = .still
        // A synthetic in point need not lie on the video frame grid.
        project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48000)
        let plan = try compile(project)
        #expect(try plan.videoLayers(at: 2).map(\.clipID) == [lowerID])
        for frame: Int64 in [3, 60, 119, 3] {
            let layers = try plan.videoLayers(at: frame)
            #expect(layers.map(\.clipID) == [upperID, lowerID])
            #expect(layers[0].isStill)
            #expect(layers[0].sourceFrame == 0)
            #expect(layers[0].streamIndex == 0)
            #expect(!layers[1].isStill)
        }
        #expect(try plan.videoLayers(at: 120).map(\.clipID) == [lowerID])
        project.assets[1].streams = [.init(index: 0, kind: .video, timeOffset: try RationalTime(1, 2))]
        #expect(throws: (any Error).self) { try compile(project) }
    }

    @Test func rejectsUnsupportedGridAlignmentAndOutputSettings() throws {
        var project = try fixture()
        project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48000)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[0].clips[0].timelineStart = try RationalTime(1, 48000)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].clips[0].sourceRange.start = try RationalTime(1, 96000)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].clips[0].timelineStart = try RationalTime(1, 96000)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].clips[0].sourceRange.duration = try RationalTime(1, 96000)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.settings.width = 159
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.settings.audioLayout = .surround51
        project.tracks[2].template.routing.outputChannels = [0, 1]
        #expect(throws: (any Error).self) { try compile(project) }
        for rate in [0, -1, 768001] {
            project = try fixture()
            project.settings.audioSampleRate = rate
            #expect(throws: (any Error).self) { try compile(project) }
        }
        project = try fixture()
        project.settings.frameRate = try FrameRate(25)
        #expect(throws: (any Error).self) { try compile(project) }
    }

    @Test func rejectsMalformedSelectionsRoutingRangesAndStreams() throws {
        var project = try fixture()
        project.tracks[2].template.routing.outputChannels = [0]
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].template.routing.outputChannels = [0, 2]
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].clips[0].selection = .audio(.init(channels: [.init(streamIndex: 2, channelIndex: 0)], layout: .stereo))
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].clips[0].selection = .audio(.init(channels: [
            .init(streamIndex: 2, channelIndex: -1), .init(streamIndex: 1, channelIndex: 0)], layout: .stereo))
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.assets[0].streams[2].kind = .video
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.assets[0].streams[2].index = 1
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[0].clips[0].sourceRange.start = try RationalTime(20)
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[0].clips[0].sourceRange.duration = .zero
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].template.gain = .nan
        #expect(throws: (any Error).self) { try compile(project) }
        project = try fixture()
        project.tracks[2].template.gain = -1
        #expect(throws: (any Error).self) { try compile(project) }
    }

    @Test func rejectsEmptySequenceAndArithmeticOverflow() throws {
        let empty = Project(settings: try SequenceSettings())
        #expect(throws: (any Error).self) { try compile(empty) }
        var project = try fixture()
        project.settings.frameRate = try FrameRate(24)
        project.tracks = [project.tracks[1]]
        project.assets[0].duration = try RationalTime(.max)
        project.tracks[0].clips[0].sourceRange = try TimeRange(start: .zero, duration: RationalTime(.max))
        #expect(throws: EditorCoreError.overflow) { try compile(project) }
    }
}

@Test func nativeFadeRequestsUseClipRelativeClockAcrossChannelsAndSeeks() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.assets[0].originalURL = URL(fileURLWithPath: "/private/tmp/fade-source.mov")
    project.tracks[0].clips[1].fadeIn = .init(duration: try RationalTime(4), curve: .linear)
    project.tracks[0].clips[1].fadeOut = .init(duration: try RationalTime(4), curve: .equalPower)
    let plan = try NativePlaybackPlan(TimelineRenderPlan(project: project))
    func envelope(_ read: NativeAudioReadRequest, _ offset: Int64 = 0) throws -> Double {
        try AudioFadeEnvelope.gain(sampleIndex: read.clipSampleOffset + offset, sampleRate: read.sampleRate,
            duration: read.clipDuration, fadeIn: read.fadeIn, fadeOut: read.fadeOut)
    }
    // The source in (10s), timeline in (5s), and envelope clock (0s) differ.
    let entering = try plan.audioBlock(startSample: 239999, sampleCount: 3)
    let second = entering.filter { $0.clipID == project.tracks[0].clips[1].id }
    #expect(second.count == 2)
    #expect(second.allSatisfy { $0.sourceStartSample == 480000 && $0.clipSampleOffset == 0 && $0.destinationOffset == 1 })
    #expect(try envelope(second[0]) == 0)
    #expect(try envelope(second[0], 1) == envelope(second[1], 1))
    // Both edges are active in the middle and multiply independently.
    let middle = try plan.audioBlock(startSample: 360000, sampleCount: 2)
    #expect(middle.allSatisfy { $0.clipSampleOffset == 120000 })
    let expected = 0.625 * sin(0.625 * .pi / 2)
    #expect(abs(try envelope(middle[0]) - expected) < 1e-12)
    let last = try plan.audioBlock(startSample: 479999, sampleCount: 1)
    #expect(abs(try envelope(last[0]) - sin(.pi / (2 * 192000))) < 1e-12)
    _ = try plan.audioBlock(startSample: 240000, sampleCount: 1)
    #expect(try plan.audioBlock(startSample: 360000, sampleCount: 2) == middle)
    // A fade edit changes the plan even when source addressing stays identical.
    project.tracks[0].clips[1].fadeIn.curve = .equalPower
    let replaced = try NativePlaybackPlan(TimelineRenderPlan(project: project))
    #expect(plan != replaced)
    let edited = try replaced.audioBlock(startSample: 360000, sampleCount: 2)
    #expect(edited[0].sourceStartSample == middle[0].sourceStartSample)
    #expect(try envelope(edited[0]) > envelope(middle[0]))
}
