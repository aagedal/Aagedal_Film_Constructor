import AppKit
import EditorCore
import UniformTypeIdentifiers

struct SequenceExportDraft: Identifiable {
    let id = UUID()
    let plan: TimelineRenderPlan
    var sequenceName = "Sequence"
    /// The sequence In to Out when marked; the export window offers it or the whole sequence.
    var markedRange: TimeRange?
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
            renderExportDraft = SequenceExportDraft(plan: plan, sequenceName: project.sequenceName,
                                                    markedRange: sequenceMarkedRange(duration: plan.duration))
        } catch { errorMessage = error.localizedDescription }
    }

    func exportFCPXML() {
        guard renderExportDraft == nil, edlExportDraft == nil, audioAppendAsset == nil else { return }
        do {
            let snapshot = project
            let result = try FCPXMLExporter.export(project: snapshot)
            guard Self.confirmOmissions(result.report.warnings, format: "FCPXML") else { return }
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
            statusMessage = "Exported FCPXML: \(url.lastPathComponent)\(Self.omissionSuffix(result.report.warnings))."
        } catch { errorMessage = error.localizedDescription }
    }

    func exportOTIO() {
        guard renderExportDraft == nil, edlExportDraft == nil, audioAppendAsset == nil else { return }
        do {
            let snapshot = project
            let result = try OTIOExporter.export(project: snapshot)
            guard Self.confirmOmissions(result.warnings, format: "OpenTimelineIO") else { return }
            // Keep the snapshot's original media accessible through the save panel's
            // nested event loop, even if the document closes or relinks meanwhile.
            let scopedSources = Set(snapshot.assets.compactMap(\.originalURL)).filter {
                $0.startAccessingSecurityScopedResource()
            }
            defer { scopedSources.forEach { $0.stopAccessingSecurityScopedResource() } }
            let panel = NSSavePanel()
            panel.title = "Export OpenTimelineIO"
            panel.nameFieldStringValue = "Sequence.otio"
            panel.allowedContentTypes = [UTType(filenameExtension: "otio") ?? .json]
            panel.message = "Exports cuts, dissolves, speed changes and gaps with original media references. Media files are not copied. Spatial conform and receiving-editor import are unqualified."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Self.validateInterchangeDestination(url, originals: snapshot.assets + project.assets)
            try Data(result.json.utf8).write(to: url, options: .atomic)
            statusMessage = "Exported OpenTimelineIO: \(url.lastPathComponent)\(Self.omissionSuffix(result.warnings))."
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
        guard Self.confirmOmissions(result.report.warnings, format: "CMX3600 EDL") else { return false }
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
        statusMessage = "Exported track EDL: \(url.lastPathComponent)\(Self.omissionSuffix(result.report.warnings))."
        return true
    }

    /// Lists the edits an interchange file leaves out and asks whether to export the rest.
    static func confirmOmissions(_ warnings: [String], format: String) -> Bool {
        guard !warnings.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some edits can't be exported to \(format)"
        alert.informativeText = "The rest of the sequence can be exported without them.\n\n" + warnings.map { "• " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func omissionSuffix(_ warnings: [String]) -> String {
        warnings.isEmpty ? "" : ", without \(warnings.count == 1 ? "1 unsupported edit type" : "\(warnings.count) unsupported edit types")"
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
