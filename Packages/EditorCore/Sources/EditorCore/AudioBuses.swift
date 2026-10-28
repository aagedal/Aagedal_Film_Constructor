import Foundation

/// A mix bus in the sequence's channel layout, as in Resolve's Fairlight buses. Main buses
/// are outputs: the render's sound is the first main bus, and multi-track exports write
/// each main bus as its own stream. Submix buses gather tracks and feed main buses.
nonisolated public struct AudioBus: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case main, submix }
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Linear fader gain applied after the bus's effects.
    public var gain: Double
    public var muted: Bool
    public var effects: [AudioEffect]
    /// Main buses a submix feeds; empty sends it to the first main bus. Ignored for mains.
    public var outputs: [UUID]
    public init(id: UUID = UUID(), name: String, kind: Kind, gain: Double = 1, muted: Bool = false, effects: [AudioEffect] = [], outputs: [UUID] = []) {
        self.id = id; self.name = name; self.kind = kind; self.gain = gain; self.muted = muted; self.effects = effects; self.outputs = outputs
    }
    /// The main bus every sequence has until buses are added; fixed so untouched documents
    /// stay equal.
    public static let defaultMainID = UUID(uuidString: "5E9E7C3A-0000-4000-8000-0000000000B1")!
    public static var defaultMain: AudioBus { AudioBus(id: defaultMainID, name: "Main 1", kind: .main) }
}

public extension Project {
    /// The sequence's buses with a main bus always first.
    var mixBuses: [AudioBus] {
        let mains = buses.filter { $0.kind == .main }
        return (mains.isEmpty ? [AudioBus.defaultMain] : mains) + buses.filter { $0.kind == .submix }
    }
    var mainBuses: [AudioBus] { mixBuses.filter { $0.kind == .main } }
    /// Where a bus or track with these outputs sends its sound: the listed buses, or the first main.
    func resolvedOutputs(_ outputs: [UUID]) -> [UUID] {
        let known = Set(mixBuses.map(\.id))
        let listed = outputs.filter { known.contains($0) }
        return listed.isEmpty ? [mainBuses[0].id] : listed
    }

    func validateBuses() throws {
        let all = mixBuses
        guard Set(all.map(\.id)).count == all.count, all.count <= 64 else { throw EditorCoreError.invalidModel("Duplicate or too many buses") }
        let mains = Set(all.filter { $0.kind == .main }.map(\.id)), ids = Set(all.map(\.id))
        for bus in all {
            guard !bus.name.trimmingCharacters(in: .whitespaces).isEmpty, bus.gain.isFinite, bus.gain >= 0, bus.gain <= 16, bus.effects.count <= 16 else {
                throw EditorCoreError.invalidModel("A bus needs a name, gain up to +24 dB and at most 16 effects")
            }
            try bus.effects.forEach { try $0.validate() }
            // Submixes feed mains only, so routing never loops.
            guard bus.outputs.allSatisfy(mains.contains), bus.kind == .submix || bus.outputs.isEmpty else {
                throw EditorCoreError.invalidModel("Submix buses feed main buses")
            }
        }
        for track in tracks {
            guard track.template.busOutputs.allSatisfy(ids.contains) else { throw EditorCoreError.invalidModel("A track sends to a missing bus") }
            guard track.kind == .audio || (track.template.busOutputs.isEmpty && track.template.effects.isEmpty) else {
                throw EditorCoreError.invalidModel("Video tracks have no audio effects or buses")
            }
            guard track.template.effects.count <= 16 else { throw EditorCoreError.invalidModel("A track has at most 16 effects") }
            try track.template.effects.forEach { try $0.validate() }
        }
    }

    /// Adds a bus named "Main 2", "Submix 1"… and returns its identity. The implicit first
    /// main bus is kept as a real bus so its identity stays stable.
    @discardableResult
    mutating func addBus(kind: AudioBus.Kind) throws -> UUID {
        var candidate = self
        candidate.materialiseBuses()
        let prefix = kind == .main ? "Main" : "Submix"
        let names = Set(candidate.buses.map(\.name))
        var number = candidate.buses.filter { $0.kind == kind }.count + 1
        while names.contains("\(prefix) \(number)") { number += 1 }
        let bus = AudioBus(name: "\(prefix) \(number)", kind: kind)
        candidate.buses.append(bus)
        try candidate.validate()
        self = candidate
        return bus.id
    }

    /// Removes a bus; tracks and submixes that sent to it fall back to the first main bus.
    /// The last main bus stays.
    mutating func removeBus(id: UUID) throws {
        var candidate = self
        candidate.materialiseBuses()
        guard let bus = candidate.buses.first(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing bus") }
        guard bus.kind == .submix || candidate.buses.filter({ $0.kind == .main }).count > 1 else {
            throw EditorCoreError.invalidModel("A sequence keeps at least one main bus")
        }
        candidate.buses.removeAll { $0.id == id }
        for index in candidate.buses.indices { candidate.buses[index].outputs.removeAll { $0 == id } }
        for index in candidate.tracks.indices { candidate.tracks[index].template.busOutputs.removeAll { $0 == id } }
        try candidate.validate()
        self = candidate
    }

    /// Edits a bus in place, materialising the implicit main bus first.
    mutating func updateBus(id: UUID, _ change: (inout AudioBus) -> Void) throws {
        var candidate = self
        candidate.materialiseBuses()
        guard let index = candidate.buses.firstIndex(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing bus") }
        change(&candidate.buses[index])
        candidate.buses[index].name = candidate.buses[index].name.trimmingCharacters(in: .whitespaces)
        try candidate.validate()
        self = candidate
    }

    mutating func setTrackBusOutputs(id: UUID, outputs: [UUID]) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingTrack }
        var candidate = self
        // Sending only to the first main bus is the default.
        candidate.tracks[index].template.busOutputs = outputs == [mainBuses[0].id] ? [] : outputs
        try candidate.validate()
        self = candidate
    }

    mutating func setTrackEffects(id: UUID, effects: [AudioEffect]) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingTrack }
        var candidate = self
        candidate.tracks[index].template.effects = effects
        try candidate.validate()
        self = candidate
    }

    private mutating func materialiseBuses() {
        if !buses.contains(where: { $0.kind == .main }) { buses.insert(.defaultMain, at: 0) }
    }
}

/// How the sequence's tracks and buses combine, for render and preview. Muted and
/// unsoloed tracks are absent; muted buses pass nothing on.
public struct AudioMixPlan: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let effects: [AudioEffect]
        public let outputs: [UUID]
    }
    public let tracks: [Track]
    public let buses: [AudioBus]
    public var mains: [AudioBus] { buses.filter { $0.kind == .main } }
    public var submixes: [AudioBus] { buses.filter { $0.kind == .submix } }

    init(project: Project, includedTrackIDs: Set<UUID>) {
        buses = project.mixBuses
        tracks = project.tracks.filter { $0.kind == .audio && includedTrackIDs.contains($0.id) }.map {
            Track(id: $0.id, name: $0.displayName(in: project), effects: $0.template.effects.filter(\.isActive),
                  outputs: project.resolvedOutputs($0.template.busOutputs))
        }
    }

    /// A single unprocessed main bus fed directly by every track: the plain sum.
    public var isPlainSum: Bool {
        buses.count == 1 && buses.allSatisfy { !$0.muted && $0.gain == 1 && !$0.effects.contains(where: \.isActive) }
            && tracks.allSatisfy { $0.effects.isEmpty }
    }

    /// One way a track reaches a main bus: the effect chains and fader gains after the
    /// track's own effects, in order.
    public struct Path: Equatable, Sendable {
        public let main: UUID
        public let stages: [(bus: UUID, effects: [AudioEffect], gain: Double)]
        public static func == (a: Path, b: Path) -> Bool {
            a.main == b.main && a.stages.count == b.stages.count
                && zip(a.stages, b.stages).allSatisfy { $0.bus == $1.bus && $0.effects == $1.effects && $0.gain == $1.gain }
        }
        /// Whether the path passes sound unchanged.
        public var isTransparent: Bool { stages.allSatisfy { $0.effects.isEmpty && $0.gain == 1 } }
    }
    /// Every route from a track to a main bus, through submixes, skipping muted buses.
    public func paths(from trackID: UUID) -> [Path] {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: buses.map { ($0.id, $0) })
        func stage(_ bus: AudioBus) -> (bus: UUID, effects: [AudioEffect], gain: Double) { (bus.id, bus.effects.filter(\.isActive), bus.gain) }
        var result: [Path] = []
        for output in track.outputs {
            guard let bus = byID[output], !bus.muted else { continue }
            if bus.kind == .main { result.append(Path(main: bus.id, stages: [stage(bus)])); continue }
            let targets = bus.outputs.isEmpty ? [self.mains[0].id] : bus.outputs
            for main in targets {
                guard let target = byID[main], !target.muted else { continue }
                result.append(Path(main: main, stages: [stage(bus), stage(target)]))
            }
        }
        return result
    }
}
