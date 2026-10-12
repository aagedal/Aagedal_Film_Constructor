import Foundation

public enum NativePlaybackTransportError: Error, Equatable, Sendable {
    case invalidClockSample
    case regressingClockSample
}

/// Pure transport state driven by an output device's presented sample count.
/// Scheduling or decoding samples does not advance this clock. The caller must
/// serialize mutations and supply counts in the plan's output sample rate.
public struct NativePlaybackTransport: Sendable {
    public private(set) var plan: NativePlaybackPlan
    public private(set) var position: RationalTime = .zero
    public private(set) var isPlaying = false
    /// Nil at the exact sequence end; black gaps still have a frame index.
    public private(set) var frameIndex: Int64?
    /// Floor of position on the sample grid. At end this is audioSamples,
    /// allowing callers to identify that no further output block remains.
    public private(set) var sampleIndex: Int64 = 0
    public private(set) var generation = UUID()
    public let duration: RationalTime
    private var anchorPosition: RationalTime = .zero
    private var anchorClockSample: Int64 = 0
    private var lastClockSample: Int64 = 0

    public init(plan: NativePlaybackPlan) throws {
        self.plan = plan
        duration = plan.duration
        frameIndex = 0
    }

    /// Starts a new clock epoch. Repeated play while running is idempotent.
    /// Playing from the end restarts at zero. No wall-clock time is consulted.
    @discardableResult
    public mutating func play(clockSample: Int64 = 0) throws -> UUID {
        guard clockSample >= 0 else { throw NativePlaybackTransportError.invalidClockSample }
        guard !isPlaying else { return generation }
        if position == duration { assign(.zero, frame: 0, sample: 0) }
        isPlaying = true
        reanchor(clockSample: clockSample)
        return generation
    }

    /// Holds the last accepted device position and invalidates in-flight callbacks.
    /// Submit the device's final presented count before pausing if available.
    public mutating func pause() {
        guard isPlaying else { return }
        isPlaying = false
        generation = UUID()
    }

    /// Seeks to exact seconds, clamping to [zero, duration]. A running seek
    /// remains running but starts a new clock epoch at the supplied device count.
    /// Fractional sample anchors are preserved rather than rounded into drift.
    @discardableResult
    public mutating func seek(to time: RationalTime, clockSample: Int64 = 0) throws -> UUID {
        guard clockSample >= 0 else { throw NativePlaybackTransportError.invalidClockSample }
        let clamped = try clamp(time)
        let indices = try indices(at: clamped)
        assign(clamped, frame: indices.frame, sample: indices.sample)
        if clamped == duration { isPlaying = false }
        reanchor(clockSample: clockSample)
        return generation
    }

    @discardableResult
    public mutating func seek(toFrame frame: Int64, clockSample: Int64 = 0) throws -> UUID {
        // Clamp before conversion so even an extreme out-of-range frame is safe.
        let clamped = min(max(frame, 0), plan.videoFrames)
        return try seek(to: plan.settings.frameRate.time(forFrames: clamped), clockSample: clockSample)
    }

    /// Replaces the plan, resets to zero and pauses. Tokens from the old plan
    /// cannot advance the replacement, even if the plans compare equal.
    public mutating func replacePlan(_ plan: NativePlaybackPlan) throws {
        var replacement = try Self(plan: plan)
        replacement.generation = UUID()
        self = replacement
    }

    /// Returns false for stale epochs or paused transport, with no mutation.
    /// Current-epoch negative or decreasing counts throw without mutation.
    /// Duplicate counts are accepted. Overshoot clamps to exact duration and
    /// stops playback; the possible ceiled final silent sample is not extra time.
    @discardableResult
    public mutating func update(clockSample: Int64, generation: UUID) throws -> Bool {
        guard generation == self.generation, isPlaying else { return false }
        guard clockSample >= 0 else { throw NativePlaybackTransportError.invalidClockSample }
        guard clockSample >= lastClockSample else { throw NativePlaybackTransportError.regressingClockSample }
        let elapsed = try RationalTime(clockSample - anchorClockSample, Int64(plan.settings.audioSampleRate))
        // Compare the elapsed interval first to avoid adding a large overshoot.
        let remaining = try duration.subtracting(anchorPosition)
        let next = try elapsed.compared(to: remaining) != .orderedAscending
            ? duration : anchorPosition.adding(elapsed)
        let indices = try indices(at: next)
        assign(next, frame: indices.frame, sample: indices.sample)
        lastClockSample = clockSample
        if next == duration {
            isPlaying = false
            self.generation = UUID()
        }
        return true
    }

    private func clamp(_ time: RationalTime) throws -> RationalTime {
        if time.numerator < 0 { return .zero }
        return try time.compared(to: duration) == .orderedDescending ? duration : time
    }

    private func indices(at time: RationalTime) throws -> (frame: Int64?, sample: Int64) {
        if time == duration { return (nil, plan.audioSamples) }
        let frames = try time.multiplied(by: plan.settings.frameRate.value)
        let samples = try time.multiplied(by: Int64(plan.settings.audioSampleRate))
        return (frames.numerator / frames.denominator, samples.numerator / samples.denominator)
    }

    private mutating func assign(_ time: RationalTime, frame: Int64?, sample: Int64) {
        position = time; frameIndex = frame; sampleIndex = sample
    }

    private mutating func reanchor(clockSample: Int64) {
        anchorPosition = position
        anchorClockSample = clockSample
        lastClockSample = clockSample
        generation = UUID()
    }
}
