import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import NativePlaybackRuntime

struct DecoderRetentionTests {
    private func withImages(_ count: Int, operation: ([SourceKey], Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([200, 100, 50, 128, 30, 40, 50, 255, 10, 20, 30, 255, 100, 150, 200, 0])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("0.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let encoded = try Data(contentsOf: url)
        let keys = try (0..<count).map { index in
            let path = directory.appendingPathComponent("\(index).png")
            if index > 0 { try encoded.write(to: path) }
            return SourceKey(url: path, streamIndex: 0, isStill: true)
        }
        try operation(keys, bytes)
    }

    @Test func limitsAreValidated() throws {
        for limits in [NativeDecoderLimits(maximumActiveDecoders: 0),
                       NativeDecoderLimits(maximumActiveDecoders: 65),
                       NativeDecoderLimits(retainedSourceByteLimit: -1)] {
            #expect(throws: ProofFailure.self) { try SourceDecoderCache(limits: limits) }
        }
    }

    @Test func activeBoundEvictsLeastRecentlyUsedAndReopensExactly() throws {
        try withImages(3) { keys, bytes in
            let cache = try SourceDecoderCache(limits: NativeDecoderLimits(maximumActiveDecoders: 2))
            weak var first: SourceDecoder?
            weak var second: SourceDecoder?
            try cache.withDecoder(key: keys[0]) { first = $0 }
            try cache.withDecoder(key: keys[1]) { second = $0 }
            try cache.withDecoder(key: keys[0]) { #expect($0 === first) }
            try cache.withDecoder(key: keys[2]) {
                let decoded = try $0.still(width: 2, height: 2, scalingMode: .none)
                #expect(decoded == bytes)
            }
            #expect(cache.count == 2)
            #expect(first != nil)
            #expect(second == nil)
            try cache.withDecoder(key: keys[1]) {
                #expect(first == nil)
                let decoded = try $0.still(width: 2, height: 2, scalingMode: .none)
                #expect(decoded == bytes)
            }
            cache.reset()
            #expect(cache.count == 0)
            #expect(cache.retainedBytes == 0)
        }
    }

    @Test func byteBoundEvictsOversizedSourcesAfterSuccessAndFailure() throws {
        try withImages(1) { keys, bytes in
            let cache = try SourceDecoderCache(limits: NativeDecoderLimits(retainedSourceByteLimit: 1))
            weak var source: SourceDecoder?
            for _ in 0..<2 {
                try cache.withDecoder(key: keys[0]) {
                    source = $0
                    #expect($0.retainedBytes >= bytes.count)
                    let decoded = try $0.still(width: 2, height: 2, scalingMode: .none)
                    #expect(decoded == bytes)
                }
                #expect(cache.count == 0)
                #expect(cache.retainedBytes == 0)
                #expect(source == nil)
            }
            #expect(throws: ProofFailure.self) {
                try cache.withDecoder(key: keys[0]) { decoder in
                    source = decoder
                    _ = try decoder.still(width: 0, height: 2, scalingMode: .none)
                }
            }
            #expect(cache.count == 0)
            #expect(source == nil)
        }
    }

    @Test func byteBoundEvictsOldestUntilWithinBudget() throws {
        try withImages(3) { keys, _ in
            let measured = try SourceDecoder(url: keys[0].url, streamIndex: 0, isStill: true).retainedBytes
            let cache = try SourceDecoderCache(limits: NativeDecoderLimits(retainedSourceByteLimit: measured * 2))
            weak var first: SourceDecoder?
            try cache.withDecoder(key: keys[0]) { first = $0 }
            try cache.withDecoder(key: keys[1]) { _ in }
            #expect(cache.count == 2)
            try cache.withDecoder(key: keys[2]) { _ in }
            #expect(first == nil)
            #expect(cache.count == 2)
            #expect(cache.retainedBytes <= measured * 2)
        }
    }

    @Test func moreThan64DistinctSourcesRemainUsableWithBoundedRetention() throws {
        try withImages(65) { keys, bytes in
            let cache = try SourceDecoderCache(limits: NativeDecoderLimits(maximumActiveDecoders: 3))
            for key in keys + keys.reversed() {
                try cache.withDecoder(key: key) {
                    let decoded = try $0.still(width: 2, height: 2, scalingMode: .none)
                    #expect(decoded == bytes)
                }
                #expect(cache.count <= 3)
            }
        }
    }

    @Test func pcmEvictionReopensExactSampleRangesAndCountsConversionCapacity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampleCount = 40_000
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func sample(_ index: Int) -> Int16 { Int16(index % 2001 - 1000) }
        text("RIFF"); integer(UInt32(36 + sampleCount * 2)); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(48_000)); integer(UInt32(96_000)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(UInt32(sampleCount * 2))
        for index in 0..<sampleCount { integer(sample(index)) }
        let paths = [directory.appendingPathComponent("a.wav"), directory.appendingPathComponent("b.wav")]
        for url in paths { try wav.write(to: url) }
        let cache = try SourceDecoderCache(limits: NativeDecoderLimits(maximumActiveDecoders: 1))
        for start in [0, 20_000, 17, 39_000, 0] {
            for url in paths {
                try cache.withDecoder(key: SourceKey(url: url, streamIndex: 0, isStill: false)) { source in
                    let decoded = try source.audio(start: Int64(start), count: 1000, sampleRate: 48_000)
                    let expected = (start..<(start + 1000)).map { Float(sample($0)) / 32768 }
                    #expect(decoded == expected)
                    // Includes the float conversion allocation as well as PCM
                    // AVFrame storage, independent of the returned Swift array.
                    #expect(source.retainedBytes >= 1000 * MemoryLayout<Float>.stride)
                }
                #expect(cache.count == 1)
            }
        }
        let noRetention = try SourceDecoderCache(limits: NativeDecoderLimits(retainedSourceByteLimit: 0))
        try noRetention.withDecoder(key: SourceKey(url: paths[0], streamIndex: 0, isStill: false)) {
            _ = try $0.audio(start: 100, count: 1000, sampleRate: 48_000)
        }
        #expect(noRetention.count == 0)
        #expect(noRetention.retainedBytes == 0)
    }
}
