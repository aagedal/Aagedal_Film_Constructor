import AppKit
import AVFoundation
import EditorCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum SmokeError: Error { case failed(String) }

@main
struct AppFileSmoke {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audioURL = directory.appendingPathComponent("stereo.wav")
        let imageURL = directory.appendingPathComponent("still.png")
        try createAudio(at: audioURL)
        try createImage(at: imageURL)
        let audio = try await MediaImporter.inspect(url: audioURL)
        try check(abs(audio.asset.duration.seconds - 2) < 0.001, "WAV duration")
        try check(audio.asset.streams.count == 1 && audio.asset.streams[0].audioLayout == .stereo, "WAV stereo layout")
        try check(audio.bookmark != nil, "WAV bookmark")
        try await exerciseSourcePlayback(audio: audio)
        try await exerciseSequenceCommands(audio: audio)
        let still = try await MediaImporter.inspect(url: imageURL)
        try check(still.asset.streams.isEmpty && still.asset.duration.seconds == 5, "Still image import")
        try await exerciseTimelineFileDrop(audioURL: audioURL, imageURL: imageURL, directory: directory)
        try await exerciseMediaBins(audioURL: audioURL, still: still)
        try exerciseDerivedProjectValues(asset: still.asset)
        try await exerciseWorkspaceResume(still: still)
        try await exerciseStillPreview(directory: directory, still: still, audio: audio)
        try exerciseProxyDocument(directory: directory)
        try exerciseTrackSettings()
        try exerciseSourceMarks()
        try exerciseRippleTrimCommands()
        try exerciseSequenceSettings()
        try exerciseSequenceMatching()
        let corruptURL = directory.appendingPathComponent("corrupt.png")
        try Data("invalid image".utf8).write(to: corruptURL)
        do {
            _ = try await MediaImporter.inspect(url: corruptURL)
            throw SmokeError.failed("Corrupt image accepted")
        } catch MediaImportError.invalidImage { }
        let batch = EditorStore()
        defer { batch.close() }
        batch.importMedia(urls: [corruptURL, audioURL])
        batch.importMedia(urls: [imageURL])
        for _ in 0..<500 where batch.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(!batch.isImporting && batch.project.assets.count == 1 && batch.project.assets[0].name == "stereo.wav",
                  "Batch import continues after a bad file and ignores overlapping requests")
        try check(batch.errorMessage?.contains("corrupt.png") == true && batch.statusMessage == "Imported 1 file.",
                  "Batch import reports partial success and the failed file")
        batch.importMedia(urls: [imageURL])
        let emptyDocument = ProjectDocument()
        batch.load(emptyDocument)
        try await Task.sleep(for: .milliseconds(20))
        try check(batch.project == emptyDocument.project && !batch.isImporting && !batch.canUndo,
                  "Opening a document cancels pending imports before they mutate the new project")

        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(audio)
        store.undo()
        try check(store.project.assets.isEmpty && store.mediaBookmarks.isEmpty, "Import undo restores grants")
        store.redo()
        try check(store.project.assets == [audio.asset] && store.mediaBookmarks[audio.asset.id] == audio.bookmark, "Import redo restores grants")
        try store.registerImportedMedia(still)
        store.selectedAssetID = audio.asset.id
        store.appendSelectedAsset()
        try check(store.errorMessage == nil && store.duration == 2, "Audio append")
        store.playheadSeconds = 1
        store.splitSelectedClip()
        try check(store.project.tracks.flatMap(\.clips).count == 2, "Audio split")
        store.undo()
        try check(store.project.tracks.flatMap(\.clips).count == 1, "Undo split")
        store.redo()
        try check(store.project.tracks.flatMap(\.clips).count == 2, "Redo split")
        store.selectedAssetID = still.asset.id
        store.appendSelectedAsset()
        try check(store.errorMessage == nil && store.duration == 7, "Still append")
        try store.project.validate()
        let beforeExport = store.project
        let exportHistory = (store.canUndo, store.canRedo)
        store.beginRenderExport()
        try check(store.renderExportDraft?.plan == TimelineRenderPlan(project: beforeExport),
                  "Render dialog captures an immutable original-media sequence snapshot including imported stills")
        try check(store.project == beforeExport && store.canUndo == exportHistory.0 && store.canRedo == exportHistory.1,
                  "Opening render export does not edit the document or undo history")
        store.undo()
        try check(store.renderExportDraft?.plan == TimelineRenderPlan(project: beforeExport),
                  "Subsequent edits do not change the export snapshot")
        store.redo()
        store.renderExportDraft = nil
        store.selectedClipID = store.project.tracks.flatMap(\.clips).first?.id
        store.beginEDLExport()
        let edlSnapshot = store.edlExportDraft!
        try check(edlSnapshot.project == store.project &&
                  edlSnapshot.initialTrackID == store.project.tracks.first(where: { $0.clips.contains { $0.id == store.selectedClipID } })?.id,
                  "Track EDL captures the project and starts on the selected clip's track")
        store.beginRenderExport()
        try check(store.renderExportDraft == nil, "An EDL sheet prevents a second export sheet")
        store.exportOTIO()
        try check(store.errorMessage == nil && store.project == edlSnapshot.project,
                  "An EDL sheet prevents OpenTimelineIO export without changing the document")
        store.undo()
        try check(store.edlExportDraft?.project == edlSnapshot.project,
                  "Subsequent edits preserve the EDL snapshot")
        store.redo()
        store.edlExportDraft = nil
        let beforeOTIO = store.project
        let otioHistory = (store.canUndo, store.canRedo)
        store.exportOTIO()
        try check(store.errorMessage?.contains("OpenTimelineIO") == true,
                  "Unsupported stills fail OpenTimelineIO validation before opening a save panel")
        try check(store.project == beforeOTIO && store.canUndo == otioHistory.0 && store.canRedo == otioHistory.1,
                  "Refused OpenTimelineIO export preserves the project and undo history")
        store.errorMessage = nil
        try exerciseInterchangeDestinationProtection(directory: directory, asset: audio.asset)
        let emptyExport = EditorStore()
        emptyExport.beginRenderExport()
        try check(emptyExport.renderExportDraft == nil && emptyExport.errorMessage != nil,
                  "Empty sequence export fails without opening a draft")
        emptyExport.close()
        emptyExport.beginEDLExport()
        try check(emptyExport.edlExportDraft == nil, "Empty track EDL does not open a sheet")

        var document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks, proxyBookmarks: store.proxyBookmarks)
        document.mediaBookmarks[UUID()] = Data([1, 2, 3])
        let projectURL = directory.appendingPathComponent("roundtrip.afcproject")
        try document.encodedData().write(to: projectURL)
        var restored = try ProjectDocument(data: Data(contentsOf: projectURL))
        try check(restored.project == store.project && restored.mediaBookmarks == store.mediaBookmarks, "Project round trip and orphan bookmark pruning")
        var fallback = ProjectDocument(project: store.project)
        let fallbackURL = try fallback.resolveMediaURL(for: audio.asset.id)
        try check(fallbackURL == audioURL, "Media without a bookmark preserves its original URL")
        try check(try fallback.resolveMediaURL(for: UUID()) == nil, "Unknown media resolution")
        var damagedGrant = ProjectDocument(project: store.project, mediaBookmarks: [audio.asset.id: Data([1, 2, 3])])
        let recoverable = try ProjectDocument(data: damagedGrant.encodedData())
        try check(recoverable.project == store.project, "Damaged media grant does not prevent opening the project for relinking")
        do {
            _ = try damagedGrant.resolveMediaURL(for: audio.asset.id)
            throw SmokeError.failed("Damaged media grant resolved")
        } catch let error as SmokeError { throw error }
        catch { }
        let resolved = try restored.resolveMediaURL(for: audio.asset.id)
        try check(resolved?.standardizedFileURL == audioURL.standardizedFileURL, "Persistent bookmark resolution")
        let reopened = EditorStore()
        reopened.load(restored)
        var canonicalExpected = store.project
        var canonicalReopened = reopened.project
        for index in canonicalExpected.assets.indices {
            canonicalExpected.assets[index].originalURL = canonicalExpected.assets[index].originalURL?.resolvingSymlinksInPath()
            canonicalReopened.assets[index].originalURL = canonicalReopened.assets[index].originalURL?.resolvingSymlinksInPath()
        }
        try check(canonicalReopened == canonicalExpected, "Editor reopen")
        try check(!reopened.canUndo && reopened.selectedClipID == nil, "Document load resets history and selection")
        var replacement = audio.asset
        replacement.originalURL = directory.appendingPathComponent("replacement.wav")
        try FileManager.default.copyItem(at: audioURL, to: replacement.originalURL!)
        let replacementMedia = try await MediaImporter.inspect(url: replacement.originalURL!)
        try reopened.replaceMedia(assetID: audio.asset.id, with: replacementMedia)
        try check(reopened.mediaBookmarks[audio.asset.id] == replacementMedia.bookmark, "Relink updates grant")
        reopened.undo()
        try check(reopened.mediaBookmarks[audio.asset.id] == audio.bookmark, "Relink undo restores original grant")
        var undoneDocument = ProjectDocument(project: reopened.project, mediaBookmarks: reopened.mediaBookmarks)
        let undoneURL = try undoneDocument.resolveMediaURL(for: audio.asset.id)
        try check(undoneURL?.resolvingSymlinksInPath() == audioURL.resolvingSymlinksInPath(), "Relink undo reopen uses original file")
        reopened.redo()
        try check(reopened.mediaBookmarks[audio.asset.id] == replacementMedia.bookmark, "Relink redo restores replacement grant")
        var incompatible = replacementMedia.asset
        incompatible.streams[0].index += 1
        let beforeFailure = reopened.project
        do {
            try reopened.replaceMedia(assetID: audio.asset.id, with: ImportedMedia(asset: incompatible, bookmark: nil))
            throw SmokeError.failed("Relink accepted mismatched stream identities")
        } catch EditorCoreError.invalidModel { }
        try check(reopened.project == beforeFailure, "Relink failure is atomic")
        let grantsBeforeFailure = reopened.mediaBookmarks
        var tooShort = replacementMedia.asset
        tooShort.duration = try RationalTime(1, 2)
        do {
            try reopened.replaceMedia(assetID: audio.asset.id, with: ImportedMedia(asset: tooShort, bookmark: nil))
            throw SmokeError.failed("Relink accepted media shorter than used source range")
        } catch EditorCoreError.invalidModel { }
        try check(reopened.project == beforeFailure && reopened.mediaBookmarks == grantsBeforeFailure,
                  "Short relink failure preserves project and grants")
        reopened.load(restored)
        try check(!reopened.canUndo, "Reload clears previous editing history")
        reopened.close()

        try reject(Data("{bad json".utf8), "Corrupt project accepted")
        let unknown = Data("{\"formatVersion\":999}".utf8)
        do {
            _ = try ProjectDocument(data: unknown)
            throw SmokeError.failed("Unknown project schema accepted")
        } catch ProjectFileError.unsupportedVersion(999) { }
        var invalid = try JSONSerialization.jsonObject(with: document.encodedData()) as! [String: Any]
        var invalidProject = invalid["project"] as! [String: Any]
        var invalidSettings = invalidProject["settings"] as! [String: Any]
        invalidSettings["width"] = 0
        invalidProject["settings"] = invalidSettings
        invalid["project"] = invalidProject
        try reject(JSONSerialization.data(withJSONObject: invalid), "Invalid project settings accepted")
        try exerciseWorkspace()
        try exerciseAudioSelection()
        try exerciseAudioAppend()
        try exerciseAudioFades()
        try exerciseAudioCrossfades()
        try exerciseShortcuts()
        print("App file smoke passed: Q/W ripple scope/undo/playhead/remapping/migration and Shift+Z dispatch, exact source marks/scoped I/O commands/linked range append/explicit audio preview/undo/redo/clear/document reset, track/family naming/gain/retention/undo/redo/document round trip, viewer context/Tab command dispatch/special-key mapping/selection and playhead preservation, exact sequence settings/persistence/render-plan propagation/atomic undo/redo/track and family route rejection, nested-bin persistence/navigation/batch moves/undo/bookmarks/captured imports/deleted-destination fallback, Finder timeline drops/captured rational placement/batch ordering/target-track siblings/atomic import-clip-grant history/stale-document cancellation, EDL snapshot/selection/export exclusion/original alias protection, WAV/PNG import, bookmarks, relink safety, linked trims/snapping/undo/redo, timecode, initial audio placement/picture-only append, audio channel maps/routing/consolidation/stale drafts, sample-aligned audio fades/overlap/undo, linked crossfade drafts/handles/relink/undo, shortcut persistence/scoped dispatch, source J/K/L/reverse bounds/transport cancellation, workspace resume preserving undo/selection/playhead, project save/reopen, corrupt and unsupported file rejection.")
    }

    @MainActor
    static func exerciseRippleTrimCommands() throws {
        let asset = MediaAsset(name: "Shortcut fixture", duration: try RationalTime(8), streams: [MediaStream(index: 0, kind: .video)])
        let template = TrackTemplate(kind: .video)
        let family = TrackFamily(baseName: "Video", template: template)
        let first = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(4)), selection: .video(streamIndex: 0))
        var second = first; second.id = UUID(); second.timelineStart = try RationalTime(4)
        let store = EditorStore()
        defer { store.close() }
        store.project = Project(settings: try SequenceSettings(), assets: [asset], families: [family], tracks: [TimelineTrack(familyID: family.id, template: template, clips: [first, second])])
        store.selectedClipID = first.id
        store.playheadSeconds = 2
        let original = store.project
        let registry = EditorCommandRegistry(defaults: UserDefaults(suiteName: "afc-ripple-shortcuts")!)
        registry.reset()
        try check(registry.isEnabled(.rippleTrimStart, store: store, scope: .timeline), "Q enabled inside selected clip")
        try check(!registry.isEnabled(.rippleTrimStart, store: store, scope: .source), "Q restricted to timeline scope")
        registry.perform(.rippleTrimStart, store: store, scope: .source)
        try check(store.project == original, "Source focus must not ripple timeline")
        registry.perform(.rippleTrimStart, store: store, scope: .timeline)
        try check(store.project.tracks[0].clips[0].sourceRange.start == (try RationalTime(2)) && store.project.tracks[0].clips[1].timelineStart == (try RationalTime(2)), "Q trims source and closes following time")
        try check(store.playheadSeconds == 0 && store.errorMessage == nil, "Leading ripple moves playhead to resulting cut")
        store.undo(); try check(store.project == original, "Q is one undoable edit")
        store.playheadSeconds = 2
        registry.perform(.rippleTrimEnd, store: store, scope: .timeline)
        try check(store.project.tracks[0].clips[0].sourceRange.duration == (try RationalTime(2)) && store.project.tracks[0].clips[1].timelineStart == (try RationalTime(2)), "W trims end and closes following time")
        try check(store.playheadSeconds == 2, "Trailing ripple retains cut playhead")
        try check(!registry.isEnabled(.rippleTrimEnd, store: store, scope: .timeline), "Ripple disabled at clip end")
        let fitRequest = store.timelineFitRequest
        registry.perform(.zoomTimelineToFit, store: store, scope: .timeline)
        try check(store.timelineFitRequest != fitRequest, "Shift Z requests viewport fit")
        let defaults = UserDefaults(suiteName: "afc-ripple-shortcuts")!
        try check(registry.set(ShortcutBinding(key: "r", option: true), for: .rippleTrimStart) == nil, "Q command remains remappable")
        let restored = EditorCommandRegistry(defaults: defaults)
        try check(restored.binding(for: .rippleTrimStart) == ShortcutBinding(key: "r", option: true), "Ripple shortcut persists")
        registry.reset()
        var legacy = Dictionary(uniqueKeysWithValues: EditorCommandID.allCases.filter {
            ![.rippleTrimStart, .rippleTrimEnd, .zoomTimelineToFit].contains($0)
        }.map { ($0.rawValue, $0.defaultBinding) })
        legacy[EditorCommandID.playForward.rawValue] = ShortcutBinding(key: "q")
        defaults.set(try JSONEncoder().encode(legacy), forKey: "editor.keyboardShortcuts.v1")
        let migrated = EditorCommandRegistry(defaults: defaults)
        try check(migrated.binding(for: .playForward) == ShortcutBinding(key: "q") && migrated.binding(for: .rippleTrimStart).isEmpty,
            "New defaults preserve old custom bindings and leave conflicting new command unbound")
        migrated.reset()
    }

    @MainActor
    static func exerciseSourceMarks() throws {
        let store = EditorStore()
        defer { store.close() }
        let rate = try FrameRate(24000, 1001)
        let format = try VideoSourceFormat(width: 1920, height: 1080, frameRate: rate)
        let asset = MediaAsset(name: "Marked take", duration: try RationalTime(10), streams: [
            MediaStream(index: 0, kind: .video, videoFormat: format),
            MediaStream(index: 1, kind: .audio, audioLayout: .stereo)
        ])
        store.project = Project(settings: try SequenceSettings(), assets: [asset])
        store.selectedAssetID = asset.id
        let before = store.project
        store.pendingSourceTransport = (CMTime(seconds: 1, preferredTimescale: 60000), false)
        let registry = EditorCommandRegistry(defaults: UserDefaults(suiteName: "afc.source-marks.smoke")!)
        registry.reset()
        registry.perform(.markSourceIn, store: store, scope: .timeline)
        try check(store.sourceRanges.isEmpty, "Source marking shortcuts respect timeline focus")
        registry.perform(.markSourceIn, store: store, scope: .source)
        store.pendingSourceTransport = (CMTime(seconds: 3, preferredTimescale: 60000), false)
        registry.perform(.markSourceOut, store: store, scope: .source)
        let range = try unwrap(store.selectedSourceRange, "Missing source range")
        try check(range.start == RationalTime(1001, 1000), "In snaps to exact source cadence")
        try check(try range.end() == RationalTime(3003, 1000), "Out snaps to exact source cadence")
        try check(store.project == before && !store.canUndo, "Marks do not edit the document")
        store.pendingSourceTransport = (CMTime.zero, false)
        store.markSource(inPoint: false)
        try check(store.selectedSourceRange == range && store.errorMessage != nil, "Invalid marks preserve selection")
        store.errorMessage = nil
        let selection = AudioSourceSelection(channels: [SourceChannel(streamIndex: 1, channelIndex: 0)], layout: .mono)
        let candidate = try store.previewAudioAppend(assetID: asset.id, selections: [selection], routing: [AudioRouting(outputChannels: [0])], sourceRange: range)
        try check(Set(candidate.tracks.flatMap(\.clips).map(\.sourceRange)) == [range], "Explicit audio preview uses the same range")
        store.appendSelectedAsset()
        try check(Set(store.project.tracks.flatMap(\.clips).map(\.sourceRange)) == [range], "Append uses marks for picture and audio")
        store.undo()
        try check(store.project == before && store.selectedSourceRange == range, "Append undo keeps source marks")
        store.redo()
        try check(store.duration == range.duration.seconds, "Append redo restores marked duration")
        store.clearSourceMarks()
        try check(store.selectedSourceRange?.duration == asset.duration, "Clear restores full source extent")
        store.load(ProjectDocument(project: before))
        try check(store.sourceRanges.isEmpty, "Loading another document clears working marks")
    }

    @MainActor
    static func exerciseTrackSettings() throws {
        let store = EditorStore()
        defer { store.close() }
        store.project = try DemoProjectFactory.musicCollision()
        let original = store.project
        let track = original.tracks[0]
        store.renameTrack(track.id, name: " Dialogue ")
        try check(store.project.tracks[0].customName == "Dialogue", "Track custom name")
        store.undo()
        try check(store.project == original && store.canRedo, "Track rename undo")
        store.renameTrackFamily(track.familyID, name: " ")
        try check(store.project == original && store.canRedo, "Invalid family rename preserves redo")
        store.redo()
        store.renameTrackFamily(track.familyID, name: " Voice ")
        try check(store.project.families[0].baseName == "Voice" && store.project.tracks[0].displayName(in: store.project) == "Dialogue", "Independent family naming")
        let beforeGain = store.project
        for invalid in ["NaN", "inf", "25", "-97", "text"] {
            store.setTrackGain(track.id, decibels: invalid)
            try check(store.project == beforeGain, "Invalid dB gain rejected")
        }
        store.setTrackGain(track.id, decibels: "-6")
        let gained = store.project
        try check(abs(gained.tracks[0].template.gain - pow(10, -6.0 / 20)) < 1e-12, "Gain converts dB to amplitude")
        store.undo()
        try check(store.project == beforeGain, "Gain undo")
        store.redo()
        try check(store.project == gained, "Gain redo")
        store.setTrackRetention(track.id, retained: true)
        let saved = try ProjectDocument(data: ProjectDocument(project: store.project).encodedData())
        try check(saved.project == store.project, "Track settings document round trip")
        for clip in track.clips {
            store.selectedClipID = clip.id
            store.deleteSelectedClip()
        }
        try check(store.project.tracks[0].clips.isEmpty, "Pinned empty track survives deletion")
        store.setTrackRetention(track.id, retained: false)
        try check(store.project.tracks.isEmpty, "Unpin empty track removes it")
        store.undo()
        try check(store.project.tracks[0].retained && store.project.tracks[0].clips.isEmpty, "Track removal undo")
    }

    @MainActor
    static func exerciseMediaBins(audioURL: URL, still: ImportedMedia) async throws {
        let store = EditorStore()
        defer { store.close() }
        store.createMediaBin(name: "Media sources")
        let parent = try unwrap(store.selectedMediaBinID, "Created parent bin")
        store.createMediaBin(name: "Sound")
        let child = try unwrap(store.selectedMediaBinID, "Created child bin")
        try check(store.project.mediaBins.last?.parentID == parent, "Create nested bin")
        store.importMedia(urls: [audioURL])
        store.selectMediaBin(nil)
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        let imported = try unwrap(store.project.assets.first, "Imported into bin")
        try check(store.project.assetBinAssignments[imported.id] == child, "Import captures destination before asynchronous inspection")
        store.undo()
        try check(store.project.assets.isEmpty && store.mediaBookmarks.isEmpty && store.project.assetBinAssignments.isEmpty,
                  "Undo import restores media, grants and bin assignment together")
        store.redo()
        try check(store.project.assetBinAssignments[imported.id] == child, "Redo restores import bin")
        try store.registerImportedMedia(still, binID: child)
        store.selectMediaBin(child)
        store.selectAssets(Set(store.visibleBinAssets.map(\.id)))
        let beforeMove = store.project
        let grants = store.mediaBookmarks
        store.moveBinAssets(store.selectedAssetIDs, to: parent)
        try check(store.visibleBinAssets.isEmpty && store.selectedAssetIDs.isEmpty, "Batch move clears hidden selection")
        try check(store.project.assetBinAssignments.values.allSatisfy { $0 == parent } && store.mediaBookmarks == grants,
                  "Batch bin move preserves all grants")
        store.undo()
        try check(store.project == beforeMove, "Batch move uses one undo transaction")
        store.redo(); store.undo()
        store.moveBinAssets([imported.id], to: child)
        try check(store.canRedo, "No-op bin move preserves redo history")
        store.selectMediaBin(child)
        store.removeSelectedMediaBin()
        try check(store.selectedMediaBinID == parent && store.project.assets.count == 2,
                  "Remove bin promotes contents and navigates to parent")
        store.undo()
        try check(store.project == beforeMove, "Remove bin is undoable")
        store.selectMediaBin(child)
        store.renameSelectedMediaBin(name: "Audio")
        store.moveMediaBin(parent, to: child)
        try check(store.errorMessage != nil && store.project.mediaBins.first?.parentID == nil,
                  "Cycle rejection leaves parent intact")
        let document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks)
        let reopened = try ProjectDocument(data: document.encodedData())
        try check(reopened.project == store.project && reopened.mediaBookmarks == grants, "Bins round trip with grants")
        store.load(ProjectDocument())
        try check(store.selectedMediaBinID == nil, "Opening a document resets bin navigation")
        store.createMediaBin(name: "Temporary")
        store.importMedia(urls: [audioURL])
        store.removeSelectedMediaBin()
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(store.project.assets.count == 1 && store.project.assetBinAssignments.isEmpty,
                  "Import falls back to root when captured destination is removed")
    }

    @MainActor
    static func exerciseTimelineFileDrop(audioURL: URL, imageURL: URL, directory: URL) async throws {
        let store = EditorStore()
        defer { store.close() }
        try check(!store.importMediaToTimeline(urls: [], at: 0) &&
                  !store.importMediaToTimeline(urls: [URL(string: "https://example.com/movie.mov")!], at: 0) &&
                  !store.importMediaToTimeline(urls: [directory], at: 0) &&
                  !store.importMediaToTimeline(urls: [audioURL], at: .nan) &&
                  !store.importMediaToTimeline(urls: [audioURL], at: -1),
                  "Timeline drops reject empty batches, remote URLs, directories, and invalid placement synchronously")
        store.audioAppendAsset = MediaAsset(name: "Pending audio", duration: try RationalTime(1))
        try check(!store.importMediaToTimeline(urls: [audioURL], at: 0), "Audio draft excludes timeline drops")
        store.audioAppendAsset = nil
        store.updateSequence(try SequenceSettings(frameRate: FrameRate(30000, 1001)))
        let baseline = store.project
        let captured = try baseline.settings.frameRate.time(forFrames: 30)
        try check(store.importMediaToTimeline(urls: [audioURL, imageURL], at: 1.01),
                  "An unsaved empty sequence accepts real Finder media")
        try check(!store.importMediaToTimeline(urls: [imageURL], at: 99), "Busy import rejects another timeline drop")
        store.playheadSeconds = 99
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(!store.isImporting && store.errorMessage == nil && store.project.assets.map(\.name) == ["stereo.wav", "still.png"],
                  "Timeline drop imports WAV and PNG in input order")
        let clips = store.project.tracks.flatMap(\.clips).sorted { $0.timelineStart.seconds < $1.timelineStart.seconds }
        try check(clips.count == 2 && clips[0].timelineStart == captured &&
                  clips[1].timelineStart == captured.adding(store.project.assets[0].duration),
                  "Drop captures rational frame-grid time and advances by the prior asset duration")
        let afterDrop = store.project
        let afterGrants = store.mediaBookmarks
        store.undo()
        try check(store.project.assets.count == 1 && store.project.tracks.flatMap(\.clips).count == 1 && store.mediaBookmarks.count == 1,
                  "One undo removes a dropped file, its clip and its bookmark atomically")
        store.undo()
        try check(store.project == baseline && store.mediaBookmarks.isEmpty, "Undo batch entries restores the empty sequence and grants")
        store.redo(); store.redo()
        try check(store.project == afterDrop && store.mediaBookmarks == afterGrants,
                  "Redo restores dropped clips, assets and grants together")
        let audioTrack = store.project.tracks.first(where: { $0.kind == .audio })!
        let sibling = TimelineTrack(familyID: audioTrack.familyID, template: audioTrack.template)
        let videoTrack = store.project.tracks.first(where: { $0.kind == .video })!
        let cleanedEarlierTrack = TimelineTrack(familyID: videoTrack.familyID, template: videoTrack.template)
        try store.change {
            $0.tracks.insert(cleanedEarlierTrack, at: 0)
            $0.tracks.append(sibling)
        }
        let targetOrder = store.project.tracks.filter { $0.id != cleanedEarlierTrack.id }.map(\.id)
        try check(store.importMediaToTimeline(urls: [audioURL], at: 10, trackID: sibling.id), "Selected compatible track accepts drop")
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(store.project.tracks.first(where: { $0.id == sibling.id })?.clips.count == 1 && store.project.tracks.map(\.id) == targetOrder,
                  "Dropped component uses the selected compatible track")
        let occupiedTarget = store.project.tracks.first(where: { $0.id == sibling.id })!
        let occupiedClips = occupiedTarget.clips
        try check(store.importMediaToTimeline(urls: [audioURL], at: 10, trackID: sibling.id), "An occupied track accepts timeline drops")
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(store.errorMessage == nil && store.project.tracks.first(where: { $0.id == sibling.id })?.clips == occupiedClips &&
                  store.project.tracks.contains { $0.id != sibling.id && $0.familyID == sibling.familyID &&
                      $0.clips.contains { $0.timelineStart == occupiedClips[0].timelineStart } },
                  "Overlapping drops create a compatible sibling and preserve occupied target clips")
        let vanishingTarget = TimelineTrack(familyID: audioTrack.familyID, template: audioTrack.template)
        try store.change { $0.tracks.append(vanishingTarget) }
        try check(store.importMediaToTimeline(urls: [audioURL], at: 15, trackID: vanishingTarget.id), "Drop captures a target before inspection")
        try store.change { $0.tracks.removeAll { $0.id == vanishingTarget.id } }
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        let fallbackStart = try store.project.settings.frameRate.time(forFrames: 450)
        try check(store.errorMessage == nil && store.project.tracks.flatMap(\.clips).contains { $0.timelineStart == fallbackStart },
                  "A target removed during inspection falls back to a compatible track")
        let beforeBinClips = store.project.tracks.flatMap(\.clips)
        store.importMedia(urls: [imageURL])
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(store.project.tracks.flatMap(\.clips) == beforeBinClips && store.project.assets.last?.name == "still.png" && !store.isImporting,
                  "Normal bin import keeps the timeline unchanged")
        store.renderExportDraft = SequenceExportDraft(plan: try TimelineRenderPlan(project: store.project))
        try check(!store.importMediaToTimeline(urls: [audioURL], at: 0), "Export draft excludes timeline drops")
        store.renderExportDraft = nil
        try check(store.importMediaToTimeline(urls: [imageURL], at: 0), "Stale drop fixture starts")
        let document = ProjectDocument()
        store.load(document)
        try await Task.sleep(for: .milliseconds(30))
        try check(store.project == document.project && store.mediaBookmarks.isEmpty && !store.isImporting && !store.canUndo,
                  "Document replacement cancels a pending timeline drop without stale clips or grants")

        let surroundURL = directory.appendingPathComponent("surround.wav")
        try createAudio(at: surroundURL, channels: 6)
        try check(store.importMediaToTimeline(urls: [surroundURL, imageURL], at: 0), "Incompatible layout fixture accepted for inspection")
        for _ in 0..<500 where store.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(store.project.assets.map(\.name) == ["still.png"] && store.project.tracks.flatMap(\.clips).first?.timelineStart == .zero &&
                  store.mediaBookmarks.count == 1 && store.errorMessage?.contains("choose audio channels and routing") == true,
                  "Incompatible audio is refused atomically with guidance; remaining batch files retain the drop cursor")
        try store.project.validate()
    }

    @MainActor
    static func exerciseAudioCrossfades() throws {
        let store = EditorStore()
        defer { store.close() }
        let outgoingAsset = MediaAsset(name: "Outgoing", duration: try RationalTime(3), streams: [MediaStream(index: 0, kind: .audio, audioLayout: .stereo)])
        let incomingAsset = MediaAsset(name: "Incoming", duration: try RationalTime(2), streams: outgoingAsset.streams)
        let selection = ClipSelection.audio(AudioSourceSelection(channels: [SourceChannel(streamIndex: 0, channelIndex: 0), SourceChannel(streamIndex: 0, channelIndex: 1)], layout: .stereo))
        let outgoing = TimelineClip(assetID: outgoingAsset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)), selection: selection,
                                    fadeIn: AudioFade(duration: try RationalTime(1, 4), curve: .linear))
        let incoming = TimelineClip(assetID: incomingAsset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(2)), timelineStart: try RationalTime(2), selection: selection)
        let template = TrackTemplate(kind: .audio, audioLayout: .stereo)
        let family = TrackFamily(baseName: "Audio", template: template)
        let baseline = Project(settings: try SequenceSettings(), assets: [outgoingAsset, incomingAsset], families: [family],
                               tracks: [TimelineTrack(familyID: family.id, template: template, clips: [outgoing, incoming])])
        try baseline.validate()
        store.load(ProjectDocument(project: baseline))
        try check(store.audioCrossfadeTargets(for: outgoing).map(\.id) == [incoming.id], "Crossfade targets include adjacent audio with one-sided handles")
        let preview = try store.previewAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: 0.1234567, curve: .equalPower)
        try check(store.project == baseline && !store.canUndo && preview.audioCrossfades.first?.duration == RationalTime(5926, 48000), "Crossfade preview is sample-aligned and does not mutate history")
        try store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: 0.5, curve: .equalPower, expectedProject: baseline)
        let linked = store.project
        try check(linked.tracks == baseline.tracks && linked.audioCrossfades.count == 1, "Crossfade preserves editorial timing and standalone opposite-edge fades")
        store.undo()
        try check(store.project == baseline && !store.canUndo, "Crossfade creation is one undo transaction")
        store.redo()
        try check(store.project == linked, "Crossfade redo restores relation")
        try check(try ProjectDocument(data: ProjectDocument(project: linked).encodedData()).project == linked, "Crossfade persists through document reopen")
        var shorter = outgoingAsset
        shorter.duration = try RationalTime(2)
        let bookmarks = store.mediaBookmarks
        do {
            try store.replaceMedia(assetID: outgoingAsset.id, with: ImportedMedia(asset: shorter, bookmark: nil))
            throw SmokeError.failed("Relink discarded required crossfade source handles")
        } catch TimelineEditError.invalidAudioCrossfade { }
        try check(store.project == linked && store.mediaBookmarks == bookmarks, "Relink rejection preserves crossfade document and grants")
        store.undo()
        try check(store.project == baseline && !store.canUndo, "Rejected relink does not add history")
        store.redo()
        try store.removeAudioCrossfade(linked.audioCrossfades[0].id, expectedProject: linked)
        try check(store.project == baseline, "Removing crossfade restores unchanged clip source ranges and timing")
        store.undo()
        try check(store.project == linked, "Crossfade removal undo restores the link")
        store.selectedClipID = incoming.id
        store.moveSelectedClip(to: 3)
        let edited = store.project
        do {
            try store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: 0.75, curve: .linear, expectedProject: linked)
            throw SmokeError.failed("Stale crossfade draft accepted after counterpart moved")
        } catch EditorCoreError.invalidModel { }
        try check(store.project == edited, "Stale counterpart draft is rejected atomically")
        store.undo()
        try check(store.project == linked && store.canRedo, "Rejected stale draft preserves counterpart redo")
        for invalid in [Double.nan, Double.infinity, -1, 0, 2] {
            do {
                try store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: invalid, curve: .linear, expectedProject: linked)
                throw SmokeError.failed("Invalid crossfade duration accepted")
            } catch EditorCoreError.invalidModel { }
        }
        try check(store.project == linked && store.canRedo, "Invalid crossfade drafts preserve document and history")
        try store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id, seconds: 0.5, curve: .equalPower, expectedProject: linked)
        try check(store.canRedo, "No-op crossfade apply preserves redo history")
        var singleSample = baseline
        singleSample.assets[0].duration = try RationalTime(2).adding(RationalTime(1, 48000))
        store.load(ProjectDocument(project: singleSample))
        try check(store.audioCrossfadeTargets(for: outgoing).map(\.id) == [incoming.id], "Target discovery accepts exactly one sample of source handles")
        try store.applyAudioCrossfade(outgoingClipID: outgoing.id, incomingClipID: incoming.id,
                                     seconds: 1.0 / 48000, curve: .linear, expectedProject: singleSample)
        try check(store.project.audioCrossfades.first?.duration == RationalTime(1, 48000), "Single-sample crossfade commits exactly")
    }

    @MainActor
    static func exerciseAudioFades() throws {
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(ImportedMedia(asset: MediaAsset(name: "Fade fixture", duration: try RationalTime(4), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 1, kind: .audio, audioLayout: .stereo)
        ]), bookmark: nil))
        store.appendSelectedAsset()
        let baseline = store.project
        let audio = baseline.tracks.flatMap(\.clips).first { $0.requiredTrackKind == .audio }!
        let picture = baseline.tracks.flatMap(\.clips).first { $0.requiredTrackKind == .video }!
        let proposed = store.proposedAudioFadeDuration(clip: audio, seconds: 0.1234567)
        try check(abs(proposed - 5926.0 / 48000) < 1e-12,
                  "Linked audio fades use audio sample alignment rather than picture frames")
        try check(store.project == baseline && store.proposedAudioFadeDuration(clip: audio, seconds: -2) == 0 &&
                  store.proposedAudioFadeDuration(clip: audio, seconds: 100) == 4,
                  "Local fade preview clamps independently without mutating history")
        try store.applyAudioFades(clipID: audio.id, fadeInSeconds: proposed, fadeInCurve: .equalPower,
                                 fadeOutSeconds: 3.5, fadeOutCurve: .linear, expectedClip: audio)
        let changed = store.project
        let faded = changed.tracks.flatMap(\.clips).first { $0.id == audio.id }!
        try check(faded.fadeIn.duration == RationalTime(5926, 48000) && faded.fadeIn.curve == .equalPower &&
                  faded.fadeOut.duration == RationalTime(7, 2), "Fade commit preserves rational samples and curves")
        try check(changed.tracks.flatMap(\.clips).first { $0.id == picture.id } == picture,
                  "Audio fade edit preserves linked picture")
        store.undo()
        try check(store.project == baseline, "One undo restores both audio fades")
        store.redo()
        try check(store.project == changed, "Audio fades redo")
        try check(try ProjectDocument(data: ProjectDocument(project: changed).encodedData()).project == changed,
                  "Audio fades persist through project save and reopen")
        store.undo()
        do {
            try store.applyAudioFades(clipID: audio.id, fadeInSeconds: 1, fadeInCurve: .linear,
                                     fadeOutSeconds: 1, fadeOutCurve: .linear, expectedClip: faded)
            throw SmokeError.failed("Stale audio fade draft accepted")
        } catch EditorCoreError.invalidModel { }
        for invalid in [-1.0, Double.nan, Double.infinity] {
            do {
                try store.applyAudioFades(clipID: audio.id, fadeInSeconds: invalid, fadeInCurve: .linear,
                                         fadeOutSeconds: 0, fadeOutCurve: .linear, expectedClip: audio)
                throw SmokeError.failed("Invalid fade duration accepted")
            } catch EditorCoreError.invalidTime { }
        }
        try check(store.project == baseline && store.canRedo, "Rejected fade edits preserve the document and redo history")
        try store.applyAudioFades(clipID: audio.id, fadeInSeconds: 0, fadeInCurve: .linear,
                                 fadeOutSeconds: 0, fadeOutCurve: .linear, expectedClip: audio)
        try check(store.canRedo, "No-op fade commit preserves redo history")
        try store.applyAudioFades(clipID: audio.id, fadeInSeconds: 3, fadeInCurve: .equalPower,
                                 fadeOutSeconds: 3, fadeOutCurve: .equalPower, expectedClip: audio)
        let overlap = store.selectedClip!
        try check(overlap.fadeIn.duration.seconds == 3 && overlap.fadeOut.duration.seconds == 3,
                  "Fade durations may overlap independently")
        let fractional = TimelineClip(assetID: audio.assetID, sourceRange: try TimeRange(start: .zero, duration: RationalTime(1, 7)),
                                      timelineStart: .zero, selection: audio.selection)
        let bound = store.proposedAudioFadeDuration(clip: fractional, seconds: 1)
        try check(abs(bound - 6857.0 / 48000) < 1e-12 && bound < 1.0 / 7,
                  "Fade clamp floors a fractional duration to the last complete sample")
        var imported = store.project
        for track in imported.tracks.indices {
            if let index = imported.tracks[track].clips.firstIndex(where: { $0.id == audio.id }) {
                imported.tracks[track].clips[index].fadeOut.duration = try RationalTime(1, 7)
            }
        }
        store.load(ProjectDocument(project: imported))
        let importedAudio = imported.tracks.flatMap(\.clips).first { $0.id == audio.id }!
        try store.applyAudioFades(clipID: audio.id, fadeInSeconds: 1, fadeInCurve: .linear,
                                 fadeOutSeconds: importedAudio.fadeOut.duration.seconds, fadeOutCurve: importedAudio.fadeOut.curve,
                                 expectedClip: importedAudio)
        try check(store.selectedClip?.fadeOut == importedAudio.fadeOut,
                  "Changing one fade preserves the opposite edge's exact imported rational duration")
    }

    @MainActor
    static func exerciseSequenceCommands(audio: ImportedMedia) async throws {
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(audio)
        store.appendSelectedAsset()
        let backend = CommandSequenceBackend()
        let controller = SequencePlaybackController(factory: { _ in backend })
        store.sequencePlayback = controller
        controller.activate(project: store.project, seconds: 0)
        for _ in 0..<100 where controller.isPreparing { try await Task.sleep(for: .milliseconds(5)) }
        let registry = EditorCommandRegistry(defaults: UserDefaults(suiteName: "afc-sequence-commands")!)
        controller.play()
        try check(controller.isPreparing, "Sequence play enters priming")
        try check(registry.isEnabled(.pausePlayback, store: store, scope: .timeline), "K remains enabled while sequence primes")
        try check(!registry.isEnabled(.playForward, store: store, scope: .timeline), "L is disabled while sequence primes")
        try check(!registry.isEnabled(.playReverse, store: store, scope: .timeline), "Sequence mode cannot play source backwards")
        registry.perform(.pausePlayback, store: store, scope: .timeline)
        try await Task.sleep(for: .milliseconds(200))
        try check(!backend.isPlaying && !controller.isPlaying, "K rejects delayed sequence play")
        controller.deactivate()
    }

    @MainActor
    static func exerciseSourcePlayback(audio: ImportedMedia) async throws {
        let store = EditorStore()
        defer { store.close() }
        let suite = "afc-playback-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EditorCommandRegistry(defaults: defaults)
        try check(!registry.isEnabled(.playForward, store: store, scope: .document), "Playback disabled without playable media")
        try store.registerImportedMedia(audio)
        let player = store.sourcePlayer!
        for _ in 0..<300 where player.currentItem?.status == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(player.currentItem?.status == .readyToPlay, "Playback fixture ready")
        try check(registry.isEnabled(.playReverse, store: store, scope: .timeline), "Source playback available with timeline focus")
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        registry.perform(.playReverse, store: store, scope: .timeline)
        try await Task.sleep(for: .milliseconds(250))
        try check(player.currentTime().seconds < 0.9 && player.rate == 0, "J seeks backwards silently")
        registry.perform(.pausePlayback, store: store, scope: .timeline)
        try await Task.sleep(for: .milliseconds(50))
        let paused = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(150))
        try check(abs(player.currentTime().seconds - paused) < 0.01, "K cancels reverse seeking")
        registry.perform(.playForward, store: store, scope: .timeline)
        try await Task.sleep(for: .milliseconds(150))
        try check(player.rate == 1, "L plays forwards")
        registry.perform(.pausePlayback, store: store, scope: .document)
        try check(player.rate == 0, "K pauses forward playback")
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        store.playSourceForwards()
        try await Task.sleep(for: .milliseconds(150))
        try check(player.currentTime().seconds < 1 && player.rate == 1, "L restarts at source end")
        store.pauseSource()
        await player.seek(to: CMTime(seconds: 0.1, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        store.playSourceBackwards()
        try await Task.sleep(for: .milliseconds(250))
        try check(player.currentTime().seconds < 0.01, "Reverse stops at source start")
        store.playSourceBackwards()
        try await Task.sleep(for: .milliseconds(100))
        try check(player.currentTime().seconds > 1.7, "J starts from source end when at zero")
        store.selectAsset(audio.asset.id)
        try await Task.sleep(for: .milliseconds(100))
        try check(store.sourcePlayer !== player && player.rate == 0, "Changing source cancels old transport")
        store.playSourceBackwards()
        store.close()
        try await Task.sleep(for: .milliseconds(100))
        try check(store.sourcePlayer == nil && player.rate == 0, "Closing cancels source transport")
    }

    @MainActor
    static func exerciseShortcuts() throws {
        let suite = "afc-shortcut-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EditorCommandRegistry(defaults: defaults)
        let remapped = ShortcutBinding(key: "k", command: true, shift: true)
        try check(registry.set(remapped, for: .splitClip) == nil, "Shortcut remapping")
        let reloaded = EditorCommandRegistry(defaults: defaults)
        try check(reloaded.binding(for: .splitClip) == remapped, "Shortcut persistence")
        let previous = reloaded.binding(for: .nextFrame)
        try check(reloaded.set(remapped, for: .nextFrame) != nil && reloaded.binding(for: .nextFrame) == previous,
                  "Shortcut conflicts preserve existing assignment")
        try check(reloaded.set(ShortcutBinding(key: "s", command: true), for: .splitClip) != nil,
                  "Shortcut editor reserves document Save")
        reloaded.reset()
        try check(EditorCommandRegistry(defaults: defaults).binding(for: .splitClip) == EditorCommandID.splitClip.defaultBinding,
                  "Shortcut defaults restore persistently")
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(ImportedMedia(asset: MediaAsset(name: "Shortcut fixture", duration: try RationalTime(5)), bookmark: nil))
        try check(reloaded.binding(for: .toggleViewer).keyEquivalent == .tab, "Tab key equivalent is a named special key")
        try check(reloaded.isEnabled(.toggleViewer, store: store, scope: .source), "Viewer switching is available across panel scopes")
        let original = store.project
        store.playheadSeconds = 1
        reloaded.perform(.toggleViewer, store: store, scope: .source)
        try check(store.showSequenceMonitor, "Tab switches from Source to Sequence")
        store.focusSourceViewer()
        try check(!store.showSequenceMonitor, "Media-bin interaction selects Source")
        store.focusSequenceViewer()
        try check(store.showSequenceMonitor, "Timeline interaction selects Sequence")
        reloaded.perform(.toggleViewer, store: store, scope: .timeline)
        try check(!store.showSequenceMonitor && store.project == original && store.playheadSeconds == 1,
                  "Viewer toggling preserves edits and sequence playhead")
        try check(!reloaded.isEnabled(.appendSource, store: store, scope: .timeline), "Source commands respect timeline focus")
        reloaded.perform(.appendSource, store: store, scope: .timeline)
        try check(store.project.tracks.isEmpty, "Command dispatch rejects mismatched panel scope")
        reloaded.perform(.appendSource, store: store, scope: .source)
        try check(store.project.tracks.flatMap(\.clips).count == 1, "Source command dispatch")
        store.selectTimelineClip(store.project.tracks[0].clips[0].id)
        try check(store.showSequenceMonitor && store.selectedClipID == store.project.tracks[0].clips[0].id,
                  "Timeline clip click/drag selects Sequence even with an existing clip selection")
        store.seek(to: 2)
        reloaded.perform(.splitClip, store: store, scope: .timeline)
        try check(store.project.tracks.flatMap(\.clips).count == 2, "Timeline command dispatch")
        try check(reloaded.isEnabled(.exportOTIO, store: store, scope: .source),
                  "OpenTimelineIO is available from any panel as a document command")
        store.beginEDLExport()
        try check(!reloaded.isEnabled(.exportOTIO, store: store, scope: .timeline),
                  "An active export sheet disables OpenTimelineIO commands")
    }

    @MainActor
    static func exerciseAudioAppend() throws {
        let store = EditorStore()
        defer { store.close() }
        let asset = MediaAsset(name: "Surround fixture", duration: try RationalTime(3), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 1, kind: .audio, audioLayout: .surround51)
        ])
        try store.registerImportedMedia(ImportedMedia(asset: asset, bookmark: nil))
        let baseline = store.project
        store.appendSelectedAsset()
        try check(store.project == baseline && store.audioAppendAsset?.id == asset.id,
                  "Unsupported default audio layout opens a draft without placing picture")
        let maps = [AudioSourceSelection(channels: [.init(streamIndex: 1, channelIndex: 0)], layout: .mono),
                    AudioSourceSelection(channels: [.init(streamIndex: 1, channelIndex: 1)], layout: .mono)]
        let routes = [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])]
        let preview = try store.previewAudioAppend(assetID: asset.id, selections: maps, routing: routes)
        try check(store.project == baseline && preview.tracks.flatMap(\.clips).count == 3,
                  "Initial audio placement preview is nonmutating")
        try store.applyAudioAppend(assetID: asset.id, selections: maps, routing: routes, expectedProject: baseline)
        let appended = store.project
        try check(appended.tracks.flatMap(\.clips).count == 3 &&
                  Set(appended.tracks.flatMap(\.clips).compactMap(\.linkGroupID)).count == 1,
                  "Explicit initial mono maps remain linked with picture")
        let reopened = try ProjectDocument(data: ProjectDocument(project: appended).encodedData())
        try check(reopened.project == appended, "Initial audio maps survive save/reopen")
        store.undo()
        try check(store.project == baseline, "One undo removes initial picture, audio, and tracks")
        store.redo()
        try check(store.project == appended, "Initial audio placement redo")
        do {
            try store.applyAudioAppend(assetID: asset.id, selections: maps, routing: routes, expectedProject: baseline)
            throw SmokeError.failed("Stale initial audio draft accepted")
        } catch EditorCoreError.invalidModel { }
        try check(store.project == appended, "Stale initial audio draft preserves document")
        try store.applyAudioAppend(assetID: asset.id, selections: [], routing: [], expectedProject: appended)
        try check(store.project.tracks.flatMap(\.clips).count == 4 && store.duration == 6,
                  "Explicit picture-only append omits audio")
    }

    @MainActor
    static func exerciseAudioSelection() throws {
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(ImportedMedia(asset: MediaAsset(name: "Audio selection fixture", duration: try RationalTime(4), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 1, kind: .audio, audioLayout: .stereo),
            MediaStream(index: 2, kind: .audio, audioLayout: .mono)
        ]), bookmark: nil))
        store.appendSelectedAsset()
        let baseline = store.project
        let audio = baseline.tracks.flatMap(\.clips).first { $0.requiredTrackKind == .audio }!
        let picture = baseline.tracks.flatMap(\.clips).first { $0.requiredTrackKind == .video }!
        store.selectedClipID = audio.id
        let maps = [AudioSourceSelection(channels: [.init(streamIndex: 1, channelIndex: 1)], layout: .mono),
                    AudioSourceSelection(channels: [.init(streamIndex: 2, channelIndex: 0)], layout: .mono)]
        let routes = [AudioRouting(outputChannels: [0]), AudioRouting(outputChannels: [1])]
        let preview = try store.previewAudioSelection(clipID: audio.id, selections: maps, routing: routes)
        try check(store.project == baseline && preview.tracks.flatMap(\.clips).count == 3,
                  "Audio source preview does not mutate the document")
        try store.applyAudioSelection(clipID: audio.id, selections: maps, routing: routes, expectedProject: baseline)
        let changed = store.project
        try check(changed.tracks.flatMap(\.clips).first { $0.id == picture.id } == picture,
                  "Audio source selection preserves linked picture")
        try check(changed.tracks.flatMap(\.clips).allSatisfy { $0.linkGroupID == picture.linkGroupID },
                  "Separate mono components retain linked timing")
        store.undo()
        try check(store.project == baseline, "One undo restores audio selection and all track changes")
        store.redo()
        try check(store.project == changed, "Audio source selection redo")
        let saved = try ProjectDocument(data: ProjectDocument(project: changed).encodedData())
        try check(saved.project == changed, "Audio maps and routes persist")
        do {
            try store.applyAudioSelection(clipID: audio.id, selections: maps, routing: routes, expectedProject: baseline)
            throw SmokeError.failed("Stale audio selection draft accepted")
        } catch EditorCoreError.invalidModel { }
        try check(store.project == changed, "Stale selection rejection preserves document")
        store.setAudioLayoutConfirmation(false)
        try check(!store.project.preferences.askBeforeAudioTrackLayoutChanges, "Audio confirmation preference")
        store.undo()
        try check(store.project == changed, "Audio confirmation preference undo")
        do {
            try store.applyAudioSelection(clipID: audio.id, selections: maps, routing: [.init(outputChannels: [99]), routes[1]], expectedProject: changed)
            throw SmokeError.failed("Invalid audio output route accepted")
        } catch TimelineEditError.incompatibleAudioRouting { }
        try check(store.project == changed && store.canRedo, "Rejected audio route preserves document and redo")

        let replacementIDs = try changed.audioConsolidationCandidates(for: audio.id).map(\.id)
        try check(replacementIDs.count == 1, "Linked mono component available for consolidation")
        let combinedMap = AudioSourceSelection(channels: [.init(streamIndex: 2, channelIndex: 0), .init(streamIndex: 1, channelIndex: 1)], layout: .stereo)
        let combinedRoute = AudioRouting(outputChannels: [1, 0])
        let combinedPreview = try store.previewAudioSelection(clipID: audio.id, selections: [combinedMap], routing: [combinedRoute], replacingClipIDs: replacementIDs)
        try check(store.project == changed && combinedPreview.tracks.flatMap(\.clips).count == 2, "Consolidation preview leaves document unchanged")
        do {
            try store.applyAudioSelection(clipID: audio.id, selections: [combinedMap], routing: [combinedRoute], replacingClipIDs: replacementIDs, expectedProject: baseline)
            throw SmokeError.failed("Stale consolidation accepted")
        } catch EditorCoreError.invalidModel { }
        do {
            try store.applyAudioSelection(clipID: audio.id, selections: maps, routing: routes, replacingClipIDs: replacementIDs, expectedProject: changed)
            throw SmokeError.failed("Consolidation into multiple components accepted")
        } catch TimelineEditError.incompatibleAudioConsolidation { }
        try check(store.project == changed && store.canRedo, "Rejected consolidation preserves redo and document")
        try store.applyAudioSelection(clipID: audio.id, selections: [combinedMap], routing: [combinedRoute], replacingClipIDs: replacementIDs, expectedProject: changed)
        let consolidated = store.project
        try check(consolidated == combinedPreview && store.selectedClipID == audio.id, "Consolidation matches preview and retains selection")
        try check(consolidated.tracks.flatMap(\.clips).first { $0.id == picture.id } == picture, "Consolidation preserves linked picture")
        try check(try ProjectDocument(data: ProjectDocument(project: consolidated).encodedData()).project == consolidated, "Consolidated maps and tracks persist")
        store.undo()
        try check(store.project == changed, "One undo restores separate audio components")
        store.redo()
        try check(store.project == consolidated, "Consolidation redo restores identical document")
    }

    @MainActor
    static func exerciseWorkspace() throws {
        let store = EditorStore()
        defer { store.close() }
        let asset = MediaAsset(name: "Linked fixture", duration: try RationalTime(4), streams: [
            MediaStream(index: 0, kind: .video),
            MediaStream(index: 1, kind: .audio, audioLayout: .stereo)
        ])
        try store.registerImportedMedia(ImportedMedia(asset: asset, bookmark: nil))
        store.appendSelectedAsset()
        let baseline = store.project
        let originalClips = baseline.tracks.flatMap(\.clips)
        try check(originalClips.count == 2 && originalClips[0].linkGroupID != nil &&
                  originalClips[0].linkGroupID == originalClips[1].linkGroupID, "Video/audio append creates linked components")
        store.trimSelectedClip(edge: .leading, delta: 1)
        let leadingTrim = store.project
        try check(leadingTrim.tracks.flatMap(\.clips).allSatisfy {
            $0.sourceRange.start.seconds == 1 && $0.timelineStart.seconds == 1 && $0.sourceRange.duration.seconds == 3
        }, "Leading drag trim preserves the out point of both linked components")
        store.undo()
        try check(store.project == baseline, "One undo restores the whole linked drag trim")
        store.redo()
        try check(store.project == leadingTrim, "Linked drag trim redo")
        store.trimSelectedClip(edge: .trailing, delta: -1)
        let trailingTrim = store.project
        try check(trailingTrim.tracks.flatMap(\.clips).allSatisfy {
            $0.sourceRange.start.seconds == 1 && $0.timelineStart.seconds == 1 && $0.sourceRange.duration.seconds == 2
        }, "Trailing drag trim preserves linked in points")
        store.undo()
        try check(store.project == leadingTrim && store.canRedo, "Trailing trim undo")
        store.trimSelectedClip(start: 1, duration: .infinity)
        try check(store.project == leadingTrim && store.canRedo && store.errorMessage != nil,
                  "Invalid inspector trim is atomic and preserves redo")
        store.errorMessage = nil
        store.trimSelectedClip(edge: .trailing, delta: .nan)
        try check(store.project == leadingTrim && store.canRedo, "Nonfinite drag trim creates no history entry")
        store.redo()
        try check(store.project == trailingTrim, "Redo survives rejected trims")
        let clip = store.selectedClip!
        store.playheadSeconds = 2
        store.snappingEnabled = true
        try check(store.proposedMove(clip: clip, to: 1.97, tolerance: 0.1) == 2, "Move snaps to the playhead")
        store.snappingEnabled = false
        try check(abs(store.proposedMove(clip: clip, to: 1.97, tolerance: 0.1) - 2) > 0.01,
                  "Disabling snapping keeps frame-grid placement without magnetic targets")
        let bounded = store.proposedTrimDelta(clip: clip, edge: .leading, delta: 100, tolerance: 0)
        store.trimSelectedClip(edge: .leading, delta: bounded)
        try check(store.project.tracks.flatMap(\.clips).allSatisfy {
            abs($0.sourceRange.duration.seconds - 1.0 / 24) < 0.000001
        }, "Oversized drag trim clamps to one video frame for the whole linked group")
        try store.project.validate()
        store.undo()
        try check(store.project == trailingTrim, "Bounded drag trim undo")
        store.seek(toTimecode: "00:00:00:02")
        try check(store.playheadTimecode == "00:00:00:02" && abs(store.playheadSeconds - 2.0 / 24) < 0.000001,
                  "24 fps seeking preserves the second frame despite decimal conversion")
        store.stepPlayhead(frames: 1)
        try check(store.playheadTimecode == "00:00:00:03", "24 fps frame step advances exactly one frame")

        store.updateSequence(try SequenceSettings(frameRate: FrameRate(30000, 1001)))
        let beforeTimecode = store.project
        let start = try Timecode(parsing: "01:00:00;00", rate: store.project.settings.frameRate)
        store.updateStartTimecode(start)
        let withTimecode = store.project
        store.undo()
        try check(store.project == beforeTimecode, "Start timecode undo")
        store.redo()
        try check(store.project == withTimecode, "Start timecode redo")
        store.seek(toTimecode: "01:00:00;02")
        try check(store.playheadTimecode == "01:00:00;02" && abs(store.playheadSeconds - 2 * 1001.0 / 30000) < 0.000001,
                  "29.97 fps seeking preserves the second frame")
        store.stepPlayhead(frames: 1)
        try check(store.playheadTimecode == "01:00:00;03", "29.97 fps frame step advances exactly one frame")
        store.seek(toTimecode: "01:00:01;00")
        try check(abs(store.playheadSeconds - 1.001) < 0.000001 && store.playheadTimecode == "01:00:01;00",
                  "Drop-frame seeking uses the sequence start offset")
        let validPosition = store.playheadSeconds
        store.seek(toTimecode: "01:01:00;00")
        try check(store.playheadSeconds == validPosition && store.errorMessage != nil, "Skipped drop-frame label does not move playhead")
        store.stepPlayhead(frames: 1)
        try check(abs(store.playheadSeconds - validPosition - 1001.0 / 30000) < 0.000001, "Fractional-rate frame stepping")
        let persisted = try ProjectDocument(data: ProjectDocument(project: store.project).encodedData())
        let reopened = EditorStore()
        defer { reopened.close() }
        reopened.load(persisted)
        try check(reopened.project == store.project && reopened.playheadTimecode == "01:00:00;00",
                  "Sequence frame rate and start timecode survive document reopen")
    }

    @MainActor
    static func exerciseSequenceMatching() throws {
        let store = EditorStore()
        defer { store.close() }
        let rate = try FrameRate(24000, 1001)
        let asset = MediaAsset(name: "Qualified picture", duration: try RationalTime(2), streams: [
            MediaStream(index: 0, kind: .video, videoFormat: try VideoSourceFormat(width: 1280, height: 720, frameRate: rate))
        ])
        let baseline = Project(settings: try SequenceSettings(), assets: [asset])
        store.load(ProjectDocument(project: baseline))
        store.selectAsset(asset.id)
        store.matchSequenceToSelectedSource(streamIndex: 0)
        let matched = store.project
        try check(matched.settings.width == 1280 && matched.settings.height == 720 && matched.settings.frameRate == rate,
                  "Source matching applies exact picture format")
        try check(matched.assets == baseline.assets && matched.settings.audioLayout == baseline.settings.audioLayout,
                  "Matching retains media and explicit audio settings")
        store.undo()
        try check(store.project == baseline, "Source matching undo is atomic")
        store.matchSequenceToSelectedSource(streamIndex: 99)
        try check(store.project == baseline && store.errorMessage != nil, "Unqualified matching is refused")
        store.redo()
        try check(store.project == matched, "Failed matching preserves redo")
        store.appendSelectedAsset()
        let populated = store.project
        store.matchSequenceToSelectedSource(streamIndex: 0)
        try check(store.project == populated && store.errorMessage != nil, "Existing timeline refuses source matching")
        store.undo()
        try check(store.project == matched, "Refused matching preserves append undo")
    }

    @MainActor
    static func exerciseSequenceSettings() throws {
        let store = EditorStore()
        defer { store.close() }
        let baseline = try DemoProjectFactory.musicCollision()
        store.load(ProjectDocument(project: baseline))
        let rate = try FrameRate(parsing: "24000/1001")
        let configured = try SequenceSettings(width: 1280, height: 720, frameRate: rate,
                                             audioSampleRate: 44100, audioLayout: .stereo,
                                             startTimecode: Timecode(parsing: "01:00:00:00", rate: rate))
        store.updateSequence(width: 1280, height: 720, frameRateText: "24000/1001",
                             audioSampleRate: 44100, audioLayout: .stereo, startTimecodeLabel: "01:00:00:00")
        let changed = store.project
        try check(changed.settings == configured && changed.tracks == baseline.tracks && changed.assets == baseline.assets,
                  "Complete sequence settings preserve original clips, routing and media")
        let plan = try TimelineRenderPlan(project: changed)
        try check(plan.settings == configured, "Render plan uses exact sequence picture/audio/timecode settings")
        let reopened = try ProjectDocument(data: ProjectDocument(project: changed).encodedData())
        try check(reopened.project == changed, "Exact output settings survive save/reopen")
        store.undo()
        try check(store.project == baseline, "All sequence settings undo atomically")
        store.redo()
        try check(store.project == changed, "All sequence settings redo atomically")

        var incompatible = configured
        incompatible.audioLayout = .mono
        store.updateSequence(incompatible)
        try check(store.project == changed && store.errorMessage != nil,
                  "Identity stereo track and family reject mono output without changing project")
        var invalid = configured
        invalid.audioSampleRate = 0
        store.updateSequence(invalid)
        try check(store.project == changed, "Invalid output settings reject the complete edit")
        store.updateSequence(configured)
        store.undo()
        try check(store.project == baseline, "Rejected and unchanged settings add no undo entries")
        store.updateSequence(incompatible)
        store.redo()
        try check(store.project == changed, "Rejected settings preserve redo history")

        store.updateSequence(width: 1280, height: 720, frameRateText: "29.97",
                             audioSampleRate: 44100, audioLayout: .stereo, startTimecodeLabel: "01:00:00;00")
        try check(store.project == changed, "Literal decimal rate cannot silently enable drop frame")
        store.updateSequence(width: 1280, height: 720, frameRateText: "NaN",
                             audioSampleRate: 44100, audioLayout: .stereo, startTimecodeLabel: "01:00:00:00")
        try check(store.project == changed, "Malformed frame-rate entry leaves output settings unchanged")
        var unwrapped = baseline
        unwrapped.settings.startTimecode = Timecode(frameCount: 24 * 86400 + 1)
        store.load(ProjectDocument(project: unwrapped))
        let displayed = try unwrapped.settings.startTimecode.formatted(rate: unwrapped.settings.frameRate)
        store.updateSequence(width: 1920, height: 1080, frameRateText: "24",
                             audioSampleRate: 44100, audioLayout: .stereo, startTimecodeLabel: displayed)
        try check(store.project.settings.startTimecode == unwrapped.settings.startTimecode,
                  "Unchanged displayed timecode retains unwrapped saved count on audio-only apply")
        store.undo()
        try check(store.project == unwrapped, "Unwrapped settings undo without changing start count")

        // Explicit routing to retained output indices permits output expansion.
        var mapped = baseline
        mapped.families[0].template.routing.outputChannels = [0, 1]
        mapped.tracks[0].template.routing.outputChannels = [0, 1]
        store.load(ProjectDocument(project: mapped))
        var surround = configured
        surround.audioLayout = .surround51
        store.updateSequence(surround)
        try check(store.project.settings == surround && store.project.tracks == mapped.tracks,
                  "Explicit stereo output maps survive expanding the sequence to 5.1")
        var missingOutput = surround
        missingOutput.audioLayout = .mono
        let routed = store.project
        store.updateSequence(missingOutput)
        try check(store.project == routed && store.errorMessage != nil,
                  "Output reconfiguration cannot discard an explicitly routed channel")
        var familyOnly = mapped
        familyOnly.tracks = []
        store.load(ProjectDocument(project: familyOnly))
        store.updateSequence(missingOutput)
        try check(store.project == familyOnly, "Retained family templates also protect their output routing")
    }

    @MainActor
    static func exerciseProxyDocument(directory: URL) throws {
        // Persistence fixtures only: media decoding is exercised by proxy-service-smoke.
        let original = directory.appendingPathComponent("proxy-document-original.mov")
        let derived = directory.appendingPathComponent("proxy-document-derived.mov")
        try Data("original grant fixture".utf8).write(to: original)
        try Data("proxy grant fixture".utf8).write(to: derived)
        let proxy = MediaProxy(url: derived, preset: .proResProxy,
                               sourceFingerprint: try ProxyGenerationService.fingerprint(for: original),
                               videoStreamIndex: 0, width: 80, height: 48,
                               frameRate: try RationalTime(24), frameCount: 48)
        let asset = MediaAsset(name: "Proxy persistence fixture", originalURL: original,
                               duration: try RationalTime(2), streams: [.init(index: 0, kind: .video)], proxy: proxy)
        let grantOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let originalGrant = try original.bookmarkData(options: grantOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        let proxyGrant = try derived.bookmarkData(options: grantOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        var document = ProjectDocument(project: Project(settings: try SequenceSettings(), assets: [asset]),
                                       mediaBookmarks: [asset.id: originalGrant], proxyBookmarks: [asset.id: proxyGrant, UUID(): Data([0])])
        var decoded = try ProjectDocument(data: document.encodedData())
        try check(decoded.project == document.project && decoded.proxyBookmarks == [asset.id: proxyGrant],
                  "Proxy references/grants survive save and unrelated grants are pruned")
        try check(try decoded.resolveProxyURL(for: asset.id)?.resolvingSymlinksInPath() == derived.resolvingSymlinksInPath(),
                  "Proxy grant resolves independently of the original")
        try check(try decoded.resolveMediaURL(for: asset.id)?.resolvingSymlinksInPath() == original.resolvingSymlinksInPath(),
                  "Proxy grant never redirects original media")
        try check(try decoded.resolveProxyURL(for: UUID()) == nil, "Unknown proxy grant resolution")
        document.project.assets[0].proxy = nil
        let removed = try ProjectDocument(data: document.encodedData())
        try check(removed.proxyBookmarks.isEmpty, "Removed proxies do not retain sandbox grants")
        var legacy = try JSONSerialization.jsonObject(with: removed.encodedData()) as! [String: Any]
        legacy.removeValue(forKey: "proxyBookmarks")
        let backward = try ProjectDocument(data: JSONSerialization.data(withJSONObject: legacy))
        try check(backward.proxyBookmarks.isEmpty && backward.project == removed.project,
                  "Existing version-one projects without proxy bookmarks still open")
        let reopened = EditorStore()
        defer { reopened.close() }
        reopened.load(decoded)
        try check(reopened.proxyBookmarks[asset.id] != nil && reopened.project.assets[0].proxy != nil,
                  "Editor reopen retains separate proxy access")
        let replacement = MediaAsset(name: asset.name, originalURL: original, duration: asset.duration, streams: asset.streams)
        try reopened.replaceMedia(assetID: asset.id, with: ImportedMedia(asset: replacement, bookmark: originalGrant))
        try check(reopened.project.assets[0].proxy == nil && reopened.proxyBookmarks.isEmpty,
                  "Explicit original relinking invalidates derived media even with matching file metadata")
        reopened.undo()
        try check(reopened.project.assets[0].proxy != nil && reopened.proxyBookmarks[asset.id] != nil,
                  "Undo relinking restores both proxy identity and grant")
        reopened.redo()
        try check(reopened.project.assets[0].proxy == nil && reopened.proxyBookmarks.isEmpty,
                  "Redo relinking removes the previous derived media")
    }

    @MainActor
    static func exerciseInterchangeDestinationProtection(directory: URL, asset: MediaAsset) throws {
        // Keep alias creation isolated: adding a hard link can mark the imported
        // original's macOS security bookmark stale during later reopen checks.
        let original = directory.appendingPathComponent("protected-source.wav")
        try FileManager.default.copyItem(at: asset.originalURL!, to: original)
        var isolatedAsset = asset
        isolatedAsset.originalURL = original
        let symlink = directory.appendingPathComponent("original-alias.edl")
        let hardlink = directory.appendingPathComponent("original-hardlink.edl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: hardlink)
        let before = try Data(contentsOf: original)
        for destination in [original, symlink, hardlink] {
            do {
                try EditorStore.validateInterchangeDestination(destination, originals: [isolatedAsset])
                throw SmokeError.failed("Interchange accepted an original media alias")
            } catch is EditorCoreError { }
        }
        try EditorStore.validateInterchangeDestination(directory.appendingPathComponent("new.edl"), originals: [isolatedAsset])
        try check(try Data(contentsOf: original) == before,
                  "Interchange preflight protects original bytes and allows an independent destination")
    }

    @MainActor
    static func exerciseWorkspaceResume(still: ImportedMedia) async throws {
        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(still)
        // Resolve grants once before recording the baseline, as document load does.
        store.resumeMediaAccess()
        await store.sourcePreviewTask?.value
        store.appendSelectedAsset()
        store.selectedClipID = store.project.tracks.flatMap(\.clips).first!.id
        store.playheadSeconds = 2
        let expected = store.project
        let selection = (store.selectedAssetID, store.selectedAssetIDs, store.selectedClipID)
        let history = (store.canUndo, store.canRedo)
        try check(store.previewImage != nil, "Workspace fixture has a source image before hiding")
        store.close()
        try check(store.previewImage == nil && store.sourcePlayer == nil, "Hidden workspace releases its source resources")
        store.resumeMediaAccess()
        await store.sourcePreviewTask?.value
        try check(store.project == expected && store.playheadSeconds == 2,
                  "Resuming preserves project and playhead")
        try check(store.selectedAssetID == selection.0 && store.selectedAssetIDs == selection.1 && store.selectedClipID == selection.2,
                  "Resuming preserves source and clip selection")
        try check(store.canUndo == history.0 && store.canRedo == history.1 && store.previewImage != nil,
                  "Resuming restores source preview without replacing editing history")
        store.undo()
        try check(store.project.tracks.flatMap(\.clips).isEmpty && store.canRedo,
                  "An edit made before hiding remains undoable after resume")
        store.redo()
        try check(store.project.tracks.flatMap(\.clips).count == 1,
                  "Resume preserves redo semantics for the original edit")
    }

    @MainActor
    static func exerciseStillPreview(directory: URL, still: ImportedMedia, audio: ImportedMedia) async throws {
        let largeURL = directory.appendingPathComponent("oriented-large.jpg")
        let context = CGContext(data: nil, width: 4096, height: 2048, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        let destination = CGImageDestinationCreateWithURL(largeURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try check(CGImageDestinationFinalize(destination), "Oriented JPEG fixture creation")
        let large = try await MediaImporter.inspect(url: largeURL)
        let image = try await MediaImporter.stillPreview(url: largeURL)
        try check(image.width == 1024 && image.height == 2048, "Still preview bounds pixels and applies EXIF orientation")
        let thumbnail = try await MediaImporter.stillPreview(url: largeURL, maximumDimension: 64)
        try check(thumbnail.width == 32 && thumbnail.height == 64, "Import validation uses a small oriented decode")
        let cancelled = Task { try await MediaImporter.stillPreview(url: largeURL) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw SmokeError.failed("Cancelled still preview completed")
        } catch is CancellationError { }

        let store = EditorStore()
        defer { store.close() }
        try store.registerImportedMedia(audio)
        try store.registerImportedMedia(large)
        // A source switch cancels pending picture work before it can publish.
        let stale = store.sourcePreviewTask
        store.selectAsset(audio.asset.id)
        await stale?.value
        try check(store.sourcePlayer != nil && store.previewImage == nil, "Obsolete still cannot replace selected audio source")
        try store.registerImportedMedia(still)
        await store.sourcePreviewTask?.value
        try check(store.previewImage != nil && store.sourcePlayer == nil, "Still source preview publishes asynchronously")
        store.selectAsset(large.asset.id)
        let closing = store.sourcePreviewTask
        store.close()
        await closing?.value
        try check(store.previewImage == nil && store.sourcePlayer == nil, "Closing rejects pending still decode and releases displayed pixels")
        store.load(ProjectDocument(project: Project(settings: try SequenceSettings(), assets: [large.asset])))
        store.selectAsset(large.asset.id)
        let deselected = store.sourcePreviewTask
        store.selectAssets([])
        await deselected?.value
        try check(store.previewImage == nil && store.selectedAsset == nil, "Deselection rejects pending still preview")
    }

    @MainActor
    static func exerciseDerivedProjectValues(asset: MediaAsset) throws {
        let store = EditorStore()
        defer { store.close() }
        store.project.assets = [asset]
        store.selectedAssetID = asset.id
        try check(store.duration == 0 && store.selectedAsset == asset, "Empty sequence derived values")
        var ids: [UUID] = []
        try store.change { ids = try $0.appendAsset(asset.id) }
        store.selectedClipID = ids[0]
        let originalClip = store.selectedClip!
        try check(store.duration == 5 && store.selectedClip?.assetID == asset.id, "Append invalidates derived values")
        store.project.assets[0].name = "Renamed source"
        store.project.tracks[0].clips[0].scalingMode = .fill
        try check(store.selectedAsset?.name == "Renamed source" && store.asset(id: asset.id)?.name == "Renamed source"
                  && store.selectedClip?.scalingMode == .fill, "Nested project mutations invalidate lookup caches")
        try store.change { $0.tracks[0].clips[0].timelineStart = try RationalTime(3) }
        try check(store.duration == 8, "Moved clip invalidates cached duration")
        store.undo()
        try check(store.duration == 5 && store.selectedClip?.timelineStart == originalClip.timelineStart, "Undo invalidates derived values")
        store.redo()
        try check(store.duration == 8, "Redo invalidates derived values")
        store.load(ProjectDocument())
        try check(store.duration == 0 && store.asset(id: asset.id) == nil && store.selectedClip == nil,
                  "Document replacement discards old derived values")
    }

    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeError.failed(message) }
        return value
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeError.failed(message) }
    }
    static func reject(_ data: Data, _ message: String) throws {
        do {
            _ = try ProjectDocument(data: data)
        } catch { return }
        throw SmokeError.failed(message)
    }
    static func createAudio(at url: URL, channels: AVAudioChannelCount = 2) throws {
        let format: AVAudioFormat
        if channels == 6 {
            format = AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                   channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!)
        } else {
            format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for channel in 0..<Int(channels) {
            for frame in 0..<96_000 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.1 }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
    static func createImage(at url: URL) throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture creation")
    }
}

@MainActor private final class CommandSequenceBackend: SequencePlaybackBackend {
    var position: Double = 0
    var isPlaying = false
    var display: ((CGImage, Int64) -> Void)?
    var failure: ((any Error) -> Void)?
    func play() async throws { try await Task.sleep(for: .milliseconds(100)); isPlaying = true }
    func pause() { isPlaying = false }
    func seek(toFrame frame: Int64) async throws { position = Double(frame) / 24 }
    func close() async { isPlaying = false }
}
