import AVFoundation
import CoreImage

/// A layer's render transform over time: its fit into the canvas, then a scale about the
/// canvas centre and an offset in canvas fractions, interpolated between timeline points.
nonisolated struct LayerPlacement: Sendable {
    struct Point: Sendable { let time: Double, scale: Double, offsetX: Double, offsetY: Double }
    let base: CGAffineTransform
    let canvas: CGSize
    /// Sorted by time; empty means no placement beyond the fit.
    let points: [Point]

    func transform(at seconds: Double) -> CGAffineTransform {
        guard let first = points.first, let last = points.last else { return base }
        let p: Point
        if seconds <= first.time { p = first }
        else if seconds >= last.time { p = last }
        else {
            let next = points.firstIndex { $0.time > seconds }!
            let a = points[next - 1], b = points[next]
            let f = (seconds - a.time) / (b.time - a.time)
            p = Point(time: seconds, scale: a.scale + (b.scale - a.scale) * f, offsetX: a.offsetX + (b.offsetX - a.offsetX) * f,
                      offsetY: a.offsetY + (b.offsetY - a.offsetY) * f)
        }
        return base.concatenating(CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2))
            .concatenating(CGAffineTransform(scaleX: p.scale, y: p.scale))
            .concatenating(CGAffineTransform(translationX: canvas.width * (0.5 + p.offsetX), y: canvas.height * (0.5 + p.offsetY)))
    }
}

/// One preview segment for the CoreImage compositor: layers front to back, each with its
/// composition track, render transform (top-left origin, as for layer instructions),
/// opacity over time and colour correction.
final class CoreImageInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Layer {
        let trackID: CMPersistentTrackID
        let placement: LayerPlacement
        let opacity: @Sendable (Double) -> Double
        /// Colour correction as plain values, read on the compositor's own queue.
        let brightness: Double, contrast: Double, saturation: Double
        var isNeutral: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
    }
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer]
    let canvas: CGSize

    init(timeRange: CMTimeRange, layers: [Layer], canvas: CGSize) {
        self.timeRange = timeRange; self.layers = layers; self.canvas = canvas
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

/// Used only for sequences with colour correction, which the system compositor can't
/// apply per layer. Filters run on encoded values without colour management, matching
/// the export's arithmetic on the encoded picture.
final class CoreImageCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CoreImageInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "SequencePreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not compose the preview frame."]))
            return
        }
        let bounds = CGRect(origin: .zero, size: instruction.canvas)
        let seconds = request.compositionTime.seconds
        var image = CIImage(color: .black).cropped(to: bounds)
        for layer in instruction.layers.reversed() {
            guard let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            let source = CIImage(cvPixelBuffer: frame)
            let height = source.extent.height
            // CoreImage has a lower-left origin: flip into the layer transform's space and back.
            let placement = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
                .concatenating(layer.placement.transform(at: seconds))
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: instruction.canvas.height))
            var picture = source.transformed(by: placement)
            if !layer.isNeutral {
                picture = picture.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: layer.brightness, kCIInputContrastKey: layer.contrast,
                    kCIInputSaturationKey: layer.saturation])
            }
            let opacity = layer.opacity(seconds)
            if opacity < 1 {
                picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            }
            image = picture.cropped(to: bounds).composited(over: image)
        }
        context.render(image, to: output, bounds: bounds, colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }
}
