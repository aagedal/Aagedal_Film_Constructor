import Foundation
import Testing
@testable import EditorCore

struct TrackEditingTests {
    private func fixture() throws -> Project {
        var project = try DemoProjectFactory.musicCollision()
        let first = project.tracks[0]
        project.tracks.append(TimelineTrack(familyID: first.familyID, customName: "Solo", template: first.template, retained: true))
        return project
    }

    @Test func familyNamesPreserveCustomNamesAndRestoreNumbering() throws {
        var project = try fixture()
        let first = project.tracks[0]
        try project.renameTrack(id: first.id, name: "  Dialogue  ")
        try project.renameTrackFamily(id: first.familyID, name: "  Voice  ")
        #expect(project.tracks.map { $0.displayName(in: project) } == ["Dialogue", "Solo"])
        try project.renameTrack(id: first.id, name: " \n ")
        #expect(project.tracks[0].displayName(in: project) == "Voice 1")
        let before = project
        #expect(throws: (any Error).self) { try project.renameTrackFamily(id: first.familyID, name: " ") }
        #expect(project == before)
    }

    @Test func gainReachesRenderAndNewSiblingsWithoutChangingExistingSiblings() throws {
        var project = try fixture()
        let first = project.tracks[0]
        try project.setTrackGain(id: first.id, gain: 0.25)
        #expect(project.tracks[1].template.gain == first.template.gain)
        #expect(try TimelineRenderPlan(project: project).components.allSatisfy { $0.gain == 0.25 })
        // Occupy the retained sibling so collision placement must create a new one.
        project.tracks[1].clips = first.clips.map { clip in var copy = clip; copy.id = UUID(); return copy }
        var engine = try TimelineEditEngine(project: project)
        var incoming = first.clips[0]; incoming.id = UUID()
        try engine.apply(.place(clip: incoming, trackID: first.id))
        #expect(engine.project.tracks.count == 3)
        #expect(engine.project.tracks.first { $0.id == project.tracks[1].id }?.template.gain == first.template.gain)
        #expect(engine.project.tracks.first { $0.clips.contains { $0.id == incoming.id } }?.template.gain == 0.25)
    }

    @Test func invalidGainLeavesProjectUnchanged() throws {
        var project = try fixture()
        let before = project
        for gain in [-1, Double.nan, Double.infinity] {
            #expect(throws: (any Error).self) { try project.setTrackGain(id: project.tracks[0].id, gain: gain) }
            #expect(project == before)
        }
        #expect(throws: (any Error).self) { try project.setTrackGain(id: UUID(), gain: 1) }
        try project.setTrackGain(id: project.tracks[0].id, gain: 0)
        #expect(try TimelineRenderPlan(project: project).components.allSatisfy { $0.gain == 0 })
    }

    @Test func retentionControlsCleanupAndSurvivesRoundTrip() throws {
        var project = try fixture()
        let trackID = project.tracks[0].id
        try project.setTrackRetention(id: trackID, retained: true)
        var engine = try TimelineEditEngine(project: project)
        for clip in project.tracks[0].clips { try engine.apply(.delete(clipID: clip.id)) }
        #expect(engine.project.tracks.first { $0.id == trackID }?.clips.isEmpty == true)
        project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(engine.project))
        #expect(project == engine.project)
        try project.setTrackRetention(id: trackID, retained: false)
        #expect(!project.tracks.contains { $0.id == trackID })
        #expect(project.families == engine.project.families)
        engine.undo()
        #expect(engine.project.tracks.first { $0.id == trackID }?.clips.isEmpty == false)
    }

    @Test func disabledCleanupKeepsUnpinnedEmptyTracks() throws {
        var project = try fixture()
        project.preferences.automaticallyRemoveEmptyTracks = false
        let id = project.tracks[1].id
        try project.setTrackRetention(id: id, retained: false)
        #expect(project.tracks.contains { $0.id == id })
    }
}
