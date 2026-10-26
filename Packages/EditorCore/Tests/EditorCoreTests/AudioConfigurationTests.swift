import Foundation
import XCTest
@testable import EditorCore

final class AudioConfigurationTests: XCTestCase {
    /// A camera file with picture and four mono channels (two lavaliers, two boom tracks).
    private func fixture() throws -> (Project, pictureID: UUID) {
        var streams = [MediaStream(index: 0, kind: .video)]
        for index in 1...4 { streams.append(MediaStream(index: index, kind: .audio, audioLayout: .mono)) }
        var asset = MediaAsset(name: "Camera", duration: try RationalTime(30), streams: streams)
        asset.originalURL = URL(fileURLWithPath: "/private/tmp/camera.mov")
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        let ids = try project.appendAsset(asset.id, audioSelections: [], routing: [])
        return (project, ids[0])
    }

    private func sounds(_ project: Project) -> [(TimelineTrack, TimelineClip)] {
        project.tracks.filter { $0.kind == .audio }.flatMap { track in track.clips.map { (track, $0) } }
    }

    func testPresetsSplitChannelsAndRouteForTheSequence() throws {
        let (project, _) = try fixture()
        let asset = project.assets[0]
        XCTAssertEqual(asset.audioComponents(.multiMono, sequence: .stereo).map(\.routing), Array(repeating: AudioRouting(outputChannels: [0, 1]), count: 4))
        XCTAssertEqual(asset.audioComponents(.stereoPairs, sequence: .stereo).map(\.selection.layout), [.stereo, .stereo])
        XCTAssertEqual(asset.audioComponents(.stereo, sequence: .stereo).map(\.routing), [AudioRouting()])
        XCTAssertEqual(asset.audioComponents(.multiMono, sequence: .surround51).first?.routing, AudioRouting(outputChannels: [2]))
        XCTAssertTrue(asset.audioComponents(.surround51, sequence: .stereo).isEmpty)
        XCTAssertFalse(asset.availableAudioConfigurations(sequence: .stereo).contains(.surround51))
        let pairs = asset.audioComponents(.stereoPairs, sequence: .stereo).map(\.selection)
        XCTAssertEqual(asset.audioConfiguration(matching: pairs.reversed(), sequence: .stereo), .stereoPairs)
        XCTAssertEqual(asset.audioConfiguration(matching: [pairs[0]], sequence: .stereo), .stereo, "The first pair is the stereo preset")
        XCTAssertNil(asset.audioConfiguration(matching: [pairs[1]], sequence: .stereo))
    }

    func testReconfiguringAddsMonoTracksAndKeepsTheLink() throws {
        var (project, pictureID) = try fixture()
        let asset = project.assets[0]
        let mono = asset.audioComponents(.multiMono, sequence: .stereo)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.configureAudio(clipID: pictureID, selections: mono.map(\.selection), routing: mono.map(\.routing)))
        project = engine.project
        let placed = sounds(project)
        XCTAssertEqual(placed.count, 4)
        XCTAssertTrue(placed.allSatisfy { $0.0.audioLayout == .mono && $0.0.template.routing == AudioRouting(outputChannels: [0, 1]) })
        XCTAssertEqual(Set(placed.map(\.0.id)).count, 4, "Overlapping mono components get a track each")
        let group = project.tracks.flatMap(\.clips).first { $0.id == pictureID }?.linkGroupID
        XCTAssertNotNil(group)
        XCTAssertTrue(placed.allSatisfy { $0.1.linkGroupID == group })
        // Back to pairs: two stereo tracks; the emptied mono tracks go.
        let pairs = asset.audioComponents(.stereoPairs, sequence: .stereo)
        try engine.apply(.configureAudio(clipID: pictureID, selections: pairs.map(\.selection), routing: pairs.map(\.routing)))
        XCTAssertEqual(sounds(engine.project).map(\.0.audioLayout), [.stereo, .stereo])
        XCTAssertEqual(engine.project.tracks.filter { $0.kind == .audio }.count, 2)
    }

    func testUnchangedComponentsKeepTheirSettings() throws {
        var (project, pictureID) = try fixture()
        let mono = project.assets[0].audioComponents(.multiMono, sequence: .stereo)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.configureAudio(clipID: pictureID, selections: mono.map(\.selection), routing: mono.map(\.routing)))
        let first = sounds(engine.project).first { $0.1.selection == .audio(mono[0].selection) }!.1
        try engine.apply(.setGain(clipIDs: [first.id], gain: 0.5))
        // Dropping the last channel leaves the others, and their volume, alone.
        try engine.apply(.configureAudio(clipID: first.id, selections: mono.dropLast().map(\.selection), routing: mono.dropLast().map(\.routing)))
        project = engine.project
        XCTAssertEqual(sounds(project).count, 3)
        XCTAssertEqual(sounds(project).first { $0.1.id == first.id }?.1.gain, 0.5)
    }

    func testCentredMonoRendersOnBothSidesAndPlacesByDefault() throws {
        var (project, _) = try fixture()
        project.assets[0].audioConfiguration = .multiMono
        let assetID = project.assets[0].id
        _ = try project.appendAsset(assetID)
        XCTAssertEqual(sounds(project).count, 4)
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: URL(fileURLWithPath: "/private/tmp/centre.mov"))
        XCTAssertTrue(command.filterGraph.contains("pan=stereo|c0=c0|c1=c0"))
        // Interchange places mono in the centre by default, so centred mono is not a custom route.
        do { _ = try FCPXMLExporter.export(project: project) } catch FCPXMLExportError.unsupported(let reasons) {
            XCTAssertFalse(reasons.contains { $0.contains("routing") }, "\(reasons)")
        }
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        // A mono channel cannot list one output twice.
        XCTAssertFalse(AudioRouting(outputChannels: [0, 0]).fits(inputCount: 1, outputCount: 2))
    }
}
