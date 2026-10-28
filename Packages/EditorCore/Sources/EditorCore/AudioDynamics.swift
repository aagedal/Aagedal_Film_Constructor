import Foundation

/// A compressor and optional limiter for an audio component. Both are downward compressors
/// with peak detection and a hard knee; the limiter is a fast 20:1 stage at its ceiling.
/// Export runs FFmpeg's acompressor with these settings; the preview runs `Compressor`,
/// a port of the same algorithm, so they agree sample for sample.
nonisolated public struct AudioDynamics: Equatable, Codable, Sendable {
    /// Level above which gain is reduced, in dBFS.
    public var threshold: Double
    public var ratio: Double
    /// Gain added after compression, in dB.
    public var makeup: Double
    /// Optional limiter ceiling in dBFS.
    public var limiterCeiling: Double?
    public init(threshold: Double = -18, ratio: Double = 3, makeup: Double = 0, limiterCeiling: Double? = nil) {
        self.threshold = threshold; self.ratio = ratio; self.makeup = makeup; self.limiterCeiling = limiterCeiling
    }
    public func validate() throws {
        guard threshold.isFinite, ratio.isFinite, makeup.isFinite, (-60...0).contains(threshold), (1...20).contains(ratio), (0...24).contains(makeup),
              limiterCeiling.map({ $0.isFinite && (-30...0).contains($0) }) ?? true else {
            throw EditorCoreError.invalidModel("Compressor threshold −60 to 0 dB, ratio 1–20, makeup 0–24 dB, limiter ceiling −30 to 0 dB")
        }
    }
    /// The compressor stage then the limiter stage.
    public var stages: [Compressor.Settings] {
        var result = [Compressor.Settings(threshold: threshold, ratio: ratio, attack: 20, release: 250, makeup: makeup)]
        if let ceiling = limiterCeiling { result.append(.init(threshold: ceiling, ratio: 20, attack: 1, release: 50, makeup: 0)) }
        return result
    }
    /// FFmpeg filters for one channel, in order.
    public var ffmpegFilters: String {
        stages.map { s in
            "acompressor=threshold=\(pow(10, s.threshold / 20)):ratio=\(s.ratio):attack=\(s.attack):release=\(s.release):makeup=\(pow(10, s.makeup / 20))"
                + ":knee=1:link=maximum:detection=peak:mode=downward"
        }.joined(separator: ",")
    }
}

/// FFmpeg acompressor (downward, peak detection, hard knee) for one channel.
nonisolated public struct Compressor: Sendable {
    public struct Settings: Equatable, Sendable {
        public var threshold: Double, ratio: Double, attack: Double, release: Double, makeup: Double
    }
    private let attackCoefficient: Double, releaseCoefficient: Double
    private let threshold: Double, logThreshold: Double, ratio: Double, makeup: Double
    private var slope = 0.0

    public init(_ settings: Settings, sampleRate: Double) {
        attackCoefficient = min(1, 1 / (settings.attack * sampleRate / 4000))
        releaseCoefficient = min(1, 1 / (settings.release * sampleRate / 4000))
        threshold = pow(10, settings.threshold / 20); logThreshold = log(threshold)
        ratio = settings.ratio; makeup = pow(10, settings.makeup / 20)
    }

    public mutating func process(_ sample: Double) -> Double { sample * gain(forLevel: abs(sample)) }

    /// Advances the detector by one frame whose (linked) peak is `level` and returns the
    /// gain to apply to that frame, including makeup.
    public mutating func gain(forLevel level: Double) -> Double {
        slope += (level - slope) * (level > slope ? attackCoefficient : releaseCoefficient)
        var gain = 1.0
        if slope > threshold {
            let logSlope = log(slope)
            gain = exp((logSlope - logThreshold) / ratio + logThreshold - logSlope)
        }
        return gain * makeup
    }
}
