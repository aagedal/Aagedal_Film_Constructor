import Foundation
import XCTest
@testable import EditorCore

final class CrossfadeRenderTests: XCTestCase {
    private func fixture(adjacent: Bool, duration: RationalTime = try! RationalTime(1), curve: AudioFadeCurve = .equalPower) throws -> (Project, UUID, UUID) {
        let settings = try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(24), audioLayout: .mono)
        let template = TrackTemplate(kind: .audio, audioLayout: .mono)
        let family = TrackFamily(baseName: "Audio", template: template)
        let asset = MediaAsset(name: "Tone", originalURL: URL(fileURLWithPath: "/private/tmp/crossfade-tone.mov"),
                               duration: try RationalTime(10), streams: [.init(index: 0, kind: .audio, audioLayout: .mono)])
        let selection = ClipSelection.audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0)], layout: .mono))
        let outgoing = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1), duration: RationalTime(adjacent ? 2 : 3)),
                                    timelineStart: try RationalTime(1), selection: selection)
        let incoming = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(3), duration: RationalTime(2)),
                                    timelineStart: try RationalTime(3), selection: selection)
        let project = Project(settings: settings, assets: [asset], families: [family], tracks: [.init(familyID: family.id, template: template, clips: [outgoing]), .init(familyID: family.id, template: template, clips: [incoming])])
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, duration: duration, curve: curve))
        XCTAssertEqual(engine.project.tracks, project.tracks, "Crossfades preserve editorial source and timeline ranges")
        return (engine.project, outgoing.id, incoming.id)
    }

    func testOverlapUsesComplementarySampleEnvelopesWithoutShorteningSequence() throws {
        let (project, outgoing, incoming) = try fixture(adjacent: false)
        let render = try TimelineRenderPlan(project: project)
        let native = try NativePlaybackPlan(render)
        XCTAssertEqual(native.videoFrames, 120)
        XCTAssertEqual(native.audioSamples, 240000)
        for offset: Int64 in [0, 1, 12000, 24000, 36000, 47999] {
            let requests = try native.audioBlock(startSample: 144000 + offset, sampleCount: 1)
            XCTAssertEqual(Set(requests.map(\.clipID)), [outgoing, incoming])
            let gains = try requests.map { try AudioFadeEnvelope.gain(sampleIndex: $0.clipSampleOffset, sampleRate: $0.sampleRate,
                                                    duration: $0.clipDuration, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut) }
            XCTAssertEqual(gains.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-12)
        }
        let command = try FFmpegRenderCompiler.compile(render, outputURL: URL(fileURLWithPath: "/private/tmp/crossfade-render.mov"))
        XCTAssertEqual(command.audioSamples, native.audioSamples)
        XCTAssertTrue(command.filterGraph.contains("(144000-n)*1/48000"))
        XCTAssertTrue(command.filterGraph.contains("(n)*1/48000"))
        XCTAssertTrue(command.filterGraph.contains("adelay=144000S:all=1"))
    }

    func testAdjacentCenteredHandlesAndRepeatedSeeksUseExpandedSourceBounds() throws {
        let (project, outgoing, incoming) = try fixture(adjacent: true)
        let render = try TimelineRenderPlan(project: project)
        let native = try NativePlaybackPlan(render)
        let components = Dictionary(uniqueKeysWithValues: render.components.map { ($0.clipID, $0) })
        XCTAssertEqual(components[outgoing]?.sourceRange, try TimeRange(start: RationalTime(1), duration: RationalTime(5, 2)))
        XCTAssertEqual(components[incoming]?.sourceRange, try TimeRange(start: RationalTime(5, 2), duration: RationalTime(5, 2)))
        let midpoint = try native.audioBlock(startSample: 144000, sampleCount: 1)
        for request in midpoint {
            XCTAssertEqual(request.sourceStartSample, 144000)
            XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: request.clipSampleOffset, sampleRate: request.sampleRate,
                           duration: request.clipDuration, fadeIn: request.fadeIn, fadeOut: request.fadeOut), sqrt(0.5), accuracy: 1e-12)
        }
        for start: Int64 in [167999, 120000, 144000, 119999, 168000, 144000] {
            let requests = try native.audioBlock(startSample: start, sampleCount: 1)
            XCTAssertEqual(requests.count, 120000 <= start && start < 168000 ? 2 : 1)
            XCTAssertTrue(requests.allSatisfy { $0.sourceStartSample == start })
        }
        XCTAssertEqual(native.audioSamples, 240000)
        let command = try FFmpegRenderCompiler.compile(render, outputURL: URL(fileURLWithPath: "/private/tmp/crossfade-render.mov"))
        XCTAssertTrue(command.filterGraph.contains("atrim=start_sample=120000:end_sample=240000"))
        XCTAssertTrue(command.filterGraph.contains("adelay=120000S:all=1"))
    }

    func testOddSampleAdjacentHandlesAndLinearComplementAreExact() throws {
        let (project, _, _) = try fixture(adjacent: true, duration: RationalTime(48001, 48000), curve: .linear)
        let native = try NativePlaybackPlan(TimelineRenderPlan(project: project))
        for start: Int64 in [120000, 144000, 168000] {
            let requests = try native.audioBlock(startSample: start, sampleCount: 1)
            XCTAssertEqual(requests.count, 2)
            let gain = try requests.reduce(0.0) { sum, request in
                sum + (try AudioFadeEnvelope.gain(sampleIndex: request.clipSampleOffset, sampleRate: request.sampleRate,
                    duration: request.clipDuration, fadeIn: request.fadeIn, fadeOut: request.fadeOut))
            }
            XCTAssertEqual(gain, 1, accuracy: 1e-12)
        }
        _ = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/crossfade-render.mov"))
    }
}
