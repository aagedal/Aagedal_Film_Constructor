import Foundation

public enum EditorCoreError: Error, Equatable, Sendable {
    case invalidTime, overflow, invalidFrameRate, invalidTimecode, invalidSettings
    case invalidModel(String)
}

/// Canonical exact seconds. Operations throw instead of silently wrapping integers.
public struct RationalTime: Hashable, Codable, Sendable {
    public let numerator: Int64
    public let denominator: Int64
    public static let zero = try! RationalTime(0)
    public init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        guard denominator != 0, denominator != .min else { throw EditorCoreError.invalidTime }
        let n: Int64
        if denominator < 0 {
            guard numerator != .min else { throw EditorCoreError.overflow }
            n = -numerator
        } else { n = numerator }
        let d = abs(denominator)
        let divisor = Self.gcd(n.magnitude, UInt64(d))
        self.numerator = n / Int64(divisor)
        self.denominator = d / Int64(divisor)
    }
    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var a = a; var b = b
        while b != 0 { let r = a % b; a = b; b = r }
        return a
    }
    private static func checked(_ result: (partialValue: Int64, overflow: Bool)) throws -> Int64 {
        guard !result.overflow else { throw EditorCoreError.overflow }; return result.partialValue
    }
    public func adding(_ other: Self) throws -> Self {
        let common = Int64(Self.gcd(UInt64(denominator), UInt64(other.denominator)))
        let a = try Self.checked(numerator.multipliedReportingOverflow(by: other.denominator / common))
        let b = try Self.checked(other.numerator.multipliedReportingOverflow(by: denominator / common))
        return try Self(Self.checked(a.addingReportingOverflow(b)), Self.checked(denominator.multipliedReportingOverflow(by: other.denominator / common)))
    }
    public func subtracting(_ other: Self) throws -> Self {
        guard other.numerator != .min else { throw EditorCoreError.overflow }
        return try adding(Self(-other.numerator, other.denominator))
    }
    public func multiplied(by other: Self) throws -> Self {
        let a = Int64(Self.gcd(numerator.magnitude, UInt64(other.denominator)))
        let b = Int64(Self.gcd(other.numerator.magnitude, UInt64(denominator)))
        return try Self(Self.checked((numerator / a).multipliedReportingOverflow(by: other.numerator / b)), Self.checked((denominator / b).multipliedReportingOverflow(by: other.denominator / a)))
    }
    public func multiplied(by value: Int64) throws -> Self { try multiplied(by: Self(value)) }
    public func divided(by other: Self) throws -> Self {
        guard other.numerator != 0, other.numerator != .min else { throw EditorCoreError.invalidTime }
        return try multiplied(by: Self(other.denominator, other.numerator))
    }
    /// Full-width cross products make comparison exact even when 64-bit multiplication overflows.
    public func compared(to other: Self) throws -> ComparisonResult {
        let a = numerator.multipliedFullWidth(by: other.denominator)
        let b = other.numerator.multipliedFullWidth(by: denominator)
        if a.high != b.high { return a.high < b.high ? .orderedAscending : .orderedDescending }
        if a.low != b.low { return a.low < b.low ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
    public var seconds: Double { Double(numerator) / Double(denominator) }
    private enum CodingKeys: String, CodingKey { case numerator, denominator }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(Int64.self, forKey: .numerator), c.decode(Int64.self, forKey: .denominator))
    }
}

public struct TimeRange: Hashable, Codable, Sendable {
    public var start: RationalTime
    public var duration: RationalTime
    public init(start: RationalTime, duration: RationalTime) throws {
        guard start.numerator >= 0, duration.numerator > 0 else { throw EditorCoreError.invalidTime }
        _ = try start.adding(duration)
        self.start = start; self.duration = duration
    }
    public func end() throws -> RationalTime { try start.adding(duration) }
    public func overlaps(_ other: Self) throws -> Bool {
        try start.compared(to: other.end()) == .orderedAscending && other.start.compared(to: end()) == .orderedAscending
    }
    public func validate() throws { _ = try Self(start: start, duration: duration) }
    private enum CodingKeys: String, CodingKey { case start, duration }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(RationalTime.self, forKey: .start), duration: c.decode(RationalTime.self, forKey: .duration))
    }
}
