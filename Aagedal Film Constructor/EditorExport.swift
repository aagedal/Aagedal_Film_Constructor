import AppKit
import EditorCore
import UniformTypeIdentifiers

struct SequenceExportDraft: Identifiable {
    let id = UUID()
    let plan: TimelineRenderPlan
}

struct EDLExportDraft: Identifiable {
    let id = UUID()
    let project: Project
    let initialTrackID: UUID
}

extension EditorStore {
    func beginRenderExport() {
        guard renderExportDraft == nil, edlExportDraft == nil, audioAppendAsset == nil else { return }
        do {
            let plan = try TimelineRenderPlan(project: project)
            // Validate the snapshot before offering a destination. No file is created.
            let validationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            _ = try FFmpegRenderCompiler.compile(plan, outputURL: validationURL)
            renderExportDraft = SequenceExportDraft(plan: plan)
        } catch { errorMessage = error.localizedDescription }
    }

    func exportFCPXML() {
        guard renderExportDraft == nil, edlExportDraft == nil, audioAppendAsset == nil else { return }
        do {
            let snapshot = project
            let result = try FCPXMLExporter.export(project: snapshot)
            // A save panel runs a nested event loop: the document can close or relink
            // while it is open. Retain access to the exact originals in the XML snapshot.
            let scopedSources = Set(snapshot.assets.compactMap(\.originalURL)).filter {
                $0.startAccessingSecurityScopedResource()
            }
            defer { scopedSources.forEach { $0.stopAccessingSecurityScopedResource() } }
            let panel = NSSavePanel()
            panel.title = "Export FCPXML"
            panel.nameFieldStringValue = "Sequence.fcpxml"
            panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
            panel.message = result.report.notes.joined(separator: "\n\n")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // Never replace any original, including through a symlink or hard link.
            try Self.validateInterchangeDestination(url, originals: snapshot.assets + project.assets)
            try Data(result.xml.utf8).write(to: url, options: .atomic)
            statusMessage = "Exported FCPXML: \(url.lastPathComponent)."
        } catch { errorMessage = error.localizedDescription }
    }

    func beginEDLExport() {
        guard renderExportDraft == nil, edlExportDraft == nil, audioAppendAsset == nil else { return }
        let tracks = project.tracks.filter { !$0.clips.isEmpty }
        guard let track = tracks.first(where: { $0.clips.contains { $0.id == selectedClipID } }) ?? tracks.first else { return }
        edlExportDraft = EDLExportDraft(project: project, initialTrackID: track.id)
    }

    /// Validate before opening the save panel; retain the snapshot for alias protection
    /// even if a document edit or relink occurs in its nested event loop.
    func saveEDL(_ result: CMX3600ExportResult, snapshot: Project) throws -> Bool {
        let scopedSources = Set(snapshot.assets.compactMap(\.originalURL)).filter {
            $0.startAccessingSecurityScopedResource()
        }
        defer { scopedSources.forEach { $0.stopAccessingSecurityScopedResource() } }
        let panel = NSSavePanel()
        panel.title = "Export Track EDL"
        panel.nameFieldStringValue = "Sequence.edl"
        panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .plainText]
        panel.message = result.report.notes.joined(separator: "\n\n")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Self.validateInterchangeDestination(url, originals: snapshot.assets + project.assets)
        try Data(result.edl.utf8).write(to: url, options: .atomic)
        statusMessage = "Exported track EDL: \(url.lastPathComponent)."
        return true
    }

    static func validateInterchangeDestination(_ url: URL, originals: [MediaAsset]) throws {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let number = attrs?[.systemFileNumber] as? NSNumber
        let device = attrs?[.systemNumber] as? NSNumber
        for asset in originals {
            guard let source = asset.originalURL else { continue }
            let original = source.standardizedFileURL.resolvingSymlinksInPath()
            let originalAttrs = try? FileManager.default.attributesOfItem(atPath: original.path)
            guard original != target,
                  number == nil || device == nil ||
                    originalAttrs?[.systemFileNumber] as? NSNumber != number ||
                    originalAttrs?[.systemNumber] as? NSNumber != device else {
                throw EditorCoreError.invalidModel("Export destination aliases original media. Choose another file.")
            }
        }
    }
}
