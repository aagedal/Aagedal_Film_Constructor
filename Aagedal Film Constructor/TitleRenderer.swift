import AppKit
import EditorCore
import ImageIO
import UniformTypeIdentifiers

/// Draws a title into a transparent PNG at the sequence raster. Each render writes a new
/// file, so undo can return to an earlier image and previews never read a stale cache.
enum TitleRenderer {
    static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Titles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func render(_ title: TitleDefinition, width: Int, height: Int, assetID: UUID) throws -> URL {
        try title.validate()
        let url = try directory().appendingPathComponent("\(assetID.uuidString)-\(UUID().uuidString).png")
        guard let image = image(title, width: width, height: height),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EditorCoreError.invalidModel("Could not draw the title")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EditorCoreError.invalidModel("Could not save the title image") }
        return url
    }

    static func image(_ title: TitleDefinition, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, let rgba = title.rgba,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGSize(width: width, height: height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(title.background ? 0 : 0.6)
        shadow.shadowBlurRadius = canvas.height * 0.006
        shadow.shadowOffset = NSSize(width: 0, height: -canvas.height * 0.002)
        let text = NSAttributedString(string: title.text, attributes: [
            .font: NSFont.systemFont(ofSize: canvas.height * title.fontSize, weight: title.bold ? .bold : .regular),
            .foregroundColor: NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha),
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
        let available = CGSize(width: canvas.width * 0.9, height: canvas.height * 0.9)
        let measured = text.boundingRect(with: available, options: [.usesLineFragmentOrigin, .usesFontLeading]).integral
        let textHeight = min(measured.height, available.height)
        // Origin is the lower left; positions keep text inside the 90% title-safe area.
        let y: CGFloat
        switch title.position {
        case .top: y = canvas.height * 0.92 - textHeight
        case .center: y = (canvas.height - textHeight) / 2
        case .lowerThird: y = canvas.height * 0.2
        case .bottom: y = canvas.height * 0.08
        }
        let frame = CGRect(x: canvas.width * 0.05, y: max(canvas.height * 0.05, y), width: available.width, height: textHeight)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        if title.background {
            let padding = canvas.height * title.fontSize * 0.35
            let textWidth = min(measured.width, available.width)
            let band = CGRect(x: (canvas.width - textWidth) / 2 - padding, y: frame.minY - padding,
                              width: textWidth + padding * 2, height: textHeight + padding * 2)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fill(band)
        }
        text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        return context.makeImage()
    }
}
