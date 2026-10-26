import AVFoundation
import AppKit
import EditorCore
import ImageIO
import UniformTypeIdentifiers

@main struct TitleSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "TitleSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "TitleSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value"]) }
        return value
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "\(executable) \(arguments.prefix(3)) failed")
        return data
    }
    /// Fraction of pixels in the band of rows that are near white.
    static func whiteShare(_ image: CGImage, rows: ClosedRange<Double>) -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            let context = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var white = 0, total = 0
        // Row 0 of the buffer is the top of the picture.
        for y in Int(rows.lowerBound * Double(height))..<Int(rows.upperBound * Double(height)) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 200 && bytes[i + 1] > 200 && bytes[i + 2] > 200 { white += 1 }
                total += 1
            }
        }
        return Double(white) / Double(max(1, total))
    }
    static func save(_ image: CGImage, _ url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
    }
    static func main() async throws {
        let movie = URL(fileURLWithPath: CommandLine.arguments[1])
        let ffmpeg = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let keep = CommandLine.arguments.count > 4 && !CommandLine.arguments[4].isEmpty ? URL(fileURLWithPath: CommandLine.arguments[4]) : nil
        let tracks = try await AVURLAsset(url: movie).load(.tracks)
        let vi = tracks.firstIndex { $0.mediaType == .video }!
        let asset = MediaAsset(name: "Movie", originalURL: movie, duration: try RationalTime(4), streams: [MediaStream(index: vi, kind: .video)])
        let family = TrackFamily(baseName: "Video", template: .init(kind: .video))
        var project = Project(settings: try SequenceSettings(width: 640, height: 360, frameRate: FrameRate(25)), assets: [asset], families: [family],
                              tracks: [TimelineTrack(familyID: family.id, template: family.template, clips: [
                                TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: RationalTime(4)), selection: .video(streamIndex: vi))])])
        let title = TitleDefinition(text: "Aagedal Film Constructor\nTitle smoke", fontSize: 0.08, position: .lowerThird, background: true)
        let assetID = UUID()
        let image = try TitleRenderer.render(title, width: 640, height: 360, assetID: assetID)
        defer { try? FileManager.default.removeItem(at: image) }
        let clipID = try project.addTitle(title, imageURL: image, at: RationalTime(1), assetID: assetID)
        var engine = try TimelineEditEngine(project: project)
        try engine.addTransition(clipID: clipID, near: RationalTime(1), duration: RationalTime(1, 2))
        project = engine.project

        let output = directory.appendingPathComponent("title.mov")
        _ = try run(ffmpeg, try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output).arguments)
        func exported(_ frame: Int) throws -> CGImage {
            let png = directory.appendingPathComponent("export-\(frame).png")
            _ = try run(ffmpeg, ["-hide_banner", "-i", output.path, "-vf", "select=eq(n\\,\(frame))", "-frames:v", "1", png.path])
            let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!
        }
        let backend = try AVFoundationSequenceBackend(project: project, videoProxies: [:])
        var shown: CGImage?
        backend.display = { image, _ in shown = image }
        func previewed(_ frame: Int) async throws -> CGImage {
            try await backend.seek(toFrame: Int64(frame)); return shown!
        }
        // Lower third occupies roughly rows 55%–80% from the top.
        let band = 0.55...0.8
        let before = try exported(10), during = try exported(60), preview = try await previewed(60), fading = try exported(31)
        print("white share export before \(whiteShare(before, rows: band)) during \(whiteShare(during, rows: band)) fading \(whiteShare(fading, rows: band)) preview \(whiteShare(preview, rows: band))")
        try require(whiteShare(before, rows: band) < 0.001, "No title before it starts")
        try require(whiteShare(during, rows: band) > 0.03, "The export shows the title text")
        try require(whiteShare(preview, rows: band) > 0.03, "The preview shows the title text")
        try require(whiteShare(fading, rows: band) < whiteShare(during, rows: band) / 2, "The title fades in")
        try require(abs(whiteShare(preview, rows: band) - whiteShare(during, rows: band)) < 0.02, "Preview and export agree")
        if let keep {
            try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            save(during, keep.appendingPathComponent("title-export.png"))
            save(preview, keep.appendingPathComponent("title-preview.png"))
        }
        await backend.close()
        print("PASS title export and preview")

        let serif = TitleDefinition(text: "Left aligned\nGeorgia title", fontSize: 0.09, position: .top, bold: false, fontFamily: "Georgia", alignment: .left)
        try require(TitleRenderer.font(serif, size: 40).familyName == "Georgia", "The chosen font family is used")
        var missing = serif; missing.fontFamily = "No Such Font Family"
        try require(TitleRenderer.font(missing, size: 40).familyName == NSFont.systemFont(ofSize: 40).familyName, "A missing font falls back to the system font")
        let drawn = try require(TitleRenderer.image(serif, width: 640, height: 360))
        // Left aligned text sits in the left half of the frame.
        func coverage(_ image: CGImage, columns: Range<Int>) -> Int {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { pointer in
                CGContext(data: pointer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return (0..<image.height).reduce(0) { sum, y in sum + columns.filter { bytes[(y * image.width + $0) * 4 + 3] > 128 }.count }
        }
        try require(coverage(drawn, columns: 0..<320) > 20 * coverage(drawn, columns: 480..<640), "Left alignment keeps text on the left")
        if let keep { save(drawn, keep.appendingPathComponent("title-georgia.png")) }
        print("PASS title fonts and alignment")
    }
}
