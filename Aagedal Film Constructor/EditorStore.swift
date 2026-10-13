import AppKit
import AVKit
import Combine
import EditorCore
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published var project: Project = Project(settings: try! SequenceSettings()) {
        didSet {
            cachedDuration = nil
            cachedAssets = nil
            cachedClips = nil
        }
    }
    // Project changes invalidate derived values; transport/selection updates can
    // then read them without rebuilding and validating the entire render plan.
    private var cachedDuration: Double?
    private var cachedAssets: [UUID: MediaAsset]?
    private var cachedClips: [UUID: TimelineClip]?
    @Published var mediaBookmarks: [UUID: Data] = [:]
    @Published var proxyBookmarks: [UUID: Data] = [:]
    @Published var proxyJobs: [ProxyGenerationJob] = []
    @Published var proxyQueueProgress: [UUID: SequenceExportProgress] = [:]
    @Published var showProxyQueue = false
    @Published var showSequenceMonitor = false
    @Published var selectedMediaBinID: UUID?
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var proxyCreationDraft: ProxyCreationDraft?
    @Published var playbackRepresentation: PlaybackRepresentation = .original
    @Published var proxyPlaybackMessage = "Original source"
    @Published var pendingSourceTransport: (time: CMTime, playing: Bool)?
    var sourceRevisions: [UUID: UUID] = [:]
    var sourcePreviewTask: Task<Void, Never>?
    var proxyGenerationTask: Task<Void, Never>?
    var proxyRelinkTask: Task<Void, Never>?
    @Published var isRelinkingProxy = false
    // Source marks are per-asset working selections, separate from document edits.
    @Published var sourceRanges: [UUID: TimeRange] = [:]
    @Published var selectedAssetID: UUID?
    @Published var selectedClipID: UUID?
    @Published var audioAppendAsset: MediaAsset?
    @Published var renderExportDraft: SequenceExportDraft?
    @Published var edlExportDraft: EDLExportDraft?
    @Published var playheadSeconds: Double = 0
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var snappingEnabled = true
    @Published var sourcePlayer: AVPlayer?
    @Published var previewImage: NSImage?
    @Published var statusMessage = "Import media to begin."
    @Published private(set) var mediaPreviewRevision = UUID()
    private struct Snapshot { var project: Project; var bookmarks: [UUID: Data]; var proxyBookmarks: [UUID: Data] }
    @Published private var undoHistory: [Snapshot] = []
    @Published private var redoHistory: [Snapshot] = []
    private var scopedURLs: Set<URL> = []
    private var sourceTransportTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    var mediaEpoch = UUID()
    weak var sequencePlayback: SequencePlaybackController?

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var duration: Double {
        if let cachedDuration { return cachedDuration }
        let value = (try? TimelineRenderPlan(project: project).duration.seconds) ?? 0
        cachedDuration = value
        return value
    }
    func asset(id: UUID) -> MediaAsset? {
        if cachedAssets == nil {
            cachedAssets = Dictionary(project.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return cachedAssets?[id]
    }
    var selectedAsset: MediaAsset? { selectedAssetID.flatMap { asset(id: $0) } }
    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        if cachedClips == nil {
            cachedClips = Dictionary(project.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return cachedClips?[selectedClipID]
    }
    var canControlSourceTransport: Bool { sourcePlayer != nil || pendingSourceTransport != nil }

    func load(_ document: ProjectDocument) {
        close()
        mediaPreviewRevision = UUID()
        errorMessage = nil
        isImporting = false
        undoHistory = []; redoHistory = []
        selectedMediaBinID = nil
        sourceRanges = [:]
        selectedAssetIDs = []; selectedAssetID = nil; selectedClipID = nil; playheadSeconds = 0
        previewImage = nil
        statusMessage = "Import media to begin."
        project = document.project
        mediaBookmarks = document.mediaBookmarks
        proxyBookmarks = document.proxyBookmarks
        proxyJobs = document.proxyJobs.map { job in
            var restored = job; restored.prepareAfterReopen(); return restored
        }
        proxyQueueProgress = [:]
        resumeMediaAccess()
    }

    /// A temporarily hidden workspace releases media resources in close(). Restore
    /// them without replacing the editing session or clearing its history/selection.
    func resumeMediaAccess() {
        mediaPreviewRevision = UUID()
        resolveProxyBookmarks()
        for index in project.assets.indices {
            let id = project.assets[index].id
            if let bookmark = mediaBookmarks[id] {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                    holdAccess(url)
                    project.assets[index].originalURL = url
                    if stale { mediaBookmarks[id] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
                } catch { statusMessage = "Some media needs relinking. Select it in the bin and choose Relink." }
            }
        }
        refreshSourcePreview()
    }

    func holdAccess(_ url: URL) {
        if !scopedURLs.contains(url), url.startAccessingSecurityScopedResource() { scopedURLs.insert(url) }
    }

    func close() {
        sequencePlayback?.deactivate()
        mediaEpoch = UUID()
        audioAppendAsset = nil
        renderExportDraft = nil
        edlExportDraft = nil
        importTask?.cancel()
        sourcePreviewTask?.cancel()
        for index in proxyJobs.indices where proxyJobs[index].state == .running {
            proxyJobs[index].prepareAfterReopen()
        }
        showProxyQueue = false
        proxyQueueProgress = [:]
        proxyGenerationTask?.cancel()
        proxyGenerationTask = nil
        proxyRelinkTask?.cancel()
        proxyRelinkTask = nil
        isRelinkingProxy = false
        sourceRevisions.removeAll()
        pendingSourceTransport = nil
        proxyCreationDraft = nil
        isImporting = false
        pauseSource()
        sourcePlayer = nil
        previewImage = nil
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    func importMedia() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importMedia(urls: panel.urls)
    }

    func importMedia(urls: [URL]) {
        guard !isImporting, !urls.isEmpty else { return }
        beginImport(urls: urls)
    }

    /// Finder drops capture their frame-aligned placement before inspection starts.
    /// A file that cannot be placed is refused entirely, including its bin entry and grant.
    @discardableResult
    func importMediaToTimeline(urls: [URL], at seconds: Double, trackID: UUID? = nil) -> Bool {
        guard !isImporting, audioAppendAsset == nil, renderExportDraft == nil, edlExportDraft == nil,
              !urls.isEmpty, seconds.isFinite, seconds >= 0,
              urls.allSatisfy({ $0.isFileURL && !$0.hasDirectoryPath &&
                  (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }) else { return false }
        let frames = seconds * project.settings.frameRate.value.seconds
        guard frames.isFinite, frames < Double(Int64.max),
              let placement = try? project.settings.frameRate.time(forFrames: Int64(frames.rounded())) else { return false }
        beginImport(urls: urls, placement: placement, trackID: trackID)
        return true
    }

    private func beginImport(urls: [URL], placement: RationalTime? = nil, trackID: UUID? = nil) {
        let epoch = mediaEpoch
        let importBinID = selectedMediaBinID
        isImporting = true
        errorMessage = nil
        importTask = Task {
            var imported = 0
            var failures: [String] = []
            var cursor = placement
            for url in urls {
                guard !Task.isCancelled, epoch == mediaEpoch else { return }
                let alreadyHeldAccess = scopedURLs.contains(url)
                holdAccess(url)
                do {
                    let result = try await MediaImporter.inspect(url: url)
                    guard !Task.isCancelled, epoch == mediaEpoch else { return }
                    if let start = cursor {
                        // Compute the next cursor before committing, so overflow is atomic too.
                        let next = try start.adding(result.asset.duration)
                        var ids: [UUID] = []
                        try change(bookmarkUpdates: [result.asset.id: result.bookmark]) { project in
                            let originalTrackIDs = project.tracks.map(\.id)
                            let targetIndex = trackID.flatMap { id in project.tracks.firstIndex(where: { $0.id == id }) }
                            let target = targetIndex.map { project.tracks[$0] }
                            try project.addAsset(result.asset)
                            if let importBinID, project.mediaBins.contains(where: { $0.id == importBinID }) {
                                try project.moveAssets([result.asset.id], toMediaBin: importBinID)
                            }
                            ids = try project.appendAsset(result.asset.id, at: start)
                            if let target, let targetIndex,
                               let component = project.tracks.flatMap(\.clips).first(where: {
                                   ids.contains($0.id) && $0.requiredTrackKind == target.kind &&
                                   $0.requiredAudioLayout == target.audioLayout
                               }) {
                                // Assembly may clean an empty target while placing onto its default track.
                                if !project.tracks.contains(where: { $0.id == target.id }) {
                                    let successors = originalTrackIDs.dropFirst(targetIndex + 1)
                                    let predecessors = originalTrackIDs.prefix(targetIndex).reversed()
                                    let nextIndex = successors.compactMap { id in project.tracks.firstIndex(where: { $0.id == id }) }.first
                                    let previousIndex = predecessors.compactMap { id in project.tracks.firstIndex(where: { $0.id == id }) }.first
                                    project.tracks.insert(target, at: nextIndex ?? previousIndex.map { $0 + 1 } ?? 0)
                                }
                                var engine = try TimelineEditEngine(project: project)
                                try engine.apply(.move(clipID: component.id, trackID: target.id, start: start))
                                project = engine.project
                            }
                        }
                        cursor = next
                        selectAsset(result.asset.id)
                        selectedClipID = ids.first
                    } else {
                        try registerImportedMedia(result, binID: importBinID)
                    }
                    imported += 1
                } catch {
                    guard !Task.isCancelled, epoch == mediaEpoch else { return }
                    if !alreadyHeldAccess, scopedURLs.contains(url),
                       !project.assets.contains(where: { $0.originalURL?.standardizedFileURL == url.standardizedFileURL }) {
                        url.stopAccessingSecurityScopedResource()
                        scopedURLs.remove(url)
                    }
                    let guidance = placement != nil && audioEditErrorMessage(error).contains("Audio layout")
                        ? " Import it into the media bin and use Append with audio selection… to choose audio channels and routing." : ""
                    failures.append("\(url.lastPathComponent): \(audioEditErrorMessage(error))\(guidance)")
                }
            }
            guard !Task.isCancelled, epoch == mediaEpoch else { return }
            isImporting = false
            statusMessage = placement == nil ? "Imported \(imported) file\(imported == 1 ? "" : "s")."
                : "Added \(imported) file\(imported == 1 ? "" : "s") to the timeline."
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func registerImportedMedia(_ imported: ImportedMedia, binID: UUID? = nil) throws {
        try change(bookmarkUpdates: [imported.asset.id: imported.bookmark]) { project in
            try project.addAsset(imported.asset)
            if let binID, project.mediaBins.contains(where: { $0.id == binID }) {
                try project.moveAssets([imported.asset.id], toMediaBin: binID)
            }
        }
        selectAsset(imported.asset.id)
    }

    func replaceMedia(assetID: UUID, with imported: ImportedMedia) throws {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else { throw TimelineEditError.missingClip }
        guard imported.asset.streams.map(\.index) == asset.streams.map(\.index),
              imported.asset.streams.map(\.kind) == asset.streams.map(\.kind),
              imported.asset.streams.map(\.audioLayout) == asset.streams.map(\.audioLayout) else {
            throw EditorCoreError.invalidModel("Replacement media must have matching stream identities and channel layouts.")
        }
        try change(bookmarkUpdates: [assetID: imported.bookmark], proxyBookmarkUpdates: [assetID: nil]) { project in
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
            project.assets[index].proxy = nil
            project.assets[index].originalURL = imported.asset.originalURL
            project.assets[index].duration = imported.asset.duration
            project.assets[index].streams = imported.asset.streams
        }
        sourceRevisions[assetID] = UUID()
        mediaPreviewRevision = UUID()
        selectAsset(assetID)
    }

    var visibleBinAssets: [MediaAsset] {
        project.assets.filter { project.assetBinAssignments[$0.id] == selectedMediaBinID }
    }

    func selectMediaBin(_ id: UUID?) {
        guard id == nil || project.mediaBins.contains(where: { $0.id == id }) else { return }
        selectedMediaBinID = id
        selectAssets([])
    }

    func createMediaBin(name: String) {
        do {
            var id: UUID?
            try change { id = try $0.createMediaBin(name: name, parentID: selectedMediaBinID) }
            selectMediaBin(id)
        } catch { report(error) }
    }

    func renameSelectedMediaBin(name: String) {
        guard let bin = project.mediaBins.first(where: { $0.id == selectedMediaBinID }) else { return }
        do { try change { try $0.updateMediaBin(id: bin.id, name: name, parentID: bin.parentID) } }
        catch { report(error) }
    }

    func moveMediaBin(_ id: UUID, to parentID: UUID?) {
        guard let bin = project.mediaBins.first(where: { $0.id == id }) else { return }
        do { try change { try $0.updateMediaBin(id: id, name: bin.name, parentID: parentID) } }
        catch { report(error) }
    }

    func removeSelectedMediaBin() {
        guard let bin = project.mediaBins.first(where: { $0.id == selectedMediaBinID }) else { return }
        do {
            try change { try $0.removeMediaBin(id: bin.id) }
            selectMediaBin(bin.parentID)
            statusMessage = "Removed bin. Its media and sub-bins moved to the parent."
        } catch { report(error) }
    }

    func moveBinAssets(_ ids: Set<UUID>, to binID: UUID?) {
        do {
            try change { try $0.moveAssets(ids, toMediaBin: binID) }
            selectAssets(selectedAssetIDs.intersection(Set(visibleBinAssets.map(\.id))))
        } catch { report(error) }
    }

    func focusSourceViewer() { if showSequenceMonitor { showSequenceMonitor = false } }
    func focusSequenceViewer() { if !showSequenceMonitor { showSequenceMonitor = true } }
    func toggleViewer() { showSequenceMonitor.toggle() }
    func selectTimelineClip(_ id: UUID) {
        focusSequenceViewer()
        if selectedClipID != id { selectedClipID = id }
    }

    func selectAsset(_ id: UUID) {
        selectedMediaBinID = project.assetBinAssignments[id]
        selectedAssetID = id
        selectedAssetIDs = [id]
        refreshSourcePreview()
    }

    func selectAssets(_ ids: Set<UUID>) {
        let added = ids.subtracting(selectedAssetIDs)
        selectedAssetIDs = ids
        if let id = project.assets.first(where: { added.contains($0.id) })?.id ?? selectedAssetID.flatMap({ ids.contains($0) ? $0 : nil }) ?? project.assets.first(where: { ids.contains($0.id) })?.id {
            if id != selectedAssetID { selectedAssetID = id; refreshSourcePreview() }
        } else {
            selectedAssetID = nil
            sourcePreviewTask?.cancel()
            pauseSource(); sourcePlayer = nil; previewImage = nil
        }
    }

    func pauseSource() {
        sourceTransportTask?.cancel()
        sourceTransportTask = nil
        sourcePlayer?.pause()
        if let pending = pendingSourceTransport { pendingSourceTransport = (pending.time, false) }
    }

    func playSourceForwards() {
        pauseSource()
        guard let asset = selectedAsset else { return }
        guard let player = sourcePlayer else {
            if let pending = pendingSourceTransport {
                let time = pending.time.seconds >= asset.duration.seconds - 0.001 ? CMTime.zero : pending.time
                pendingSourceTransport = (time, true)
            }
            return
        }
        sourceTransportTask = Task {
            if player.currentTime().seconds >= asset.duration.seconds - 0.001 {
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard !Task.isCancelled else { return }
            player.play()
        }
    }

    func playSourceBackwards() {
        pauseSource()
        guard let player = sourcePlayer, let asset = selectedAsset else { return }
        // Seek-based reverse works even when the source codec has no native reverse
        // support. Keep audio paused, and allow only one outstanding seek at a time.
        let current = player.currentTime().seconds
        let start = current.isFinite && current > 0 ? current : asset.duration.seconds
        sourceTransportTask = Task {
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let position = max(0, start - (ProcessInfo.processInfo.systemUptime - began))
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 60000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, position > 0 else { return }
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
    }

    var selectedSourceRange: TimeRange? {
        guard let asset = selectedAsset else { return nil }
        return sourceRanges[asset.id] ?? (try? TimeRange(start: .zero, duration: asset.duration))
    }

    func clearSourceMarks() {
        guard let id = selectedAssetID else { return }
        sourceRanges.removeValue(forKey: id)
    }

    /// Out is an exclusive boundary. Qualified CFR picture marks snap to source
    /// frames; other media uses an explicit microsecond clock rather than guessed cadence.
    func markSource(inPoint: Bool) {
        guard let asset = selectedAsset, let range = selectedSourceRange else { return }
        let seconds = pendingSourceTransport?.time.seconds ?? sourcePlayer?.currentTime().seconds ?? 0
        guard seconds.isFinite else { return }
        do {
            let clamped = max(0, min(asset.duration.seconds, seconds))
            let position: RationalTime
            if clamped >= asset.duration.seconds {
                position = asset.duration
            } else if let rate = asset.streams.first(where: { $0.kind == .video })?.videoFormat?.frameRate {
                let frames = (clamped * rate.value.seconds).rounded()
                guard frames.isFinite, frames < Double(Int64.max) else { throw EditorCoreError.overflow }
                position = try RationalTime(Int64(frames)).divided(by: rate.value)
            } else {
                let ticks = (clamped * 1_000_000).rounded()
                guard ticks.isFinite, ticks < Double(Int64.max) else { throw EditorCoreError.overflow }
                position = try RationalTime(Int64(ticks), 1_000_000)
            }
            let start = inPoint ? position : range.start
            let end = inPoint ? try range.end() : position
            guard try end.compared(to: asset.duration) != .orderedDescending else {
                throw EditorCoreError.invalidModel("Mark exceeds source duration")
            }
            sourceRanges[asset.id] = try TimeRange(start: start, duration: end.subtracting(start))
            statusMessage = inPoint ? "Source In marked." : "Source Out marked (exclusive)."
        } catch {
            errorMessage = "In must precede Out. Clear marks to use the full source."
        }
    }

    func appendSelectedAsset() {
        guard let asset = selectedAsset else { return }
        if let stream = asset.streams.first(where: { $0.kind == .audio }),
           let layout = stream.audioLayout,
           layout != project.settings.audioLayout && !(layout.channels.count == 1 && project.settings.audioLayout == .stereo) {
            audioAppendAsset = asset
            return
        }
        do {
            var ids: [UUID] = []
            try change { ids = try $0.appendAsset(asset.id, sourceRange: selectedSourceRange) }
            selectedClipID = ids.first
            statusMessage = "Added to sequence. Video and audio components edit together."
        } catch { report(error) }
    }

    func beginAudioAppend() {
        guard let asset = selectedAsset, asset.streams.contains(where: { $0.kind == .audio }) else { return }
        audioAppendAsset = asset
    }
    func previewAudioAppend(assetID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], sourceRange: TimeRange? = nil) throws -> Project {
        var candidate = project
        try candidate.appendAsset(assetID, sourceRange: sourceRange, audioSelections: selections, routing: routing)
        return candidate
    }
    func applyAudioAppend(assetID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], expectedProject: Project, sourceRange: TimeRange? = nil) throws {
        guard project == expectedProject else {
            throw EditorCoreError.invalidModel("The project changed while selecting audio. Reopen append to review the current sequence.")
        }
        var ids: [UUID] = []
        try change { ids = try $0.appendAsset(assetID, sourceRange: sourceRange, audioSelections: selections, routing: routing) }
        selectedClipID = ids.first
        statusMessage = "Added to sequence with the selected audio channels and output routing."
    }

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        if previous.project.assets != project.assets || previous.bookmarks != mediaBookmarks { mediaPreviewRevision = UUID() }
        redoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks, proxyBookmarks: proxyBookmarks))
        project = previous.project
        mediaBookmarks = previous.bookmarks
        proxyBookmarks = previous.proxyBookmarks
        reconcileSelection()
    }
    func redo() {
        guard let next = redoHistory.popLast() else { return }
        if next.project.assets != project.assets || next.bookmarks != mediaBookmarks { mediaPreviewRevision = UUID() }
        undoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks, proxyBookmarks: proxyBookmarks))
        project = next.project
        mediaBookmarks = next.bookmarks
        proxyBookmarks = next.proxyBookmarks
        reconcileSelection()
    }
    private func reconcileSelection() {
        if let id = selectedMediaBinID, !project.mediaBins.contains(where: { $0.id == id }) { selectedMediaBinID = nil }
        if selectedClip == nil { selectedClipID = nil }
        selectedAssetIDs.formIntersection(Set(project.assets.map(\.id)))
        if selectedAsset == nil {
            selectedAssetID = nil
            sourcePreviewTask?.cancel()
            sourcePreviewTask = nil
            pendingSourceTransport = nil
            pauseSource(); sourcePlayer = nil; previewImage = nil
        }
        else { selectedAssetIDs = selectedAssetIDs.intersection(Set(project.assets.map(\.id))); refreshSourcePreview() }
        playheadSeconds = min(playheadSeconds, duration)
    }
    func change(bookmarkUpdates: [UUID: Data?] = [:], proxyBookmarkUpdates: [UUID: Data?] = [:], _ mutation: (inout Project) throws -> Void) throws {
        var candidate = project
        try mutation(&candidate)
        try candidate.validate()
        var candidateBookmarks = mediaBookmarks
        for (id, bookmark) in bookmarkUpdates { candidateBookmarks[id] = bookmark }
        var candidateProxyBookmarks = proxyBookmarks
        for (id, bookmark) in proxyBookmarkUpdates { candidateProxyBookmarks[id] = bookmark }
        guard candidate != project || candidateBookmarks != mediaBookmarks || candidateProxyBookmarks != proxyBookmarks else { return }
        undoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks, proxyBookmarks: proxyBookmarks))
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        project = candidate
        mediaBookmarks = candidateBookmarks
        proxyBookmarks = candidateProxyBookmarks
        errorMessage = nil
    }
    private func edit(_ command: EditCommand) {
        do {
            try change {
                var engine = try TimelineEditEngine(project: $0)
                try engine.apply(command)
                $0 = engine.project
            }
        } catch { report(error) }
    }
    func renameTrack(_ id: UUID, name: String) {
        do { try change { try $0.renameTrack(id: id, name: name) } } catch { report(error) }
    }
    func renameTrackFamily(_ id: UUID, name: String) {
        do { try change { try $0.renameTrackFamily(id: id, name: name) } } catch { report(error) }
    }
    func setTrackRetention(_ id: UUID, retained: Bool) {
        do { try change { try $0.setTrackRetention(id: id, retained: retained) } } catch { report(error) }
    }
    func setTrackGain(_ id: UUID, decibels: String) {
        guard let value = Double(decibels), value.isFinite, (-96...24).contains(value) else {
            errorMessage = "Enter an audio gain between −96 and +24 dB."
            return
        }
        do { try change { try $0.setTrackGain(id: id, gain: pow(10, value / 20)) } } catch { report(error) }
    }
    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        edit(.delete(clipID: id)); reconcileSelection()
    }
    func splitSelectedClip() {
        guard let id = selectedClipID else { return }
        do { edit(.split(clipID: id, at: try editTime(playheadSeconds))) } catch { report(error) }
    }
    func moveSelectedClip(to seconds: Double) {
        guard let id = selectedClipID, let track = project.tracks.first(where: { $0.clips.contains { $0.id == id } }) else { return }
        do { edit(.move(clipID: id, trackID: track.id, start: try editTime(max(0, seconds)))) } catch { report(error) }
    }
    private func gestureQuantum(for clip: TimelineClip) -> Double {
        TimelineGesture.components(of: clip, in: project).contains { $0.requiredTrackKind == .video }
            ? 1 / project.settings.frameRate.value.seconds : 0.000001
    }
    private func snapTargets(excluding clip: TimelineClip) -> [Double] {
        let excluded = Set(TimelineGesture.components(of: clip, in: project).map(\.id))
        return [0, playheadSeconds] + project.tracks.flatMap(\.clips).filter { !excluded.contains($0.id) }.flatMap {
            [$0.timelineStart.seconds, $0.timelineStart.seconds + $0.sourceRange.duration.seconds]
        }
    }
    func proposedMove(clip: TimelineClip, to seconds: Double, tolerance: Double) -> Double {
        let components = TimelineGesture.components(of: clip, in: project)
        let minimum = clip.timelineStart.seconds - (components.map { $0.timelineStart.seconds }.min() ?? 0)
        let proposed = snappingEnabled ? TimelineGesture.snap(seconds, movingEdges: [0, clip.sourceRange.duration.seconds], targets: snapTargets(excluding: clip), tolerance: tolerance) : seconds
        let quantum = gestureQuantum(for: clip)
        return max(ceil(minimum / quantum) * quantum, (proposed / quantum).rounded() * quantum)
    }
    func proposedTrimDelta(clip: TimelineClip, edge: TimelineTrimEdge, delta: Double, tolerance: Double) -> Double {
        let edgeTime = clip.timelineStart.seconds + (edge == .leading ? 0 : clip.sourceRange.duration.seconds)
        let proposed = snappingEnabled ? TimelineGesture.snap(edgeTime + delta, movingEdges: [0], targets: snapTargets(excluding: clip), tolerance: tolerance) - edgeTime : delta
        return TimelineGesture.trimDelta(proposed, edge: edge, clip: clip, project: project, quantum: gestureQuantum(for: clip))
    }
    func trimSelectedClip(edge: TimelineTrimEdge, delta: Double) {
        guard let clip = selectedClip else { return }
        do {
            let bounded = TimelineGesture.trimDelta(delta, edge: edge, clip: clip, project: project, quantum: gestureQuantum(for: clip))
            let change = try editTime(bounded)
            let range = try TimeRange(start: edge == .leading ? clip.sourceRange.start.adding(change) : clip.sourceRange.start,
                                      duration: edge == .leading ? clip.sourceRange.duration.subtracting(change) : clip.sourceRange.duration.adding(change))
            edit(.trim(clipID: clip.id, sourceRange: range, timelineStart: edge == .leading ? try clip.timelineStart.adding(change) : clip.timelineStart))
        } catch { report(error) }
    }
    func trimSelectedClip(start: Double, duration: Double) {
        guard let clip = selectedClip else { return }
        do {
            let sourceIn = start == clip.sourceRange.start.seconds ? clip.sourceRange.start : try editTime(start)
            let extent = duration == clip.sourceRange.duration.seconds ? clip.sourceRange.duration : try editTime(duration)
            edit(.trim(clipID: clip.id, sourceRange: try TimeRange(start: sourceIn, duration: extent), timelineStart: clip.timelineStart))
        } catch { report(error) }
    }
    func seek(to seconds: Double) { playheadSeconds = max(0, min(seconds, duration)) }
    var playheadTimecode: String {
        let position = playheadSeconds * project.settings.frameRate.value.seconds
        let nearest = position.rounded()
        let frames = abs(position - nearest) < 1e-8 ? nearest : floor(position)
        guard frames.isFinite, frames >= 0, frames < Double(Int64.max) else { return "00:00:00:00" }
        let count = project.settings.startTimecode.frameCount.addingReportingOverflow(Int64(frames))
        guard !count.overflow else { return "00:00:00:00" }
        return (try? Timecode(frameCount: count.partialValue, mode: project.settings.startTimecode.mode).formatted(rate: project.settings.frameRate)) ?? "00:00:00:00"
    }
    func updateStartTimecode(_ value: Timecode) {
        do { try change { $0.settings.startTimecode = value } } catch { report(error) }
    }
    func seek(toTimecode label: String) {
        do {
            let value = try Timecode(parsing: label, rate: project.settings.frameRate)
            guard value.mode == project.settings.startTimecode.mode else { throw EditorCoreError.invalidTime }
            let (frames, overflow) = value.frameCount.subtractingReportingOverflow(project.settings.startTimecode.frameCount)
            guard !overflow, frames >= 0 else { throw EditorCoreError.invalidTime }
            seek(to: try project.settings.frameRate.time(forFrames: frames).seconds)
        } catch { report(error) }
    }
    func stepPlayhead(frames: Int64) {
        let position = playheadSeconds * project.settings.frameRate.value.seconds
        let nearest = position.rounded()
        let aligned = abs(position - nearest) < 1e-8
        let target = aligned ? nearest + Double(frames) : (frames < 0 ? ceil(position) : floor(position)) + Double(frames)
        seek(to: target / project.settings.frameRate.value.seconds)
    }
    func setAutomaticTrackCleanup(_ enabled: Bool) {
        do { try change { $0.preferences.automaticallyRemoveEmptyTracks = enabled } } catch { report(error) }
    }
    func setAudioLayoutConfirmation(_ enabled: Bool) {
        do { try change { $0.preferences.askBeforeAudioTrackLayoutChanges = enabled } } catch { report(error) }
    }
    /// Fades use the audio sample grid even when their clip is linked to picture.
    private func audioFadeTime(_ seconds: Double, clip: TimelineClip) throws -> RationalTime {
        guard seconds.isFinite else { throw EditorCoreError.invalidTime }
        let rate = Int64(project.settings.audioSampleRate)
        let extent = try clip.sourceRange.duration.multiplied(by: rate)
        let maximum = extent.numerator / extent.denominator
        let samples = min(Double(maximum), max(0, seconds * Double(rate))).rounded()
        guard samples.isFinite, samples < Double(Int64.max) else { throw EditorCoreError.invalidTime }
        return try RationalTime(min(maximum, Int64(samples)), rate)
    }
    func proposedAudioFadeDuration(clip: TimelineClip, seconds: Double) -> Double {
        (try? audioFadeTime(seconds, clip: clip).seconds) ?? 0
    }
    /// Offer only pairs that the edit engine can link, including source-handle validation.
    func audioCrossfadeTargets(for clip: TimelineClip) -> [TimelineClip] {
        guard clip.requiredTrackKind == .audio else { return [] }
        return project.tracks.flatMap(\.clips).filter { candidate in
            guard candidate.id != clip.id, candidate.requiredTrackKind == .audio else { return false }
            let overlap = clip.timelineStart.seconds + clip.sourceRange.duration.seconds - candidate.timelineStart.seconds
            let seconds = overlap > 0 ? overlap : 1 / Double(project.settings.audioSampleRate)
            return (try? previewAudioCrossfade(outgoingClipID: clip.id, incomingClipID: candidate.id,
                                              seconds: seconds, curve: .equalPower)) != nil
        }.sorted { $0.timelineStart.seconds < $1.timelineStart.seconds }
    }
    private func crossfadeTime(_ seconds: Double) throws -> RationalTime {
        let rate = Int64(project.settings.audioSampleRate)
        let samples = (seconds * Double(rate)).rounded()
        guard seconds.isFinite, seconds > 0, samples.isFinite, samples >= 1, samples < Double(Int64.max) else {
            throw EditorCoreError.invalidModel("Enter a positive crossfade duration of at least one audio sample.")
        }
        return try RationalTime(Int64(samples), rate)
    }
    func previewAudioCrossfade(outgoingClipID: UUID, incomingClipID: UUID, seconds: Double,
                               curve: AudioFadeCurve) throws -> Project {
        let existing = project.audioCrossfades.first { $0.outgoingClipID == outgoingClipID && $0.incomingClipID == incomingClipID }
        let time = existing?.duration.seconds == seconds ? existing!.duration : try crossfadeTime(seconds)
        var engine = try TimelineEditEngine(project: project)
        do {
            try engine.apply(.setAudioCrossfade(outgoingClipID: outgoingClipID, incomingClipID: incomingClipID,
                                               duration: time, curve: curve))
        } catch TimelineEditError.invalidAudioCrossfade {
            throw EditorCoreError.invalidModel("Cannot link this audio pair. Use adjacent cuts with enough source handles or a duration matching the existing overlap. Audio layouts and output routing must match, and the linked edges must have no standalone fade.")
        }
        return engine.project
    }
    func applyAudioCrossfade(outgoingClipID: UUID, incomingClipID: UUID, seconds: Double,
                             curve: AudioFadeCurve, expectedProject: Project) throws {
        guard project == expectedProject else {
            throw EditorCoreError.invalidModel("The project changed while editing the crossfade. Review the current clips and try again.")
        }
        let draft = try previewAudioCrossfade(outgoingClipID: outgoingClipID, incomingClipID: incomingClipID,
                                              seconds: seconds, curve: curve)
        try change { $0 = draft }
        selectedClipID = outgoingClipID
        statusMessage = "Updated linked audio crossfade."
    }
    func removeAudioCrossfade(_ id: UUID, expectedProject: Project) throws {
        guard project == expectedProject else {
            throw EditorCoreError.invalidModel("The project changed while editing the crossfade. Review the current clips and try again.")
        }
        try change {
            var engine = try TimelineEditEngine(project: $0)
            try engine.apply(.removeAudioCrossfade(crossfadeID: id))
            $0 = engine.project
        }
        statusMessage = "Removed linked audio crossfade."
    }
    func audioEditErrorMessage(_ error: Error) -> String {
        if case EditorCoreError.invalidModel(let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
    func applyAudioFades(clipID: UUID, fadeInSeconds: Double, fadeInCurve: AudioFadeCurve,
                         fadeOutSeconds: Double, fadeOutCurve: AudioFadeCurve, expectedClip: TimelineClip) throws {
        guard fadeInSeconds.isFinite, fadeOutSeconds.isFinite, fadeInSeconds >= 0, fadeOutSeconds >= 0 else {
            throw EditorCoreError.invalidTime
        }
        guard let clip = project.tracks.flatMap(\.clips).first(where: { $0.id == clipID }), clip == expectedClip,
              clip.requiredTrackKind == .audio else {
            throw EditorCoreError.invalidModel("The audio clip changed while editing fades. Review its current settings and try again.")
        }
        // Preserve exact persisted times on the untouched edge, including imported rational values.
        let inTime = fadeInSeconds == clip.fadeIn.duration.seconds ? clip.fadeIn.duration : try audioFadeTime(fadeInSeconds, clip: clip)
        let outTime = fadeOutSeconds == clip.fadeOut.duration.seconds ? clip.fadeOut.duration : try audioFadeTime(fadeOutSeconds, clip: clip)
        let fadeIn = AudioFade(duration: inTime, curve: fadeInCurve)
        let fadeOut = AudioFade(duration: outTime, curve: fadeOutCurve)
        try change {
            var engine = try TimelineEditEngine(project: $0)
            try engine.apply(.setAudioFades(clipID: clipID, fadeIn: fadeIn, fadeOut: fadeOut))
            $0 = engine.project
        }
        selectedClipID = clipID
        statusMessage = "Updated audio fades."
    }
    /// Validate a draft on a copy before the inspector asks to commit a track change.
    func previewAudioSelection(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], replacingClipIDs: [UUID] = []) throws -> Project {
        var engine = try TimelineEditEngine(project: project)
        try engine.apply(audioSelectionCommand(clipID: clipID, selections: selections, routing: routing, replacingClipIDs: replacingClipIDs))
        return engine.project
    }
    func applyAudioSelection(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], replacingClipIDs: [UUID] = [], expectedProject: Project) throws {
        guard project == expectedProject else {
            throw EditorCoreError.invalidModel("The project changed while editing audio. Reopen source selection to review the current clip.")
        }
        try change {
            var engine = try TimelineEditEngine(project: $0)
            try engine.apply(audioSelectionCommand(clipID: clipID, selections: selections, routing: routing, replacingClipIDs: replacingClipIDs))
            $0 = engine.project
        }
        selectedClipID = clipID
        statusMessage = replacingClipIDs.isEmpty ? "Updated audio source channels and output routing."
            : "Combined \(replacingClipIDs.count + 1) audio components. Linked picture and timing preserved."
    }
    private func audioSelectionCommand(clipID: UUID, selections: [AudioSourceSelection], routing: [AudioRouting], replacingClipIDs: [UUID]) throws -> EditCommand {
        guard !replacingClipIDs.isEmpty else {
            return .selectAudioSource(clipID: clipID, selections: selections, routing: routing)
        }
        guard selections.count == 1, routing.count == 1 else { throw TimelineEditError.incompatibleAudioConsolidation }
        return .consolidateAudioSources(clipID: clipID, replacingClipIDs: replacingClipIDs, selection: selections[0], routing: routing[0])
    }
    private func editTime(_ seconds: Double) throws -> RationalTime {
        guard let clip = selectedClip else { return try time(seconds) }
        let linkedVideo = project.tracks.flatMap(\.clips).contains {
            $0.requiredTrackKind == .video && (clip.id == $0.id || (clip.linkGroupID != nil && clip.linkGroupID == $0.linkGroupID))
        }
        guard linkedVideo else { return try time(seconds) }
        let frames = seconds * project.settings.frameRate.value.seconds
        guard frames.isFinite, abs(frames) < Double(Int64.max) else { throw EditorCoreError.invalidTime }
        return try project.settings.frameRate.time(forFrames: Int64(frames.rounded()))
    }
    private func time(_ seconds: Double) throws -> RationalTime {
        guard seconds.isFinite, abs(seconds) < Double(Int64.max) / 1_000_000 else { throw EditorCoreError.invalidTime }
        return try RationalTime(Int64((seconds * 1_000_000).rounded()), 1_000_000)
    }
    func setScalingMode(_ mode: ScalingMode) {
        guard let id = selectedClipID else { return }
        do {
            try change { project in
                for track in project.tracks.indices {
                    if let clip = project.tracks[track].clips.firstIndex(where: { $0.id == id }) { project.tracks[track].clips[clip].scalingMode = mode }
                }
            }
        } catch { report(error) }
    }
    func updateSequence(width: Int, height: Int, frameRateText: String,
                        audioSampleRate: Int, audioLayout: ChannelLayout, startTimecodeLabel: String) {
        do {
            let rate = try FrameRate(parsing: frameRateText)
            let current = project.settings
            // The inspector displays a 24-hour label; retain an unwrapped saved
            // count when neither the label nor its rate has been edited.
            let timecode: Timecode
            if rate == current.frameRate,
               startTimecodeLabel == (try current.startTimecode.formatted(rate: rate)) {
                timecode = current.startTimecode
            } else {
                timecode = try Timecode(parsing: startTimecodeLabel, rate: rate)
            }
            updateSequence(try SequenceSettings(width: width, height: height, frameRate: rate,
                                                audioSampleRate: audioSampleRate, audioLayout: audioLayout,
                                                startTimecode: timecode))
        } catch {
            errorMessage = "Enter valid dimensions, an exact frame rate (for example 24000/1001), an audio sample rate and a timecode valid at that rate."
        }
    }
    /// Commit the complete output configuration as one validated, undoable edit.
    /// Existing clip timing and channel maps are retained; incompatible routes reject
    /// the entire change instead of silently dropping or remapping channels.
    func updateSequence(_ settings: SequenceSettings) {
        do {
            try change { $0.settings = settings }
        } catch {
            errorMessage = "Sequence settings could not be applied. Check the timecode and existing audio track/family output maps. \(error)"
        }
    }
    func matchSequenceToSelectedSource(streamIndex: Int) {
        guard let asset = selectedAsset else { return }
        do {
            try change { try $0.matchSequence(to: asset.id, streamIndex: streamIndex) }
            statusMessage = "Sequence picture settings match \(asset.name)."
        } catch {
            errorMessage = "Sequence matching could not be applied. \(error)"
        }
    }
    func relinkSelectedAsset() {
        guard let asset = selectedAsset, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink \(asset.name)"
        panel.allowedContentTypes = [.movie, .audio, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        holdAccess(url)
        let epoch = mediaEpoch
        isImporting = true
        importTask = Task {
            defer { if epoch == mediaEpoch { isImporting = false } }
            do {
                let result = try await MediaImporter.inspect(url: url)
                guard !Task.isCancelled, epoch == mediaEpoch else { return }
                try replaceMedia(assetID: asset.id, with: result)
            } catch { if !Task.isCancelled, epoch == mediaEpoch { report(error) } }
        }
    }
    private func report(_ error: Error) { errorMessage = String(describing: error) }
}
