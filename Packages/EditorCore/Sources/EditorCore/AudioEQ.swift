import Foundation

/// A three-band equaliser for an audio component: low shelf at 120 Hz, a broad peak at
/// 1 kHz and a high shelf at 8 kHz, each from −24 to +24 dB. Export and preview run the
/// same biquad coefficients.
nonisolated public struct AudioEQ: Equatable, Codable, Sendable {
    public var low: Double
    public var mid: Double
    public var high: Double
    public init(low: Double = 0, mid: Double = 0, high: Double = 0) { self.low = low; self.mid = mid; self.high = high }
    public static let flat = AudioEQ()
    public var isFlat: Bool { self == .flat }
    public func validate() throws {
        guard [low, mid, high].allSatisfy({ $0.isFinite && (-24...24).contains($0) }) else {
            throw EditorCoreError.invalidModel("EQ bands range from −24 to +24 dB")
        }
    }
    /// Normalised biquads (b0, b1, b2, a1, a2) for the non-flat bands, low to high.
    public func biquads(sampleRate: Double) -> [Biquad] {
        var result: [Biquad] = []
        if low != 0 { result.append(.shelf(frequency: 120, gain: low, sampleRate: sampleRate, high: false)) }
        if mid != 0 { result.append(.peak(frequency: 1000, gain: mid, q: 0.7, sampleRate: sampleRate)) }
        if high != 0 { result.append(.shelf(frequency: 8000, gain: high, sampleRate: sampleRate, high: true)) }
        return result
    }
}

/// Direct-form biquad coefficients from the RBJ audio EQ cookbook, normalised so a0 = 1.
nonisolated public struct Biquad: Equatable, Sendable {
    public let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static func shelf(frequency: Double, gain: Double, sampleRate: Double, high: Bool) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), alpha = sin(w) / 2 * sqrt(2.0)   // shelf slope S = 1
        let root = 2 * sqrt(a) * alpha
        if high {
            let a0 = (a + 1) - (a - 1) * c + root
            return Biquad(b0: a * ((a + 1) + (a - 1) * c + root) / a0, b1: -2 * a * ((a - 1) + (a + 1) * c) / a0,
                          b2: a * ((a + 1) + (a - 1) * c - root) / a0, a1: 2 * ((a - 1) - (a + 1) * c) / a0,
                          a2: ((a + 1) - (a - 1) * c - root) / a0)
        }
        let a0 = (a + 1) + (a - 1) * c + root
        return Biquad(b0: a * ((a + 1) - (a - 1) * c + root) / a0, b1: 2 * a * ((a - 1) - (a + 1) * c) / a0,
                      b2: a * ((a + 1) - (a - 1) * c - root) / a0, a1: -2 * ((a - 1) + (a + 1) * c) / a0,
                      a2: ((a + 1) + (a - 1) * c - root) / a0)
    }

    static func peak(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * c / a0, b2: (1 - alpha * a) / a0, a1: -2 * c / a0, a2: (1 - alpha / a) / a0)
    }

    /// Magnitude response in dB at a frequency, for checks.
    public func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func magnitude(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
            let re = x0 + x1 * cos(-w) + x2 * cos(-2 * w), im = x1 * sin(-w) + x2 * sin(-2 * w)
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(magnitude(b0, b1, b2) / magnitude(1, a1, a2))
    }
}
