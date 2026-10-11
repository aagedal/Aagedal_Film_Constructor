import AppKit
import AVKit
import Combine
import EditorCore
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published var project: Project = Project(settings: try! SequenceSettings())
    @Published var mediaBookmarks: [UUID: Data] = [:]
    @Published var selectedAssetID: UUID?
    @Published var selectedClipID: UUID?
    @Published var playheadSeconds: Double = 0
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var sourcePlayer: AVPlayer?
    @Published var previewImage: NSImage?
    @Published var statusMessage = "Import media to begin."
    private struct Snapshot { var project: Project; var bookmarks: [UUID: Data] }
    @Published private var undoHistory: [Snapshot] = []
    @Published private var redoHistory: [Snapshot] = []
    private var scopedURLs: Set<URL> = []
    private var importTask: Task<Void, Never>?
    private var mediaEpoch = UUID()

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var duration: Double { (try? TimelineRenderPlan(project: project).duration.seconds) ?? 0 }
    var selectedAsset: MediaAsset? { project.assets.first { $0.id == selectedAssetID } }
    var selectedClip: TimelineClip? { project.tracks.flatMap(\.clips).first { $0.id == selectedClipID } }

    func load(_ document: ProjectDocument) {
        close()
        isImporting = false
        undoHistory = []; redoHistory = []
        selectedAssetID = nil; selectedClipID = nil; playheadSeconds = 0
        previewImage = nil
        statusMessage = "Import media to begin."
        project = document.project
        mediaBookmarks = document.mediaBookmarks
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
    }

    private func holdAccess(_ url: URL) {
        if !scopedURLs.contains(url), url.startAccessingSecurityScopedResource() { scopedURLs.insert(url) }
    }

    func close() {
        mediaEpoch = UUID()
        importTask?.cancel()
        sourcePlayer?.pause()
        sourcePlayer = nil
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
        let urls = panel.urls
        let epoch = mediaEpoch
        isImporting = true
        importTask = Task {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                guard !Task.isCancelled, epoch == mediaEpoch else { return }
                holdAccess(url)
                do {
                    let result = try await MediaImporter.inspect(url: url)
                    guard !Task.isCancelled, epoch == mediaEpoch else { return }
                    try registerImportedMedia(result)
                    imported += 1
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            guard !Task.isCancelled, epoch == mediaEpoch else { return }
            isImporting = false
            statusMessage = "Imported \(imported) file\(imported == 1 ? "" : "s")."
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func registerImportedMedia(_ imported: ImportedMedia) throws {
        try change(bookmarkUpdates: [imported.asset.id: imported.bookmark]) { try $0.addAsset(imported.asset) }
        selectAsset(imported.asset.id)
    }

    func replaceMedia(assetID: UUID, with imported: ImportedMedia) throws {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else { throw TimelineEditError.missingClip }
        guard imported.asset.streams.map(\.index) == asset.streams.map(\.index),
              imported.asset.streams.map(\.kind) == asset.streams.map(\.kind),
              imported.asset.streams.map(\.audioLayout) == asset.streams.map(\.audioLayout) else {
            throw EditorCoreError.invalidModel("Replacement media must have matching stream identities and channel layouts.")
        }
        try change(bookmarkUpdates: [assetID: imported.bookmark]) { project in
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
            project.assets[index].originalURL = imported.asset.originalURL
            project.assets[index].duration = imported.asset.duration
            project.assets[index].streams = imported.asset.streams
        }
        selectAsset(assetID)
    }

    func selectAsset(_ id: UUID) {
        selectedAssetID = id
        sourcePlayer?.pause()
        sourcePlayer = nil
        previewImage = nil
        guard let asset = selectedAsset, let url = asset.originalURL else { return }
        holdAccess(url)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            statusMessage = "Missing media: \(asset.name). Choose Relink in the inspector."
            return
        }
        if asset.streams.isEmpty { previewImage = NSImage(contentsOf: url) }
        else { sourcePlayer = AVPlayer(url: url) }
        statusMessage = "Source preview: \(asset.name)"
    }

    func appendSelectedAsset() {
        guard let id = selectedAssetID else { return }
        do {
            var ids: [UUID] = []
            try change { ids = try $0.appendAsset(id) }
            selectedClipID = ids.first
            statusMessage = "Added to sequence. Video and audio components edit together."
        } catch { report(error) }
    }

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks))
        project = previous.project
        mediaBookmarks = previous.bookmarks
        reconcileSelection()
    }
    func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks))
        project = next.project
        mediaBookmarks = next.bookmarks
        reconcileSelection()
    }
    private func reconcileSelection() {
        if selectedClip == nil { selectedClipID = nil }
        if selectedAsset == nil { selectedAssetID = nil; sourcePlayer?.pause(); sourcePlayer = nil; previewImage = nil }
        else if let id = selectedAssetID { selectAsset(id) }
        playheadSeconds = min(playheadSeconds, duration)
    }
    private func change(bookmarkUpdates: [UUID: Data?] = [:], _ mutation: (inout Project) throws -> Void) throws {
        var candidate = project
        try mutation(&candidate)
        try candidate.validate()
        var candidateBookmarks = mediaBookmarks
        for (id, bookmark) in bookmarkUpdates { candidateBookmarks[id] = bookmark }
        guard candidate != project || candidateBookmarks != mediaBookmarks else { return }
        undoHistory.append(Snapshot(project: project, bookmarks: mediaBookmarks))
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        project = candidate
        mediaBookmarks = candidateBookmarks
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
    func trimSelectedClip(start: Double, duration: Double) {
        guard let clip = selectedClip else { return }
        do {
            let sourceIn = start == clip.sourceRange.start.seconds ? clip.sourceRange.start : try editTime(start)
            let extent = duration == clip.sourceRange.duration.seconds ? clip.sourceRange.duration : try editTime(duration)
            edit(.trim(clipID: clip.id, sourceRange: try TimeRange(start: sourceIn, duration: extent), timelineStart: clip.timelineStart))
        } catch { report(error) }
    }
    func seek(to seconds: Double) { playheadSeconds = max(0, min(seconds, duration)) }
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
    func updateSequence(width: Int, height: Int, frameRate: Double) {
        do {
            try change { project in
                // Preserve the standard fractional rates rather than persisting a rounded decimal.
                let rate: FrameRate
                if abs(frameRate - 29.97) < 0.001 { rate = try FrameRate(30000, 1001) }
                else if abs(frameRate - 23.976) < 0.001 { rate = try FrameRate(24000, 1001) }
                else if abs(frameRate - 59.94) < 0.001 { rate = try FrameRate(60000, 1001) }
                else { rate = try FrameRate(time(frameRate).numerator, time(frameRate).denominator) }
                project.settings.width = width; project.settings.height = height; project.settings.frameRate = rate
            }
        } catch { report(error) }
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
