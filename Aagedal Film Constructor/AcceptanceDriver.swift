import AppKit
import EditorCore

/// Opt-in end-to-end acceptance run inside the real application. Never active in
/// ordinary sessions: it requires AFC_ACCEPTANCE_DIR. Media comes from
/// AFC_ACCEPTANCE_MEDIA (newline- or |-separated paths). The driver imports through the
/// timeline drop path, presses real keys (Tab, Space, ⇧⌘E) through AppKit's event
/// dispatch, renders the export sheet's plan, and saves in-process window snapshots.
/// Snapshots use view caching, which needs no screen-recording permission but may
/// omit hardware-composited video layers.
@MainActor
enum AcceptanceDriver {
    private static var started = false
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func start(store: EditorStore) {
        guard let output = outputDirectory, !started else { return }
        started = true
        let media = (ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_MEDIA"] ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "|" }).map { URL(fileURLWithPath: String($0)) }
        Task { @MainActor in
            var log: [[String: Any]] = []
            func record(_ step: String, _ details: [String: Any] = [:]) {
                var entry = details; entry["step"] = step; entry["uptime"] = ProcessInfo.processInfo.systemUptime
                log.append(entry)
                if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output.appendingPathComponent("acceptance.json"))
                }
            }
            func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if condition() { return true }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return condition()
            }
            func workspaceWindow() -> NSWindow? {
                NSApp.windows.first { $0.isVisible && NSDocumentController.shared.document(for: $0) != nil }
            }
            func snapshot(_ name: String, window: NSWindow?) {
                guard let window, let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
            let registry = EditorCommandRegistry()
            var dispatchPaths: [String] = []
            /// Real AppKit key events when the window can be key; otherwise (a background
            /// launch cannot take focus) the same registry action the menu shortcut performs.
            @MainActor func press(_ command: EditorCommandID, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
                guard let window = workspaceWindow() else { return }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if window.isKeyWindow && NSApp.isActive {
                    func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
                    NSApp.mainMenu?.update()
                    let item = items(NSApp.mainMenu).first { $0.title == command.title }
                    dispatchPaths.append("\(command.rawValue):keyEvent firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) })) menuItem=\(item.map { "\($0.isEnabled)/'\($0.keyEquivalent)'" } ?? "missing")")
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                            NSApp.sendEvent(event)
                        }
                    }
                } else {
                    dispatchPaths.append("\(command.rawValue):registry")
                    let scope: EditorCommandScope = store.showSequenceMonitor ? .timeline : .source
                    if registry.isEnabled(command, store: store, scope: scope) {
                        registry.perform(command, store: store, scope: scope)
                    } else { dispatchPaths.append("\(command.rawValue):disabled") }
                }
            }

            NSApp.activate()
            _ = await wait(15) { workspaceWindow() != nil }
            workspaceWindow()?.makeKeyAndOrderFront(nil)
            let ready = await wait(10) { workspaceWindow()?.isKeyWindow == true }
            workspaceWindow()?.setContentSize(NSSize(width: 1440, height: 900))
            try? await Task.sleep(for: .milliseconds(500))
            record("launch", ["keyWindow": ready])
            snapshot("01-launch", window: workspaceWindow())

            var sawConversion = false
            let accepted = store.importMediaToTimeline(urls: media, at: 0)
            let imported = await wait(600) {
                if store.statusMessage.hasPrefix("Converting") { sawConversion = true }
                return !store.isImporting
            }
            record("import", ["accepted": accepted, "finished": imported, "sawConvertingStatus": sawConversion,
                              "status": store.statusMessage, "error": store.errorMessage ?? "",
                              "assets": store.project.assets.map(\.name),
                              "clips": store.project.tracks.reduce(0) { $0 + $1.clips.count },
                              "durationSeconds": store.duration])
            try? await Task.sleep(for: .seconds(1))
            snapshot("02-imported", window: workspaceWindow())

            if !store.showSequenceMonitor { press(.toggleViewer, "\t", keyCode: 48) }
            let monitoring = await wait(5) { store.showSequenceMonitor && store.sequencePlayback != nil }
            let prepared = await wait(30) { store.sequencePlayback?.isPreparing == false }
            record("sequence_viewer", ["tabSwitchedToSequence": monitoring, "prepared": prepared,
                                       "message": store.sequencePlayback?.message ?? ""])
            let before = store.playheadSeconds
            press(.togglePlayback, " ", keyCode: 49)
            let playing = await wait(10) { store.sequencePlayback?.isPlaying == true }
            try? await Task.sleep(for: .seconds(2))
            snapshot("03-playing", window: workspaceWindow())
            let during = store.playheadSeconds
            press(.togglePlayback, " ", keyCode: 49)
            let paused = await wait(5) { store.sequencePlayback?.isPlaying == false }
            try? await Task.sleep(for: .milliseconds(500))
            let after = store.playheadSeconds
            try? await Task.sleep(for: .milliseconds(500))
            record("space_transport", ["startedPlaying": playing, "paused": paused,
                                       "playheadBefore": before, "playheadWhilePlaying": during,
                                       "playheadAfterPause": after, "playheadStable": abs(store.playheadSeconds - after) < 0.001,
                                       "notice": store.sequencePlayback?.message ?? ""])

            press(.exportSequence, "e", keyCode: 14, modifiers: [.command, .shift])
            let sheetOpened = await wait(5) { store.renderExportDraft != nil }
            try? await Task.sleep(for: .seconds(4))
            snapshot("04-export-sheet", window: workspaceWindow()?.attachedSheet ?? workspaceWindow())
            record("export_sheet", ["openedByShortcut": sheetOpened, "error": store.errorMessage ?? "",
                                    "enabled": registry.isEnabled(.exportSequence, store: store, scope: .document)])
            if let draft = store.renderExportDraft {
                for format in [RenderOutputFormat.h264, .proRes422HQ] {
                    let destination = output.appendingPathComponent("acceptance-\(format.rawValue).\(format.fileExtension)")
                    let started = Date()
                    do {
                        let result = try await SequenceExportService.shared.export(plan: draft.plan, to: destination, options: .init(format: format))
                        record("export", ["format": format.rawValue, "frames": result.videoFrames, "samples": result.audioSamples,
                                          "warnings": result.warnings, "seconds": Date().timeIntervalSince(started)])
                    } catch {
                        record("export", ["format": format.rawValue, "error": error.localizedDescription])
                    }
                }
                store.renderExportDraft = nil
            }
            record("done", ["dispatch": dispatchPaths])
            exit(0)
        }
    }
}
