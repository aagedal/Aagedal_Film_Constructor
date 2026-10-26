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
    /// "container" selects the app's own temporary folder, which a sandboxed build can
    /// always write; progress is then also streamed to stderr for the harness.
    static var outputDirectory: URL? {
        guard let value = ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_DIR"] else { return nil }
        if value == "container" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afc-acceptance-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static func start(store: EditorStore) {
        if let probe = ProcessInfo.processInfo.environment["AFC_PANEL_PROBE"], !started {
            // Diagnostic: open the Import panel (after an optional step) and report whether
            // the panel service ran it. Steps: launch, import, play.
            started = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let media = (ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_MEDIA"] ?? "").split(separator: "|").map { URL(fileURLWithPath: String($0)) }
                if probe != "launch" {
                    _ = store.importMediaToTimeline(urls: media, at: 0)
                    while store.isImporting { try? await Task.sleep(for: .milliseconds(100)) }
                }
                if probe == "play" {
                    store.showSequenceMonitor = true
                    try? await Task.sleep(for: .seconds(2))
                    store.sequencePlayback?.play()
                    try? await Task.sleep(for: .seconds(2))
                    store.sequencePlayback?.pause()
                }
                FileHandle.standardError.write(Data("AFC_PANEL_PROBE step=\(probe) error=\(store.errorMessage ?? "")\n".utf8))
                if probe == "export-complete" {
                    // Complete the real folder panel: Return opens it, one-shot timers in the panel's
                    // modal mode navigate to a folder and confirm, then the export must appear there.
                    store.beginRenderExport()
                    try? await Task.sleep(for: .seconds(3))
                    let window = NSApp.windows.first { NSDocumentController.shared.document(for: $0) != nil }
                    guard let sheet = window?.attachedSheet else { FileHandle.standardError.write(Data("AFC_PANEL_PROBE no sheet\n".utf8)); exit(1) }
                    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AFC_PANEL_FOLDER"] ?? NSTemporaryDirectory(), isDirectory: true)
                    func log(_ text: String) { FileHandle.standardError.write(Data("AFC_PANEL_PROBE \(text)\n".utf8)) }
                    func once(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
                        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
                        RunLoop.main.add(timer, forMode: .modalPanel)
                    }
                    once(4) {
                        guard let panel = NSApp.modalWindow as? NSOpenPanel else { log("no panel modal=\(NSApp.modalWindow?.className ?? "nil")"); exit(2) }
                        panel.directoryURL = folder
                        log("navigating to \(folder.path)")
                    }
                    var returned: URL?
                    once(7) {
                        guard let panel = NSApp.modalWindow as? NSOpenPanel else { log("panel gone before confirm"); exit(3) }
                        returned = panel.url
                        log("panel directory=\(panel.directoryURL?.path ?? "nil") url=\(panel.url?.path ?? "nil")")
                        panel.ok(nil)
                    }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                            NSApp.sendEvent(event)
                        }
                    }
                    // runModal has returned once this runs. The panel returns its selected item when one is
                    // highlighted, so the destination may differ from the navigated folder: cancel the export
                    // through the sheet (its cleanup removes staging) and check nothing was left behind.
                    let destination = (window?.attachedSheet != nil) ? "sheet open" : "sheet closed"
                    log("runModal returned; \(destination)")
                    try? await Task.sleep(for: .milliseconds(300))
                    store.renderExportDraft = nil
                    try? await Task.sleep(for: .seconds(3))
                    let leftovers = returned.map { url in
                        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasPrefix(".afc-export-") || $0 == "Sequence.mov" }
                    } ?? []
                    log("export cancelled; sheet dismissed=\(window?.attachedSheet == nil) leftovers=\(leftovers.count)")
                    exit(0)
                }
                if probe == "export" || probe == "export-panel" {
                    store.beginRenderExport()
                    try? await Task.sleep(for: .seconds(3))
                    let window = NSApp.windows.first { NSDocumentController.shared.document(for: $0) != nil }
                    guard let sheet = window?.attachedSheet else { FileHandle.standardError.write(Data("AFC_PANEL_PROBE no sheet\n".utf8)); exit(1) }
                    RunLoop.main.add(Timer(timeInterval: 4, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            let alert = NSApp.windows.first { $0.isVisible && $0.className.contains("Alert") }
                            FileHandle.standardError.write(Data("AFC_PANEL_PROBE modal=\(NSApp.modalWindow?.className ?? "nil") alert=\(alert != nil)\n".utf8))
                            exit(0)
                        }
                    }, forMode: .modalPanel)
                    if probe == "export" {
                        // Synthesized Return in the focused filename field.
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                                NSApp.sendEvent(event)
                            }
                        }
                    } else {
                        // Same panel configuration, opened directly while the sheet is up.
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                        panel.canCreateDirectories = true; panel.prompt = "Export"
                        _ = panel.runModal()
                    }
                    return
                }
                RunLoop.main.add(Timer(timeInterval: 4, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let alert = NSApp.windows.first { $0.isVisible && $0.className.contains("Alert") }
                        FileHandle.standardError.write(Data("AFC_PANEL_PROBE modal=\(NSApp.modalWindow?.className ?? "nil") alert=\(alert != nil)\n".utf8))
                        exit(0)
                    }
                }, forMode: .modalPanel)
                store.importMedia()
            }
            return
        }
        guard let output = outputDirectory, !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["AFC_STORY"] == "1" {
            let entries = (ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_MEDIA"] ?? "").split(separator: "|").map(String.init)
            StoryDriver.run(store: store, output: output, media: entries)
            return
        }
        let requestedMedia = (ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_MEDIA"] ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "|" }).map { path -> URL in
                // Relative paths name media bundled into Resources, readable inside the sandbox.
                path.hasPrefix("/") ? URL(fileURLWithPath: String(path))
                    : Bundle.main.resourceURL!.appendingPathComponent(String(path))
            }
        Task { @MainActor in
            var media = requestedMedia
            var log: [[String: Any]] = []
            func record(_ step: String, _ details: [String: Any] = [:]) {
                var entry = details; entry["step"] = step; entry["uptime"] = ProcessInfo.processInfo.systemUptime
                log.append(entry)
                if let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                    FileHandle.standardError.write(Data("AFC_ACCEPTANCE ".utf8) + line + Data([10]))
                }
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
                    // The scope EditorKeyboardRouter uses for a key press.
                    let scope: EditorCommandScope = command.scope == .source && store.showSequenceMonitor ? .timeline : .document
                    if registry.isEnabled(command, store: store, scope: scope) {
                        registry.perform(command, store: store, scope: scope)
                    } else { dispatchPaths.append("\(command.rawValue):disabled") }
                }
            }

            // AnyObject dynamic lookup reaches AppKit and SwiftUI accessibility elements alike.
            func children(_ element: AnyObject) -> [AnyObject] {
                (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
            }
            func containsText(_ text: String, in view: NSView) -> Bool {
                func search(_ element: AnyObject) -> Bool {
                    let label: String?? = element.accessibilityLabel?()
                    let title: String?? = element.accessibilityTitle?()
                    if [label, title].contains(where: { $0??.contains(text) == true }) { return true }
                    return children(element).contains { search($0) }
                }
                return search(view)
            }
            /// Complete the next open/save panel: navigate to `directory`, name it, confirm.
            var panelUnavailable: [String] = []
            func completePanel(directory: URL, filename: String?) -> Timer {
                var navigated = false
                var firstSeen: Date?
                let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        // An alert instead of the panel means the system file-panel service refused
                        // this process (unsigned builds in some sessions). Cancel it and report.
                        let alert = NSApp.windows.first { $0.isVisible && $0.className.contains("Alert") }
                        if let modal = alert ?? NSApp.modalWindow.flatMap({ $0 is NSSavePanel ? nil : $0 }) {
                            panelUnavailable.append(modal.className)
                            timer.invalidate()
                            NSApp.abortModal()
                            return
                        }
                        let panel = (NSApp.modalWindow as? NSSavePanel)
                            ?? (NSApp.windows.compactMap { $0.attachedSheet as? NSSavePanel }.first)
                        guard let panel, panel.isVisible else { return }
                        // The panel is hosted by a system service; configuring it while that
                        // service is still connecting makes it fail. Let it settle first.
                        let seen = firstSeen ?? Date()
                        firstSeen = seen
                        guard Date().timeIntervalSince(seen) > 2 else { return }
                        if !navigated {
                            panel.directoryURL = directory
                            if let filename { panel.nameFieldStringValue = filename }
                            navigated = true
                            return
                        }
                        guard panel.directoryURL?.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else { return }
                        timer.invalidate()
                        panel.ok(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .modalPanel)
                return timer
            }
            @MainActor func pressKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
                guard let window = workspaceWindow() else { return }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                        NSApp.sendEvent(event)
                    }
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

            // "generate": the bundled FFmpeg writes fixtures into the output folder, so a sandboxed,
            // notarized build can run end to end without access to the user's media.
            if media.map(\.lastPathComponent) == ["generate"], let helpers = Bundle.main.resourceURL?.appendingPathComponent("Helpers") {
                let ffmpeg = helpers.appendingPathComponent("ffmpeg")
                let fixtures: [(String, [String])] = [
                    ("generated-h264.mkv", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=25:d=6", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
                                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-shortest"]),
                    ("generated-prores.mov", ["-f", "lavfi", "-i", "smptehdbars=s=1920x1080:r=25:d=6", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=6",
                                              "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ac", "2", "-shortest"]),
                    // Broadcast-style multitrack: picture and four mono streams at different pitches.
                    ("generated-multitrack.mov", ["-f", "lavfi", "-i", "testsrc=s=1280x720:r=25:d=6"]
                        + [220, 330, 440, 550].flatMap { ["-f", "lavfi", "-i", "sine=frequency=\($0):sample_rate=48000:duration=6"] }
                        + ["-map", "0:v"] + (1...4).flatMap { ["-map", "\($0):a"] }
                        + ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s24le", "-shortest"]),
                ]
                var generated: [URL] = []
                for (name, arguments) in fixtures {
                    let url = output.appendingPathComponent(name)
                    do {
                        _ = try await ExportProcess.run(executable: ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y"] + arguments + [url.path])
                        generated.append(url)
                    } catch { record("generate", ["file": name, "error": error.localizedDescription]) }
                }
                record("generate", ["files": generated.map(\.lastPathComponent), "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil])
                media = generated
            }
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

            // Editing coverage: overlap, fades, crossfade, relink and proxies before playback/export.
            @MainActor func clips() -> [TimelineClip] { store.project.tracks.flatMap(\.clips) }
            let tracksBefore = store.project.tracks.count
            if let first = media.first, store.importMediaToTimeline(urls: [first], at: 1.0) {
                _ = await wait(120) { !store.isImporting }
            }
            let overlapped = store.project.tracks.count > tracksBefore
            var fadeApplied = false, crossfadeApplied = false
            var crossfaded: Set<UUID> = []
            // The overlapping placement gives a linked crossfade over the exact overlap.
            if let outgoing = clips().first(where: { $0.requiredTrackKind == .audio && !store.audioCrossfadeTargets(for: $0).isEmpty }),
               let incoming = store.audioCrossfadeTargets(for: outgoing).first {
                let overlap = outgoing.timelineStart.seconds + outgoing.sourceRange.duration.seconds - incoming.timelineStart.seconds
                crossfadeApplied = (try? store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id,
                    seconds: overlap > 0 ? overlap : 0.25, curve: .equalPower, expectedProject: store.project)) != nil
                crossfaded = [outgoing.id, incoming.id]
            }
            // Fades on a clip the crossfade doesn't use (a crossfade replaces those fade edges).
            if let audio = clips().last(where: { $0.requiredTrackKind == .audio && !crossfaded.contains($0.id) }) {
                fadeApplied = (try? store.applyFades(clipID: audio.id, fadeInSeconds: 0.5, fadeInCurve: .linear,
                    fadeOutSeconds: 0.5, fadeOutCurve: .equalPower, expectedClip: audio)) != nil
            }
            // Source audio change: pick two other mono streams of a multitrack source as left/right.
            var sourceAudioChanged = false
            let hasMultitrack = store.project.assets.contains { $0.streams.filter { $0.kind == .audio && $0.audioLayout == .mono }.count >= 3 }
            if let asset = store.project.assets.first(where: { $0.streams.filter { $0.kind == .audio && $0.audioLayout == .mono }.count >= 3 }),
               let clip = clips().first(where: { $0.assetID == asset.id && $0.requiredTrackKind == .audio && !crossfaded.contains($0.id) }) {
                let monos = asset.streams.filter { $0.kind == .audio && $0.audioLayout == .mono }
                let selection = AudioSourceSelection(channels: [SourceChannel(streamIndex: monos[1].index, channelIndex: 0),
                                                                SourceChannel(streamIndex: monos[2].index, channelIndex: 0)], layout: .stereo)
                sourceAudioChanged = (try? store.applyAudioSelection(clipID: clip.id, selections: [selection], routing: [AudioRouting()],
                                                                     expectedProject: store.project)) != nil
            }
            // Relink the last original to a renamed copy, as after moving media in Finder.
            var relinked = false
            if let asset = store.project.assets.last, let original = asset.originalURL {
                let moved = output.appendingPathComponent("relinked-" + original.lastPathComponent)
                if (try? FileManager.default.copyItem(at: original, to: moved)) != nil,
                   let imported = try? await MediaImporter.inspect(url: moved) {
                    relinked = (try? store.replaceMedia(assetID: asset.id, with: imported)) != nil
                        && store.project.assets.last?.originalURL?.lastPathComponent == moved.lastPathComponent
                }
            }
            // Proxies for every qualified constant-frame-rate video asset.
            let proxySources = store.project.assets.filter { $0.streams.contains { $0.kind == .video && $0.videoFormat != nil } }
            var proxiesReady = 0
            if !proxySources.isEmpty, (try? store.enqueueProxyJobs(assets: proxySources, preset: .proResProxy, scaleDivisor: 2, directory: output)) != nil {
                store.runProxyQueue()
                _ = await wait(600) { store.proxyGenerationTask == nil }
                proxiesReady = store.project.assets.filter { $0.proxy != nil }.count
                if proxiesReady > 0 { store.setPlaybackRepresentation(.proxy) }
            }
            record("editing", ["overlappingTracks": overlapped, "tracks": store.project.tracks.count, "fades": fadeApplied,
                               "crossfade": crossfadeApplied, "sourceAudioChanged": sourceAudioChanged, "multitrackAvailable": hasMultitrack, "relinked": relinked, "proxyCandidates": proxySources.count,
                               "proxiesReady": proxiesReady, "representation": store.playbackRepresentation.rawValue,
                               "clips": clips().count, "error": store.errorMessage ?? ""])

            // Finishing tools through real key events: ⌘T, ⌃T, volume, insert (,), overwrite (.),
            // ⌘C/⌘V, ⌘D and ⇧⌘⌫. Each is one undoable edit; counts confirm each took effect.
            @MainActor func dissolves() -> Int {
                store.project.audioCrossfades.filter { relation in clips().first { $0.id == relation.outgoingClipID }?.requiredTrackKind == .video }.count
            }
            @MainActor func edgeFades() -> Int { clips().filter { $0.requiredTrackKind == .video && ($0.fadeIn.duration.numerator > 0 || $0.fadeOut.duration.numerator > 0) }.count }
            var features: [String: Any] = [:]
            if let picture = clips().filter({ $0.requiredTrackKind == .video }).min(by: { $0.timelineStart.seconds < $1.timelineStart.seconds }) {
                store.selectTimelineClip(picture.id)
                store.seek(to: picture.timelineStart.seconds + picture.sourceRange.duration.seconds - 0.1)
                let before = (dissolves(), edgeFades())
                press(.addTransition, "t", keyCode: 17, modifiers: [.command])
                _ = await wait(3) { (dissolves(), edgeFades()) != before }
                // Whole clips have no handles, so ⌘T makes a dip. Make a handle by ripple trimming a
                // clip's end, then wipe from it into the clip that now meets it.
                if !store.project.audioCrossfades.contains(where: { r in clips().first { $0.id == r.outgoingClipID }?.requiredTrackKind == .video }),
                   let track = store.project.tracks.first(where: { $0.kind == .video && $0.clips.count > 1 }) {
                    let ordered = track.clips.sorted { $0.timelineStart.seconds < $1.timelineStart.seconds }
                    for (outgoing, incoming) in zip(ordered, ordered.dropFirst())
                    where abs(outgoing.timelineStart.seconds + outgoing.sourceRange.duration.seconds - incoming.timelineStart.seconds) < 0.001
                        && outgoing.sourceRange.duration.seconds > 2 {
                        store.selectTimelineClip(outgoing.id)
                        store.seek(to: outgoing.timelineStart.seconds + outgoing.sourceRange.duration.seconds - 1)
                        store.rippleTrimSelectedClip(edge: .trailing)
                        try? store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: 0.5,
                                                       curve: .linear, style: .wipeRight, expectedProject: store.project)
                        if store.project.audioCrossfades.contains(where: { $0.style == .wipeRight }) { break }
                    }
                }
                // Turn a created dissolve into a wipe, so the renders include one.
                if let relation = store.project.audioCrossfades.first(where: { r in clips().first { $0.id == r.outgoingClipID }?.requiredTrackKind == .video }) {
                    try? store.applyAudioCrossfade(outgoingClipID: relation.outgoingClipID, incomingClipID: relation.incomingClipID,
                        seconds: relation.duration.seconds, curve: .linear, style: .wipeRight, expectedProject: store.project)
                    features["wipe"] = ["applied": store.project.audioCrossfades.contains { $0.style == .wipeRight }]
                }
                features["transition"] = ["dissolves": dissolves(), "fadedPictures": edgeFades(), "changed": (dissolves(), edgeFades()) != before,
                                          "status": store.statusMessage, "error": store.errorMessage ?? "",
                                          "selected": store.selectedClipID == picture.id, "playhead": store.playheadSeconds]
            }
            store.seek(to: 0.5)
            let titleAssets = store.project.assets.filter { $0.title != nil }.count
            press(.addTitle, "t", keyCode: 17, modifiers: [.control])
            let titled = await wait(5) { store.project.assets.filter { $0.title != nil }.count > titleAssets }
            if titled, let asset = store.project.assets.last(where: { $0.title != nil }) {
                store.updateTitle(assetID: asset.id, to: TitleDefinition(text: "Acceptance title", position: .center, background: true))
            }
            features["title"] = ["added": titled, "text": store.project.assets.last(where: { $0.title != nil })?.title?.text ?? "",
                                 "frontTrack": store.project.tracks.first?.displayName(in: store.project) ?? ""]
            if let sound = clips().first(where: { $0.requiredTrackKind == .audio }) {
                store.selectTimelineClip(sound.id)
                store.setSelectedClipVolume(decibels: "-6")
                features["volume"] = ["gain": clips().first { $0.id == sound.id }?.gain ?? 0]
            }
            if let source = store.project.assets.first(where: { $0.title == nil && $0.streams.contains { $0.kind == .video } }) {
                store.selectAsset(source.id)
                store.clearSourceMarks()
                // At zero nothing crosses the playhead, so every clip moves later.
                store.seek(to: 0)
                let durationBefore = store.duration
                press(.insertSource, ",", keyCode: 43)
                _ = await wait(3) { store.duration > durationBefore + 0.5 }
                let inserted = store.duration - durationBefore
                let insertError = store.errorMessage ?? ""
                store.selectAsset(source.id)
                store.seek(to: 1)
                let clipsBeforeOverwrite = clips().count
                press(.overwriteSource, ".", keyCode: 47)
                _ = await wait(3) { clips().count != clipsBeforeOverwrite }
                features["insert"] = ["secondsAdded": inserted, "error": insertError]
                features["overwrite"] = ["clipsBefore": clipsBeforeOverwrite, "clipsAfter": clips().count, "error": store.errorMessage ?? ""]
            }
            if let picture = clips().first(where: { $0.requiredTrackKind == .video && store.asset(id: $0.assetID)?.title == nil }) {
                store.selectTimelineClip(picture.id)
                let before = clips().count
                // Menu key equivalents need the key window; otherwise run the menu items' actions.
                let keyed = workspaceWindow()?.isKeyWindow == true && NSApp.isActive
                @MainActor func menuKey(_ characters: String, _ keyCode: UInt16, _ action: () -> Void) {
                    if keyed { pressKey(characters, keyCode: keyCode, modifiers: [.command]) } else { action() }
                }
                menuKey("c", 8) { store.copySelectedClip() }
                store.seek(to: store.duration)
                menuKey("v", 9) { store.pasteAtPlayhead() }
                let pasted = await wait(3) { clips().count > before }
                let afterPaste = clips().count
                menuKey("d", 2) { store.duplicateSelectedClip() }
                let duplicated = await wait(3) { clips().count > afterPaste }
                let afterDuplicate = clips().count, durationBefore = store.duration
                press(.rippleDelete, "\u{7f}", keyCode: 51, modifiers: [.command, .shift])
                let rippled = await wait(3) { clips().count < afterDuplicate && store.duration < durationBefore }
                features["clipboard"] = ["menuKeys": keyed, "copiedAndPasted": pasted, "duplicated": duplicated, "rippleDeleted": rippled,
                                         "clipboardEntries": store.clipboard?.entries.count ?? 0, "error": store.errorMessage ?? ""]
            }
            if let picture = clips().first(where: { $0.requiredTrackKind == .video && store.asset(id: $0.assetID)?.title == nil }) {
                store.selectTimelineClip(picture.id)
                store.setSelectedClipTransform(scale: "33", x: "30", y: "30", opacity: "80")
                // Colour switches preview to the CoreImage compositor for the playback and export steps.
                store.setSelectedClipColor(ColorAdjustment(brightness: 0.1, contrast: 1.2, saturation: 0.5, blur: 0.01))
                // The picture's linked sound gets an EQ, which the preview tap and export both apply.
                store.setSelectedEQ(AudioEQ(low: -6, mid: 3, high: 2))
                features["eq"] = ["applied": store.selectedVolumeClips.allSatisfy { !$0.eq.isFlat } && !store.selectedVolumeClips.isEmpty]
                features["color"] = ["applied": !(clips().first { $0.id == picture.id }?.color.isNeutral ?? true),
                                     "blur": clips().first { $0.id == picture.id }?.color.blur ?? 0]
                let transform = clips().first { $0.id == picture.id }?.transform
                features["transform"] = ["scale": transform?.scale ?? 0, "opacity": transform?.opacity ?? 0]
            }
            if let sound = clips().filter({ $0.requiredTrackKind == .audio && $0.sourceRange.duration.seconds > 2 }).max(by: { $0.timelineStart.seconds < $1.timelineStart.seconds }) {
                store.selectTimelineClip(sound.id)
                store.seek(to: sound.timelineStart.seconds + 0.5); store.addVolumeKeyframeAtPlayhead(decibels: "0")
                store.seek(to: sound.timelineStart.seconds + 1.5); store.addVolumeKeyframeAtPlayhead(decibels: "-12")
                features["keyframes"] = ["count": clips().first { $0.id == sound.id }?.volumeKeyframes.count ?? 0, "error": store.errorMessage ?? ""]
            }
            if let track = store.project.tracks.first(where: { $0.kind == .audio }) {
                let before = (try? TimelineRenderPlan(project: store.project).components.count) ?? 0
                store.setTrackMuted(track.id, muted: true)
                let muted = (try? TimelineRenderPlan(project: store.project).components.count) ?? 0
                store.setTrackMuted(track.id, muted: false)
                features["mute"] = ["fewerComponentsWhileMuted": muted < before, "restored": ((try? TimelineRenderPlan(project: store.project).components.count) ?? 0) == before]
            }
            if let movie = clips().first(where: { $0.requiredTrackKind == .video && store.asset(id: $0.assetID)?.title == nil }) {
                store.selectTimelineClip(movie.id)
                let before = movie.sourceRange.duration.seconds
                store.setSelectedClipSpeed(percent: "50")
                let after = clips().first { $0.id == movie.id }?.sourceRange.duration.seconds ?? 0
                features["speed"] = ["doubled": abs(after - 2 * before) < 0.05, "error": store.errorMessage ?? ""]
            }
            if let titleClip = clips().first(where: { store.asset(id: $0.assetID)?.title != nil }) {
                store.selectTimelineClip(titleClip.id)
                store.applyMotionPreset(.slideInLeft)
                store.seek(to: titleClip.timelineStart.seconds + 3)
                store.addTransformKeyframeAtPlayhead(scale: "120", x: "0", y: "0")
                features["motion"] = ["keyframes": clips().first { $0.id == titleClip.id }?.transformKeyframes.count ?? 0, "error": store.errorMessage ?? ""]
            }
            features["undoAvailable"] = store.canUndo
            store.seek(to: 0)
            record("finishing_tools", features)
            try? await Task.sleep(for: .seconds(1))
            snapshot("02b-finishing-tools", window: workspaceWindow())

            if !store.showSequenceMonitor { press(.toggleViewer, "\t", keyCode: 48) }
            let monitoring = await wait(5) { store.showSequenceMonitor && store.sequencePlayback != nil }
            let prepared = await wait(30) { store.sequencePlayback?.isPreparing == false }
            record("sequence_viewer", ["tabSwitchedToSequence": monitoring, "prepared": prepared,
                                       "message": store.sequencePlayback?.message ?? ""])
            // Show the mixer for the playback check; the user's choice is restored at the end.
            let previousMixer = UserDefaults.standard.object(forKey: "workspace.showMixer")
            UserDefaults.standard.set(true, forKey: "workspace.showMixer")
            let before = store.playheadSeconds
            press(.togglePlayback, " ", keyCode: 49)
            let playing = await wait(10) { store.sequencePlayback?.isPlaying == true }
            try? await Task.sleep(for: .seconds(2))
            snapshot("03-playing", window: workspaceWindow())
            let during = store.playheadSeconds
            let meterPeak = AudioMeters.shared.levels.values.max() ?? -120
            press(.togglePlayback, " ", keyCode: 49)
            let paused = await wait(5) { store.sequencePlayback?.isPlaying == false }
            try? await Task.sleep(for: .milliseconds(500))
            let after = store.playheadSeconds
            try? await Task.sleep(for: .milliseconds(500))
            record("space_transport", ["startedPlaying": playing, "paused": paused,
                                       "playheadBefore": before, "playheadWhilePlaying": during,
                                       "playheadAfterPause": after, "meterPeak": meterPeak, "playheadStable": abs(store.playheadSeconds - after) < 0.001,
                                       "notice": store.sequencePlayback?.message ?? ""])

            // Customized shortcut: remap Play / Pause to P, press it, then restore the user's binding.
            if let appRegistry = EditorKeyboardRouter.shared.registry {
                let saved = appRegistry.binding(for: .togglePlayback)
                let remapError = appRegistry.set(ShortcutBinding(key: "p"), for: .togglePlayback)
                press(.togglePlayback, "p", keyCode: 35)
                let remappedPlays = await wait(10) { store.sequencePlayback?.isPlaying == true }
                press(.togglePlayback, "p", keyCode: 35)
                let remappedPauses = await wait(5) { store.sequencePlayback?.isPlaying == false }
                _ = appRegistry.set(saved, for: .togglePlayback)
                record("custom_shortcut", ["remapped": remapError == nil, "plays": remappedPlays, "pauses": remappedPauses,
                                           "restored": appRegistry.binding(for: .togglePlayback) == saved])
            }
            let previousFormat = UserDefaults.standard.string(forKey: "exportFormat")
            defer { UserDefaults.standard.set(previousFormat, forKey: "exportFormat") }
            UserDefaults.standard.set(RenderOutputFormat.h264.rawValue, forKey: "exportFormat")
            press(.exportSequence, "e", keyCode: 14, modifiers: [.command, .shift])
            let sheetOpened = await wait(5) { store.renderExportDraft != nil }
            try? await Task.sleep(for: .seconds(4))
            snapshot("04-export-sheet", window: workspaceWindow()?.attachedSheet ?? workspaceWindow())
            record("export_sheet", ["openedByShortcut": sheetOpened, "error": store.errorMessage ?? "",
                                    "enabled": registry.isEnabled(.exportSequence, store: store, scope: .document)])
            if let draft = store.renderExportDraft {
                // User path: the sheet's own button opens the real folder panel, which the
                // driver completes from a run-loop timer (runModal blocks this task).
                let uiDestination = output.appendingPathComponent("Sequence.mp4")
                let sheet = workspaceWindow()?.attachedSheet
                let panelTimer = completePanel(directory: output, filename: nil)
                // Return triggers the sheet's default "Choose export folder…" button, as for a user.
                // Only when panels are requested: a refused panel service shows an alert that
                // nothing in-process can dismiss.
                let usePanels = ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_PANELS"] == "1"
                if !usePanels { panelUnavailable.append("skipped") }
                var pressed = !usePanels
                if usePanels, let sheet {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                            NSApp.sendEvent(event)
                        }
                    }
                    pressed = true
                }
                record("export_button", ["pressed": pressed])
                // Publication is an atomic link after verification, so existence means a verified file.
                var published = await wait(600) { FileManager.default.fileExists(atPath: uiDestination.path) || !panelUnavailable.isEmpty }
                let viaPanel = FileManager.default.fileExists(atPath: uiDestination.path)
                if !viaPanel, !panelUnavailable.isEmpty {
                    let result = try? await SequenceExportService.shared.export(plan: draft.plan, to: uiDestination, options: .init(format: .h264))
                    published = result != nil
                }
                panelTimer.invalidate()
                try? await Task.sleep(for: .seconds(1))
                let exported = published && (!viaPanel || (sheet?.contentView.map { containsText("Exported Sequence.mp4", in: $0) } ?? false))
                snapshot("05-export-complete", window: workspaceWindow()?.attachedSheet)
                record("export_via_sheet", ["buttonPressed": pressed, "completed": exported, "file": uiDestination.lastPathComponent,
                                            "folderPanel": viaPanel ? "completed" : "unavailable: \(panelUnavailable)",
                                            "bytes": (try? uiDestination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0])
                // Second format through the same service and plan snapshot.
                let destination = output.appendingPathComponent("acceptance-proRes422HQ.mov")
                let started = Date()
                do {
                    let result = try await SequenceExportService.shared.export(plan: draft.plan, to: destination, options: .init(format: .proRes422HQ))
                    record("export", ["format": "proRes422HQ", "frames": result.videoFrames, "samples": result.audioSamples,
                                      "warnings": result.warnings, "seconds": Date().timeIntervalSince(started)])
                } catch {
                    record("export", ["format": "proRes422HQ", "error": error.localizedDescription])
                }
                store.renderExportDraft = nil
                _ = await wait(5) { workspaceWindow()?.attachedSheet == nil }
            }

            // ⌘S on an untitled document presents the real save panel as a sheet.
            let projectURL = output.appendingPathComponent("Acceptance.afcproject")
            let usePanels = ProcessInfo.processInfo.environment["AFC_ACCEPTANCE_PANELS"] == "1"
            let saveTimer = completePanel(directory: output, filename: projectURL.lastPathComponent)
            panelUnavailable.removeAll()
            if usePanels { pressKey("s", keyCode: 1, modifiers: [.command]) } else { panelUnavailable.append("skipped") }
            var saved = await wait(30) { (FileManager.default.fileExists(atPath: projectURL.path)
                && workspaceWindow().flatMap { NSDocumentController.shared.document(for: $0)?.fileURL } != nil) || !panelUnavailable.isEmpty }
            saveTimer.invalidate()
            let savePanel = FileManager.default.fileExists(atPath: projectURL.path) ? "completed" : "unavailable: \(panelUnavailable)"
            if !FileManager.default.fileExists(atPath: projectURL.path),
               let window = workspaceWindow(), let document = NSDocumentController.shared.document(for: window) {
                // Same NSDocument save-as path the panel would run, without the panel UI.
                try? await document.save(to: projectURL, ofType: document.fileType ?? "", for: .saveAsOperation)
                saved = await wait(10) { FileManager.default.fileExists(atPath: projectURL.path) && document.fileURL != nil }
            }
            var savedClips = -1
            if let data = try? Data(contentsOf: projectURL), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = root["project"] as? [String: Any], let tracks = model["tracks"] as? [[String: Any]] {
                savedClips = tracks.reduce(0) { $0 + (($1["clips"] as? [Any])?.count ?? 0) }
            }
            record("save", ["saved": saved, "clipsInFile": savedClips, "savePanel": savePanel,
                            "clipsInWorkspace": store.project.tracks.reduce(0) { $0 + $1.clips.count }])
            // Close and reopen from disk; the reopened workspace must show the same timeline.
            let clipsBefore = store.project.tracks.reduce(0) { $0 + $1.clips.count }
            if let window = workspaceWindow(), let document = NSDocumentController.shared.document(for: window) { document.close() }
            _ = await wait(5) { NSDocumentController.shared.documents.isEmpty }
            let reopened = (try? await NSDocumentController.shared.openDocument(withContentsOf: projectURL, display: true)) != nil
            let shown = await wait(15) { workspaceWindow()?.isVisible == true }
            try? await Task.sleep(for: .seconds(3))
            snapshot("06-reopened", window: workspaceWindow())
            record("reopen", ["reopened": reopened, "windowShown": shown, "clipsBefore": clipsBefore, "clipsInFile": savedClips,
                              "title": workspaceWindow()?.title ?? ""])
            UserDefaults.standard.set(previousMixer, forKey: "workspace.showMixer")
            record("done", ["dispatch": dispatchPaths])
            exit(0)
        }
    }
}
