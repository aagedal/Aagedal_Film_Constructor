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
        print("App file smoke passed: WAV/PNG import, bookmarks, append/split/undo/redo, project save/reopen, corrupt and unsupported file rejection.")
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
