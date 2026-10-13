import AppKit
import Combine
import EditorCore
#if canImport(NativePlaybackRuntime)
import NativePlaybackRuntime
#endif

@MainActor
protocol SequencePlaybackBackend: AnyObject {
    var position: Double { get }
    var isPlaying: Bool { get }
    var display: ((CGImage, Int64) -> Void)? { get set }
    var failure: ((any Error) -> Void)? { get set }
    func play() async throws
    func pause()
    func seek(toFrame: Int64) async throws
    func close() async
}

#if canImport(NativePlaybackRuntime)
@MainActor
private final class NativeSequenceBackend: SequencePlaybackBackend {
    private let playback: NativeLivePlayback
    init(project: Project, videoProxies: [UUID: MediaProxy]) throws {
        playback = try NativeLivePlayback(project: project, videoProxies: videoProxies)
    }
    var position: Double { playback.transport.position.seconds }
    var isPlaying: Bool { playback.transport.isPlaying }
    var display: ((CGImage, Int64) -> Void)? {
        get { playback.display }
        set { playback.display = newValue }
    }
    var failure: ((any Error) -> Void)? {
        get { playback.failure }
        set { playback.failure = newValue }
    }
    func play() async throws { try await playback.play() }
    func pause() { playback.pause() }
    func seek(toFrame frame: Int64) async throws { try await playback.seek(toFrame: frame) }
    func close() async { await playback.close() }
}
#endif

/// Verified playback choices are transient; the document and render plan retain originals.
struct SequenceProxySelection {
    var videoProxies: [UUID: MediaProxy] = [:]
    var message = "Native sequence · original media · development output"
}

/// Owns one edited-plan monitor. Edits pause immediately; rebuilding and scrubbing
/// coalesce into one worker. A timer reads the backend playback clock's position and
/// never invents timeline progress from wall time.
@MainActor
final class SequencePlaybackController: ObservableObject {
    typealias Factory = @MainActor (Project) throws -> any SequencePlaybackBackend
    typealias RepresentationFactory = @MainActor (Project, [UUID: MediaProxy]) throws -> any SequencePlaybackBackend
    typealias ProxyResolver = @MainActor (Project, PlaybackRepresentation) async throws -> SequenceProxySelection
    @Published private(set) var image: NSImage?
    @Published private(set) var displayedFrameIndex: Int64?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var message = "Select Sequence to monitor the timeline."
    var positionChanged: ((Double) -> Void)?
    var available: Bool { factory != nil }
    private let factory: RepresentationFactory?
    private let proxyResolver: ProxyResolver?
    private var pendingRepresentation: PlaybackRepresentation = .original
    private var activeRepresentation: PlaybackRepresentation?
    private var playbackMessage = "Native sequence · original media · development output"
    private var backend: (any SequencePlaybackBackend)?
    private var pendingProject: Project?
    private var activeProject: Project?
    private var activeDuration: Double = 0
    private var desiredSeconds: Double = 0
    private var pendingSeek = false
    private var revision = UUID()
    private var worker: Task<Void, Never>?
    private var verification: Task<SequenceProxySelection, any Error>?
    private var polling: Task<Void, Never>?
    private var scopes: Set<URL> = []
    private var enabled = false

    init(factory: Factory? = nil, useNativeDefault: Bool = true,
         representationFactory: RepresentationFactory? = nil, proxyResolver: ProxyResolver? = nil) {
        self.proxyResolver = proxyResolver
        if let representationFactory { self.factory = representationFactory }
        else if let factory { self.factory = { project, _ in try factory(project) } }
        else {
            #if canImport(NativePlaybackRuntime)
            self.factory = useNativeDefault ? { @MainActor project, proxies in
                try NativeSequenceBackend(project: project, videoProxies: proxies)
            } : nil
            #else
            self.factory = useNativeDefault ? { @MainActor project, proxies in
                try AVFoundationSequenceBackend(project: project, videoProxies: proxies)
            } : nil
            #endif
        }
        if self.factory == nil { message = "Sequence playback unavailable: no playback backend is enabled." }
    }

    func update(project: Project, seconds: Double, representation: PlaybackRepresentation = .original) {
        guard seconds.isFinite else { return }
        // Organization, names and retention flags have no decoding meaning.
        // Keep them out of runtime identity so these edits preserve playback.
        var playbackProject = project
        playbackProject.mediaBins = []
        playbackProject.assetBinAssignments = [:]
        for index in playbackProject.families.indices {
            playbackProject.families[index].baseName = "Track"
        }
        for index in playbackProject.tracks.indices {
            playbackProject.tracks[index].customName = nil
            playbackProject.tracks[index].retained = false
        }
        let changed = playbackProject != pendingProject || representation != pendingRepresentation
        pendingProject = playbackProject
        pendingRepresentation = representation
        desiredSeconds = max(0, seconds)
        guard enabled, available else { return }
        if changed {
            verification?.cancel()
            backend?.pause(); isPlaying = false; image = nil; displayedFrameIndex = nil
            revision = UUID()
        } else if let backend, abs(backend.position - desiredSeconds) < 0.000001 { return }
        else {
            // A scrub during asynchronous priming invalidates the eventual play,
            // even when the project itself has not changed.
            revision = UUID()
            if worker != nil { backend?.pause(); isPlaying = false }
        }
        pendingSeek = true
        startWorker()
    }

    func activate(project: Project, seconds: Double, representation: PlaybackRepresentation = .original) {
        enabled = true
        update(project: project, seconds: seconds, representation: representation)
    }

    func pause() {
        revision = UUID()
        backend?.pause(); isPlaying = false
        publishPosition()
    }

    func play() {
        guard enabled, available, worker == nil, let backend else { return }
        let token = revision
        isPreparing = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.isPreparing = false; self.startWorkerIfNeeded() }
            do {
                try await backend.play()
                guard self.enabled, token == self.revision else { backend.pause(); return }
                self.isPlaying = backend.isPlaying
                self.message = self.playbackMessage
            } catch is CancellationError {} catch {
                if token == self.revision { self.message = error.localizedDescription }
            }
        }
    }

    func deactivate() {
        enabled = false; revision = UUID()
        verification?.cancel()
        backend?.pause(); isPlaying = false; image = nil; displayedFrameIndex = nil
        // Keep the serialized worker alive to drain/close. Cancelling it would
        // poison a rapid reactivation that must reuse the same cleanup worker.
        polling?.cancel(); polling = nil
        // Cleanup stays serialized behind an in-flight seek/prime. Independent
        // scope ownership outlives the document store's own media-access release.
        if worker == nil { startWorker() }
    }

    private func startWorkerIfNeeded() {
        if !enabled || activeProject != pendingProject || activeRepresentation != pendingRepresentation || pendingSeek { startWorker() }
    }

    private func startWorker() {
        guard worker == nil else { return }
        isPreparing = enabled && available
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.isPreparing = false }
            while true {
                let token = self.revision
                if !self.enabled || self.activeProject != self.pendingProject || self.activeRepresentation != self.pendingRepresentation {
                    if let old = self.backend { old.pause(); await old.close() }
                    self.backend = nil; self.activeProject = nil; self.activeRepresentation = nil
                    self.releaseScopes()
                    guard self.enabled, let project = self.pendingProject, let factory = self.factory else { return }
                    do {
                        let representation = self.pendingRepresentation
                        // Verification and decoding own their grants through asynchronous shutdown.
                        let used = Set(project.tracks.flatMap(\.clips).map(\.assetID))
                        let assets = project.assets.filter { used.contains($0.id) }
                        let urls = assets.compactMap(\.originalURL) + assets.compactMap { $0.proxy?.url }
                        for url in Set(urls) {
                            if url.startAccessingSecurityScopedResource() { self.scopes.insert(url) }
                        }
                        let selection: SequenceProxySelection
                        if let resolver = self.proxyResolver {
                            let verification = Task { try await resolver(project, representation) }
                            self.verification = verification
                            defer { self.verification = nil }
                            selection = try await verification.value
                        } else { selection = SequenceProxySelection() }
                        guard self.enabled, token == self.revision, project == self.pendingProject,
                              representation == self.pendingRepresentation else { continue }
                        let backend = try factory(project, selection.videoProxies)
                        self.playbackMessage = selection.message
                        #if !canImport(NativePlaybackRuntime)
                        self.playbackMessage = selection.message.replacingOccurrences(of: "Native sequence", with: "System sequence").replacingOccurrences(of: "development output", with: "AVFoundation preview")
                        #endif
                        self.activeDuration = try TimelineRenderPlan(project: project).duration.seconds
                        self.backend = backend; self.activeProject = project
                        self.activeRepresentation = representation
                        backend.display = { [weak self, weak backend] image, frame in
                            guard let self, let backend, self.enabled,
                                  self.backend === backend, self.activeProject == self.pendingProject,
                                  self.activeRepresentation == self.pendingRepresentation else { return }
                            if self.worker != nil {
                                let wanted = self.desiredSeconds * project.settings.frameRate.value.seconds
                                guard wanted.isFinite, wanted >= 0, wanted < Double(Int64.max),
                                      frame == Int64(wanted.rounded(.down)) else { return }
                            }
                            self.image = NSImage(cgImage: image, size: .zero)
                            self.displayedFrameIndex = frame
                        }
                        backend.failure = { [weak self, weak backend] error in
                            guard let self, let backend, self.backend === backend else { return }
                            self.isPlaying = false; self.message = error.localizedDescription
                        }
                    } catch {
                        self.releaseScopes()
                        if token != self.revision { continue }
                        self.message = error.localizedDescription; return
                    }
                }
                guard self.enabled, let backend = self.backend, let project = self.activeProject else { return }
                let rate = project.settings.frameRate.value.seconds
                let lastFrame = max(0, ceil(self.activeDuration * rate) - 1)
                let seconds = min(self.desiredSeconds, lastFrame / rate)
                self.desiredSeconds = seconds
                do {
                    let frames = seconds * project.settings.frameRate.value.seconds
                    guard frames.isFinite, frames >= 0, frames < Double(Int64.max) else { return }
                    try await backend.seek(toFrame: Int64(frames.rounded(.down)))
                    guard token == self.revision, self.activeProject == self.pendingProject,
                          seconds == self.desiredSeconds else { continue }
                    self.pendingSeek = false
                    self.isPlaying = backend.isPlaying
                    self.message = self.playbackMessage
                    self.startPolling()
                    return
                } catch is CancellationError {
                    if !self.enabled || token != self.revision { continue }
                    return
                } catch {
                    if token != self.revision { continue }
                    self.message = error.localizedDescription; self.isPlaying = false; return
                }
            }
        }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard let self, self.enabled else { return }
                if self.worker == nil { self.publishPosition() }
            }
        }
    }
    private func publishPosition() {
        guard let backend, !pendingSeek else { return }
        isPlaying = backend.isPlaying
        desiredSeconds = backend.position
        positionChanged?(backend.position)
    }
    private func releaseScopes() {
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
    }
}
