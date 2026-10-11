import AppKit
import EditorCore
import UniformTypeIdentifiers

struct SequenceExportDraft: Identifiable {
    let id = UUID()
    let plan: TimelineRenderPlan
}

extension EditorStore {
    func beginRenderExport() {
        guard renderExportDraft == nil, audioAppendAsset == nil else { return }
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
        guard renderExportDraft == nil, audioAppendAsset == nil else { return }
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
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            let targetNumber = try? FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
            let targetDevice = try? FileManager.default.attributesOfItem(atPath: target.path)[.systemNumber] as? NSNumber
            for asset in snapshot.assets + project.assets {
                guard let source = asset.originalURL else { continue }
                let original = source.standardizedFileURL.resolvingSymlinksInPath()
                let attrs = try? FileManager.default.attributesOfItem(atPath: original.path)
                guard original != target,
                      targetNumber == nil || targetDevice == nil ||
                        attrs?[.systemFileNumber] as? NSNumber != targetNumber ||
                        attrs?[.systemNumber] as? NSNumber != targetDevice else {
                    throw EditorCoreError.invalidModel("Export destination aliases original media. Choose another file.")
                }
            }
            try Data(result.xml.utf8).write(to: url, options: .atomic)
            statusMessage = "Exported FCPXML: \(url.lastPathComponent)."
        } catch { errorMessage = error.localizedDescription }
    }
}
