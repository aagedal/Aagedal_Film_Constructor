import Foundation
import XCTest
@testable import EditorCore

final class AudioCrossfadeTests: XCTestCase {
    private func time(_ n: Int64, _ d: Int64 = 1) throws -> RationalTime { try RationalTime(n, d) }
    private func create(_ engine: inout TimelineEditEngine, _ a: UUID, _ b: UUID, duration: RationalTime = try! RationalTime(2), curve: AudioFadeCurve = .equalPower) throws {
        try engine.apply(.setAudioCrossfade(outgoingClipID: a, incomingClipID: b, duration: duration, curve: curve))
    }
    private func fixture() throws -> (Project, UUID, UUID) {
        let project = try DemoProjectFactory.musicCollision()
        return (project, project.tracks[0].clips[0].id, project.tracks[0].clips[1].id)
    }

    func testAdjacentVirtualHandlesDurationAndAtomicHistory() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        XCTAssertEqual(engine.project.tracks, project.tracks)
        let plan = try TimelineRenderPlan(project: engine.project)
        XCTAssertEqual(plan.duration, try time(10))
        XCTAssertEqual(plan.components[0].sourceRange.duration, try time(6))
        XCTAssertEqual(plan.components[1].sourceRange.start, try time(9))
        XCTAssertEqual(plan.components[1].timelineRange.start, try time(4))
        XCTAssertEqual(plan.components[0].fadeOut, AudioFade(duration: try time(2), curve: .equalPower))
        XCTAssertEqual(plan.components[1].fadeIn, plan.components[0].fadeOut)
        let relation = try XCTUnwrap(engine.project.audioCrossfades.first)
        let created = engine.project
        try create(&engine, a, b, duration: time(1), curve: .linear)
        XCTAssertEqual(engine.project.audioCrossfades[0].id, relation.id)
        engine.undo(); XCTAssertEqual(engine.project, created)
        try engine.apply(.removeAudioCrossfade(crossfadeID: relation.id))
        XCTAssertEqual(engine.project, project)
        engine.undo(); XCTAssertEqual(engine.project, created)
        engine.undo(); XCTAssertEqual(engine.project, project)
        engine.redo(); XCTAssertEqual(engine.project, created)
    }

    func testRoundTripLegacyAndMalformedRelations() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        let encoded = try JSONEncoder().encode(engine.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: encoded), engine.project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "audioCrossfades")
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)), project)
        var invalid = engine.project
        invalid.audioCrossfades[0].incomingClipID = UUID()
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(invalid)))
        invalid = engine.project
        invalid.audioCrossfades.append(invalid.audioCrossfades[0])
        XCTAssertThrowsError(try invalid.validate())
    }

    func testInvalidRequestsDoNotMutateHistoryOrDocument() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        for duration in [try time(-1), .zero, try time(1, 96000), try time(11)] {
            XCTAssertThrowsError(try create(&engine, a, b, duration: duration))
            XCTAssertEqual(engine.project, project)
            XCTAssertFalse(engine.canUndo)
        }
        XCTAssertThrowsError(try create(&engine, b, a))
        XCTAssertThrowsError(try create(&engine, a, a))
        XCTAssertThrowsError(try create(&engine, a, UUID()))
        XCTAssertThrowsError(try engine.apply(.removeAudioCrossfade(crossfadeID: UUID())))
        try create(&engine, a, b)
        let edited = engine.project
        XCTAssertThrowsError(try create(&engine, a, b, duration: time(20)))
        XCTAssertEqual(engine.project, edited)
    }

    func testSourceHandleFallbackAndOddSamples() throws {
        var (project, a, b) = try fixture()
        project.tracks[0].clips[1].sourceRange.start = .zero
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        var geometry = try engine.project.audioCrossfadeGeometry(for: engine.project.audioCrossfades[0])
        XCTAssertEqual(geometry.incomingTimelineRange.start, try time(5))
        XCTAssertEqual(geometry.outgoingTimelineRange.duration, try time(7))
        (project, a, b) = try fixture()
        engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b, duration: time(3, 48000))
        geometry = try engine.project.audioCrossfadeGeometry(for: engine.project.audioCrossfades[0])
        XCTAssertEqual(try time(5).subtracting(geometry.incomingTimelineRange.start), try time(1, 48000))
        XCTAssertEqual(try geometry.outgoingTimelineRange.duration.subtracting(time(5)), try time(2, 48000))
    }

    func testExistingOverlapRequiresExactComplementaryWindow() throws {
        var (project, a, b) = try fixture()
        let incoming = project.tracks[0].clips.removeLast()
        var moved = incoming; moved.timelineStart = try time(3)
        project.tracks.append(TimelineTrack(familyID: project.families[0].id, template: project.tracks[0].template, clips: [moved]))
        var engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try create(&engine, a, b, duration: time(1)))
        try create(&engine, a, b)
        let plan = try TimelineRenderPlan(project: engine.project)
        XCTAssertEqual(plan.components[0].timelineRange, try project.tracks[0].clips[0].timelineRange())
        XCTAssertEqual(plan.components[1].timelineRange, try moved.timelineRange())
    }

    func testStandaloneEdgesAndEffectiveRouting() throws {
        var (project, a, b) = try fixture()
        project.tracks[0].clips[0].fadeIn = AudioFade(duration: try time(1))
        project.tracks[0].clips[1].fadeOut = AudioFade(duration: try time(1))
        let incoming = project.tracks[0].clips.removeLast()
        var template = project.tracks[0].template
        template.routing = AudioRouting(outputChannels: [0, 1]); template.gain = 0.5
        project.tracks.append(TimelineTrack(familyID: project.families[0].id, template: template, clips: [incoming]))
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        let plan = try TimelineRenderPlan(project: engine.project)
        XCTAssertEqual(plan.components[0].fadeIn, project.tracks[0].clips[0].fadeIn)
        XCTAssertEqual(plan.components[1].fadeOut, incoming.fadeOut)
        project.tracks[1].template.routing.outputChannels = [1, 0]
        engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try create(&engine, a, b))
        project.tracks[1].template.routing.outputChannels = [0, 1]
        project.tracks[0].clips[0].fadeOut = AudioFade(duration: try time(1))
        engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try create(&engine, a, b))
    }

    func testMoveDeleteTrimAndFadesDissolveAtomically() throws {
        let (project, a, b) = try fixture()
        for command in [EditCommand.move(clipID: b, trackID: project.tracks[0].id, start: try time(8)),
                        .delete(clipID: a),
                        .trim(clipID: a, sourceRange: try TimeRange(start: .zero, duration: time(3)), timelineStart: .zero),
                        .setAudioFades(clipID: a, fadeIn: .init(), fadeOut: AudioFade(duration: try time(1)))] {
            var engine = try TimelineEditEngine(project: project)
            try create(&engine, a, b)
            let paired = engine.project
            try engine.apply(command)
            XCTAssertTrue(engine.project.audioCrossfades.isEmpty)
            engine.undo(); XCTAssertEqual(engine.project, paired)
        }
    }

    func testJointLinkedMoveAndNoOpPreserveRelation() throws {
        var (project, a, b) = try fixture()
        let group = UUID()
        for i in project.tracks[0].clips.indices { project.tracks[0].clips[i].linkGroupID = group }
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        let relations = engine.project.audioCrossfades
        try engine.apply(.move(clipID: a, trackID: project.tracks[0].id, start: try time(2)))
        XCTAssertEqual(engine.project.audioCrossfades, relations)
        try engine.apply(.move(clipID: a, trackID: project.tracks[0].id, start: try time(2)))
        XCTAssertEqual(engine.project.audioCrossfades, relations)
    }

    func testSplitRejectsPartialPairAndDissolvesOutsideEnvelope() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        let paired = engine.project
        XCTAssertThrowsError(try engine.apply(.split(clipID: a, at: time(9, 2))))
        XCTAssertEqual(engine.project, paired)
        try engine.apply(.split(clipID: a, at: time(2)))
        XCTAssertTrue(engine.project.audioCrossfades.isEmpty)
        engine.undo(); XCTAssertEqual(engine.project, paired)
    }

    func testChainCombinesBothSourceHandlesAndRejectsIntersectingEnvelopes() throws {
        var (project, a, b) = try fixture()
        var third = project.tracks[0].clips[1]; third.id = UUID(); third.timelineStart = try time(10)
        project.tracks[0].clips.append(third)
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        try create(&engine, b, third.id)
        let paired = engine.project
        let middle = try XCTUnwrap(TimelineRenderPlan(project: paired).components.first(where: { $0.clipID == b }))
        XCTAssertEqual(middle.timelineRange.start, try time(4))
        XCTAssertEqual(middle.timelineRange.duration, try time(7))
        XCTAssertEqual(middle.sourceRange.start, try time(9))
        XCTAssertEqual(middle.sourceRange.duration, try time(7))
        XCTAssertEqual(middle.fadeIn.duration, try time(2))
        XCTAssertEqual(middle.fadeOut.duration, try time(2))
        XCTAssertThrowsError(try create(&engine, a, b, duration: time(10)))
        XCTAssertEqual(engine.project, paired)
    }
    func testSourceRemappingDissolvesAndUndoRestoresWhileNoOpPreserves() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        let paired = engine.project
        guard case .audio(var selection) = project.tracks[0].clips[0].selection else { return XCTFail("Audio fixture") }
        try engine.selectAudioSource(clipID: a, selections: [selection], routing: [.init()])
        XCTAssertEqual(engine.project, paired)
        selection.channels.reverse()
        try engine.selectAudioSource(clipID: a, selections: [selection], routing: [.init()])
        XCTAssertTrue(engine.project.audioCrossfades.isEmpty)
        engine.undo(); XCTAssertEqual(engine.project, paired)
    }

    func testDissolvingEditedChainPreservesUnrelatedPair() throws {
        var (project, a, b) = try fixture()
        var third = project.tracks[0].clips[1]; third.id = UUID(); third.timelineStart = try time(10)
        var fourth = third; fourth.id = UUID(); fourth.timelineStart = try time(20)
        var fifth = third; fifth.id = UUID(); fifth.timelineStart = try time(25)
        project.tracks[0].clips.append(contentsOf: [third, fourth, fifth])
        var engine = try TimelineEditEngine(project: project)
        try create(&engine, a, b)
        try create(&engine, b, third.id)
        try create(&engine, fourth.id, fifth.id)
        let untouched = try XCTUnwrap(engine.project.audioCrossfades.last)
        try engine.apply(.delete(clipID: b))
        XCTAssertEqual(engine.project.audioCrossfades, [untouched])
    }

}
