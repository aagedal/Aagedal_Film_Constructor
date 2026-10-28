import Foundation

/// Video scopes computed from a frame's pixels: luma waveform, RGB parade, vectorscope and
/// histogram, on an SDR (encoded 0–100%) or HDR (PQ-encoded nits) scale.
nonisolated public enum VideoScope {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case waveform, parade, vectorscope, histogram
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .waveform: return "Waveform"
            case .parade: return "Parade"
            case .vectorscope: return "Vectorscope"
            case .histogram: return "Histogram"
            }
        }
    }
    /// SDR reads encoded values (0–1 is 0–100%). HDR reads linear light where 1.0 is
    /// 100 nits and plots PQ-encoded luminance, so the scale runs 0–10 000 nits.
    public enum Scale: String, CaseIterable, Identifiable, Sendable {
        case sdr, hdr
        public var id: String { rawValue }
    }

    /// An RGBA8 bitmap, rows top to bottom.
    public struct Bitmap: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public var rgba: [UInt8]
    }

    /// The ST 2084 (PQ) signal for an absolute luminance in nits, 0–1.
    public static func pq(nits: Double) -> Double {
        let y = max(0, min(1, nits / 10000))
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(y, m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }

    /// Luminance weights: Rec. 709 on encoded SDR values, Rec. 2020 on linear HDR light.
    public static func luminance(_ r: Double, _ g: Double, _ b: Double, scale: Scale) -> Double {
        scale == .sdr ? 0.2126 * r + 0.7152 * g + 0.0722 * b : 0.2627 * r + 0.6780 * g + 0.0593 * b
    }

    /// Graticule lines as (level 0–1, label) for a waveform or parade.
    public static func graticule(_ scale: Scale) -> [(level: Double, label: String)] {
        switch scale {
        case .sdr: return [0, 0.25, 0.5, 0.75, 1].map { ($0, "\(Int($0 * 100))") }
        case .hdr: return [(0, "0"), (pq(nits: 100), "100"), (pq(nits: 203), "203"), (pq(nits: 1000), "1000"), (pq(nits: 4000), "4000"), (1, "10000")]
        }
    }

    /// Renders one scope from RGBA float pixels (`width × height`, rows top to bottom).
    public static func render(_ kind: Kind, pixels: UnsafeBufferPointer<Float>, width: Int, height: Int, scale: Scale,
                              outputWidth: Int = 512, outputHeight: Int = 256) -> Bitmap {
        let w = max(1, outputWidth), h = max(1, outputHeight)
        guard width > 0, height > 0, pixels.count >= width * height * 4 else {
            return Bitmap(width: w, height: h, rgba: [UInt8](repeating: 0, count: w * h * 4))
        }
        // Levels per pixel: R, G, B and luma on the plotted scale, 0–1.
        func levels(_ i: Int) -> (Double, Double, Double, Double) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            switch scale {
            case .sdr:
                return (r, g, b, luminance(r, g, b, scale: .sdr))
            case .hdr:
                let y = luminance(r, g, b, scale: .hdr)
                return (pq(nits: r * 100), pq(nits: g * 100), pq(nits: b * 100), pq(nits: y * 100))
            }
        }
        var output = [UInt8](repeating: 0, count: w * h * 4)
        func row(_ level: Double, rows: Int) -> Int { rows - 1 - min(rows - 1, max(0, Int(level * Double(rows - 1) + 0.5))) }
        // Counts become brightness that saturates gracefully for dense traces.
        func plot(_ counts: [Float], gain: Float, color: (Float, Float, Float), additive: Bool) {
            for index in counts.indices where counts[index] > 0 {
                let v = 1 - exp(-counts[index] * gain)
                let o = index * 4
                for (c, tint) in [color.0, color.1, color.2].enumerated() {
                    let base: Float = additive ? Float(output[o + c]) : 0
                    output[o + c] = UInt8(min(255, base + tint * v * 255))
                }
                output[o + 3] = 255
            }
        }
        let expected = Float(height) / Float(h)
        switch kind {
        case .waveform:
            var counts = [Float](repeating: 0, count: w * h)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let column = x * w / width
                    counts[row(levels(i).3, rows: h) * w + column] += 1
                }
            }
            plot(counts, gain: 2.5 / max(1, expected * Float(width) / Float(w)), color: (0.55, 1, 0.6), additive: false)
        case .parade:
            let lane = max(1, w / 3)
            var counts = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let l = levels(i)
                    let column = x * lane / width
                    counts[0][row(l.0, rows: h) * w + column] += 1
                    counts[1][row(l.1, rows: h) * w + lane + column] += 1
                    counts[2][row(l.2, rows: h) * w + min(w - 1, 2 * lane + column)] += 1
                }
            }
            let gain = 2.5 / max(1, expected * Float(width) / Float(lane))
            plot(counts[0], gain: gain, color: (1, 0.3, 0.3), additive: true)
            plot(counts[1], gain: gain, color: (0.3, 1, 0.3), additive: true)
            plot(counts[2], gain: gain, color: (0.35, 0.5, 1), additive: true)
        case .vectorscope:
            let size = min(w, h)
            var counts = [Float](repeating: 0, count: w * h)
            let left = (w - size) / 2, top = (h - size) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let l = levels((y * width + x) * 4)
                    // BT.709 colour difference of the plotted values, ±0.5 to the edges.
                    let cb = -0.1146 * l.0 - 0.3854 * l.1 + 0.5 * l.2
                    let cr = 0.5 * l.0 - 0.4542 * l.1 - 0.0458 * l.2
                    let px = left + min(size - 1, max(0, Int((0.5 + cb) * Double(size - 1))))
                    let py = top + min(size - 1, max(0, Int((0.5 - cr) * Double(size - 1))))
                    counts[py * w + px] += 1
                }
            }
            plot(counts, gain: 40 * Float(size * size) / Float(width * height), color: (0.7, 1, 0.75), additive: false)
        case .histogram:
            var bins = [[Float]](repeating: [Float](repeating: 0, count: w), count: 4)
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let l = levels(i)
                for (c, value) in [l.0, l.1, l.2, l.3].enumerated() { bins[c][min(w - 1, max(0, Int(value * Double(w - 1) + 0.5)))] += 1 }
            }
            let peak = max(1, bins.prefix(3).flatMap { $0 }.max() ?? 1)
            let colors: [(UInt8, UInt8, UInt8)] = [(230, 70, 70), (70, 220, 90), (80, 120, 255)]
            for x in 0..<w {
                for c in 0..<3 {
                    let top = h - Int(Float(h) * min(1, bins[c][x] / peak))
                    for y in top..<h {
                        let o = (y * w + x) * 4
                        output[o] = max(output[o], colors[c].0 / 2 + (c == 0 ? 60 : 0))
                        output[o + 1] = max(output[o + 1], colors[c].1 / 2 + (c == 1 ? 60 : 0))
                        output[o + 2] = max(output[o + 2], colors[c].2 / 2 + (c == 2 ? 60 : 0))
                        output[o + 3] = 255
                    }
                }
            }
        }
        return Bitmap(width: w, height: h, rgba: output)
    }

    /// The share of pixels whose luminance exceeds a level on the plotted scale, for an
    /// out-of-range readout.
    public static func fraction(above level: Double, pixels: UnsafeBufferPointer<Float>, width: Int, height: Int, scale: Scale) -> Double {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return 0 }
        var count = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let y = luminance(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), scale: scale)
            let plotted = scale == .sdr ? y : pq(nits: y * 100)
            if plotted > level { count += 1 }
        }
        return Double(count) / Double(width * height)
    }
}
