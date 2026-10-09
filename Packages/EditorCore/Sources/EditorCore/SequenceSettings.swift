import Foundation

public struct FrameRate: Hashable, Codable, Sendable {
    public let value: RationalTime
    public init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        let value = try RationalTime(numerator, denominator)
        guard value.numerator > 0, value.seconds <= 1000 else { throw EditorCoreError.invalidFrameRate }
        self.value = value
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
        return String(format: "%02lld:%02lld:%02lld%@%02lld", hours, minutes, seconds, mode == .dropFrame ? ";" : ":", frames)
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
}
