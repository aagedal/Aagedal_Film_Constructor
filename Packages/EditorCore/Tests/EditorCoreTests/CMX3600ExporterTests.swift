import Foundation
import Testing
@testable import EditorCore

private func edlFixture(rate: FrameRate = try! FrameRate(24), mode: TimecodeMode = .nonDropFrame) throws -> (Project, UUID, [UUID: CMX3600SourceTiming]) {
    let settings = try SequenceSettings(frameRate: rate, startTimecode: Timecode(parsing: mode == .dropFrame ? "01:00:00;00" : "01:00:00:00", rate: rate))
    let asset = MediaAsset(name: "camera.mov", duration: try RationalTime(100), streams: [.init(index: 0, kind: .video)])
    let template = TrackTemplate(kind: .video)
    let family = TrackFamily(baseName: "Picture", template: template)
    let first = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: rate.time(forFrames: 48), duration: rate.time(forFrames: 24)), timelineStart: try rate.time(forFrames: 12), selection: .video(streamIndex: 0))
    let second = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: rate.time(forFrames: 120), duration: rate.time(forFrames: 24)), timelineStart: try rate.time(forFrames: 48), selection: .video(streamIndex: 0))
    let track = TimelineTrack(familyID: family.id, template: template, clips: [second, first])
    let timing = CMX3600SourceTiming(frameRate: rate, startTimecode: try Timecode(parsing: mode == .dropFrame ? "02:00:00;00" : "02:00:00:00", rate: rate), reelName: "CAM001", streamIndex: 0, constantFrameRate: true)
    return (Project(settings: settings, assets: [asset], families: [family], tracks: [track]), track.id, [asset.id: timing])
}

private func edlReasons(_ project: Project, _ track: UUID, _ timing: [UUID: CMX3600SourceTiming]) throws -> [String] {
    do {
        _ = try CMX3600Exporter.export(project: project, trackID: track, sourceTiming: timing)
        Issue.record("Expected EDL rejection")
        return []
    } catch CMX3600ExportError.unsupported(let reasons) { return reasons }
}

@Test func cmxCutsHaveExactExclusiveSourceAndRecordEndpointsAndBlackGaps() throws {
    let (project, track, timing) = try edlFixture()
    let result = try CMX3600Exporter.export(project: project, trackID: track, projectName: "Assembly", sourceTiming: timing)
    #expect(result.edl == """
    TITLE: Assembly
    FCM: NON-DROP FRAME

    001  BL       V  C        00:00:00:00 00:00:00:12 01:00:00:00 01:00:00:12

    002  CAM001   V  C        02:00:02:00 02:00:03:00 01:00:00:12 01:00:01:12
    * FROM CLIP NAME: camera.mov

    003  BL       V  C        00:00:00:00 00:00:00:12 01:00:01:12 01:00:02:00

    004  CAM001   V  C        02:00:05:00 02:00:06:00 01:00:02:00 01:00:03:00
    * FROM CLIP NAME: camera.mov

    """)
    #expect(result.report.clipCount == 2)
    #expect(result.report.gapCount == 2)
    #expect(result.report.eventCount == 4)
}

@Test func cmxSelectedTrackNeverFlattensOtherLayersOrPadsSequenceTail() throws {
    var (project, track, timing) = try edlFixture()
    var other = project.tracks[0]
    other.id = UUID()
    other.clips = [TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(10)), selection: .video(streamIndex: 0))]
    project.tracks.insert(other, at: 0)
    let result = try CMX3600Exporter.export(project: project, trackID: track, sourceTiming: timing)
    #expect(result.report.clipCount == 2)
    #expect(result.report.eventCount == 4)
    #expect(result.report.notes.contains { $0.contains("other tracks") })
    #expect(try edlReasons(project, UUID(), timing).contains { $0.contains("existing") })
}

@Test func cmxRequiresIndependentSourceTimingAndRejectsUnqualifiedCFR() throws {
    let (project, track, timing) = try edlFixture()
    #expect(try edlReasons(project, track, [:]).contains { $0.contains("verified source") })
    let assetID = project.assets[0].id
    let original = timing[assetID]!
    let unqualified = CMX3600SourceTiming(frameRate: original.frameRate, startTimecode: original.startTimecode, reelName: original.reelName, streamIndex: 0)
    #expect(try edlReasons(project, track, [assetID: unqualified]).contains { $0.contains("constant-frame-rate") })
    let mismatch = CMX3600SourceTiming(frameRate: try FrameRate(25), startTimecode: original.startTimecode, reelName: original.reelName, streamIndex: 1, constantFrameRate: true)
    let reasons = try edlReasons(project, track, [assetID: mismatch])
    #expect(reasons.contains { $0.contains("match exactly") })
    #expect(reasons.contains { $0.contains("matching timing evidence") })
    var inconsistent = project
    inconsistent.assets[0].sourceTimecode = .init(frameCount: 1)
    #expect(try edlReasons(inconsistent, track, timing).contains { $0.contains("disagrees") })
}

@Test func cmxRejectsSubframesInsteadOfRoundingAndRejectsDayWrap() throws {
    var (project, track, timing) = try edlFixture()
    project.tracks[0].clips[0].sourceRange.start = try RationalTime(1, 48)
    #expect(try edlReasons(project, track, timing).contains { $0.contains("never rounds") })
    (project, track, timing) = try edlFixture()
    project.settings.startTimecode = try Timecode(parsing: "23:59:59:00", rate: project.settings.frameRate)
    #expect(try edlReasons(project, track, timing).contains { $0.contains("24-hour") })
    (project, track, timing) = try edlFixture()
    let assetID = project.assets[0].id
    timing[assetID] = CMX3600SourceTiming(frameRate: project.settings.frameRate, startTimecode: try Timecode(parsing: "23:59:59:00", rate: project.settings.frameRate), reelName: "CAM001", streamIndex: 0, constantFrameRate: true)
    #expect(try edlReasons(project, track, timing).contains { $0.contains("24-hour") })
}

@Test func cmxDropFrameAndFractionalRatesKeepExactFrameCounts() throws {
    for rate in [try FrameRate(24000, 1001), try FrameRate(30000, 1001)] {
        let mode: TimecodeMode = rate.supportsDropFrame ? .dropFrame : .nonDropFrame
        var (project, track, timing) = try edlFixture(rate: rate, mode: mode)
        project.tracks[0].clips = [TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: .zero, duration: rate.time(forFrames: 1800)), selection: .video(streamIndex: 0))]
        let result = try CMX3600Exporter.export(project: project, trackID: track, sourceTiming: timing)
        if mode == .dropFrame {
            #expect(result.edl.contains("FCM: DROP FRAME"))
            #expect(result.edl.contains("02:00:00:00 02:01:00:02 01:00:00:00 01:01:00:02"))
            #expect(!result.edl.contains(";"))
        } else { #expect(result.edl.contains("02:00:00:00 02:01:15:00 01:00:00:00 01:01:15:00")) }
    }
}

@Test func cmxRejectsInvalidNamesReelCollisionsAndUnsupportedGeometry() throws {
    var (project, track, timing) = try edlFixture()
    for reel in ["BL", "lower", "CAM_01", "TOOLONG01", "CAM\n001"] {
        timing[project.assets[0].id] = .init(frameRate: project.settings.frameRate, startTimecode: .init(), reelName: reel, streamIndex: 0, constantFrameRate: true)
        #expect(try edlReasons(project, track, timing).contains { $0.contains("reel names") })
    }
    (project, track, timing) = try edlFixture()
    var secondAsset = project.assets[0]; secondAsset.id = UUID()
    project.assets.append(secondAsset)
    project.tracks[0].clips[0].assetID = secondAsset.id
    timing[secondAsset.id] = timing[project.assets[0].id]
    #expect(try edlReasons(project, track, timing).contains { $0.contains("share a reel") })
    (project, track, timing) = try edlFixture()
    project.assets[0].name = "camera\nTITLE: injected"
    project.tracks[0].clips[0].scalingMode = .fill
    let reasons = try edlReasons(project, track, timing)
    #expect(reasons.contains { $0.contains("one line") })
    #expect(reasons.contains { $0.contains("geometry") })
}

@Test func cmxLimitsEventCountIncludingGaps() throws {
    var (project, track, timing) = try edlFixture()
    let rate = project.settings.frameRate
    project.tracks[0].clips = try (0..<500).map { index in
        TimelineClip(assetID: project.assets[0].id, sourceRange: try TimeRange(start: .zero, duration: rate.time(forFrames: 1)), timelineStart: try rate.time(forFrames: Int64(index * 2 + 1)), selection: .video(streamIndex: 0))
    }
    #expect(try edlReasons(project, track, timing).contains { $0.contains("999") })
    project.tracks[0].clips.removeLast()
    #expect(try CMX3600Exporter.export(project: project, trackID: track, sourceTiming: timing).report.eventCount == 998)
}

@Test func cmxAudioRequiresCompleteIdentityChannelsWithoutEnvelopes() throws {
    for layout in [ChannelLayout.mono, .stereo] {
        let settings = try SequenceSettings(audioLayout: layout)
        let template = TrackTemplate(kind: .audio, audioLayout: layout)
        let family = TrackFamily(baseName: "Audio", template: template)
        let asset = MediaAsset(name: "audio.wav", duration: try RationalTime(30), streams: [.init(index: 1, kind: .audio, audioLayout: layout)])
        let selection = AudioSourceSelection(channels: layout.channels.indices.map { SourceChannel(streamIndex: 1, channelIndex: $0) }, layout: layout)
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(1), duration: RationalTime(2)), selection: .audio(selection))
        let track = TimelineTrack(familyID: family.id, template: template, clips: [clip])
        var project = Project(settings: settings, assets: [asset], families: [family], tracks: [track])
        let timing = [asset.id: CMX3600SourceTiming(frameRate: settings.frameRate, startTimecode: .init(), reelName: "AUDIO1", streamIndex: 1)]
        let result = try CMX3600Exporter.export(project: project, trackID: track.id, sourceTiming: timing)
        #expect(result.edl.contains(layout == .stereo ? " AA  C " : " A  C "))
        project.tracks[0].clips[0].fadeIn = AudioFade(duration: try RationalTime(1))
        #expect(try edlReasons(project, track.id, timing).contains { $0.contains("fades") })
        project.tracks[0].clips[0].fadeIn = .init()
        project.tracks[0].template.gain = 0.5
        #expect(try edlReasons(project, track.id, timing).contains { $0.contains("unity") })
        project.tracks[0].template.gain = 1
        if layout == .stereo {
            project.tracks[0].template.routing.outputChannels = [1, 0]
            #expect(try edlReasons(project, track.id, timing).contains { $0.contains("remapping") })
            project.tracks[0].template.routing.outputChannels = []
            var reordered = selection
            reordered.channels.reverse()
            project.tracks[0].clips[0].selection = .audio(reordered)
            #expect(try edlReasons(project, track.id, timing).contains { $0.contains("reordered") })
        }
    }
}

@Test func cmxRejectsCrossfadesOffsetsEmptyTracksAndUnsupportedRates() throws {
    var audio = try DemoProjectFactory.musicCollision()
    audio.tracks[0].template.gain = 1
    var engine = try TimelineEditEngine(project: audio)
    try engine.apply(.setAudioCrossfade(outgoingClipID: audio.tracks[0].clips[0].id, incomingClipID: audio.tracks[0].clips[1].id, duration: RationalTime(2), curve: .equalPower))
    let timing = [audio.assets[0].id: CMX3600SourceTiming(frameRate: audio.settings.frameRate, startTimecode: .init(), reelName: "AUDIO1", streamIndex: 0)]
    #expect(try edlReasons(engine.project, audio.tracks[0].id, timing).contains { $0.contains("crossfade") })
    var (project, track, evidence) = try edlFixture()
    project.assets[0].streams[0].timeOffset = try RationalTime(1)
    #expect(try edlReasons(project, track, evidence).contains { $0.contains("offsets") })
    project.tracks[0].clips = []
    #expect(try edlReasons(project, track, evidence).contains { $0.contains("no clips") })
    (project, track, evidence) = try edlFixture(rate: FrameRate(60))
    #expect(try edlReasons(project, track, evidence).contains { $0.contains("Supported sequence rates") })
    (project, track, evidence) = try edlFixture(rate: FrameRate(30000, 1001))
    evidence[project.assets[0].id] = .init(frameRate: project.settings.frameRate, startTimecode: .init(mode: .dropFrame), reelName: "CAM001", streamIndex: 0, constantFrameRate: true)
    #expect(try edlReasons(project, track, evidence).contains { $0.contains("modes must match") })
}

@Test func cmxMarkersBecomeLocatorsUnderTheirEvent() throws {
    var (project, track, timing) = try edlFixture()
    let rate = project.settings.frameRate
    try project.addMarker(at: rate.time(forFrames: 6), color: .orange)
    try project.addMarker(at: rate.time(forFrames: 20), color: .green)
    try project.updateMarker(id: project.markers[1].id, name: "Look", note: "Hold here", color: .green)
    let edl = try CMX3600Exporter.export(project: project, trackID: track, sourceTiming: timing).edl
    #expect(edl.contains("""
    001  BL       V  C        00:00:00:00 00:00:00:12 01:00:00:00 01:00:00:12
    * LOC: 01:00:00:06 RED     Marker 1

    002  CAM001   V  C        02:00:02:00 02:00:03:00 01:00:00:12 01:00:01:12
    * FROM CLIP NAME: camera.mov
    * LOC: 01:00:00:20 GREEN   Look - Hold here
    """))
    try project.addMarker(at: rate.time(forFrames: 80))
    try project.addMarker(at: RationalTime(1, 100), name: "Off frame")
    try project.addMarker(at: rate.time(forFrames: 30), name: "Snö")
    let reasons = try edlReasons(project, track, timing)
    #expect(reasons.contains { $0.contains("after the selected track's final clip") })
    #expect(reasons.contains { $0.contains("Off frame") && $0.contains("frame boundary") })
    #expect(reasons.contains { $0.contains("Snö") && $0.contains("ASCII") })
}
