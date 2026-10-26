import Foundation

public enum AudioFadeCurve: String, Codable, CaseIterable, Sendable {
    case linear, equalPower
}

/// A clip-relative envelope at one edge. Zero duration disables the fade.
public struct AudioFade: Equatable, Codable, Sendable {
    public var duration: RationalTime
    public var curve: AudioFadeCurve
    public init(duration: RationalTime = .zero, curve: AudioFadeCurve = .linear) {
        self.duration = duration
        self.curve = curve
    }
    public func validate(duration clipDuration: RationalTime) throws {
        guard duration.numerator >= 0, try duration.compared(to: clipDuration) != .orderedDescending else {
            throw EditorCoreError.invalidModel("Audio fade exceeds clip duration or is negative")
        }
    }
}

/// A volume point anchored to the clip's source time, so trims and splits keep it on the
/// same sound. Gain is linear amplitude; values are interpolated linearly between points
/// and held before the first and after the last.
public struct VolumeKeyframe: Equatable, Codable, Sendable {
    public var time: RationalTime
    public var gain: Double
    public init(time: RationalTime, gain: Double) { self.time = time; self.gain = gain }
}

public enum VolumeEnvelope {
    public static func validate(_ keyframes: [VolumeKeyframe]) throws {
        guard keyframes.count <= 1000, keyframes.allSatisfy({ $0.gain.isFinite && (0...16).contains($0.gain) && $0.time.numerator >= 0 }),
              try zip(keyframes, keyframes.dropFirst()).allSatisfy({ try $0.time.compared(to: $1.time) == .orderedAscending }) else {
            throw EditorCoreError.invalidModel("Volume keyframes need increasing times and volumes up to +24 dB")
        }
    }
    /// Envelope gain at a source time in seconds; 1 without keyframes.
    public static func gain(atSourceSeconds t: Double, keyframes: [VolumeKeyframe]) -> Double {
        guard let first = keyframes.first, let last = keyframes.last else { return 1 }
        if t <= first.time.seconds { return first.gain }
        if t >= last.time.seconds { return last.gain }
        let next = keyframes.firstIndex { $0.time.seconds > t }!
        let a = keyframes[next - 1], b = keyframes[next]
        let span = b.time.seconds - a.time.seconds
        return span > 0 ? a.gain + (b.gain - a.gain) * (t - a.time.seconds) / span : b.gain
    }
}

/// Shared sample-timed envelope. Each edge is independent; overlapping fades multiply.
public enum AudioFadeEnvelope {
    public static func gain(at time: RationalTime, duration: RationalTime, fadeIn: AudioFade, fadeOut: AudioFade) throws -> Double {
        guard duration.numerator > 0 else { throw EditorCoreError.invalidTime }
        try fadeIn.validate(duration: duration)
        try fadeOut.validate(duration: duration)
        guard time.numerator >= 0, try time.compared(to: duration) != .orderedDescending else { return 0 }
        func edge(_ fade: AudioFade, elapsed: RationalTime) throws -> Double {
            guard fade.duration.numerator > 0 else { return 1 }
            if try elapsed.compared(to: fade.duration) != .orderedAscending { return 1 }
            let progress = min(1, max(0, try elapsed.divided(by: fade.duration).seconds))
            switch fade.curve {
            case .linear: return progress
            case .equalPower: return sin(progress * .pi / 2)
            }
        }
        return try edge(fadeIn, elapsed: time) * edge(fadeOut, elapsed: duration.subtracting(time))
    }

    public static func gain(sampleIndex: Int64, sampleRate: Int, duration: RationalTime, fadeIn: AudioFade, fadeOut: AudioFade) throws -> Double {
        guard sampleRate > 0 else { throw EditorCoreError.invalidTime }
        return try gain(at: RationalTime(sampleIndex, Int64(sampleRate)), duration: duration, fadeIn: fadeIn, fadeOut: fadeOut)
    }
}
