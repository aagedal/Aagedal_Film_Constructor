import Foundation

public enum MarkerColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink
}

/// A named point on the sequence. Markers stay at their sequence time when clips move,
/// ripple or are inserted around them.
public struct SequenceMarker: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var time: RationalTime
    public var name: String
    public var note: String
    public var color: MarkerColor

    public init(id: UUID = UUID(), time: RationalTime, name: String, note: String = "", color: MarkerColor = .blue) {
        self.id = id; self.time = time; self.name = name; self.note = note; self.color = color
    }
    private enum CodingKeys: String, CodingKey { case id, time, name, note, color }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), time: try c.decode(RationalTime.self, forKey: .time),
                  name: try c.decode(String.self, forKey: .name), note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  color: try c.decodeIfPresent(MarkerColor.self, forKey: .color) ?? .blue)
    }
}

public extension Project {
    /// A name not yet used by a marker on the open sequence: "Marker 1", "Marker 2"…
    var nextMarkerName: String {
        let names = Set(markers.map(\.name))
        var number = markers.count + 1
        while names.contains("Marker \(number)") { number += 1 }
        return "Marker \(number)"
    }

    /// Adds a marker; one marker per sequence time.
    @discardableResult
    mutating func addMarker(at time: RationalTime, name: String? = nil, color: MarkerColor = .blue, id: UUID = UUID()) throws -> UUID {
        guard try !markers.contains(where: { try $0.time.compared(to: time) == .orderedSame }) else {
            throw EditorCoreError.invalidModel("A marker already exists at this time")
        }
        var candidate = self
        candidate.markers.append(SequenceMarker(id: id, time: time, name: name ?? nextMarkerName, color: color))
        try candidate.sortMarkers()
        try candidate.validateMarkers()
        self = candidate
        return id
    }

    mutating func updateMarker(id: UUID, name: String, note: String, color: MarkerColor) throws {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing marker") }
        var candidate = self
        candidate.markers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.markers[index].note = note
        candidate.markers[index].color = color
        try candidate.validateMarkers()
        self = candidate
    }

    mutating func moveMarker(id: UUID, to time: RationalTime) throws {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing marker") }
        guard try !markers.contains(where: { try $0.id != id && $0.time.compared(to: time) == .orderedSame }) else {
            throw EditorCoreError.invalidModel("A marker already exists at this time")
        }
        var candidate = self
        candidate.markers[index].time = time
        try candidate.sortMarkers()
        try candidate.validateMarkers()
        self = candidate
    }

    mutating func removeMarker(id: UUID) throws {
        guard markers.contains(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing marker") }
        markers.removeAll { $0.id == id }
    }

    /// The first marker after (or, backwards, before) the given time.
    func marker(after time: RationalTime, forward: Bool) throws -> SequenceMarker? {
        forward ? try markers.first { try $0.time.compared(to: time) == .orderedDescending }
                : try markers.last { try $0.time.compared(to: time) == .orderedAscending }
    }

    /// Every cut on the open sequence: the start and end of each clip on every track, and zero.
    var editPoints: [RationalTime] {
        get throws {
            var points: Set<RationalTime> = [.zero]
            for clip in tracks.flatMap(\.clips) {
                let range = try clip.timelineRange()
                points.insert(range.start); points.insert(try range.end())
            }
            return try points.sorted { try $0.compared(to: $1) == .orderedAscending }
        }
    }

    /// The next (or, backwards, previous) cut from the given time.
    func editPoint(after time: RationalTime, forward: Bool) throws -> RationalTime? {
        let points = try editPoints
        return forward ? try points.first { try $0.compared(to: time) == .orderedDescending }
                       : try points.last { try $0.compared(to: time) == .orderedAscending }
    }

    func validateMarkers() throws {
        guard Set(markers.map(\.id)).count == markers.count else { throw EditorCoreError.invalidModel("Duplicate marker identity") }
        for (index, marker) in markers.enumerated() {
            guard marker.time.numerator >= 0 else { throw EditorCoreError.invalidModel("Markers cannot lie before the sequence start") }
            if index > 0, try markers[index - 1].time.compared(to: marker.time) != .orderedAscending {
                throw EditorCoreError.invalidModel("Markers must be in time order with one marker per time")
            }
        }
    }

    private mutating func sortMarkers() throws {
        markers = try markers.sorted { try $0.time.compared(to: $1.time) == .orderedAscending }
    }
}
