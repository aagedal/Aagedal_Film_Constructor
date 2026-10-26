import Foundation

/// A sequence that is not open: its settings and timeline, kept whole until it is opened.
public struct StoredSequence: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: SequenceSettings
    public var families: [TrackFamily]
    public var tracks: [TimelineTrack]
    public var audioCrossfades: [AudioCrossfade]

    public init(id: UUID = UUID(), name: String, settings: SequenceSettings, families: [TrackFamily] = [],
                tracks: [TimelineTrack] = [], audioCrossfades: [AudioCrossfade] = []) {
        self.id = id; self.name = name; self.settings = settings
        self.families = families; self.tracks = tracks; self.audioCrossfades = audioCrossfades
    }
}

public extension Project {
    /// Fixed so a new, untouched document always equals another one.
    static let defaultSequenceID = UUID(uuidString: "5E9E7C3A-0000-4000-8000-000000000001")!
    static let defaultSequenceName = "Sequence 1"

    struct SequenceSummary: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let isOpen: Bool
        public let binID: UUID?
    }

    /// Every sequence, open or stored, by name.
    var sequenceSummaries: [SequenceSummary] {
        ([SequenceSummary(id: sequenceID, name: sequenceName, isOpen: true, binID: sequenceBinAssignments[sequenceID])]
         + storedSequences.map { SequenceSummary(id: $0.id, name: $0.name, isOpen: false, binID: sequenceBinAssignments[$0.id]) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A name not yet used by any sequence: "Sequence 2", "Sequence 3"…
    var nextSequenceName: String {
        let names = Set(sequenceSummaries.map(\.name))
        var number = sequenceSummaries.count + 1
        while names.contains("Sequence \(number)") { number += 1 }
        return "Sequence \(number)"
    }

    /// Stores the open sequence and opens a new, empty one with the given settings.
    @discardableResult
    mutating func createSequence(name: String, settings: SequenceSettings, binID: UUID? = nil) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = self
        candidate.storeOpenSequence()
        candidate.sequenceID = UUID()
        candidate.sequenceName = trimmed
        candidate.settings = settings
        candidate.families = []; candidate.tracks = []; candidate.audioCrossfades = []
        candidate.sequenceBinAssignments[candidate.sequenceID] = binID
        try candidate.validate()
        self = candidate
        return candidate.sequenceID
    }

    /// Stores the open sequence and opens the given one in its place.
    mutating func openSequence(id: UUID) throws {
        guard id != sequenceID else { return }
        guard let stored = storedSequences.first(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing sequence") }
        var candidate = self
        candidate.storeOpenSequence()
        candidate.storedSequences.removeAll { $0.id == id }
        candidate.sequenceID = stored.id; candidate.sequenceName = stored.name
        candidate.settings = stored.settings; candidate.families = stored.families
        candidate.tracks = stored.tracks; candidate.audioCrossfades = stored.audioCrossfades
        try candidate.validate()
        self = candidate
    }

    mutating func renameSequence(id: UUID, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = self
        if id == sequenceID { candidate.sequenceName = trimmed }
        else if let index = candidate.storedSequences.firstIndex(where: { $0.id == id }) { candidate.storedSequences[index].name = trimmed }
        else { throw EditorCoreError.invalidModel("Missing sequence") }
        try candidate.validate()
        self = candidate
    }

    /// Removes a sequence. Removing the open one opens the next by name; the last one stays.
    mutating func removeSequence(id: UUID) throws {
        guard !storedSequences.isEmpty else { throw EditorCoreError.invalidModel("A project keeps at least one sequence") }
        var candidate = self
        if id == sequenceID {
            let summaries = sequenceSummaries
            let index = summaries.firstIndex { $0.id == id }!
            let next = summaries[index + 1 < summaries.count ? index + 1 : index - 1]
            try candidate.openSequence(id: next.id)
        }
        guard candidate.storedSequences.contains(where: { $0.id == id }) else { throw EditorCoreError.invalidModel("Missing sequence") }
        candidate.storedSequences.removeAll { $0.id == id }
        candidate.sequenceBinAssignments[id] = nil
        try candidate.validate()
        self = candidate
    }

    mutating func moveSequences(_ ids: Set<UUID>, toMediaBin binID: UUID?) throws {
        let known = Set(sequenceSummaries.map(\.id))
        guard ids.isSubset(of: known), binID.map({ id in mediaBins.contains { $0.id == id } }) ?? true else {
            throw EditorCoreError.invalidModel("Missing sequence or destination bin")
        }
        var candidate = self
        for id in ids { candidate.sequenceBinAssignments[id] = binID }
        try candidate.validate()
        self = candidate
    }

    /// Each stored sequence must be a valid timeline over the project's media.
    func validateSequences() throws {
        let ids = [sequenceID] + storedSequences.map(\.id)
        guard Set(ids).count == ids.count else { throw EditorCoreError.invalidModel("Duplicate sequence identity") }
        guard !sequenceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              storedSequences.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EditorCoreError.invalidModel("Empty sequence name")
        }
        let bins = Set(mediaBins.map(\.id)), known = Set(ids)
        guard sequenceBinAssignments.allSatisfy({ known.contains($0.key) && bins.contains($0.value) }) else {
            throw EditorCoreError.invalidModel("Sequence bin assignment references a missing sequence or bin")
        }
        for stored in storedSequences {
            try Project(settings: stored.settings, assets: assets, families: stored.families, tracks: stored.tracks,
                        preferences: preferences, audioCrossfades: stored.audioCrossfades).validate()
        }
    }

    private mutating func storeOpenSequence() {
        storedSequences.append(StoredSequence(id: sequenceID, name: sequenceName, settings: settings, families: families,
                                              tracks: tracks, audioCrossfades: audioCrossfades))
    }
}
