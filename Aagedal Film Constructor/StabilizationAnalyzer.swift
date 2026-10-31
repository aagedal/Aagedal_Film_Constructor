import AVFoundation
import CoreImage
import EditorCore
import Vision

/// Measures camera motion for analysis-based stabilisation: each frame is registered against
/// the previous one with Vision on a small copy, and the translations accumulate into the
/// content's path in display-oriented frame fractions. Nothing is rendered; preview and
/// export shift the picture live from this path.
nonisolated enum StabilizationAnalyzer {
    /// Longest side of the frames Vision compares.
    static let analysisSize: CGFloat = 480

    /// `start` and `duration` are source seconds of the stream at `streamIndex`.
    @concurrent static func analyze(url: URL, streamIndex: Int, start: Double, duration: Double,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> MotionAnalysis {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        // Media imported unconverted through FFmpeg may be unreadable by AVFoundation.
        guard try await asset.load(.isReadable) else {
            throw EditorCoreError.invalidModel("Analysis cannot read this format. Render a deshaken copy instead.")
        }
        let tracks = try await asset.load(.tracks)
        guard tracks.indices.contains(streamIndex), tracks[streamIndex].mediaType == .video else {
            throw EditorCoreError.invalidModel("The clip's picture stream is unavailable for analysis")
        }
        let track = tracks[streamIndex]
        let (naturalSize, orientation) = try await track.load(.naturalSize, .preferredTransform)
        let display = CGRect(origin: .zero, size: naturalSize).applying(orientation).size
        guard display.width > 0, display.height > 0 else { throw EditorCoreError.invalidModel("Invalid picture size") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditorCoreError.invalidModel("The picture cannot be read for analysis") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditorCoreError.invalidModel("The picture cannot be read for analysis") }
        defer { reader.cancelReading() }

        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let handler = VNSequenceRequestHandler()
        var times: [Double] = [], xs: [Double] = [], ys: [Double] = []
        var previous: CIImage?
        var position = CGPoint.zero
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, times.last.map({ time > $0 }) ?? true else { continue }
            let full = CIImage(cvPixelBuffer: buffer)
            let scale = analysisSize / max(full.extent.width, full.extent.height)
            // Render the small greyscale copy once so Vision does not rescale the full frame twice.
            let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).applyingFilter("CIPhotoEffectMono")
            guard let rendered = context.createCGImage(small, from: small.extent) else { continue }
            let current = CIImage(cgImage: rendered)
            if let previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: current)
                // Vision reports how to move this frame onto the previous one: the content moved
                // by the opposite, here in CoreImage's y-up space.
                if (try? handler.perform([request], on: previous)) != nil,
                   let alignment = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
                    // Stored-picture fractions, y down, then pixels of the natural size.
                    let fx = -alignment.tx / current.extent.width, fy = alignment.ty / current.extent.height
                    let v = CGPoint(x: fx * naturalSize.width, y: fy * naturalSize.height)
                    // Into display orientation (rotation only; translation does not apply to vectors).
                    let rotated = CGPoint(x: orientation.a * v.x + orientation.c * v.y, y: orientation.b * v.x + orientation.d * v.y)
                    // Discard implausible jumps (cuts, flashes) rather than shift the whole path.
                    if abs(rotated.x) < display.width / 4, abs(rotated.y) < display.height / 4 {
                        position.x += rotated.x / display.width
                        position.y += rotated.y / display.height
                    }
                }
            }
            previous = current
            times.append(time); xs.append(position.x); ys.append(position.y)
            progress(min(1, max(0, (time - start) / max(duration, 0.001))))
        }
        if reader.status == .failed { throw reader.error ?? EditorCoreError.invalidModel("Analysis failed") }
        let analysis = MotionAnalysis(times: times, x: xs, y: ys)
        try analysis.validate()
        return analysis
    }
}
