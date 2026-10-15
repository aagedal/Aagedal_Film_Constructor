import XCTest
@testable import EditorCore

final class VideoCompositionPlanTests: XCTestCase {
    private func fixture(seed: UInt64, tracks: Int = 12, clips: Int = 20) throws -> Project {
        var state = seed
        func random(_ limit: Int64) -> Int64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int64((state >> 32) % UInt64(limit))
        }
        let video = MediaAsset(name: "Video", duration: try RationalTime(10_000), streams: [.init(index: 0, kind: .video)])
        let still = MediaAsset(name: "Still", duration: try RationalTime(10_000))
        let family = TrackFamily(baseName: "Picture", template: .init(kind: .video))
        var result: [TimelineTrack] = []
        for _ in 0..<tracks {
            var start = random(5)
            var components: [TimelineClip] = []
            for _ in 0..<clips {
                let duration = random(20) + 1
                let isStill = random(3) == 0
                components.append(TimelineClip(assetID: isStill ? still.id : video.id,
                    sourceRange: try TimeRange(start: .zero, duration: RationalTime(duration * 1001, 30_000)),
                    timelineStart: try RationalTime(start * 1001, 30_000), selection: isStill ? .still : .video(streamIndex: 0)))
                start += duration + random(7)
            }
            result.append(TimelineTrack(familyID: family.id, template: family.template, clips: components.reversed()))
        }
        return Project(settings: try SequenceSettings(), assets: [video, still], families: [family], tracks: result)
    }

    func testSweepAndTrackReuseMatchIndependentBoundaryOracle() throws {
        for seed: UInt64 in 1...12 {
            let render = try TimelineRenderPlan(project: fixture(seed: seed))
            let compiled = try VideoCompositionPlan(render)
            let ends = try render.components.map { try $0.timelineRange.end() }
            let boundaries = try Set([.zero, render.duration] + render.components.map(\.timelineRange.start) + ends)
                .sorted { try $0.compared(to: $1) == .orderedAscending }
            var maximumVideo = 0, maximumStills = 0
            for boundary in boundaries.dropLast() {
                let active = try render.components.indices.filter {
                    try render.components[$0].timelineRange.start.compared(to: boundary) != .orderedDescending &&
                        ends[$0].compared(to: boundary) == .orderedDescending
                }.sorted {
                    let a = render.components[$0], b = render.components[$1]
                    return a.layerOrder == b.layerOrder ? a.clipID.uuidString < b.clipID.uuidString : a.layerOrder < b.layerOrder
                }
                let stills = active.filter { render.components[$0].selection == .still }.count
                maximumVideo = max(maximumVideo, active.count - stills)
                maximumStills = max(maximumStills, stills)
                var expected: [Int] = []
                for index in active {
                    expected.append(index)
                    if case .video = render.components[index].selection { break }
                }
                let segment = try XCTUnwrap(try compiled.instructions.first {
                    try $0.timeRange.start.compared(to: boundary) != .orderedDescending &&
                        $0.timeRange.end().compared(to: boundary) == .orderedDescending
                })
                XCTAssertEqual(segment.componentIndices, expected)
            }
            XCTAssertEqual(compiled.trackCount, maximumVideo + maximumStills)
            XCTAssertEqual(compiled.placements.count, render.components.count)
            XCTAssertEqual(compiled.instructions.first?.timeRange.start, .zero)
            XCTAssertEqual(try compiled.instructions.last?.timeRange.end(), render.duration)
            for (a, b) in zip(compiled.instructions, compiled.instructions.dropFirst()) {
                XCTAssertEqual(try a.timeRange.end(), b.timeRange.start)
                XCTAssertNotEqual(a.componentIndices, b.componentIndices)
            }
            for placements in Dictionary(grouping: compiled.placements, by: \.trackIndex).values {
                XCTAssertEqual(Set(placements.map { render.components[$0.componentIndex].selection == .still }).count, 1)
                for (a, b) in zip(placements, placements.dropFirst()) {
                    XCTAssertNotEqual(try ends[a.componentIndex].compared(to: render.components[b.componentIndex].timelineRange.start), .orderedDescending)
                }
            }
        }
    }

    func testAdjacentStillsReuseOneTrackAndKeepExactFractionalHolds() throws {
        var project = try fixture(seed: 1, tracks: 1, clips: 1)
        let still = project.assets[1]
        project.tracks[0].clips = try (0..<1000).reversed().map { index in
            TimelineClip(assetID: still.id,
                sourceRange: try TimeRange(start: RationalTime(3), duration: RationalTime(1001, 30_000)),
                timelineStart: try RationalTime(Int64(index) * 1001, 30_000), selection: .still)
        }
        let render = try TimelineRenderPlan(project: project)
        let compiled = try VideoCompositionPlan(render)
        XCTAssertEqual(compiled.trackCount, 1)
        XCTAssertEqual(compiled.instructions.count, 1000)
        XCTAssertEqual(compiled.placements.map(\.componentIndex), Array(0..<1000))
        XCTAssertTrue(compiled.instructions.allSatisfy { $0.timeRange.duration == (try? RationalTime(1001, 30_000)) })
    }

    func testHiddenCutsCoalesceAndLeadingTrailingGapsCoverAudioDuration() throws {
        var project = try fixture(seed: 3, tracks: 1, clips: 1)
        let original = project.tracks[0]
        project.tracks = try (0..<2000).map { index in
            var track = original
            track.id = UUID()
            track.clips[0].id = UUID()
            track.clips[0].assetID = project.assets[0].id
            track.clips[0].selection = .video(streamIndex: 0)
            track.clips[0].timelineStart = try RationalTime(Int64(index + 1), 30_000)
            track.clips[0].sourceRange = try TimeRange(start: .zero, duration: RationalTime(Int64(4001 - index * 2), 30_000))
            return track
        }
        let render = try TimelineRenderPlan(project: project)
        let compiled = try VideoCompositionPlan(render)
        XCTAssertEqual(compiled.trackCount, 2000)
        XCTAssertEqual(compiled.instructions.count, 2) // Leading black, then opaque top clip.
        XCTAssertEqual(compiled.instructions.map(\.componentIndices), [[], [0]])

        let audio = MediaAsset(name: "Audio", duration: try RationalTime(10), streams: [.init(index: 0, kind: .audio, audioLayout: .stereo)])
        let family = TrackFamily(baseName: "Audio", template: .init(kind: .audio, audioLayout: .stereo))
        let clip = TimelineClip(assetID: audio.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(10)),
            selection: .audio(.init(channels: [.init(streamIndex: 0, channelIndex: 0), .init(streamIndex: 0, channelIndex: 1)], layout: .stereo)))
        project.assets.append(audio); project.families.append(family)
        project.tracks.append(TimelineTrack(familyID: family.id, template: family.template, clips: [clip]))
        let withAudio = try VideoCompositionPlan(TimelineRenderPlan(project: project))
        XCTAssertEqual(withAudio.instructions.count, 3)
        XCTAssertEqual(withAudio.instructions.last?.componentIndices, [])
        XCTAssertEqual(try withAudio.instructions.last?.timeRange.end(), try RationalTime(10))
        project.tracks = [project.tracks.last!]
        let audioOnly = try VideoCompositionPlan(TimelineRenderPlan(project: project))
        XCTAssertEqual(audioOnly.trackCount, 0)
        XCTAssertTrue(audioOnly.placements.isEmpty && audioOnly.instructions.isEmpty)
    }
}
