import AVFoundation
import Foundation
import EditorCore

/// Imports real files with the app importer, appends up to a few seconds of each,
/// builds the system sequence preview and renders through the app export service. Reports warnings and refusals per file.
@main struct RealMediaExportCheck {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let helpers = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let format = RenderOutputFormat(rawValue: arguments[3]) ?? .h264
        let seconds = Int64(arguments[4]) ?? 4
        let files = arguments.dropFirst(5).map { URL(fileURLWithPath: $0) }
        let service = SequenceExportService(ffmpegURL: helpers.appendingPathComponent("ffmpeg"),
                                            ffprobeURL: helpers.appendingPathComponent("ffprobe"))
        let rate = try FrameRate(25)
        var failures = 0
        for file in files {
            let label = file.lastPathComponent
            do {
                let imported: ImportedMedia
                do {
                    imported = try await MediaImporter.inspect(url: file)
                } catch {
                    // Mirrors MediaImporter.inspectOrConvert with explicit helpers.
                    let started = Date()
                    let converted = try await MediaConversionService(ffmpegURL: helpers.appendingPathComponent("ffmpeg"),
                        ffprobeURL: helpers.appendingPathComponent("ffprobe")).convert(file, into: output)
                    print("     converted in \(String(format: "%.1f", Date().timeIntervalSince(started))) s → \(converted.lastPathComponent)")
                    imported = try await MediaImporter.inspect(url: converted, displayName: label)
                }
                var project = Project(settings: try SequenceSettings(width: 1920, height: 1080, frameRate: rate))
                try project.addAsset(imported.asset)
                let frames = min(seconds * 25, try imported.asset.duration.multiplied(by: rate.value).numerator
                                 / imported.asset.duration.multiplied(by: rate.value).denominator)
                let range = try TimeRange(start: .zero, duration: RationalTime(frames).divided(by: rate.value))
                try project.appendAsset(imported.asset.id, sourceRange: range)
                let preview = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
                do {
                    let item = try await preview.makePlayerItem()
                    let tracks = try await item.asset.load(.tracks)
                    print("     preview: \(tracks.count) composition tracks\(preview.previewQualificationNotice.map { " · " + $0 } ?? "")")
                } catch {
                    failures += 1
                    print("     preview FAILED: \(error.localizedDescription)")
                }
                await preview.close()
                let plan = try TimelineRenderPlan(project: project)
                let destination = output.appendingPathComponent((label as NSString).deletingPathExtension + "." + format.fileExtension)
                let started = Date()
                let result = try await service.export(plan: plan, to: destination, options: .init(format: format))
                print("PASS \(label): \(result.videoFrames) frames in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                result.warnings.forEach { print("     warning: \($0)") }
            } catch {
                failures += 1
                print("FAIL \(label): \(error.localizedDescription)")
            }
        }
        if failures > 0 { exit(1) }
    }
}
