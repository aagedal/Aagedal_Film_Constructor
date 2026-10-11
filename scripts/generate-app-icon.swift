// Run from the repository root: swift scripts/generate-app-icon.swift
import AppKit
import Foundation

let destination = URL(fileURLWithPath: "Aagedal Film Constructor/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
var entries: [[String: String]] = []
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.29, alpha: 1),
                   ending: NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.12, alpha: 1))!.draw(in: tile, angle: -90)
        // Film frame and perforations, with three staggered assembly tracks.
        NSColor(calibratedRed: 0.87, green: 0.94, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 220, y: 236, width: 584, height: 552), xRadius: 44, yRadius: 44).fill()
        NSColor(calibratedRed: 0.055, green: 0.12, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 290, y: 304, width: 444, height: 416), xRadius: 16, yRadius: 16).fill()
        for x in [240, 754] {
            for y in stride(from: 290, through: 710, by: 84) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 30, height: 42), xRadius: 7, yRadius: 7).fill()
            }
        }
        for (index, rect) in [NSRect(x: 326, y: 580, width: 282, height: 72),
                              NSRect(x: 420, y: 476, width: 278, height: 72),
                              NSRect(x: 326, y: 372, width: 226, height: 72)].enumerated() {
            (index == 1 ? NSColor(calibratedRed: 1, green: 0.68, blue: 0.28, alpha: 1)
                        : NSColor(calibratedRed: 0.25, green: 0.8, blue: 0.76, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon-\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let manifest: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
