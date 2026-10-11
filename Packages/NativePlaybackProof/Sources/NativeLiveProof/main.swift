import AppKit
import EditorCore
import Foundation
import NativePlaybackRuntime

/// Standalone development UI. Space toggles playback; arrows seek one second.
@MainActor final class LiveWindow: NSWindow {
    var monitor: NativeLivePlayback?
    override func keyDown(with event: NSEvent) {
        guard let monitor else { return }
        switch event.keyCode {
        case 49:
            if monitor.transport.isPlaying { monitor.pause() }
            else { Task { do { try await monitor.play() } catch { monitor.failure?(error) } } }
        case 123, 124:
            let rate = monitor.transport.plan.settings.frameRate.value
            let step = max(1, rate.numerator / rate.denominator)
            let frame = (monitor.transport.frameIndex ?? monitor.transport.plan.videoFrames)
                + (event.keyCode == 123 ? -step : step)
            Task { do { try await monitor.seek(toFrame: frame) } catch { monitor.failure?(error) } }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: LiveWindow?
    var monitor: NativeLivePlayback?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ProofFailure("Usage: NativeLiveProof /absolute/path/project.json")
            }
            let project = try JSONDecoder().decode(Project.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let monitor = try NativeLivePlayback(project: project)
            self.monitor = monitor
            let window = LiveWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Native live proof — Space: play/pause · Arrows: seek"
            window.monitor = monitor; window.delegate = self
            let view = NSImageView(frame: window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]; view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView?.addSubview(view)
            monitor.display = { [weak window, weak view] image, frame in
                view?.image = NSImage(cgImage: image, size: .zero)
                window?.title = "Native live proof — frame \(frame) · Space: play/pause · Arrows: seek"
            }
            monitor.failure = { [weak window] error in
                window?.title = "Native live proof stopped: \(error)"
                FileHandle.standardError.write(Data("Live playback stopped: \(error)\n".utf8))
            }
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { do { try await monitor.seek(toFrame: 0) } catch { monitor.failure?(error) } }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let monitor {
            let stats = monitor.statistics
            print("Live observations: clock=\(stats.clockSamples) scheduled=\(stats.scheduledSamples) maxQueued=\(stats.maximumQueuedSamples) displayed=\(stats.displayedFrames) discarded=\(stats.discardedFrames)")
            Task { await monitor.close(); NSApp.terminate(nil) }
        } else { NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
