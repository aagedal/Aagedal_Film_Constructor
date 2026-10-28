import AVFoundation
import CoreImage

/// A layer's render transform over time: its fit into the canvas, then a scale about the
/// canvas centre and an offset in canvas fractions, interpolated between timeline points.
nonisolated struct LayerPlacement: Sendable {
    struct Point: Sendable { let time: Double, scale: Double, offsetX: Double, offsetY: Double }
    let base: CGAffineTransform
    let canvas: CGSize
    /// The track's natural size, which applies pixel aspect; `base` maps from it. Decoded
    /// frames arrive at their stored size (1440 wide for anamorphic 1080), so they are
    /// stretched to this first.
    let presentation: CGSize
    /// Sorted by time; empty means no placement beyond the fit.
    let points: [Point]

    func transform(at seconds: Double) -> CGAffineTransform { base.concatenating(placement(at: seconds)) }

    /// The scale about the canvas centre and the offset, after the fit.
    func placement(at seconds: Double) -> CGAffineTransform {
        guard let first = points.first, let last = points.last else { return .identity }
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
        return CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
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
        /// Blur standard deviation in canvas pixels before placement scaling.
        let blur: Double
        /// A chroma key as a premultiplied RGBA colour cube, applied to the source picture.
        let keyCube: (data: Data, size: Int)?
        /// Levels: input black and white points and gamma on each RGB channel.
        let levels: (black: Double, white: Double, gamma: Double)?
        /// A wipe uncovering the picture: start and length in seconds, from the left or right edge.
        let reveal: (start: Double, duration: Double, fromLeft: Bool)?
        /// Stabilisation at a sequence time: zoom and the shift in picture fractions (x right, y down).
        var stabilization: (@Sendable (Double) -> (zoom: Double, x: Double, y: Double))? = nil
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
            var source = CIImage(cvPixelBuffer: frame)
            let stored = source.extent.size, shown = layer.placement.presentation
            if stored.width > 0, stored.height > 0, shown.width > 0, shown.height > 0, stored != shown {
                source = source.transformed(by: CGAffineTransform(scaleX: shown.width / stored.width, y: shown.height / stored.height))
            }
            if let cube = layer.keyCube {
                source = source.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cube.size, "inputCubeData": cube.data])
            }
            let height = source.extent.height
            // CoreImage has a lower-left origin: flip into the layer transform's space and back.
            let flipCanvas = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: instruction.canvas.height)
            var picture = source.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
                .concatenating(layer.placement.base).concatenating(flipCanvas))
            if let stabilize = layer.stabilization {
                // In display orientation, on the fitted picture: shift against the jitter, zoom about
                // the centre and keep the picture's own bounds, as export crops a moving window of the
                // rotated, square-pixel picture and scales it back up.
                let s = stabilize(seconds), extent = picture.extent
                picture = picture.transformed(by: CGAffineTransform(translationX: s.x * extent.width, y: -s.y * extent.height)
                    .concatenating(CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                    .concatenating(CGAffineTransform(scaleX: s.zoom, y: s.zoom))
                    .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY)))
                    .cropped(to: extent)
            }
            if layer.blur > 0 {
                // As in export: blur the fitted, frame-sized layer (transparent around the picture,
                // edges held at the frame border), then place it.
                picture = picture.composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: layer.blur]).cropped(to: bounds)
            }
            picture = picture.transformed(by: flipCanvas.concatenating(layer.placement.placement(at: seconds)).concatenating(flipCanvas))
            if let reveal = layer.reveal {
                let shown = bounds.width * min(1, max(0, (seconds - reveal.start) / reveal.duration))
                picture = picture.cropped(to: CGRect(x: reveal.fromLeft ? 0 : bounds.width - shown, y: 0, width: shown, height: bounds.height))
            }
            if let levels = layer.levels {
                let scale = 1 / (levels.white - levels.black), bias = -levels.black * scale
                picture = picture.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
                    .applyingFilter("CIColorClamp")
                    .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / levels.gamma])
            }
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
