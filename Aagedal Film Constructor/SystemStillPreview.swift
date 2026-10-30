import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Creates a short movie preserving image alpha whose complete time range can be stretched to a still clip.
/// Ownership of a successful result passes to the caller, which must remove it after playback.
/// Any image ImageIO decodes is accepted (HEIC, TIFF, PSD, GIF, RAW, …); multi-image files use the first.
nonisolated enum SystemStillPreview: Sendable {
    /// A prepared movie and the original pixels per movie pixel: larger than 1 when an image
    /// above the preview limit was reduced, so unscaled placement keeps the original size.
    struct Prepared: Sendable {
        let url: URL
        let pixelScale: CGFloat
    }
    /// Longest edge of the preview movie; larger images are reduced to it.
    static let maximumDimension = 4_096

    nonisolated enum PreparationError: LocalizedError {
        case unsupportedImage, imageTooLarge, invalidImage, cannotEncode, timedOut

        var errorDescription: String? {
            switch self {
            case .unsupportedImage: "This image format cannot be decoded for preview."
            case .imageTooLarge: "This image is too large to decode for preview."
            case .invalidImage: "The still image could not be decoded."
            case .cannotEncode: "The system could not encode the still preview."
            case .timedOut: "The system still preview encoder timed out."
            }
        }
    }

    static func prepare(url: URL, directory: URL) async throws -> Prepared {
        let worker = Task.detached(priority: .userInitiated) {
            try await encode(url: url, directory: directory)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: result.url)
                throw CancellationError()
            }
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private static func encode(url: URL, directory: URL) async throws -> Prepared {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1 else {
            throw PreparationError.unsupportedImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PreparationError.invalidImage }
        guard width <= 65_536, height <= 65_536 else { throw PreparationError.imageTooLarge }
        // Thumbnail transformation applies all eight EXIF orientations; only images above
        // the preview limit are reduced.
        let longest = max(width, height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, maximumDimension),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PreparationError.invalidImage }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: image.width,
            AVVideoHeightKey: image.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: image.width,
            kCVPixelBufferHeightKey as String: image.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw PreparationError.cannotEncode }
        writer.add(input)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw PreparationError.cannotEncode }
        CVBufferSetAttachments(buffer, [
            kCVImageBufferCGColorSpaceKey: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ] as CFDictionary, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let rendered = autoreleasepool {
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
                                          height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.clear(rect)
            context.draw(image, in: rect)
            return true
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard rendered else { throw PreparationError.cannotEncode }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !input.isReadyForMoreMediaData {
            guard ContinuousClock.now < deadline else { throw PreparationError.timedOut }
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? PreparationError.cannotEncode }
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
        guard adaptor.append(buffer, withPresentationTime: .zero) else {
            throw writer.error ?? PreparationError.cannotEncode
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 24))
        input.markAsFinished()
        // Polling keeps cancellation owned by this worker; AVAssetWriter is not Sendable.
        writer.finishWriting {}
        while writer.status == .writing {
            guard ContinuousClock.now < deadline else { throw PreparationError.timedOut }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? PreparationError.cannotEncode }
        completed = true
        return Prepared(url: output, pixelScale: CGFloat(longest) / CGFloat(max(image.width, image.height)))
    }
}
