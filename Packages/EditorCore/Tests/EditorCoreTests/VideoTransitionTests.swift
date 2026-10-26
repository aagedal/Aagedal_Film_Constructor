import Foundation
import XCTest
@testable import EditorCore

final class VideoTransitionTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/private/tmp/video-transition-render.mov")

    /// Two adjacent five-second shots from one 20-second movie, cut at 5 s on one track.
    private func fixture(still: Bool = false) throws -> (Project, TimelineClip, TimelineClip) {
        let settings = try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25), audioLayout: .stereo)
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let movie = MediaAsset(name: "Movie", originalURL: URL(fileURLWithPath: "/private/tmp/transition-movie.mov"),
                               duration: try RationalTime(20), streams: [.init(index: 0, kind: .video)])
        let image = MediaAsset(name: "Still", originalURL: URL(fileURLWithPath: "/private/tmp/transition-still.png"),
                               duration: try MediaAsset.stillSourceExtent())
        let selection: ClipSelection = still ? .still : .video(streamIndex: 0)
        let asset = still ? image : movie
        let a = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: still ? .zero : RationalTime(2), duration: RationalTime(5)),
                             selection: selection)
        let b = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: still ? .zero : RationalTime(10), duration: RationalTime(5)),
                             timelineStart: try RationalTime(5), selection: selection)
        let track = TimelineTrack(familyID: family.id, template: family.template, clips: [a, b])
        return (Project(settings: settings, assets: [movie, image], families: [family], tracks: [track]), a, b)
    }

    func testAdjacentDissolveUsesCenteredFrameHandlesAndKeepsOutgoingOpaque() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(2), curve: .linear))
        XCTAssertEqual(engine.project.tracks, project.tracks, "Dissolves keep editorial ranges")
        let plan = try TimelineRenderPlan(project: engine.project)
        let byID = Dictionary(uniqueKeysWithValues: plan.components.map { ($0.clipID, $0) })
        let outgoing = try XCTUnwrap(byID[a.id]), incoming = try XCTUnwrap(byID[b.id])
        XCTAssertEqual(outgoing.timelineRange, try TimeRange(start: .zero, duration: RationalTime(6)))
        XCTAssertEqual(outgoing.sourceRange, try TimeRange(start: RationalTime(2), duration: RationalTime(6)))
        XCTAssertEqual(outgoing.fadeOut, .init(), "The outgoing picture stays opaque under the incoming one")
        XCTAssertEqual(incoming.timelineRange, try TimeRange(start: RationalTime(4), duration: RationalTime(6)))
        XCTAssertEqual(incoming.sourceRange, try TimeRange(start: RationalTime(9), duration: RationalTime(6)))
        XCTAssertEqual(incoming.fadeIn, AudioFade(duration: try RationalTime(2), curve: .linear))
        XCTAssertEqual(plan.duration, try RationalTime(10))

        let command = try FFmpegRenderCompiler.compile(plan, outputURL: output)
        // The incoming picture is composited after (over) the outgoing one.
        let outgoingLayer = try XCTUnwrap(command.filterGraph.range(of: "trim=start_frame=50:end_frame=200"))
        let incomingLayer = try XCTUnwrap(command.filterGraph.range(of: "trim=start_frame=225:end_frame=375"))
        XCTAssertLessThan(outgoingLayer.lowerBound, incomingLayer.lowerBound)
        XCTAssertTrue(command.filterGraph.contains("format=yuva444p,fade=t=in:st=4.000000000:d=2.000000000:alpha=1[v1]"))
        XCTAssertEqual(command.videoFrames, 250)

        // An odd frame count puts the extra frame after the cut.
        var odd = try TimelineEditEngine(project: project)
        try odd.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .linear))
        let oddPlan = try TimelineRenderPlan(project: odd.project)
        XCTAssertEqual(oddPlan.components.first { $0.clipID == b.id }?.timelineRange.start, try RationalTime(113, 25))

        let composition = try VideoCompositionPlan(plan)
        let indexA = try XCTUnwrap(plan.components.firstIndex { $0.clipID == a.id })
        let indexB = try XCTUnwrap(plan.components.firstIndex { $0.clipID == b.id })
        XCTAssertEqual(composition.instructions.map(\.componentIndices), [[indexA], [indexB, indexA], [indexB]])
        XCTAssertEqual(composition.instructions[1].timeRange, try TimeRange(start: RationalTime(4), duration: RationalTime(2)))
        XCTAssertEqual(composition.trackCount, 2)
    }

    func testDissolveRequiresOneTrackLinearCurveWholeFramesAndHandles() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        XCTAssertThrowsError(try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .equalPower)))
        XCTAssertThrowsError(try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1, 50), curve: .linear)),
                             "Half a frame at 25 fps")
        // Source in at 2 s limits the incoming handle; the outgoing has 13 s after its out point.
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(9), curve: .linear))
        XCTAssertThrowsError(try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(11), curve: .linear)))

        var split = project
        let family = split.families[0]
        split.tracks[0].clips.removeLast()
        split.tracks.append(TimelineTrack(familyID: family.id, template: family.template, clips: [b]))
        var other = try TimelineEditEngine(project: split)
        XCTAssertThrowsError(try other.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .linear)),
                             "Dissolves join two pictures on one track")
    }

    func testStillDissolvesExtendTheHeldPicture() throws {
        let (project, a, b) = try fixture(still: true)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(2), curve: .linear))
        let plan = try TimelineRenderPlan(project: engine.project)
        let byID = Dictionary(uniqueKeysWithValues: plan.components.map { ($0.clipID, $0) })
        XCTAssertEqual(byID[a.id]?.timelineRange, try TimeRange(start: .zero, duration: RationalTime(6)))
        XCTAssertEqual(byID[b.id]?.timelineRange, try TimeRange(start: RationalTime(4), duration: RationalTime(6)))
        XCTAssertEqual(byID[b.id]?.sourceRange.start, .zero)
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: output)
        XCTAssertTrue(command.filterGraph.contains("fade=t=in:st=4.000000000:d=2.000000000:alpha=1"))
    }

    func testPictureFadesRevealLowerLayersAndCompileAlphaRamps() throws {
        var (project, a, _) = try fixture()
        project.tracks[0].clips.removeLast()
        // An upper picture fading in and out over the lower shot.
        let family = project.families[0]
        let top = TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: RationalTime(4), duration: RationalTime(2)),
                               timelineStart: try RationalTime(1), selection: .video(streamIndex: 0))
        project.tracks.insert(TimelineTrack(familyID: family.id, template: family.template, clips: [top]), at: 0)
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setFades(clipID: top.id, fadeIn: AudioFade(duration: try RationalTime(1, 2)), fadeOut: AudioFade(duration: try RationalTime(1, 5))))
        try engine.apply(.setFades(clipID: a.id, fadeIn: AudioFade(duration: try RationalTime(1)), fadeOut: .init()))
        let plan = try TimelineRenderPlan(project: engine.project)
        let command = try FFmpegRenderCompiler.compile(plan, outputURL: output)
        XCTAssertTrue(command.filterGraph.contains("fade=t=in:st=1.000000000:d=0.500000000:alpha=1,fade=t=out:st=2.800000000:d=0.200000000:alpha=1"))
        XCTAssertTrue(command.filterGraph.contains("fade=t=in:st=0.000000000:d=1.000000000:alpha=1"), "A fade from black over the base")

        let composition = try VideoCompositionPlan(plan)
        let topIndex = try XCTUnwrap(plan.components.firstIndex { $0.clipID == top.id })
        let lowIndex = try XCTUnwrap(plan.components.firstIndex { $0.clipID == a.id })
        let expected: [(RationalTime, [Int])] = [
            (.zero, [lowIndex]), (try RationalTime(1), [topIndex, lowIndex]), (try RationalTime(3, 2), [topIndex]),
            (try RationalTime(14, 5), [topIndex, lowIndex]), (try RationalTime(3), [lowIndex])]
        XCTAssertEqual(composition.instructions.map(\.timeRange.start), expected.map(\.0))
        XCTAssertEqual(composition.instructions.map(\.componentIndices), expected.map(\.1))
    }

    /// Linked picture and stereo sound for each shot, as Append creates them.
    private func linkedFixture() throws -> (Project, [TimelineClip]) {
        var (project, a, b) = try fixture()
        project.assets[0].streams.append(.init(index: 1, kind: .audio, audioLayout: .stereo))
        let template = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let family = TrackFamily(baseName: "Audio", template: template)
        project.families.append(family)
        let stereo = ClipSelection.audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo))
        var sounds: [TimelineClip] = []
        for index in 0..<2 {
            let group = UUID()
            project.tracks[0].clips[index].linkGroupID = group
            var sound = project.tracks[0].clips[index]
            sound.id = UUID(); sound.selection = stereo
            sounds.append(sound)
        }
        project.tracks.append(TimelineTrack(familyID: family.id, template: template, clips: sounds))
        return (project, [project.tracks[0].clips[0], project.tracks[0].clips[1], sounds[0], sounds[1]])
    }

    func testAddTransitionJoinsLinkedPictureAndSoundAtTheNearestCutAsOneEdit() throws {
        let (project, clips) = try linkedFixture()
        var engine = try TimelineEditEngine(project: project)
        // The playhead near the end of the first shot picks the cut at 5 s.
        XCTAssertEqual(try engine.addTransition(clipID: clips[0].id, near: RationalTime(4), duration: RationalTime(1)).joined, 2)
        let relations = Dictionary(uniqueKeysWithValues: engine.project.audioCrossfades.map { ($0.outgoingClipID, $0) })
        XCTAssertEqual(relations[clips[0].id]?.incomingClipID, clips[1].id)
        XCTAssertEqual(relations[clips[0].id]?.curve, .linear)
        XCTAssertEqual(relations[clips[2].id]?.incomingClipID, clips[3].id)
        XCTAssertEqual(relations[clips[2].id]?.curve, .equalPower)
        XCTAssertEqual(relations[clips[2].id]?.duration, try RationalTime(1))
        _ = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: output)
        engine.undo()
        XCTAssertEqual(engine.project, project, "One undo removes both transitions")
    }

    func testAddTransitionFadesFreeEdgesAndShrinksToAvailableHandles() throws {
        let (project, clips) = try linkedFixture()
        var engine = try TimelineEditEngine(project: project)
        // The first shot's start has no neighbour: picture fades from black, sound fades in.
        XCTAssertEqual(try engine.addTransition(clipID: clips[0].id, near: RationalTime(1), duration: RationalTime(2)).fades, 2)
        XCTAssertEqual(engine.project.tracks[0].clips[0].fadeIn, AudioFade(duration: try RationalTime(2), curve: .linear))
        XCTAssertEqual(engine.project.tracks[1].clips[0].fadeIn, AudioFade(duration: try RationalTime(2), curve: .equalPower))
        // The incoming source starts at 10 s, the outgoing has 13 s left: 30 s fits as 20 s at most.
        try engine.addTransition(clipID: clips[1].id, near: RationalTime(5), duration: RationalTime(30))
        let dissolve = try XCTUnwrap(engine.project.audioCrossfades.first { $0.outgoingClipID == clips[0].id })
        XCTAssertLessThanOrEqual(dissolve.duration.seconds, 10)
        XCTAssertNoThrow(try engine.project.audioCrossfadeGeometry(for: dissolve))
    }

    func testAddTransitionDipsThroughBlackWhenNoMediaLiesBeyondTheCut() throws {
        var (project, clips) = try linkedFixture()
        // Whole-file clips: the outgoing ends at its media end, the incoming starts at zero.
        project.assets[0].duration = try RationalTime(17, 2)
        for t in project.tracks.indices {
            project.tracks[t].clips[0].sourceRange = try TimeRange(start: RationalTime(7, 2), duration: RationalTime(5))
            project.tracks[t].clips[1].sourceRange = try TimeRange(start: .zero, duration: RationalTime(5))
        }
        var engine = try TimelineEditEngine(project: project)
        let result = try engine.addTransition(clipID: clips[0].id, near: RationalTime(4), duration: RationalTime(1))
        XCTAssertEqual(result, TransitionResult(joined: 0, dips: 2, fades: 0))
        XCTAssertTrue(engine.project.audioCrossfades.isEmpty)
        XCTAssertEqual(engine.project.tracks[0].clips[0].fadeOut, AudioFade(duration: try RationalTime(12, 25), curve: .linear), "Half a second floors to whole frames")
        XCTAssertEqual(engine.project.tracks[0].clips[1].fadeIn, AudioFade(duration: try RationalTime(12, 25), curve: .linear), "Half a second floors to whole frames")
        XCTAssertEqual(engine.project.tracks[1].clips[1].fadeIn.curve, .equalPower)
        _ = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: output)
    }

    func testAddTransitionLeavesEdgesAlreadyJoinedElsewhere() throws {
        var (project, clips) = try linkedFixture()
        // The first shot's sound already crossfades into an overlapping sound on another track.
        let template = project.tracks[1].template
        var other = clips[3]; other.id = UUID(); other.linkGroupID = nil
        other.timelineStart = try RationalTime(4); other.sourceRange.start = try RationalTime(9)
        project.tracks.append(TimelineTrack(familyID: project.tracks[1].familyID, template: template, clips: [other]))
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: clips[2].id, incomingClipID: other.id, duration: RationalTime(1)))
        let result = try engine.addTransition(clipID: clips[0].id, near: RationalTime(4), duration: RationalTime(1))
        XCTAssertEqual(result.joined, 1, "Only the pictures dissolve")
        XCTAssertEqual(engine.project.audioCrossfades.count, 2)
        XCTAssertTrue(engine.project.audioCrossfades.contains { $0.outgoingClipID == clips[2].id && $0.incomingClipID == other.id })
    }

    func testEditsDissolveInvalidRelationsAndSplitRefusesInsideTheDissolve() throws {
        let (project, a, b) = try fixture()
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(1), curve: .linear))
        XCTAssertThrowsError(try engine.apply(.split(clipID: b.id, at: RationalTime(51, 10))))
        try engine.apply(.split(clipID: b.id, at: RationalTime(8)))
        XCTAssertTrue(engine.project.audioCrossfades.isEmpty, "A split outside the envelope removes the relation")
        engine.undo()
        XCTAssertEqual(engine.project.audioCrossfades.count, 1)
        try engine.apply(.move(clipID: b.id, trackID: engine.project.tracks[0].id, start: RationalTime(12)))
        XCTAssertTrue(engine.project.audioCrossfades.isEmpty, "A gap between the shots removes the dissolve")
        engine.undo()
        XCTAssertEqual(engine.project.audioCrossfades.count, 1)
    }
}

/// Decoded pixel check of fades and dissolves through a real FFmpeg render.
final class VideoTransitionRenderTests: XCTestCase {
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EditorCoreError.invalidModel("\(executable) failed: \(arguments.joined(separator: " "))") }
        return data
    }

    func testRenderedFadeFromBlackAndDissolveBlendDecodedPixels() throws {
        guard let ffmpeg = ProcessInfo.processInfo.environment["AFC_FFMPEG"] else {
            throw XCTSkip("Set AFC_FFMPEG to an FFmpeg executable to render transitions")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transition-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var assets: [MediaAsset] = []
        for color in ["red", "blue"] {
            let url = directory.appendingPathComponent("\(color).mov")
            _ = try run(ffmpeg, ["-hide_banner", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=25:d=20", "-c:v", "prores_ks", url.path])
            assets.append(MediaAsset(name: color, originalURL: url, duration: try RationalTime(20), streams: [.init(index: 0, kind: .video)]))
        }
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        let a = TimelineClip(assetID: assets[0].id, sourceRange: try TimeRange(start: RationalTime(2), duration: RationalTime(5)), selection: .video(streamIndex: 0))
        let b = TimelineClip(assetID: assets[1].id, sourceRange: try TimeRange(start: RationalTime(10), duration: RationalTime(5)),
                             timelineStart: try RationalTime(5), selection: .video(streamIndex: 0))
        let project = Project(settings: try SequenceSettings(width: 160, height: 90, frameRate: FrameRate(25), audioLayout: .stereo),
                              assets: assets, families: [family], tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [a, b])])
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(.setAudioCrossfade(outgoingClipID: a.id, incomingClipID: b.id, duration: RationalTime(2), curve: .linear))
        try engine.apply(.setFades(clipID: a.id, fadeIn: AudioFade(duration: try RationalTime(1)), fadeOut: .init()))
        try engine.apply(.setFades(clipID: b.id, fadeIn: .init(), fadeOut: AudioFade(duration: try RationalTime(1))))
        let output = directory.appendingPathComponent("render.mov")
        let command = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: engine.project), outputURL: output)
        _ = try run(ffmpeg, command.arguments)

        func pixel(_ frame: Int) throws -> (Double, Double, Double) {
            let data = try run(ffmpeg, ["-hide_banner", "-i", output.path, "-vf", "select=eq(n\\,\(frame)),crop=2:2:79:44",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            XCTAssertEqual(data.count, 12)
            return (Double(data[0]), Double(data[1]), Double(data[2]))
        }
        // Red fades up from black over the first second (frame n has n/25 opacity).
        let black = try pixel(0)
        XCTAssertLessThan(black.0 + black.1 + black.2, 20)
        let halfRed = try pixel(12)
        XCTAssertEqual(halfRed.0, 255 * 12 / 25, accuracy: 14); XCTAssertLessThan(halfRed.2, 14)
        let red = try pixel(99)
        XCTAssertGreaterThan(red.0, 240); XCTAssertLessThan(red.2, 14)
        // The dissolve runs from 4 s to 6 s; at the cut both pictures are at half strength.
        let middle = try pixel(125)
        XCTAssertEqual(middle.0, 127, accuracy: 14); XCTAssertEqual(middle.2, 127, accuracy: 14)
        let blue = try pixel(150)
        XCTAssertLessThan(blue.0, 14); XCTAssertGreaterThan(blue.2, 240)
        // Blue fades to black over the last second, reaching 1/25 on the final frame.
        let last = try pixel(249)
        XCTAssertLessThan(last.2, 24)
    }
}
