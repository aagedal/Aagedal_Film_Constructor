import AVFoundation
import AppKit
import Combine
import CoreImage
import EditorCore
import SwiftUI

/// Samples the frame in the active viewer several times a second and draws the selected
/// scopes from a small float copy of it. The source viewer reads decoded frames, so HDR
/// sources keep their full range; the sequence viewer reads its SDR Rec. 709 preview.
@MainActor
final class ScopeAnalyzer: ObservableObject {
    @Published private(set) var images: [VideoScope.Kind: CGImage] = [:]
    @Published private(set) var detail = ""
    private var timer: Timer?
    private var busy = false
    private var lastImage: NSImage?
    private var lastSettings = ""
    private var output: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    private var lastSourceTime = CMTime.invalid

    func start(store: EditorStore, sequence: SequencePlaybackController, kinds: @escaping () -> [VideoScope.Kind], scale: @escaping () -> VideoScope.Scale) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8, repeats: true) { [weak self, weak store, weak sequence] _ in
            MainActor.assumeIsolated {
                guard let self, let store, let sequence else { return }
                self.tick(store: store, sequence: sequence, kinds: kinds(), scale: scale())
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let output, let item = outputItem { item.remove(output) }
        output = nil; outputItem = nil
    }

    private func tick(store: EditorStore, sequence: SequencePlaybackController, kinds: [VideoScope.Kind], scale: VideoScope.Scale) {
        guard !busy else { return }
        let settings = kinds.map(\.rawValue).joined() + scale.rawValue + (store.showSequenceMonitor ? "seq" : "src")
        let changed = settings != lastSettings
        var frame: CIImage?
        var hdrSource = false
        if store.showSequenceMonitor {
            guard let image = sequence.image, changed || image !== lastImage,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            lastImage = image
            frame = CIImage(cgImage: cg)
        } else if case .avFoundation(let player) = store.sourcePlayback?.surface, let item = player.currentItem {
            if outputItem !== item {
                if let output, let old = outputItem { old.remove(output) }
                // Half-float frames keep values above SDR white for HDR sources.
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
                item.add(output)
                self.output = output; outputItem = item; lastSourceTime = .invalid
            }
            let time = item.currentTime()
            guard let output, changed || time != lastSourceTime || output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
            lastSourceTime = time
            let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
            hdrSource = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            frame = CIImage(cvPixelBuffer: buffer)
        }
        guard let frame else { return }
        lastSettings = settings
        busy = true
        let source = store.showSequenceMonitor ? "Sequence (SDR Rec. 709)" : hdrSource ? "Source (HDR)" : "Source"
        Task {
            let result = await Self.analyze(frame, kinds: kinds, scale: scale)
            self.busy = false
            self.images = result.images
            self.detail = source + (scale == .hdr ? String(format: " · peak %.0f nits", result.peakNits) : "")
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Renders a copy at most 384 pixels wide into float RGBA: encoded Rec. 709 for SDR,
    /// extended linear Rec. 2020 (1.0 = 100 nits) for HDR.
    @concurrent private static func analyze(_ frame: CIImage, kinds: [VideoScope.Kind], scale: VideoScope.Scale) async -> (images: [VideoScope.Kind: CGImage], peakNits: Double) {
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return ([:], 0) }
        let factor = min(1, 384 / extent.width)
        let width = max(1, Int(extent.width * factor)), height = max(1, Int(extent.height * factor))
        let small = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).scaledBy(x: factor, y: factor))
        let space = scale == .hdr ? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)! : CGColorSpace(name: CGColorSpace.itur_709)!
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: space)
        }
        var images: [VideoScope.Kind: CGImage] = [:]
        var peak = 0.0
        pixels.withUnsafeBufferPointer { buffer in
            for kind in kinds {
                let bitmap = VideoScope.render(kind, pixels: buffer, width: width, height: height, scale: scale,
                                               outputWidth: kind == .vectorscope ? 256 : 512, outputHeight: 256)
                images[kind] = cgImage(bitmap)
            }
            if scale == .hdr {
                for i in stride(from: 0, to: buffer.count, by: 4) {
                    peak = max(peak, VideoScope.luminance(Double(buffer[i]), Double(buffer[i + 1]), Double(buffer[i + 2]), scale: .hdr))
                }
            }
        }
        return (images, peak * 100)
    }

    nonisolated private static func cgImage(_ bitmap: VideoScope.Bitmap) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bitmap.rgba) as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Waveform, RGB parade, vectorscope and histogram of the viewer's frame, one at a time or
/// all four, on an SDR (0–100%) or HDR (PQ, 0–10 000 nits) scale. ⇧⌘W shows or hides it.
struct ScopesPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var sequence: SequencePlaybackController
    @AppStorage("scopes.kind") private var kind: VideoScope.Kind = .waveform
    @AppStorage("scopes.scale") private var scale: VideoScope.Scale = .sdr
    @AppStorage("scopes.all") private var showAll = false
    @StateObject private var analyzer = ScopeAnalyzer()

    private var kinds: [VideoScope.Kind] { showAll ? VideoScope.Kind.allCases : [kind] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Scopes").font(.headline)
                Spacer()
                Picker("Scale", selection: $scale) {
                    Text("SDR").tag(VideoScope.Scale.sdr)
                    Text("HDR").tag(VideoScope.Scale.hdr)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("SDR plots 0–100% of the encoded signal; HDR plots PQ-encoded luminance from 0 to 10 000 nits")
                Toggle(isOn: $showAll) { Image(systemName: "square.grid.2x2") }.toggleStyle(.button).help("Show all four scopes")
            }.padding(12)
            if !showAll {
                Picker("Scope", selection: $kind) {
                    ForEach(VideoScope.Kind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            GeometryReader { geometry in
                let columns = showAll ? 2 : 1
                let rows = showAll ? 2 : 1
                let cell = CGSize(width: geometry.size.width / CGFloat(columns), height: geometry.size.height / CGFloat(rows))
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < kinds.count {
                                    ScopeView(kind: kinds[index], scale: scale, image: analyzer.images[kinds[index]])
                                        .frame(width: cell.width, height: cell.height)
                                }
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            Text(analyzer.detail.isEmpty ? "Waiting for a frame…" : analyzer.detail)
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear {
            analyzer.start(store: store, sequence: sequence, kinds: { [kinds] in kinds }, scale: { [scale] in scale })
        }
        .onChange(of: kinds) { _, kinds in
            analyzer.start(store: store, sequence: sequence, kinds: { kinds }, scale: { [scale] in scale })
        }
        .onChange(of: scale) { _, scale in
            analyzer.start(store: store, sequence: sequence, kinds: { [kinds] in kinds }, scale: { scale })
        }
        .onDisappear { analyzer.stop() }
    }
}

/// One scope image with its graticule and labels.
private struct ScopeView: View {
    let kind: VideoScope.Kind
    let scale: VideoScope.Scale
    let image: CGImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    .aspectRatio(kind == .vectorscope ? 1 : nil, contentMode: kind == .vectorscope ? .fit : .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Canvas { context, size in draw(in: &context, size: size) }
            Text(kind.title).font(.caption2.bold()).foregroundStyle(.white.opacity(0.7)).padding(4)
        }
        .clipped()
        .accessibilityLabel("\(kind.title) scope")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let line = Color.white.opacity(0.25)
        switch kind {
        case .waveform, .parade:
            for (level, label) in VideoScope.graticule(scale) {
                let y = size.height * (1 - level)
                var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(line), lineWidth: 0.5)
                context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: size.width - 2, y: max(6, y - 6)), anchor: .trailing)
            }
            if kind == .parade {
                for i in 1..<3 {
                    let x = size.width * CGFloat(i) / 3
                    var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(line), lineWidth: 0.5)
                }
            }
        case .vectorscope:
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(line), lineWidth: 0.5)
            var cross = Path()
            cross.move(to: CGPoint(x: rect.midX, y: rect.minY)); cross.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            cross.move(to: CGPoint(x: rect.minX, y: rect.midY)); cross.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.stroke(cross, with: .color(line), lineWidth: 0.5)
            // 75% colour-bar targets and the skin-tone line.
            for (name, r, g, b) in [("R", 0.75, 0.0, 0.0), ("Mg", 0.75, 0.0, 0.75), ("B", 0.0, 0.0, 0.75), ("Cy", 0.0, 0.75, 0.75), ("G", 0.0, 0.75, 0.0), ("Yl", 0.75, 0.75, 0.0)] {
                let cb = -0.1146 * r - 0.3854 * g + 0.5 * b, cr = 0.5 * r - 0.4542 * g - 0.0458 * b
                let point = CGPoint(x: rect.minX + (0.5 + cb) * side, y: rect.minY + (0.5 - cr) * side)
                context.stroke(Path(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.white.opacity(0.5)), lineWidth: 0.75)
                context.draw(Text(name).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: point.x + 10, y: point.y))
            }
            var skin = Path()
            skin.move(to: CGPoint(x: rect.midX, y: rect.midY))
            let angle = 123.0 * .pi / 180
            skin.addLine(to: CGPoint(x: rect.midX + cos(angle) * side / 2, y: rect.midY - sin(angle) * side / 2))
            context.stroke(skin, with: .color(.orange.opacity(0.5)), lineWidth: 0.75)
        case .histogram:
            for level in [0.25, 0.5, 0.75] {
                let x = size.width * level
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(line), lineWidth: 0.5)
            }
        }
    }
}
