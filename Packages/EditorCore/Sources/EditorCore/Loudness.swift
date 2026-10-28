import Foundation

/// ITU-R BS.1770-4 / EBU R 128 loudness: K-weighted, channel-weighted mean square in
/// 100 ms steps, giving momentary (400 ms), short-term (3 s) and gated integrated loudness
/// in LUFS, plus the sample peak.
nonisolated public final class LoudnessMeter: @unchecked Sendable {
    public struct Reading: Equatable, Sendable {
        public var momentary: Double
        public var shortTerm: Double
        public var integrated: Double
        /// Loudness range (EBU Tech 3342) in LU.
        public var range: Double
        /// Highest absolute sample, in dBFS.
        public var peak: Double
        public static let silent = Reading(momentary: -.infinity, shortTerm: -.infinity, integrated: -.infinity, range: 0, peak: -.infinity)
    }
    public let channels: Int
    private let weights: [Double]
    private var filters: [(Biquad, Biquad)]
    private var state: [[Double]]
    private let blockLength: Int
    private var blockFill = 0
    private var blockEnergy: [Double]
    /// Weighted mean square of each completed 100 ms step.
    private var steps: [Double] = []
    /// Momentary-block loudness for integrated gating (400 ms blocks every 100 ms).
    private var gatingBlocks: [Double] = []
    /// Short-term loudness every 100 ms for loudness range (3 s blocks).
    private var rangeBlocks: [Double] = []
    private var peak = 0.0

    /// `layout` names each channel; LFE is excluded and surrounds weigh +1.5 dB.
    public init(sampleRate: Double, layout: ChannelLayout) {
        channels = layout.channels.count
        weights = layout.channels.map { position in
            switch position {
            case .lowFrequency: return 0
            case .leftSurround, .rightSurround, .leftRear, .rightRear: return 1.41
            default: return 1
            }
        }
        let shelf = Self.highShelf(sampleRate: sampleRate), highPass = Self.highPass(sampleRate: sampleRate)
        filters = Array(repeating: (shelf, highPass), count: channels)
        state = Array(repeating: [Double](repeating: 0, count: 8), count: channels)
        blockLength = max(1, Int((sampleRate / 10).rounded()))
        blockEnergy = [Double](repeating: 0, count: channels)
    }

    public func reset() {
        state = Array(repeating: [Double](repeating: 0, count: 8), count: channels)
        blockFill = 0; blockEnergy = [Double](repeating: 0, count: channels)
        steps = []; gatingBlocks = []; rangeBlocks = []; peak = 0
    }

    /// Adds one frame of `channels` samples.
    public func add(frame: UnsafePointer<Float>) {
        for c in 0..<channels {
            let x = Double(frame[c])
            peak = max(peak, abs(x))
            let (a, b) = filters[c]
            var s = state[c]
            let y1 = a.b0 * x + a.b1 * s[0] + a.b2 * s[1] - a.a1 * s[2] - a.a2 * s[3]
            s[1] = s[0]; s[0] = x; s[3] = s[2]; s[2] = y1
            let y2 = b.b0 * y1 + b.b1 * s[4] + b.b2 * s[5] - b.a1 * s[6] - b.a2 * s[7]
            s[5] = s[4]; s[4] = y1; s[7] = s[6]; s[6] = y2
            state[c] = s
            blockEnergy[c] += y2 * y2
        }
        blockFill += 1
        if blockFill == blockLength { completeStep() }
    }

    /// Adds interleaved samples.
    public func add(interleaved samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            var index = 0
            while index + channels <= buffer.count { add(frame: buffer.baseAddress! + index); index += channels }
        }
    }

    private func completeStep() {
        var sum = 0.0
        for c in 0..<channels { sum += weights[c] * blockEnergy[c] / Double(blockLength) }
        steps.append(sum)
        blockFill = 0
        for c in 0..<channels { blockEnergy[c] = 0 }
        if steps.count >= 4 { gatingBlocks.append(Self.loudness(Self.mean(steps.suffix(4)))) }
        if steps.count >= 30 { rangeBlocks.append(Self.loudness(Self.mean(steps.suffix(30)))) }
        // Bound memory to about 10 hours of history.
        if steps.count > 400_000 { steps.removeFirst(steps.count - 30) }
    }

    public var reading: Reading {
        let momentary = steps.count >= 4 ? Self.loudness(Self.mean(steps.suffix(4))) : -.infinity
        let shortTerm = steps.count >= 30 ? Self.loudness(Self.mean(steps.suffix(30))) : (steps.isEmpty ? -.infinity : Self.loudness(Self.mean(steps.suffix(30))))
        return Reading(momentary: momentary, shortTerm: shortTerm, integrated: integrated, range: range,
                       peak: peak > 0 ? 20 * log10(peak) : -.infinity)
    }

    /// Two-stage gating: blocks above −70 LUFS, then above the mean of those minus 10 LU.
    private var integrated: Double {
        let absolute = gatingBlocks.filter { $0 > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relative = Self.loudness(Self.mean(absolute.map(Self.energy))) - 10
        let gated = absolute.filter { $0 > relative }
        guard !gated.isEmpty else { return -.infinity }
        return Self.loudness(Self.mean(gated.map(Self.energy)))
    }

    /// The spread between the 10th and 95th percentiles of gated short-term loudness.
    private var range: Double {
        let absolute = rangeBlocks.filter { $0 > -70 }
        guard absolute.count > 1 else { return 0 }
        let relative = Self.loudness(Self.mean(absolute.map(Self.energy))) - 20
        let gated = absolute.filter { $0 > relative }.sorted()
        guard gated.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double { gated[min(gated.count - 1, max(0, Int((p * Double(gated.count - 1)).rounded())))] }
        return percentile(0.95) - percentile(0.10)
    }

    private static func mean<S: Collection>(_ values: S) -> Double where S.Element == Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    private static func loudness(_ energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }
    private static func energy(_ loudness: Double) -> Double { pow(10, (loudness + 0.691) / 10) }

    /// The K-weighting pre-filter (a high shelf of about +4 dB above 1.5 kHz) for any rate.
    static func highShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate), vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
    /// The K-weighting RLB high-pass at about 38 Hz.
    static func highPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate), a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}
