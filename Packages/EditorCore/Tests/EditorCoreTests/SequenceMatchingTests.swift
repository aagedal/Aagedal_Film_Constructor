import Foundation
import XCTest
@testable import EditorCore

final class SequenceMatchingTests: XCTestCase {
    private func source() throws -> MediaAsset {
        MediaAsset(name: "Picture", duration: try RationalTime(2), streams: [
            MediaStream(index: 0, kind: .video, videoFormat: try VideoSourceFormat(width: 1280, height: 720, frameRate: FrameRate(24000, 1001))),
            MediaStream(index: 1, kind: .video, videoFormat: try VideoSourceFormat(width: 640, height: 480, frameRate: FrameRate(25)))
        ])
    }

    func testExplicitStreamPreservesAudioAndSourceAndPersists() throws {
        let asset = try source()
        var project = Project(settings: try SequenceSettings(audioSampleRate: 44100, audioLayout: .mono,
                                                            startTimecode: Timecode(frameCount: 123)), assets: [asset])
        let before = project
        try project.matchSequence(to: asset.id, streamIndex: 0)
        XCTAssertEqual(project.settings.width, 1280)
        XCTAssertEqual(project.settings.height, 720)
        XCTAssertEqual(project.settings.frameRate, try FrameRate(24000, 1001))
        XCTAssertEqual(project.settings.audioSampleRate, before.settings.audioSampleRate)
        XCTAssertEqual(project.settings.audioLayout, before.settings.audioLayout)
        XCTAssertEqual(project.settings.startTimecode, before.settings.startTimecode)
        XCTAssertEqual(project.assets, before.assets)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        try project.matchSequence(to: asset.id, streamIndex: 1)
        XCTAssertEqual(project.settings.frameRate, try FrameRate(25))
        XCTAssertEqual(project.settings.width, 640)
    }

    func testRefusalIsAtomicForExistingEditsMissingMetadataAndDF() throws {
        let asset = try source()
        var populated = Project(settings: try SequenceSettings(), assets: [asset])
        try populated.appendAsset(asset.id)
        let populatedBefore = populated
        XCTAssertThrowsError(try populated.matchSequence(to: asset.id, streamIndex: 0))
        XCTAssertEqual(populated, populatedBefore)
        var project = Project(settings: try SequenceSettings(frameRate: FrameRate(30000, 1001),
                                                            startTimecode: Timecode(mode: .dropFrame)), assets: [asset])
        let before = project
        XCTAssertThrowsError(try project.matchSequence(to: asset.id, streamIndex: 0))
        XCTAssertEqual(project, before)
        XCTAssertThrowsError(try project.matchSequence(to: UUID(), streamIndex: 0))
        XCTAssertThrowsError(try project.matchSequence(to: asset.id, streamIndex: 99))
        project.assets[0].streams[0].videoFormat = nil
        let unqualified = project
        XCTAssertThrowsError(try project.matchSequence(to: asset.id, streamIndex: 0))
        XCTAssertEqual(project, unqualified)
    }

    func testVideoMetadataCannotBeAttachedToAudio() throws {
        let format = try VideoSourceFormat(width: 320, height: 180, frameRate: FrameRate(24))
        let asset = MediaAsset(name: "Invalid", duration: try RationalTime(2), streams: [
            MediaStream(index: 0, kind: .audio, audioLayout: .stereo, videoFormat: format)
        ])
        let project = Project(settings: try SequenceSettings(), assets: [asset])
        XCTAssertThrowsError(try project.validate())
    }
}
