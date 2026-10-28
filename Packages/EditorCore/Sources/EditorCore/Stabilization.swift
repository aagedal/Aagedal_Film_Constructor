import Foundation

/// Measured camera motion of a source: where the picture content sits in each analysed
/// frame relative to the first, in fractions of the frame (x right, y down).
nonisolated public struct MotionAnalysis: Equatable, Codable, Sendable {
    /// Source seconds of each analysed frame, increasing.
    public var times: [Double]
    public var x: [Double]
    public var y: [Double]
    public init(times: [Double], x: [Double], y: [Double]) { self.times = times; self.x = x; self.y = y }
    public func validate() throws {
        guard times.count == x.count, times.count == y.count, times.count >= 2, times.count <= 1_000_000,
              (times + x + y).allSatisfy(\.isFinite), zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw EditorCoreError.invalidModel("Stabilisation needs an analysis of at least two increasing frames")
        }
    }
    public var start: Double { times.first ?? 0 }
    public var end: Double { times.last ?? 0 }
}

/// Analysis-based stabilisation, applied live in preview and in export without rendering a
/// copy: the picture is shifted against its jitter (measured path minus a smoothed path)
/// and zoomed in so the shifted edges stay outside the frame.
nonisolated public struct Stabilization: Equatable, Codable, Sendable {
    public var analysis: MotionAnalysis
    /// Smoothing window in seconds; longer windows hold the frame steadier.
    public var smoothing: Double
    /// Picture zoom; nil chooses the smallest zoom that hides the edges (up to 150%).
    public var zoom: Double?
    public init(analysis: MotionAnalysis, smoothing: Double = 1, zoom: Double? = nil) {
        self.analysis = analysis; self.smoothing = smoothing; self.zoom = zoom
    }
    public func validate() throws {
        try analysis.validate()
        guard smoothing.isFinite, (0.1...10).contains(smoothing), zoom.map({ $0.isFinite && (1...2).contains($0) }) ?? true else {
            throw EditorCoreError.invalidModel("Stabilisation smoothing is 0.1–10 seconds and zoom 100–200%")
        }
    }

    /// Per analysed frame, the shift that cancels jitter, in frame fractions.
    public func corrections() -> (x: [Double], y: [Double]) {
        let times = analysis.times
        // Gaussian with σ = window / 3, over ±window seconds.
        func smooth(_ values: [Double]) -> [Double] {
            let sigma = smoothing / 3
            var result = [Double](repeating: 0, count: values.count)
            var lower = 0, upper = 0
            for i in values.indices {
                while times[lower] < times[i] - smoothing { lower += 1 }
                while upper + 1 < times.count && times[upper + 1] <= times[i] + smoothing { upper += 1 }
                var sum = 0.0, weights = 0.0
                for j in lower...upper {
                    let d = (times[j] - times[i]) / sigma
                    let w = exp(-0.5 * d * d)
                    sum += values[j] * w; weights += w
                }
                result[i] = sum / weights
            }
            return result
        }
        let sx = smooth(analysis.x), sy = smooth(analysis.y)
        return (zip(sx, analysis.x).map { $0 - $1 }, zip(sy, analysis.y).map { $0 - $1 })
    }

    /// A ready-to-sample stabiliser for render and preview.
    public func resolved() -> Resolved {
        let c = corrections()
        let autoZoom = 1 + 2 * max(c.x.map(abs).max() ?? 0, c.y.map(abs).max() ?? 0)
        return Resolved(times: analysis.times, x: c.x, y: c.y, zoom: zoom ?? min(1.5, max(1, autoZoom)))
    }

    nonisolated public struct Resolved: Equatable, Sendable {
        public let times: [Double]
        public let x: [Double]
        public let y: [Double]
        public let zoom: Double
        /// The largest shift the zoomed picture allows without showing an edge.
        public var limit: Double { (1 - 1 / zoom) / 2 }
        /// The shift at a source time, interpolated between analysed frames and held beyond
        /// them, limited so edges never show.
        public func correction(atSourceSeconds t: Double) -> (x: Double, y: Double) {
            guard let first = times.first, let last = times.last else { return (0, 0) }
            let limit = self.limit
            func clamp(_ v: Double) -> Double { max(-limit, min(limit, v)) }
            if t <= first { return (clamp(x[0]), clamp(y[0])) }
            if t >= last { return (clamp(x[x.count - 1]), clamp(y[y.count - 1])) }
            var low = 0, high = times.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if times[mid] <= t { low = mid } else { high = mid }
            }
            let f = (t - times[low]) / (times[high] - times[low])
            return (clamp(x[low] + (x[high] - x[low]) * f), clamp(y[low] + (y[high] - y[low]) * f))
        }
    }
}
