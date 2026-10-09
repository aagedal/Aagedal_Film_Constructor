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

    @Test func validatesHiddenSourcesAndRejectsStillsAndNonlocalOriginals() throws {
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
