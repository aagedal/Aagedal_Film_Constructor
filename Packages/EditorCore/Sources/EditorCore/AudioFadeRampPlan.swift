import Foundation

/// Piecewise-linear preview of the canonical envelope. The error bound applies
/// to interpolated volume, before a playback engine quantizes or renders ramps.
public struct AudioFadeRampPlan: Sendable {
    public struct Point: Sendable {
        public let seconds: Double
        public let volume: Double
    }
    public let points: [Point]
    public let maximumVolumeError: Double
    public let isNonlinear: Bool

    public init(duration: RationalTime, fadeIn: AudioFade, fadeOut: AudioFade,
                gain: Double, tolerance: Double = 0.0001) throws {
        guard duration.numerator > 0, gain.isFinite, gain >= 0,
              tolerance.isFinite, tolerance > 0 else { throw EditorCoreError.invalidTime }
        try fadeIn.validate(duration: duration)
        try fadeOut.validate(duration: duration)
        let length = duration.seconds
        let incoming = fadeIn.duration.seconds, outgoing = fadeOut.duration.seconds
        let boundaries = Set([0, length, incoming, length - outgoing]).sorted()
        func edge(_ elapsed: Double, _ span: Double, _ curve: AudioFadeCurve) -> Double {
            guard span > 0 else { return 1 }
            let progress = min(1, max(0, elapsed / span))
            return curve == .linear ? progress : sin(progress * .pi / 2)
        }
        func point(_ seconds: Double) -> Point {
            Point(seconds: seconds, volume: gain * edge(seconds, incoming, fadeIn.curve)
                  * edge(length - seconds, outgoing, fadeOut.curve))
        }
        var result = [point(0)]
        var bound = 0.0
        var nonlinear = false
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let span = end - start
            // Bounds for derivatives in interval-normalized coordinates. Splitting
            // at fade edges keeps every interval smooth, including overlap regions.
            func derivatives(_ active: Bool, _ duration: Double, _ curve: AudioFadeCurve) -> (Double, Double) {
                guard active, duration > 0 else { return (0, 0) }
                let first = span / duration * (curve == .linear ? 1 : .pi / 2)
                return (first, curve == .linear ? 0 : first * first)
            }
            let a = derivatives(end <= incoming, incoming, fadeIn.curve)
            let b = derivatives(start >= length - outgoing, outgoing, fadeOut.curve)
            let curvature = gain * (a.1 + 2 * a.0 * b.0 + b.1)
            nonlinear = nonlinear || curvature > 0
            // Linear interpolation error <= sup(abs(f'')) * step^2 / 8.
            // Cap work even for caller-supplied extreme tolerances or gains.
            let requested = sqrt(curvature / (8 * tolerance))
            let count = requested >= 4096 ? 4096 : max(1, Int(ceil(requested)))
            bound = max(bound, curvature / (8 * Double(count) * Double(count)))
            for index in 1...count {
                result.append(point(index == count ? end : start + span * Double(index) / Double(count)))
            }
        }
        points = result
        maximumVolumeError = bound
        isNonlinear = nonlinear
    }
}
