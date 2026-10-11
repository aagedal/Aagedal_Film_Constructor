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
        let still = try await MediaImporter.inspect(url: imageURL)
        try check(still.asset.streams.isEmpty && still.asset.duration.seconds == 5, "Still image import")
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

        var document = ProjectDocument(project: store.project, mediaBookmarks: store.mediaBookmarks)
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
        try exerciseShortcuts()
        print("App file smoke passed: WAV/PNG import, bookmarks, relink safety, linked trims/snapping/undo/redo, timecode, audio channel maps/routing/consolidation/stale drafts, shortcut persistence/scoped dispatch, project save/reopen, corrupt and unsupported file rejection.")
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
        try check(!reloaded.isEnabled(.appendSource, store: store, scope: .timeline), "Source commands respect timeline focus")
        reloaded.perform(.appendSource, store: store, scope: .timeline)
        try check(store.project.tracks.isEmpty, "Command dispatch rejects mismatched panel scope")
        reloaded.perform(.appendSource, store: store, scope: .source)
        try check(store.project.tracks.flatMap(\.clips).count == 1, "Source command dispatch")
        store.seek(to: 2)
        reloaded.perform(.splitClip, store: store, scope: .timeline)
        try check(store.project.tracks.flatMap(\.clips).count == 2, "Timeline command dispatch")
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

        store.updateSequence(width: 1920, height: 1080, frameRate: 29.97)
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

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeError.failed(message) }
    }
    static func reject(_ data: Data, _ message: String) throws {
        do {
            _ = try ProjectDocument(data: data)
        } catch { return }
        throw SmokeError.failed(message)
    }
    static func createAudio(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for channel in 0..<2 {
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
