import Foundation
import Testing
@testable import EditorCore

@Test func rationalCanonicalArithmeticAndOverflow() throws {
    #expect(try RationalTime(2, 4) == RationalTime(1, 2))
    #expect(try RationalTime(-2, -4) == RationalTime(1, 2))
    #expect(try RationalTime(1, 3).adding(RationalTime(1, 6)) == RationalTime(1, 2))
    #expect(try RationalTime(7, 3).subtracting(RationalTime(1, 3)) == RationalTime(2))
    #expect(try RationalTime(.max, 2).multiplied(by: RationalTime(2, .max)) == RationalTime(1))
    #expect(throws: EditorCoreError.overflow) { try RationalTime(.max).adding(RationalTime(1)) }
    #expect(throws: EditorCoreError.invalidTime) { try RationalTime(1, 0) }
    #expect(try RationalTime(.max, .max - 1).compared(to: RationalTime(.max - 1, .max)) == .orderedDescending)
    #expect(try RationalTime(.min, .max).compared(to: RationalTime(-1)) == .orderedAscending)
}

@Test func decodedExactTimeRejectsInvalidDenominator() throws {
    let data = Data(#"{"numerator":1,"denominator":0}"#.utf8)
    #expect(throws: EditorCoreError.invalidTime) { try JSONDecoder().decode(RationalTime.self, from: data) }
    let badRate = Data(#"{"value":{"numerator":0,"denominator":1}}"#.utf8)
    #expect(throws: EditorCoreError.invalidFrameRate) { try JSONDecoder().decode(FrameRate.self, from: badRate) }
    var badSettings = try SequenceSettings()
    badSettings.width = 0
    #expect(throws: EditorCoreError.invalidSettings) { try JSONDecoder().decode(SequenceSettings.self, from: JSONEncoder().encode(badSettings)) }
    let badRange = Data(#"{"start":{"numerator":0,"denominator":1},"duration":{"numerator":-1,"denominator":1}}"#.utf8)
    #expect(throws: EditorCoreError.invalidTime) { try JSONDecoder().decode(TimeRange.self, from: badRange) }
}

@Test func exactFrameRateAndDropFrameBoundaries() throws {
    let rate = try FrameRate(30000, 1001)
    #expect(try rate.time(forFrames: 30000) == RationalTime(1001))
    #expect(try Timecode(frameCount: 1799, mode: .dropFrame).formatted(rate: rate) == "00:00:59;29")
    #expect(try Timecode(frameCount: 1800, mode: .dropFrame).formatted(rate: rate) == "00:01:00;02")
    #expect(try Timecode(frameCount: 17982, mode: .dropFrame).formatted(rate: rate) == "00:10:00;00")
    #expect(try Timecode(frameCount: 2589408, mode: .dropFrame).formatted(rate: rate) == "00:00:00;00")
    let sixty = try FrameRate(60000, 1001)
    #expect(try Timecode(frameCount: 3600, mode: .dropFrame).formatted(rate: sixty) == "00:01:00;04")
    #expect(try Timecode(frameCount: 1800).formatted(rate: rate) == "00:01:00:00")
    #expect(throws: EditorCoreError.invalidTimecode) { try Timecode(mode: .dropFrame).formatted(rate: FrameRate(24)) }
    #expect(throws: EditorCoreError.invalidTimecode) { try SequenceSettings(frameRate: FrameRate(25), startTimecode: Timecode(mode: .dropFrame)) }
}

@Test func adjacencyAndProjectRoundTrip() throws {
    let a = try TimeRange(start: .zero, duration: RationalTime(5))
    let b = try TimeRange(start: RationalTime(5), duration: RationalTime(3))
    #expect(try !a.overlaps(b))
    #expect(try a.overlaps(TimeRange(start: RationalTime(4), duration: RationalTime(2))))
    let project = try DemoProjectFactory.musicCollision()
    try project.validate()
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
    var corrupt = project
    corrupt.tracks[0].clips[0].sourceRange.duration = try RationalTime(31)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(corrupt)) }
}

@Test func projectRejectsMissingIdentityAndUnknownChannelMapping() throws {
    var project = try DemoProjectFactory.musicCollision()
    project.tracks[0].clips[0].assetID = UUID()
    #expect(throws: (any Error).self) { try project.validate() }
    project = try DemoProjectFactory.musicCollision()
    project.tracks[0].clips[0].selection = .audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0)], layout: .stereo))
    #expect(throws: (any Error).self) { try TimelineRenderPlan(project: project) }
    project = try DemoProjectFactory.musicCollision()
    project.assets[0].streams.append(project.assets[0].streams[0])
    #expect(throws: (any Error).self) { try project.validate() }
    #expect(ChannelLayout(channels: [nil, nil]) != .stereo)
}

@Test func renderPlanPreservesAbsolutePositionsSourceMapsAndLayers() throws {
    var project = try DemoProjectFactory.musicCollision()
    let videoTemplate = TrackTemplate(kind: .video)
    let family = TrackFamily(baseName: "Video", template: videoTemplate)
    let asset = MediaAsset(name: "Video", duration: try RationalTime(100), streams: [.init(index: 3, kind: .video, timeOffset: try RationalTime(1, 2))])
    let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(17, 3), duration: RationalTime(8)), timelineStart: try RationalTime(2), selection: .video(streamIndex: 3), scalingMode: .fill)
    project.assets.append(asset); project.families.append(family)
    project.tracks.insert(.init(familyID: family.id, template: videoTemplate, clips: [clip]), at: 0)
    let plan = try TimelineRenderPlan(project: project)
    #expect(plan.components[0].layerOrder == 0)
    #expect(try plan.components[0].sourceStreams[0].timeOffset == RationalTime(1, 2))
    #expect(try plan.components[0].sourceRange.start == RationalTime(17, 3))
    #expect(try plan.components[0].timelineRange.start == RationalTime(2))
    #expect(plan.components[0].scalingMode == .fill)
    #expect(plan.components[1].layerOrder == 1)
    #expect(plan.components[1].gain == 0.8)
    #expect(plan.components[1].selection == project.tracks[1].clips[0].selection)
    #expect(try plan.duration == RationalTime(10))
}
