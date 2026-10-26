import Foundation
import XCTest
@testable import EditorCore

final class AudioFadeTests: XCTestCase {
    private func fixture() throws -> (Project, UUID) {
        let project = try DemoProjectFactory.musicCollision()
        return (project, project.tracks[0].clips[0].id)
    }
    private func fade(_ seconds: Int64, _ curve: AudioFadeCurve = .linear) throws -> AudioFade {
        AudioFade(duration: try RationalTime(seconds), curve: curve)
    }

    func testProjectRoundTripAndLegacyClipDefaults() throws {
        var (project, _) = try fixture()
        project.tracks[0].clips[0].fadeIn = try fade(2, .equalPower)
        project.tracks[0].clips[0].fadeOut = try fade(4)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        for i in tracks.indices {
            var clips = try XCTUnwrap(tracks[i]["clips"] as? [[String: Any]])
            for j in clips.indices { clips[j].removeValue(forKey: "fadeIn"); clips[j].removeValue(forKey: "fadeOut") }
            tracks[i]["clips"] = clips
        }
        json["tracks"] = tracks
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.tracks.flatMap(\.clips).allSatisfy { $0.fadeIn == .init() && $0.fadeOut == .init() })
        let plan = try TimelineRenderPlan(project: project)
        XCTAssertEqual(plan.components[0].fadeIn, project.tracks[0].clips[0].fadeIn)
        XCTAssertEqual(plan.components[0].fadeOut, project.tracks[0].clips[0].fadeOut)
    }

    func testAtomicFadeEditIndependentOverlapUndoRedoAndInvalidValues() throws {
        let (project, id) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setFades(clipID: id, fadeIn: fade(4), fadeOut: fade(4, .equalPower)))
        let edited = engine.project
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project, edited)
        engine.undo()
        for value in [try fade(-1), try fade(6)] {
            XCTAssertThrowsError(try engine.apply(.setFades(clipID: id, fadeIn: value, fadeOut: .init())))
            XCTAssertEqual(engine.project, project)
            XCTAssertTrue(engine.canRedo)
        }
        XCTAssertThrowsError(try engine.apply(.setFades(clipID: UUID(), fadeIn: .init(), fadeOut: .init())))
    }

    func testAudioOnlyFadeEditDoesNotChangeLinkedAudioOrVideo() throws {
        var (project, id) = try fixture()
        let group = UUID()
        project.tracks[0].clips[0].linkGroupID = group
        project.tracks[0].clips[1].linkGroupID = group
        let family = TrackFamily(baseName: "Picture", template: TrackTemplate(kind: .video))
        project.families.append(family)
        project.assets[0].streams.append(MediaStream(index: 1, kind: .video))
        let video = TimelineClip(assetID: project.assets[0].id, sourceRange: project.tracks[0].clips[0].sourceRange,
                                 selection: .video(streamIndex: 1), linkGroupID: group)
        project.tracks.append(TimelineTrack(familyID: family.id, template: family.template, clips: [video]))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setFades(clipID: id, fadeIn: fade(1), fadeOut: fade(1)))
        XCTAssertEqual(engine.project.tracks[0].clips[1], project.tracks[0].clips[1])
        XCTAssertEqual(engine.project.tracks[1], project.tracks[1])
        let edited = engine.project
        // Pictures fade opacity linearly; curved picture fades are refused.
        XCTAssertThrowsError(try engine.apply(.setFades(clipID: video.id, fadeIn: fade(1, .equalPower), fadeOut: .init())))
        XCTAssertEqual(engine.project, edited)
        try engine.apply(.setFades(clipID: video.id, fadeIn: fade(1), fadeOut: .init()))
        XCTAssertEqual(engine.project.tracks[1].clips[0].fadeIn, try fade(1))
        XCTAssertEqual(engine.project.tracks[0].clips[1], project.tracks[0].clips[1], "Picture fades leave linked audio unchanged")
        var invalid = project; invalid.tracks[1].clips[0].fadeIn = try fade(1, .equalPower)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testTrimClampsAndSplitRetainsOuterEnvelopeOrRejectsPartialFade() throws {
        var (project, id) = try fixture()
        project.tracks[0].clips[0].fadeIn = try fade(4, .equalPower)
        project.tracks[0].clips[0].fadeOut = try fade(3)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.trim(clipID: id, sourceRange: TimeRange(start: .zero, duration: RationalTime(2)), timelineStart: .zero))
        let trimmed = try XCTUnwrap(engine.project.tracks.flatMap(\.clips).first { $0.id == id })
        XCTAssertEqual(trimmed.fadeIn.duration, try RationalTime(2))
        XCTAssertEqual(trimmed.fadeIn.curve, .equalPower)
        XCTAssertEqual(trimmed.fadeOut.duration, try RationalTime(2))
        engine.undo(); XCTAssertEqual(engine.project, project)
        XCTAssertThrowsError(try engine.apply(.split(clipID: id, at: RationalTime(2))))
        XCTAssertEqual(engine.project, project)
        XCTAssertTrue(engine.canRedo)
        project.tracks[0].clips[0].fadeIn = try fade(1, .equalPower)
        project.tracks[0].clips[0].fadeOut = try fade(2)
        engine = try TimelineEditEngine(project: project)
        try engine.apply(.split(clipID: id, at: RationalTime(2)))
        let halves = engine.project.tracks[0].clips.filter { $0.timelineStart.seconds < 5 }.sorted { $0.timelineStart.seconds < $1.timelineStart.seconds }
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves[0].fadeIn, project.tracks[0].clips[0].fadeIn)
        XCTAssertEqual(halves[0].fadeOut, .init())
        XCTAssertEqual(halves[1].fadeIn, .init())
        XCTAssertEqual(halves[1].fadeOut, project.tracks[0].clips[0].fadeOut)
        for sample in 0..<500 {
            let t = try RationalTime(Int64(sample), 100)
            let original = project.tracks[0].clips[0]
            let half = sample < 200 ? halves[0] : halves[1]
            XCTAssertEqual(try AudioFadeEnvelope.gain(at: t, duration: original.sourceRange.duration, fadeIn: original.fadeIn, fadeOut: original.fadeOut),
                           try AudioFadeEnvelope.gain(at: t.subtracting(half.timelineStart), duration: half.sourceRange.duration, fadeIn: half.fadeIn, fadeOut: half.fadeOut), accuracy: 1e-12)
        }
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project.tracks[0].clips.count, 3)
    }

    func testSourceSelectionsPreserveFadesAndConsolidationRejectsDifferentEnvelopes() throws {
        var (project, id) = try fixture()
        project.tracks[0].clips[0].fadeIn = try fade(2, .equalPower)
        project.tracks[0].clips[0].fadeOut = try fade(3)
        let selected = project.tracks[0].clips[0]
        let map = AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0)], layout: .mono)
        var engine = try TimelineEditEngine(project: project)
        let ids = try engine.selectAudioSource(clipID: id, selections: [map, map], routing: [.init(outputChannels: [0]), .init(outputChannels: [1])])
        for clip in engine.project.tracks.flatMap(\.clips).filter({ ids.contains($0.id) }) {
            XCTAssertEqual(clip.fadeIn, selected.fadeIn); XCTAssertEqual(clip.fadeOut, selected.fadeOut)
        }
        let separated = engine.project
        try engine.apply(.setFades(clipID: ids[1], fadeIn: .init(), fadeOut: .init()))
        let different = engine.project
        XCTAssertTrue(try different.audioConsolidationCandidates(for: id).isEmpty)
        XCTAssertThrowsError(try engine.consolidateAudioSources(clipID: id, replacingClipIDs: [ids[1]], selection: map, routing: .init(outputChannels: [0])))
        XCTAssertEqual(engine.project, different)
        engine.undo(); XCTAssertEqual(engine.project, separated)
        try engine.consolidateAudioSources(clipID: id, replacingClipIDs: [ids[1]], selection: map, routing: .init(outputChannels: [0]))
        XCTAssertEqual(engine.project.tracks.flatMap(\.clips).first { $0.id == id }?.fadeIn, selected.fadeIn)
        engine.undo(); XCTAssertEqual(engine.project, separated)
    }

    func testExactSampleEnvelopeEndpointsCurvesAndOverlap() throws {
        let duration = try RationalTime(4)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 0, sampleRate: 100, duration: duration, fadeIn: fade(2), fadeOut: fade(2)), 0)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 100, sampleRate: 100, duration: duration, fadeIn: fade(2), fadeOut: fade(2)), 0.5)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 100, sampleRate: 100, duration: duration, fadeIn: fade(2, .equalPower), fadeOut: fade(2)), sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 400, sampleRate: 100, duration: duration, fadeIn: fade(2), fadeOut: fade(2)), 0)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 200, sampleRate: 100, duration: duration, fadeIn: fade(4), fadeOut: fade(4)), 0.25)
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 200, sampleRate: 100, duration: duration, fadeIn: .init(), fadeOut: .init()), 1)
        let fractional = AudioFade(duration: try RationalTime(3, 200))
        XCTAssertEqual(try AudioFadeEnvelope.gain(sampleIndex: 1, sampleRate: 100, duration: duration, fadeIn: fractional, fadeOut: .init()), 2.0 / 3, accuracy: 1e-12)
    }
}
