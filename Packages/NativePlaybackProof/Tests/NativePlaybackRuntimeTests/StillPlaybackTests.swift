import Foundation
import CoreGraphics
import ImageIO
import Testing
import EditorCore
@testable import NativePlaybackRuntime

struct StillPlaybackTests {
    @Test func straightAlphaPreservesBackgroundAndRoundsPartialCoverage() {
        var rgb = Data([10, 20, 30, 10, 20, 30, 10, 20, 30])
        NativeStillComposition.over(Data([200, 100, 50, 0, 200, 100, 50, 255, 200, 100, 50, 128]), onto: &rgb)
        #expect(rgb == Data([10, 20, 30, 200, 100, 50, 105, 60, 40]))
    }

    @Test func stillPaddingIsTransparentAndCroppingRetainsAlpha() throws {
        let image = Data(repeating: 128, count: 2 * 2 * 4)
        let padding = try NativeVideoGeometry(sourceWidth: 2, sourceHeight: 2, width: 4, height: 2, mode: .none)
        #expect(padding.compose(image, channels: 4) == Data([0, 0, 0, 0] + Array(repeating: 128, count: 8) + [0, 0, 0, 0]
            + [0, 0, 0, 0] + Array(repeating: 128, count: 8) + [0, 0, 0, 0]))
        let crop = try NativeVideoGeometry(sourceWidth: 2, sourceHeight: 2, width: 1, height: 1, mode: .none)
        #expect(crop.compose(image, channels: 4) == Data(repeating: 128, count: 4))
    }

    @Test func pngDecoderRetainsOneImageAndAlphaAcrossRepeatedReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.png")
        let bytes = Data([200, 100, 50, 0, 200, 100, 50, 255, 200, 100, 50, 128, 30, 40, 50, 255])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = try SourceDecoder(url: url, streamIndex: 0, isStill: true)
        let first = try source.still(width: 2, height: 2, scalingMode: .none)
        #expect(first == bytes)
        _ = try source.still(width: 4, height: 4, scalingMode: .fit)
        #expect(try source.still(width: 2, height: 2, scalingMode: .none) == first)
        #expect(throws: (any Error).self) { try SourceDecoder(url: url, streamIndex: 1, isStill: true) }
        let animated = directory.appendingPathComponent("multiple.png")
        let png = try Data(contentsOf: url)
        try (png + png).write(to: animated)
        #expect(throws: (any Error).self) { try SourceDecoder(url: animated, streamIndex: 0, isStill: true) }
        let jpeg = directory.appendingPathComponent("image.jpg")
        let jpegDestination = try #require(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(jpegDestination, image, nil)
        #expect(CGImageDestinationFinalize(jpegDestination))
        let jpegSource = try SourceDecoder(url: jpeg, streamIndex: 0, isStill: true)
        let jpegFirst = try jpegSource.still(width: 2, height: 2, scalingMode: .none)
        #expect(jpegFirst.count == 16)
        #expect(stride(from: 3, to: 16, by: 4).allSatisfy { jpegFirst[$0] == 255 })
        #expect(try jpegSource.still(width: 2, height: 2, scalingMode: .none) == jpegFirst)
        let multipleJPEG = directory.appendingPathComponent("multiple.jpg")
        let jpegData = try Data(contentsOf: jpeg)
        try (jpegData + jpegData).write(to: multipleJPEG)
        #expect(throws: (any Error).self) { try SourceDecoder(url: multipleJPEG, streamIndex: 0, isStill: true) }
        // Filename suffixes cannot admit GIF or APNG through the still gate.
        let spoofed = directory.appendingPathComponent("spoofed.png")
        for encoded in [
            "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAAEACgAAWn8w0AAAAA1JREFUeJxj+M/A8B8ABQAB/4mZPR0AAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAEACgAAwQzaBAAAABFmZEFUAAAAAnicY2Bg+P8fAAMCAf/1e6XXAAAAAElFTkSuQmCC"
        ] {
            try #require(Data(base64Encoded: encoded)).write(to: spoofed)
            #expect(throws: (any Error).self) { try SourceDecoder(url: spoofed, streamIndex: 0, isStill: true) }
        }
        // Motion extraction must not silently discard an image's alpha.
        #expect(throws: (any Error).self) { try SourceDecoder(url: url, streamIndex: 0) }
    }
}
