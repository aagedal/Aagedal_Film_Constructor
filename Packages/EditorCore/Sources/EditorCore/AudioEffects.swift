import Foundation

/// One band of the parametric equaliser. Cuts are 12 dB/octave filters; shelves and bells
/// use the RBJ cookbook with the band's Q.
nonisolated public struct EQBand: Equatable, Codable, Sendable {
    public enum Shape: String, Codable, Sendable, CaseIterable { case lowCut, lowShelf, bell, highShelf, highCut }
    public var shape: Shape
    public var frequency: Double
    /// Boost or cut in dB; cuts ignore it.
    public var gain: Double
    public var q: Double
    public var enabled: Bool
    public init(shape: Shape, frequency: Double, gain: Double = 0, q: Double = 0.71, enabled: Bool = true) {
        self.shape = shape; self.frequency = frequency; self.gain = gain; self.q = q; self.enabled = enabled
    }
    public func validate() throws {
        guard frequency.isFinite, gain.isFinite, q.isFinite, (20...20000).contains(frequency), (-24...24).contains(gain), (0.1...10).contains(q) else {
            throw EditorCoreError.invalidModel("EQ bands need 20 Hz–20 kHz, −24 to +24 dB and Q 0.1–10")
        }
    }
    /// Whether the band changes the sound.
    public var isActive: Bool { enabled && (shape == .lowCut || shape == .highCut || gain != 0) }
    public func biquad(sampleRate: Double) -> Biquad {
        // Keep the filter below Nyquist at low sequence rates.
        let f = min(frequency, sampleRate * 0.45)
        switch shape {
        case .lowCut: return .highPass(frequency: f, q: q, sampleRate: sampleRate)
        case .highCut: return .lowPass(frequency: f, q: q, sampleRate: sampleRate)
        case .lowShelf: return .shelf(frequency: f, gain: gain, sampleRate: sampleRate, high: false)
        case .highShelf: return .shelf(frequency: f, gain: gain, sampleRate: sampleRate, high: true)
        case .bell: return .peak(frequency: f, gain: gain, q: q, sampleRate: sampleRate)
        }
    }
}

/// A six-band parametric equaliser in the style of Resolve's track EQ: a low cut, four
/// shaping bands and a high cut. The cuts start disabled.
nonisolated public struct ParametricEQ: Equatable, Codable, Sendable {
    public var bands: [EQBand]
    public init(bands: [EQBand] = ParametricEQ.defaultBands) { self.bands = bands }
    public static let defaultBands: [EQBand] = [
        EQBand(shape: .lowCut, frequency: 80, enabled: false),
        EQBand(shape: .lowShelf, frequency: 120),
        EQBand(shape: .bell, frequency: 500, q: 1),
        EQBand(shape: .bell, frequency: 2500, q: 1),
        EQBand(shape: .highShelf, frequency: 8000),
        EQBand(shape: .highCut, frequency: 16000, enabled: false),
    ]
    public func validate() throws {
        guard bands.count <= 12 else { throw EditorCoreError.invalidModel("An EQ has at most 12 bands") }
        try bands.forEach { try $0.validate() }
    }
    public func biquads(sampleRate: Double) -> [Biquad] { bands.filter(\.isActive).map { $0.biquad(sampleRate: sampleRate) } }
    /// Combined magnitude response in dB, for drawing the curve.
    public func response(at frequency: Double, sampleRate: Double = 48000) -> Double {
        biquads(sampleRate: sampleRate).reduce(0) { $0 + $1.response(at: frequency, sampleRate: sampleRate) }
    }
}

/// A downward compressor with peak detection and a hard knee, linked across channels:
/// the loudest channel sets the gain for all of them, as FFmpeg's acompressor does with
/// `link=maximum`.
nonisolated public struct CompressorSettings: Equatable, Codable, Sendable {
    public var threshold: Double
    public var ratio: Double
    /// Milliseconds.
    public var attack: Double
    public var release: Double
    public var makeup: Double
    public init(threshold: Double = -18, ratio: Double = 3, attack: Double = 20, release: Double = 250, makeup: Double = 0) {
        self.threshold = threshold; self.ratio = ratio; self.attack = attack; self.release = release; self.makeup = makeup
    }
    public func validate() throws {
        guard [threshold, ratio, attack, release, makeup].allSatisfy(\.isFinite), (-60...0).contains(threshold), (1...20).contains(ratio),
              (0.01...2000).contains(attack), (0.01...9000).contains(release), (0...24).contains(makeup) else {
            throw EditorCoreError.invalidModel("Compressor threshold −60 to 0 dB, ratio 1–20, attack 0.01–2000 ms, release 0.01–9000 ms, makeup 0–24 dB")
        }
    }
    var stage: Compressor.Settings { .init(threshold: threshold, ratio: ratio, attack: attack, release: release, makeup: makeup) }
}

/// A brickwall limiter: a fast 20:1 compressor at the ceiling followed by a clip at the
/// ceiling, so no sample exceeds it.
nonisolated public struct LimiterSettings: Equatable, Codable, Sendable {
    /// dBFS.
    public var ceiling: Double
    /// Milliseconds.
    public var release: Double
    public init(ceiling: Double = -1, release: Double = 50) { self.ceiling = ceiling; self.release = release }
    public func validate() throws {
        guard ceiling.isFinite, release.isFinite, (-30...0).contains(ceiling), (1...2000).contains(release) else {
            throw EditorCoreError.invalidModel("Limiter ceiling −30 to 0 dB, release 1–2000 ms")
        }
    }
    var stage: Compressor.Settings { .init(threshold: ceiling, ratio: 20, attack: 1, release: release, makeup: 0) }
    var linearCeiling: Double { pow(10, ceiling / 20) }
}

/// An insert effect on an audio track or bus. Disabled effects are bypassed but kept.
nonisolated public struct AudioEffect: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: Equatable, Codable, Sendable {
        case equalizer(ParametricEQ)
        case compressor(CompressorSettings)
        case limiter(LimiterSettings)
    }
    public var id: UUID
    public var enabled: Bool
    public var kind: Kind
    public init(id: UUID = UUID(), enabled: Bool = true, kind: Kind) { self.id = id; self.enabled = enabled; self.kind = kind }
    public static func equalizer() -> AudioEffect { AudioEffect(kind: .equalizer(ParametricEQ())) }
    public static func compressor() -> AudioEffect { AudioEffect(kind: .compressor(CompressorSettings())) }
    public static func limiter() -> AudioEffect { AudioEffect(kind: .limiter(LimiterSettings())) }
    public var name: String {
        switch kind {
        case .equalizer: return "EQ"
        case .compressor: return "Compressor"
        case .limiter: return "Limiter"
        }
    }
    public func validate() throws {
        switch kind {
        case .equalizer(let eq): try eq.validate()
        case .compressor(let settings): try settings.validate()
        case .limiter(let settings): try settings.validate()
        }
    }
    /// Whether the effect changes the sound.
    public var isActive: Bool {
        guard enabled else { return false }
        if case .equalizer(let eq) = kind { return eq.bands.contains(where: \.isActive) }
        return true
    }

    /// FFmpeg filters for a stream of `channels` channels, in order; empty when bypassed.
    public func ffmpegFilters(sampleRate: Int, channels: Int) -> [String] {
        guard isActive else { return [] }
        func compressor(_ s: Compressor.Settings) -> String {
            "acompressor=threshold=\(pow(10, s.threshold / 20)):ratio=\(s.ratio):attack=\(s.attack):release=\(s.release):makeup=\(pow(10, s.makeup / 20))"
                + ":knee=1:link=maximum:detection=peak:mode=downward"
        }
        switch kind {
        case .equalizer(let eq):
            return eq.biquads(sampleRate: Double(sampleRate)).map { "biquad=b0=\($0.b0):b1=\($0.b1):b2=\($0.b2):a0=1:a1=\($0.a1):a2=\($0.a2)" }
        case .compressor(let settings):
            return [compressor(settings.stage)]
        case .limiter(let settings):
            let c = settings.linearCeiling
            let clip = (0..<channels).map { "max(-\(c),min(\(c),val(\($0))))" }.joined(separator: "|")
            return [compressor(settings.stage), "aeval=exprs='\(clip)'"]
        }
    }
}

/// Runs a chain of insert effects on interleaved frames of `channels` samples, exactly as
/// the FFmpeg filters from `AudioEffect.ffmpegFilters` do.
nonisolated public final class AudioEffectProcessor: @unchecked Sendable {
    private enum Stage {
        case biquad(Biquad, state: [(x1: Double, x2: Double, y1: Double, y2: Double)])
        case compressor(Compressor)
        case clip(Double)
    }
    public let channels: Int
    private var stages: [Stage] = []
    public var isEmpty: Bool { stages.isEmpty }

    public init(effects: [AudioEffect], sampleRate: Double, channels: Int) {
        self.channels = max(1, channels)
        let zero = Array(repeating: (x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0), count: self.channels)
        for effect in effects where effect.isActive {
            switch effect.kind {
            case .equalizer(let eq):
                for biquad in eq.biquads(sampleRate: sampleRate) { stages.append(.biquad(biquad, state: zero)) }
            case .compressor(let settings):
                stages.append(.compressor(Compressor(settings.stage, sampleRate: sampleRate)))
            case .limiter(let settings):
                stages.append(.compressor(Compressor(settings.stage, sampleRate: sampleRate)))
                stages.append(.clip(settings.linearCeiling))
            }
        }
    }

    /// Processes one frame in place: `frame` holds `channels` samples.
    public func process(_ frame: UnsafeMutablePointer<Double>) {
        for index in stages.indices {
            switch stages[index] {
            case .biquad(let f, var state):
                for c in 0..<channels {
                    let s = state[c], x = frame[c]
                    let y = f.b0 * x + f.b1 * s.x1 + f.b2 * s.x2 - f.a1 * s.y1 - f.a2 * s.y2
                    state[c] = (x, s.x1, y, s.y1)
                    frame[c] = y
                }
                stages[index] = .biquad(f, state: state)
            case .compressor(var compressor):
                var level = 0.0
                for c in 0..<channels { level = max(level, abs(frame[c])) }
                let gain = compressor.gain(forLevel: level)
                for c in 0..<channels { frame[c] *= gain }
                stages[index] = .compressor(compressor)
            case .clip(let ceiling):
                for c in 0..<channels { frame[c] = max(-ceiling, min(ceiling, frame[c])) }
            }
        }
    }

    /// Processes planar buffers in place, one per channel.
    public func process(planar: [UnsafeMutablePointer<Float>], frames: Int) {
        guard !stages.isEmpty else { return }
        var frame = [Double](repeating: 0, count: channels)
        frame.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<frames {
                for c in 0..<min(channels, planar.count) { buffer[c] = Double(planar[c][i]) }
                process(buffer.baseAddress!)
                for c in 0..<min(channels, planar.count) { planar[c][i] = Float(buffer[c]) }
            }
        }
    }
}

nonisolated extension Biquad {
    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate, c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate, c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}
