import AppKit
import EditorCore

@main struct NativeSmoke {
    @MainActor static func wait(_ condition: @MainActor () -> Bool, _ description: String) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "NativeSequenceMonitorSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: description])
    }
    @MainActor static func compareImage(_ controller: SequencePlaybackController, reference: URL) throws {
        guard let image = controller.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = image.dataProvider?.data else { fatalError("No native image bytes") }
        let expected = try Data(contentsOf: reference)
        let actual = bytes as Data
        guard actual.count == expected.count,
              zip(actual, expected).allSatisfy({ abs(Int($0.0) - Int($0.1)) <= 2 }) else {
            fatalError("Native image differs from independent FFmpeg reference")
        }
    }
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = try SequenceSettings(width: 80, height: 48, frameRate: FrameRate(24))
        let video = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Video", template: video)
        let asset = MediaAsset(name: "Native fixture", originalURL: source,
            duration: try RationalTime(2), streams: [.init(index: 0, kind: .video), .init(index: 1, kind: .audio, audioLayout: .stereo)])
        let clip = TimelineClip(assetID: asset.id,
            sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)), selection: .video(streamIndex: 0))
        let audio = TrackTemplate(kind: .audio, audioLayout: .stereo, gain: 0.05)
        let audioFamily = TrackFamily(baseName: "Audio", template: audio)
        let audioClip = TimelineClip(assetID: asset.id, sourceRange: clip.sourceRange,
            selection: .audio(.init(channels: [.init(streamIndex: 1, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo)))
        var project = Project(settings: settings, assets: [asset], families: [family, audioFamily],
            tracks: [.init(familyID: family.id, template: video, clips: [clip]),
                     .init(familyID: audioFamily.id, template: audio, clips: [audioClip])])
        let payload: [String: Any] = ["formatVersion": 1,
            "project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)),
            "mediaBookmarks": [:], "proxyBookmarks": [:], "proxyJobs": []]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: source.deletingLastPathComponent().appendingPathComponent("fixture.afcproject"))
        let controller = SequencePlaybackController()
        guard controller.available else { fatalError("Native runtime branch was not compiled") }
        var position = 0.0
        controller.positionChanged = { position = $0 }
        controller.activate(project: project, seconds: 0)
        do { try await wait({ !controller.isPreparing && controller.image != nil }, "Initial native frame was not displayed") }
        catch { print("Native monitor status: \(controller.message)"); throw error }
        controller.update(project: project, seconds: 0.5)
        try await wait({ !controller.isPreparing && controller.displayedFrameIndex == 12 && abs(position - 0.5) < 0.000001 }, "Native seek did not present exact frame 12/position 0.5")
        try compareImage(controller, reference: source.deletingLastPathComponent().appendingPathComponent("seek.rgb"))
        controller.play()
        try await wait({ controller.isPlaying }, "Live output failed to start: \(controller.message)")
        try await wait({ position > 0.55 }, "Native sample clock did not advance")
        controller.pause()
        let paused = position
        try await Task.sleep(for: .milliseconds(100))
        guard !controller.isPlaying, position == paused else { fatalError("Pause advanced timeline position") }
        for index in project.tracks.indices {
            project.tracks[index].clips[0].sourceRange = try TimeRange(start: RationalTime(1), duration: RationalTime(1))
        }
        controller.update(project: project, seconds: 0)
        try await wait({ !controller.isPreparing && controller.image != nil }, "Edited-plan native rebuild failed: \(controller.message)")
        try await wait({ controller.displayedFrameIndex == 0 && position == 0 }, "Edited plan did not present frame zero")
        try compareImage(controller, reference: source.deletingLastPathComponent().appendingPathComponent("edited.rgb"))
        controller.play()
        try await wait({ controller.isPlaying }, "Edited sequence did not play")
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        guard !controller.isPlaying else { fatalError("Close did not pause") }
        print("Native app controller frame parity/exact seek/play/sample-clock/pause/edit/replay/deactivation smoke passed")
    }
}
