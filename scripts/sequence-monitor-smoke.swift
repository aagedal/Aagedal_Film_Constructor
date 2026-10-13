import AppKit
import EditorCore

@MainActor final class FakeSequenceBackend: SequencePlaybackBackend {
    var position: Double = 0
    var isPlaying = false
    var display: ((CGImage, Int64) -> Void)?
    var failure: ((any Error) -> Void)?
    var seeks: [Int64] = []
    var closed = false
    var playDelay: Duration = .zero
    func play() async throws {
        try await Task.sleep(for: playDelay)
        isPlaying = true
    }
    func pause() { isPlaying = false }
    func seek(toFrame frame: Int64) async throws {
        try await Task.sleep(for: .milliseconds(5))
        seeks.append(frame); position = Double(frame) / 24
    }
    func close() async { closed = true }
}

@main struct Smoke {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ text: String) throws {
        if !value() { throw NSError(domain: "SequenceMonitorSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    }
    @MainActor static func settle(_ controller: SequencePlaybackController) async throws {
        for _ in 0..<200 {
            if !controller.isPreparing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SequenceMonitorSmoke", code: 2)
    }
    @MainActor static func main() async throws {
        let unavailable = SequencePlaybackController(useNativeDefault: false)
        let project = try DemoProjectFactory.musicCollision()
        unavailable.activate(project: project, seconds: 0)
        unavailable.play()
        try check(!unavailable.available && !unavailable.isPlaying && !unavailable.isPreparing,
                  "Missing runtime must remain explicitly unavailable")
        try check(unavailable.message.contains("unavailable"), "Unavailable state must explain missing runtime")
        var backends: [FakeSequenceBackend] = []
        let controller = SequencePlaybackController(factory: { _ in
            let backend = FakeSequenceBackend(); backends.append(backend); return backend
        })
        controller.activate(project: project, seconds: 1)
        controller.update(project: project, seconds: 2)
        controller.update(project: project, seconds: 3)
        try await settle(controller)
        try check(backends.count == 1 && backends[0].position == 3, "Rapid scrubs must converge on latest seek")
        backends[0].playDelay = .milliseconds(40)
        controller.play()
        controller.pause()
        try await settle(controller)
        try check(!backends[0].isPlaying && !controller.isPlaying, "Pause during priming must reject late play")
        controller.play()
        controller.update(project: project, seconds: 5)
        controller.pause()
        try await settle(controller)
        try check(!controller.isPlaying && backends[0].position == 5,
                  "Scrub and pause during priming must reject old play and preserve latest seek")
        controller.play(); try await settle(controller)
        try check(controller.isPlaying, "Explicit play can restart")
        var organized = project
        let binID = try organized.createMediaBin(name: "Sources")
        controller.update(project: organized, seconds: 5)
        try await settle(controller)
        try check(controller.isPlaying && backends.count == 1, "Creating bins must preserve playing runtime")
        try organized.updateMediaBin(id: binID, name: "Footage", parentID: nil)
        controller.update(project: organized, seconds: 5)
        try await settle(controller)
        try check(controller.isPlaying && backends.count == 1, "Renaming bins must preserve playing runtime")
        try organized.moveAssets([project.assets[0].id], toMediaBin: binID)
        controller.update(project: organized, seconds: 5)
        try await settle(controller)
        try check(controller.isPlaying && backends.count == 1, "Moving media between bins must preserve playing runtime")
        try organized.removeMediaBin(id: binID)
        controller.update(project: organized, seconds: 5)
        try await settle(controller)
        try check(controller.isPlaying && backends.count == 1, "Removing bins must preserve playing runtime")
        var edited = project
        edited.preferences.automaticallyRemoveEmptyTracks.toggle()
        controller.update(project: edited, seconds: 4)
        try check(!controller.isPlaying, "Edits must pause synchronously")
        try await settle(controller)
        try check(backends.count == 2 && backends[0].closed && backends[1].position == 4,
                  "Edited plan must replace and close previous runtime")
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(30))
        try check(backends[1].closed && !controller.isPlaying, "Deactivation must close runtime")
        controller.activate(project: edited, seconds: 2)
        try await settle(controller)
        try check(backends.count == 3 && backends[2].position == 2, "Reappearance must restore current position")
        controller.update(project: edited, seconds: 6)
        controller.deactivate()
        controller.activate(project: edited, seconds: 7)
        try await settle(controller)
        try check(backends.last?.position == 7 && !controller.isPlaying,
                  "Rapid hide/show during a pending seek must drain and restore latest target")
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(30))
        print("Sequence monitor lifecycle smoke passed")
    }
}
