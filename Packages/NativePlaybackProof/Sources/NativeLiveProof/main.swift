import AppKit
import EditorCore
import Darwin
import Foundation
import NativePlaybackRuntime

struct LiveOptions {
    var project: URL
    var observations: URL?
    var observationInterval: Double = 0.5
    var scriptedDuration: Double?

    init(arguments: [String]) throws {
        guard let project = arguments.first else {
            throw ProofFailure("Usage: NativeLiveProof project.json [--observations file.jsonl] [--observation-interval seconds] [--scripted-duration seconds]")
        }
        self.project = URL(fileURLWithPath: project)
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw ProofFailure("Missing value for \(option)") }
            let value = arguments[index + 1]
            switch option {
            case "--observations": observations = URL(fileURLWithPath: value)
            case "--observation-interval", "--scripted-duration":
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                    throw ProofFailure("\(option) must be a finite positive number")
                }
                if option == "--observation-interval" { observationInterval = seconds }
                else { scriptedDuration = seconds }
            default: throw ProofFailure("Unknown option: \(option)")
            }
            index += 2
        }
    }
}

struct LiveObservation: Encodable {
    let schemaVersion = 1
    let event: String
    let elapsedSeconds: Double
    let clockBasis = "AVAudioPlayerNode render sample clock; not acoustic or display presentation"
    let hardwareQualified = false
    let statisticsScope = "Current playback epoch; counters reset on explicit play"
    let frameIndex: Int64?
    let displayedFrameIndex: Int64?
    let sampleIndex: Int64
    let generation: String
    let isPlaying: Bool
    let statistics: LivePlaybackStatistics
    let errors: [String]
}

/// Standalone development UI. Space toggles playback; arrows seek one second.
@MainActor final class LiveWindow: NSWindow {
    var monitor: NativeLivePlayback?
    var observe: ((String) -> Void)?
    override func keyDown(with event: NSEvent) {
        guard let monitor else { return }
        switch event.keyCode {
        case 49:
            if monitor.transport.isPlaying { monitor.pause(); observe?("manual-pause") }
            else { Task { do { try await monitor.play(); observe?("manual-play") }
                catch is CancellationError {} catch { monitor.failure?(error) } } }
        case 123, 124:
            let step = Int64(max(1, monitor.transport.plan.settings.frameRate.nominalFramesPerSecond))
            let frame = (monitor.transport.frameIndex ?? monitor.transport.plan.videoFrames)
                + (event.keyCode == 123 ? -step : step)
            Task { do { try await monitor.seek(toFrame: frame); observe?("manual-seek") }
                catch is CancellationError {} catch { monitor.failure?(error) } }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: LiveWindow?
    var monitor: NativeLivePlayback?
    var observations: FileHandle?
    var errors: [String] = []
    var exitCode: Int32 = 0
    private var displayedFrameIndex: Int64?
    private let start = ProcessInfo.processInfo.systemUptime
    private var sampling: Task<Void, Never>?
    private var script: Task<Void, Never>?
    private var scriptedRun = false
    private var scriptCompleted = false
    private var closing = false
    private var finished = false
    private var terminationRequested = false

    func record(_ event: String) {
        guard let monitor else { return }
        let observation = LiveObservation(event: event,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
            frameIndex: monitor.transport.frameIndex, displayedFrameIndex: displayedFrameIndex,
            sampleIndex: monitor.transport.sampleIndex,
            generation: monitor.transport.generation.uuidString, isPlaying: monitor.transport.isPlaying,
            statistics: monitor.statistics, errors: errors)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(observation); data.append(0x0a)
            try (observations ?? FileHandle.standardOutput).write(contentsOf: data)
        } catch {
            exitCode = 1
            FileHandle.standardError.write(Data("Cannot retain live observation: \(error)\n".utf8))
        }
    }

    func failed(_ error: any Error) {
        errors.append(String(describing: error)); exitCode = 1
        window?.title = "Native live proof stopped: \(error)"
        FileHandle.standardError.write(Data("Live playback stopped: \(error)\n".utf8))
        record("error")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let options = try LiveOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            scriptedRun = options.scriptedDuration != nil
            if let url = options.observations {
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                guard descriptor >= 0 else {
                    throw ProofFailure("Cannot create live observations file: \(String(cString: strerror(errno)))")
                }
                observations = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }
            let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: options.project))
            let monitor = try NativeLivePlayback(project: project)
            self.monitor = monitor
            let window = LiveWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Native live proof — Space: play/pause · Arrows: seek"
            window.monitor = monitor; window.delegate = self
            window.observe = { [weak self] event in self?.record(event) }
            let view = NSImageView(frame: window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]; view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView?.addSubview(view)
            monitor.display = { [weak self, weak window, weak view] image, frame in
                self?.displayedFrameIndex = frame
                view?.image = NSImage(cgImage: image, size: .zero)
                window?.title = "Native live proof — frame \(frame) · Space: play/pause · Arrows: seek"
            }
            monitor.failure = { [weak self] error in self?.failed(error) }
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            record("opened")
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(options.observationInterval)) }
                    catch { return }
                    self?.record("sample")
                }
            }
            script = Task { [weak self] in
                guard let self else { return }
                do {
                    try await monitor.seek(toFrame: 0)
                    self.record("initial-seek")
                    if let duration = options.scriptedDuration {
                        try await monitor.play(); self.record("script-play")
                        try await Task.sleep(for: .seconds(duration / 3))
                        try await monitor.seek(toFrame: 0); self.record("script-seek")
                        try await Task.sleep(for: .seconds(duration / 3))
                        monitor.pause(); self.record("script-pause")
                        try await Task.sleep(for: .seconds(duration / 6))
                        try await monitor.play(); self.record("script-resume")
                        try await Task.sleep(for: .seconds(duration / 6))
                        self.scriptCompleted = true
                        self.window?.close()
                    }
                } catch is CancellationError {
                    if options.scriptedDuration != nil, !self.closing { self.window?.close() }
                } catch {
                    self.failed(error)
                    if options.scriptedDuration != nil { self.window?.close() }
                }
            }
        } catch {
            exitCode = 1
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
    func windowWillClose(_ notification: Notification) { finish() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard monitor != nil, !finished else { return .terminateNow }
        terminationRequested = true
        finish()
        return .terminateLater
    }

    private func finish() {
        guard !closing else { return }
        if scriptedRun, !scriptCompleted {
            failed(ProofFailure("Scripted live run closed before completing all actions"))
        }
        closing = true; sampling?.cancel(); script?.cancel()
        Task {
            if let monitor { await monitor.close(); record("closed") }
            do { try observations?.close() } catch { exitCode = 1 }
            finished = true
            if terminationRequested { NSApp.reply(toApplicationShouldTerminate: true) }
            else { NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
exit(delegate.exitCode)
