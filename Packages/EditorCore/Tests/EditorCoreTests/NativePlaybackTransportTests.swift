import Foundation
import Testing
@testable import EditorCore

struct NativePlaybackTransportTests {
    private func plan(frames: Int64 = 300, rate: FrameRate = try! FrameRate(30000, 1001)) throws -> NativePlaybackPlan {
        let settings = try SequenceSettings(width: 160, height: 90, frameRate: rate)
        let template = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Video", template: template)
        let duration = try rate.time(forFrames: frames)
        let asset = MediaAsset(name: "Video", originalURL: URL(fileURLWithPath: "/private/tmp/transport.mov"),
                               duration: duration, streams: [.init(index: 0, kind: .video)])
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: duration),
                                selection: .video(streamIndex: 0))
        let project = Project(settings: settings, assets: [asset], families: [family],
                              tracks: [.init(familyID: family.id, template: template, clips: [clip])])
        return try NativePlaybackPlan(TimelineRenderPlan(project: project))
    }

    @Test func presentedSamplesSelectExactFractionalRateFrames() throws {
        var transport = try NativePlaybackTransport(plan: plan())
        #expect(transport.position == .zero)
        #expect(transport.frameIndex == 0)
        #expect(!transport.isPlaying)
        let token = try transport.play(clockSample: 100)
        #expect(try transport.play(clockSample: 999) == token)
        // One frame is exactly 1601.6 output samples.
        #expect(try transport.update(clockSample: 1701, generation: token))
        #expect(try transport.position == RationalTime(1601, 48000))
        #expect(transport.frameIndex == 0)
        #expect(try transport.update(clockSample: 1702, generation: token))
        #expect(transport.frameIndex == 1)
        #expect(transport.sampleIndex == 1602)
        #expect(try transport.plan.videoFrame(at: #require(transport.frameIndex))?.sourceFrame == 1)
        #expect(try transport.update(clockSample: 8108, generation: token))
        #expect(transport.frameIndex == 5) // 8008 samples is exactly five frames.
        #expect(try transport.position == transport.plan.settings.frameRate.time(forFrames: 5))
    }

    @Test func pauseAndResumeUseNewDeviceAnchorsWithoutElapsedWallTime() throws {
        var transport = try NativePlaybackTransport(plan: plan())
        let first = try transport.play(clockSample: 500)
        try transport.update(clockSample: 1500, generation: first)
        transport.pause()
        let held = transport.position
        #expect(!transport.isPlaying)
        #expect(try !transport.update(clockSample: .max, generation: first))
        #expect(transport.position == held)
        let resumed = try transport.play(clockSample: 200000)
        #expect(resumed != first)
        #expect(try !transport.update(clockSample: 200001, generation: first))
        try transport.update(clockSample: 200100, generation: resumed)
        #expect(try transport.position == RationalTime(1100, 48000))
        #expect(transport.sampleIndex == 1100)
    }

    @Test func seeksPreserveFractionalSampleAnchorAndRejectOldCallbacks() throws {
        var transport = try NativePlaybackTransport(plan: plan())
        let old = try transport.play()
        try transport.update(clockSample: 5000, generation: old)
        let forward = try transport.seek(toFrame: 1, clockSample: 9000)
        #expect(transport.isPlaying)
        #expect(try transport.position == RationalTime(1001, 30000))
        #expect(transport.frameIndex == 1)
        #expect(transport.sampleIndex == 1601)
        #expect(try !transport.update(clockSample: .max, generation: old))
        try transport.update(clockSample: 10601, generation: forward)
        #expect(transport.frameIndex == 1) // 3202.6 is still before frame two (3203.2).
        try transport.update(clockSample: 10602, generation: forward)
        #expect(transport.frameIndex == 2)
        #expect(try transport.position == RationalTime(1001, 30000).adding(RationalTime(1602, 48000)))
        let reverse = try transport.seek(toFrame: 0, clockSample: 10)
        #expect(reverse != forward)
        #expect(try !transport.update(clockSample: 10603, generation: forward))
        try transport.update(clockSample: 11, generation: reverse)
        #expect(try transport.position == RationalTime(1, 48000))
    }

    @Test func fractionalSequenceEndClampsAndPlayRestarts() throws {
        var transport = try NativePlaybackTransport(plan: plan(frames: 1))
        #expect(try transport.duration == RationalTime(1001, 30000))
        let token = try transport.play()
        try transport.update(clockSample: 1601, generation: token)
        #expect(transport.isPlaying)
        #expect(transport.frameIndex == 0)
        try transport.update(clockSample: 1602, generation: token)
        #expect(transport.position == transport.duration)
        #expect(transport.frameIndex == nil)
        #expect(transport.sampleIndex == 1602)
        #expect(!transport.isPlaying)
        #expect(try !transport.update(clockSample: 99999, generation: token))
        let restarted = try transport.play(clockSample: 99999)
        #expect(restarted != token)
        #expect(transport.position == .zero)
        #expect(transport.frameIndex == 0)
        try transport.update(clockSample: .max, generation: restarted)
        #expect(transport.position == transport.duration)
        #expect(!transport.isPlaying)
    }

    @Test func seekClampsAndReplacementAlwaysPausesAtZero() throws {
        var transport = try NativePlaybackTransport(plan: plan())
        try transport.seek(to: RationalTime(-1))
        #expect(transport.position == .zero)
        try transport.seek(toFrame: .max)
        #expect(transport.position == transport.duration)
        #expect(transport.frameIndex == nil)
        try transport.seek(toFrame: .min)
        #expect(transport.position == .zero)
        try transport.seek(to: RationalTime(.max))
        #expect(transport.position == transport.duration)
        let token = try transport.play()
        try transport.replacePlan(plan(frames: 24, rate: FrameRate(24)))
        #expect(!transport.isPlaying)
        #expect(transport.position == .zero)
        #expect(transport.sampleIndex == 0)
        #expect(try transport.duration == RationalTime(1))
        let newToken = try transport.play(clockSample: 100)
        #expect(try !transport.update(clockSample: 48100, generation: token))
        try transport.update(clockSample: 48100, generation: newToken)
        #expect(try transport.position == RationalTime(1))
        #expect(transport.frameIndex == nil)
    }

    @Test func invalidCurrentClockAndArithmeticFailureLeaveStateUnchanged() throws {
        var transport = try NativePlaybackTransport(plan: plan())
        let token = try transport.play(clockSample: 100)
        try transport.update(clockSample: 200, generation: token)
        let position = transport.position
        #expect(throws: NativePlaybackTransportError.invalidClockSample) {
            try transport.update(clockSample: -1, generation: token)
        }
        #expect(throws: NativePlaybackTransportError.regressingClockSample) {
            try transport.update(clockSample: 199, generation: token)
        }
        #expect(throws: NativePlaybackTransportError.invalidClockSample) { try transport.play(clockSample: -1) }
        #expect(throws: NativePlaybackTransportError.invalidClockSample) { try transport.seek(toFrame: 1, clockSample: -1) }
        #expect(throws: EditorCoreError.overflow) { try transport.seek(to: RationalTime(.max, .max - 1)) }
        #expect(transport.position == position)
        #expect(transport.generation == token)
        #expect(transport.isPlaying)
        #expect(try transport.update(clockSample: 200, generation: token)) // Duplicate is harmless.
        #expect(transport.position == position)
        #expect(try transport.update(clockSample: 201, generation: token))
        #expect(try transport.position == RationalTime(101, 48000))
        transport.pause()
        #expect(try !transport.update(clockSample: -1, generation: transport.generation))
    }

    @Test func manyUpdatesEqualOneUpdateAndIntegerRateEndIsExact() throws {
        let plan = try plan(frames: 240, rate: FrameRate(24))
        var stepped = try NativePlaybackTransport(plan: plan)
        var direct = try NativePlaybackTransport(plan: plan)
        let stepToken = try stepped.play()
        let directToken = try direct.play()
        for sample in stride(from: Int64(0), through: 480000, by: 480) {
            try stepped.update(clockSample: sample, generation: stepToken)
        }
        try direct.update(clockSample: 480000, generation: directToken)
        #expect(stepped.position == direct.position)
        #expect(try stepped.position == RationalTime(10))
        #expect(stepped.sampleIndex == 480000)
        #expect(stepped.frameIndex == nil)
    }
}
