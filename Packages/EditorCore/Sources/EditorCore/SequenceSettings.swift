import Foundation

public struct FrameRate: Hashable, Codable, Sendable {
    public let value: RationalTime
    public init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        let value = try RationalTime(numerator, denominator)
        guard value.numerator > 0,
              try value.compared(to: RationalTime(1000)) != .orderedDescending else { throw EditorCoreError.invalidFrameRate }
        self.value = value
    }
    /// Parses an integer, decimal, or numerator/denominator without rounding.
    /// Decimal input is literal: `29.97` is `2997/100`, not `30000/1001`.
    /// Components must contain ASCII digits; only exterior whitespace is ignored.
    public init(parsing text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func integer(_ text: Substring) throws -> Int64 {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int64(text) else { throw EditorCoreError.invalidFrameRate }
            return value
        }
        let numerator: Int64
        let denominator: Int64
        if text.contains("/") {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw EditorCoreError.invalidFrameRate }
            numerator = try integer(parts[0])
            denominator = try integer(parts[1])
        } else if text.contains(".") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty, parts[1].count <= 18 else {
                throw EditorCoreError.invalidFrameRate
            }
            let whole = try integer(parts[0])
            let fraction = try integer(parts[1])
            denominator = (0..<parts[1].count).reduce(Int64(1)) { value, _ in value * 10 }
            let scaled = whole.multipliedReportingOverflow(by: denominator)
            let combined = scaled.partialValue.addingReportingOverflow(fraction)
            guard !scaled.overflow, !combined.overflow else { throw EditorCoreError.invalidFrameRate }
            numerator = combined.partialValue
        } else {
            numerator = try integer(text[...])
            denominator = 1
        }
        guard numerator > 0, denominator > 0 else { throw EditorCoreError.invalidFrameRate }
        try self.init(numerator, denominator)
    }
    /// Canonical, lossless input text, including rates with recurring decimals.
    public var editableText: String {
        value.denominator == 1 ? String(value.numerator) : "\(value.numerator)/\(value.denominator)"
    }
    public var nominalFramesPerSecond: Int { Int(value.seconds.rounded()) }
    public var supportsDropFrame: Bool { value == (try! RationalTime(30000, 1001)) || value == (try! RationalTime(60000, 1001)) }
    public func time(forFrames frames: Int64) throws -> RationalTime { try RationalTime(frames).divided(by: value) }
    private enum CodingKeys: String, CodingKey { case value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(RationalTime.self, forKey: .value)
        try self.init(value.numerator, value.denominator)
    }
}

public enum TimecodeMode: String, Codable, Sendable { case nonDropFrame, dropFrame }
public struct Timecode: Hashable, Codable, Sendable {
    /// Unwrapped count; formatting wraps at 24 hours without changing stored time.
    public var frameCount: Int64
    public var mode: TimecodeMode
    public init(frameCount: Int64 = 0, mode: TimecodeMode = .nonDropFrame) {
        self.frameCount = frameCount; self.mode = mode
    }
    /// Parses a 24-hour SMPTE label. The final separator selects non-drop (`:`)
    /// or drop-frame (`;`) mode; skipped drop-frame labels are rejected.
    public init(parsing label: String, rate: FrameRate) throws {
        let bytes = Array(label.utf8)
        let frameDigits = max(2, String(max(0, rate.nominalFramesPerSecond - 1)).count)
        guard bytes.count == 9 + frameDigits,
              bytes[2] == 58, bytes[5] == 58,
              bytes[8] == 58 || bytes[8] == 59 else { throw EditorCoreError.invalidTimecode }
        func number(_ range: Range<Int>) throws -> Int64 {
            var result: Int64 = 0
            for index in range {
                guard bytes[index] >= 48, bytes[index] <= 57 else { throw EditorCoreError.invalidTimecode }
                result = result * 10 + Int64(bytes[index] - 48)
            }
            return result
        }
        let hours = try number(0..<2)
        let minutes = try number(3..<5)
        let seconds = try number(6..<8)
        let frames = try number(9..<bytes.count)
        let fps = Int64(rate.nominalFramesPerSecond)
        let mode: TimecodeMode = bytes[8] == 59 ? .dropFrame : .nonDropFrame
        guard hours < 24, minutes < 60, seconds < 60, frames < fps,
              mode != .dropFrame || rate.supportsDropFrame else { throw EditorCoreError.invalidTimecode }
        var count = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        if mode == .dropFrame {
            let dropped = fps / 15
            guard minutes % 10 == 0 || seconds != 0 || frames >= dropped else { throw EditorCoreError.invalidTimecode }
            let totalMinutes = hours * 60 + minutes
            count -= dropped * (totalMinutes - totalMinutes / 10)
        }
        self.init(frameCount: count, mode: mode)
        try validate(rate: rate)
    }
    public func validate(rate: FrameRate) throws {
        guard frameCount >= 0, rate.nominalFramesPerSecond > 0,
              mode != .dropFrame || rate.supportsDropFrame else { throw EditorCoreError.invalidTimecode }
    }
    public func formatted(rate: FrameRate) throws -> String {
        try validate(rate: rate)
        let fps = Int64(rate.nominalFramesPerSecond)
        var count: Int64
        if mode == .dropFrame {
            let dropped = fps / 15
            let perMinute = fps * 60 - dropped
            let perTenMinutes = fps * 600 - dropped * 9
            count = frameCount % (perTenMinutes * 144)
            let blocks = count / perTenMinutes
            let remainder = count % perTenMinutes
            count += dropped * 9 * blocks
            if remainder >= dropped { count += dropped * ((remainder - dropped) / perMinute) }
        } else { count = frameCount % (fps * 86400) }
        let frames = count % fps
        let seconds = count / fps % 60
        let minutes = count / (fps * 60) % 60
        let hours = count / (fps * 3600) % 24
        let frameDigits = max(2, String(fps - 1).count)
        return String(format: "%02lld:%02lld:%02lld%@%0*lld", hours, minutes, seconds, mode == .dropFrame ? ";" : ":", frameDigits, frames)
    }
}
public struct SequenceSettings: Equatable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var audioSampleRate: Int
    public var audioLayout: ChannelLayout
    public var startTimecode: Timecode
    public init(width: Int = 1920, height: Int = 1080, frameRate: FrameRate = try! FrameRate(24), audioSampleRate: Int = 48000, audioLayout: ChannelLayout = .stereo, startTimecode: Timecode = .init()) throws {
        self.width = width; self.height = height; self.frameRate = frameRate
        self.audioSampleRate = audioSampleRate; self.audioLayout = audioLayout; self.startTimecode = startTimecode
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case width, height, frameRate, audioSampleRate, audioLayout, startTimecode }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height), frameRate: c.decode(FrameRate.self, forKey: .frameRate), audioSampleRate: c.decode(Int.self, forKey: .audioSampleRate), audioLayout: c.decode(ChannelLayout.self, forKey: .audioLayout), startTimecode: c.decode(Timecode.self, forKey: .startTimecode))
    }
    public func validate() throws {
        guard width > 0, height > 0, width <= 65536, height <= 65536, audioSampleRate > 0, audioSampleRate <= 768000 else { throw EditorCoreError.invalidSettings }
        try audioLayout.validate(); try startTimecode.validate(rate: frameRate)
    }
    /// Timecode of the frame containing a nonnegative sequence position.
    /// Start timecode is a display offset and does not change sequence timing.
    public func timecode(at position: RationalTime) throws -> Timecode {
        try startTimecode.validate(rate: frameRate)
        guard position.numerator >= 0 else { throw EditorCoreError.invalidTime }
        let frames = try position.multiplied(by: frameRate.value)
        let offset = frames.numerator / frames.denominator
        let count = startTimecode.frameCount.addingReportingOverflow(offset)
        guard !count.overflow else { throw EditorCoreError.overflow }
        return Timecode(frameCount: count.partialValue, mode: startTimecode.mode)
    }
    public func formattedTimecode(at position: RationalTime) throws -> String {
        try timecode(at: position).formatted(rate: frameRate)
    }
}
