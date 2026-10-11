import Foundation
import XCTest
@testable import EditorCore

final class ProjectAssemblyTests: XCTestCase {
    private func audiovisual(layout: ChannelLayout = .stereo) throws -> MediaAsset {
        MediaAsset(name: "Camera take", originalURL: URL(fileURLWithPath: "/Volumes/Media/Camera take.mov"),
                   duration: try RationalTime(10), streams: [MediaStream(index: 0, kind: .video),
                       MediaStream(index: 1, kind: .audio, audioLayout: layout)])
    }

    func testAppendPlacesLinkedPictureAndSoundAndReusesTracks() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings())
        try project.addAsset(asset)
        let firstIDs = try project.appendAsset(asset.id)
        XCTAssertEqual(firstIDs.count, 2)
        let clips = project.tracks.flatMap(\.clips)
        XCTAssertEqual(clips.map(\.id), firstIDs)
        XCTAssertNotNil(clips[0].linkGroupID)
        XCTAssertEqual(clips[0].linkGroupID, clips[1].linkGroupID)
        XCTAssertEqual(clips[0].selection, .video(streamIndex: 0))
        let secondIDs = try project.appendAsset(asset.id)
        XCTAssertEqual(project.tracks.count, 2)
        XCTAssertEqual(project.families.count, 2)
        XCTAssertEqual(Set(project.tracks.flatMap(\.clips).filter { secondIDs.contains($0.id) }.map(\.timelineStart)), [try RationalTime(10)])
        XCTAssertEqual(try TimelineRenderPlan(project: project).duration, try RationalTime(20))
    }

    func testExplicitPlacementCreatesSiblingsAndPreservesExistingTimes() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        let originalIDs = try project.appendAsset(asset.id)
        try project.appendAsset(asset.id, at: RationalTime(2))
        XCTAssertEqual(project.tracks.count, 4)
        XCTAssertEqual(project.families.count, 2)
        XCTAssertEqual(Set(project.tracks.flatMap(\.clips).filter { originalIDs.contains($0.id) }.map(\.timelineStart)), [.zero])
        try project.validate()
    }

    func testMonoSourceIsExplicitlyDuplicatedToStereo() throws {
        let asset = try audiovisual(layout: .mono)
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id)
        let audio = try XCTUnwrap(project.tracks.first { $0.kind == .audio })
        XCTAssertEqual(audio.audioLayout, .stereo)
        XCTAssertEqual(audio.clips.first?.selection, .audio(AudioSourceSelection(channels: [
            SourceChannel(streamIndex: 1, channelIndex: 0), SourceChannel(streamIndex: 1, channelIndex: 0)
        ], layout: .stereo)))
        try project.validate()
    }

    func testStillAndAudioOnlyAssetsHaveSingleUnlinkedComponents() throws {
        let still = MediaAsset(name: "Title.png", duration: try RationalTime(5))
        let audio = MediaAsset(name: "Music.wav", duration: try RationalTime(3), streams: [MediaStream(index: 0, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(), assets: [still, audio])
        XCTAssertEqual(try project.appendAsset(still.id).count, 1)
        XCTAssertEqual(try project.appendAsset(audio.id).count, 1)
        let clips = project.tracks.flatMap(\.clips)
        XCTAssertEqual(clips[0].selection, .still)
        XCTAssertEqual(clips[1].timelineStart, try RationalTime(5))
        XCTAssertTrue(clips.allSatisfy { $0.linkGroupID == nil })
    }

    func testFailedImportsAndPlacementAreAtomic() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        let before = project
        XCTAssertThrowsError(try project.addAsset(asset))
        XCTAssertEqual(project, before)
        XCTAssertThrowsError(try project.appendAsset(UUID()))
        XCTAssertThrowsError(try project.appendAsset(asset.id, at: RationalTime(-1)))
        XCTAssertEqual(project, before)
        let surround = try audiovisual(layout: .surround51)
        try project.addAsset(surround)
        let withSurround = project
        XCTAssertThrowsError(try project.appendAsset(surround.id))
        XCTAssertEqual(project, withSurround)
    }

    func testExplicitSplitMonoPlacementPreservesRoutingAndLinksEveryComponent() throws {
        let asset = MediaAsset(name: "Multistream take", duration: try RationalTime(10), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 2, kind: .audio, audioLayout: .mono),
            MediaStream(index: 5, kind: .audio, audioLayout: .mono)
        ])
        let selections = [2, 5].map {
            AudioSourceSelection(channels: [SourceChannel(streamIndex: $0, channelIndex: 0)], layout: .mono)
        }
        let routes = [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])]
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        let ids = try project.appendAsset(asset.id, audioSelections: selections, routing: routes)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(project.families.count, 3)
        let clips = project.tracks.flatMap(\.clips)
        XCTAssertNotNil(clips[0].linkGroupID)
        XCTAssertEqual(Set(clips.compactMap(\.linkGroupID)).count, 1)
        let audio = try TimelineRenderPlan(project: project).components.filter { $0.selection != .video(streamIndex: 0) }
        XCTAssertEqual(audio.map(\.selection), selections.map(ClipSelection.audio))
        XCTAssertEqual(audio.map(\.routing), routes)
        try project.appendAsset(asset.id, audioSelections: selections, routing: routes)
        XCTAssertEqual(project.tracks.count, 3)
        XCTAssertEqual(project.families.count, 3)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.move(clipID: ids[0], trackID: project.tracks[0].id, start: RationalTime(25)))
        XCTAssertEqual(Set(engine.project.tracks.flatMap(\.clips).filter { ids.contains($0.id) }.map(\.timelineStart)), [try RationalTime(25)])
    }

    func testExplicitStereoSelectionCanSpanMonoStreams() throws {
        let asset = MediaAsset(name: "Recorder", duration: try RationalTime(4), streams: [
            MediaStream(index: 3, kind: .audio, audioLayout: .mono),
            MediaStream(index: 7, kind: .audio, audioLayout: .mono)
        ])
        let selection = AudioSourceSelection(channels: [SourceChannel(streamIndex: 3, channelIndex: 0),
                                                        SourceChannel(streamIndex: 7, channelIndex: 0)], layout: .stereo)
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        let ids = try project.appendAsset(asset.id, audioSelections: [selection], routing: [AudioRouting()])
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(project.tracks[0].clips[0].selection, .audio(selection))
        XCTAssertNil(project.tracks[0].clips[0].linkGroupID)
    }

    func testEmptyExplicitAudioSelectionPlacesPictureOnlyAndRejectsAudioOnly() throws {
        let video = try audiovisual(layout: .surround51)
        let audio = MediaAsset(name: "Audio", duration: try RationalTime(4), streams: [MediaStream(index: 0, kind: .audio, audioLayout: .stereo)])
        var project = Project(settings: try SequenceSettings(), assets: [video, audio])
        let ids = try project.appendAsset(video.id, audioSelections: [], routing: [])
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(project.tracks[0].clips[0].selection, .video(streamIndex: 0))
        XCTAssertNil(project.tracks[0].clips[0].linkGroupID)
        let before = project
        XCTAssertThrowsError(try project.appendAsset(audio.id, audioSelections: [], routing: []))
        XCTAssertEqual(project, before)
    }

    func testExplicitPlacementRejectsAllInvalidMapsAtomically() throws {
        let asset = try audiovisual(layout: .surround51)
        let mono = AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: 2)], layout: .mono)
        let left = AudioRouting(outputChannels: [0])
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id, audioSelections: [mono], routing: [left])
        let before = project
        let invalidSelections = [
            AudioSourceSelection(channels: [], layout: .mono),
            AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0)], layout: .mono),
            AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: 6)], layout: .mono),
            AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: -1)], layout: .mono)
        ]
        for invalid in invalidSelections {
            XCTAssertThrowsError(try project.appendAsset(asset.id, audioSelections: [mono, invalid], routing: [left, left]))
            XCTAssertEqual(project, before)
        }
        for invalid in [AudioRouting(), AudioRouting(outputChannels: [-1]), AudioRouting(outputChannels: [2]), AudioRouting(outputChannels: [0, 1])] {
            XCTAssertThrowsError(try project.appendAsset(asset.id, audioSelections: [mono, mono], routing: [left, invalid]))
            XCTAssertEqual(project, before)
        }
        XCTAssertThrowsError(try project.appendAsset(asset.id, audioSelections: [mono], routing: []))
        XCTAssertEqual(project, before)
    }

    func testPlacementDoesNotReuseReconfiguredTrackRoutingOrGain() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id)
        let originalAudioID = project.tracks[1].id
        project.tracks[1].template.routing = AudioRouting(outputChannels: [1, 0])
        project.tracks[1].template.gain = 0.5
        let ids = try project.appendAsset(asset.id)
        XCTAssertEqual(project.families.count, 2)
        let newAudio = try XCTUnwrap(project.tracks.first { $0.clips.contains { $0.id == ids[1] } })
        XCTAssertNotEqual(newAudio.id, originalAudioID)
        XCTAssertEqual(newAudio.template.routing, AudioRouting())
        XCTAssertEqual(newAudio.template.gain, 1)
        XCTAssertEqual(project.tracks.first { $0.id == originalAudioID }?.template.gain, 0.5)
        try project.validate()
    }

    func testPlacementDoesNotInheritExistingFamilyGain() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id)
        project.families[1].template.gain = 0.25
        project.tracks[1].template.gain = 0.25
        let ids = try project.appendAsset(asset.id)
        XCTAssertEqual(project.families.count, 3)
        let newAudio = try XCTUnwrap(project.tracks.first { $0.clips.contains { $0.id == ids[1] } })
        XCTAssertEqual(newAudio.template.gain, 1)
        XCTAssertNotEqual(newAudio.familyID, project.families[1].id)
        XCTAssertEqual(project.tracks[1].template.gain, 0.25)
    }

    func testProjectFileRoundTripPreservesLocationsAndLinkedEdits() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(30000, 1001)), assets: [asset])
        let ids = try project.appendAsset(asset.id)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.split(clipID: ids[0], at: RationalTime(4)))
        let leftTrack = try XCTUnwrap(engine.project.tracks.first { $0.clips.contains { $0.id == ids[0] } })
        try engine.apply(.move(clipID: ids[0], trackID: leftTrack.id, start: RationalTime(12)))
        project = engine.project
        project.preferences.automaticallyRemoveEmptyTracks = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sequence.afc")
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
        let reopened = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(reopened.assets.first?.originalURL, asset.originalURL)
        XCTAssertEqual(try TimelineRenderPlan(project: reopened), try TimelineRenderPlan(project: project))
    }

    func testRelinkPreservesAssetIdentityAndTimeline() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id)
        let url = URL(fileURLWithPath: "/Volumes/Replacement/Camera take.mov")
        let relinked = try project.replacingAssetLocation(id: asset.id, url: url)
        XCTAssertEqual(relinked.assets[0].id, asset.id)
        XCTAssertEqual(relinked.assets[0].originalURL, url)
        XCTAssertEqual(relinked.tracks, project.tracks)
        XCTAssertEqual(project.assets[0].originalURL, asset.originalURL)
        XCTAssertThrowsError(try project.replacingAssetLocation(id: UUID(), url: url))
    }

    func testDecodeRejectsInvalidDocumentReferencesAndOverlap() throws {
        let asset = try audiovisual()
        var project = Project(settings: try SequenceSettings(), assets: [asset])
        try project.appendAsset(asset.id)
        var missingAsset = project
        missingAsset.assets.removeAll()
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(missingAsset)))
        var overlap = project
        var duplicate = overlap.tracks[0].clips[0]
        duplicate.id = UUID()
        overlap.tracks[0].clips.append(duplicate)
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(overlap)))
    }
}
