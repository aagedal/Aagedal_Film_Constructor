import Foundation

/// Organization only: bin moves never change media identity, URLs or timeline edits.
public struct MediaBin: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

public extension Project {
    func validateMediaBins() throws {
        let ids = Set(mediaBins.map(\.id))
        guard ids.count == mediaBins.count else { throw EditorCoreError.invalidModel("Duplicate media bin identity") }
        let bins = Dictionary(uniqueKeysWithValues: mediaBins.map { ($0.id, $0) })
        var checked: Set<UUID> = []
        for bin in mediaBins {
            guard !bin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bin.parentID.map({ ids.contains($0) }) ?? true else {
                throw EditorCoreError.invalidModel("Empty media bin name or missing parent")
            }
            var path: Set<UUID> = []
            var cursor: UUID? = bin.id
            while let id = cursor, !checked.contains(id) {
                guard path.insert(id).inserted else { throw EditorCoreError.invalidModel("Media bin cycle") }
                cursor = bins[id]?.parentID
            }
            checked.formUnion(path)
        }
        let assets = Set(assets.map(\.id))
        guard assetBinAssignments.allSatisfy({ assets.contains($0.key) && ids.contains($0.value) }) else {
            throw EditorCoreError.invalidModel("Media bin assignment references missing media or bin")
        }
    }

    @discardableResult
    mutating func createMediaBin(name: String, parentID: UUID? = nil) throws -> UUID {
        let bin = MediaBin(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID)
        var candidate = self
        candidate.mediaBins.append(bin)
        try candidate.validate()
        self = candidate
        return bin.id
    }

    mutating func updateMediaBin(id: UUID, name: String, parentID: UUID?) throws {
        var candidate = self
        guard let index = candidate.mediaBins.firstIndex(where: { $0.id == id }) else {
            throw EditorCoreError.invalidModel("Missing media bin")
        }
        candidate.mediaBins[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.mediaBins[index].parentID = parentID
        try candidate.validate()
        self = candidate
    }

    mutating func moveAssets(_ assetIDs: Set<UUID>, toMediaBin binID: UUID?) throws {
        guard assetIDs.isSubset(of: Set(assets.map(\.id))),
              binID.map({ id in mediaBins.contains { $0.id == id } }) ?? true else {
            throw EditorCoreError.invalidModel("Missing media or destination bin")
        }
        var candidate = self
        for id in assetIDs { candidate.assetBinAssignments[id] = binID }
        try candidate.validate()
        self = candidate
    }

    /// Dissolve this folder, promoting its media and child folders to its parent.
    mutating func removeMediaBin(id: UUID) throws {
        guard let bin = mediaBins.first(where: { $0.id == id }) else {
            throw EditorCoreError.invalidModel("Missing media bin")
        }
        var candidate = self
        candidate.mediaBins.removeAll { $0.id == id }
        for index in candidate.mediaBins.indices where candidate.mediaBins[index].parentID == id {
            candidate.mediaBins[index].parentID = bin.parentID
        }
        for assetID in assetBinAssignments.keys where assetBinAssignments[assetID] == id {
            candidate.assetBinAssignments[assetID] = bin.parentID
        }
        for sequenceID in sequenceBinAssignments.keys where sequenceBinAssignments[sequenceID] == id {
            candidate.sequenceBinAssignments[sequenceID] = bin.parentID
        }
        try candidate.validate()
        self = candidate
    }

    func mediaBinPath(id: UUID) -> String {
        let bins = Dictionary(mediaBins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = [], visited: Set<UUID> = []
        var cursor: UUID? = id
        while let current = cursor, visited.insert(current).inserted, let bin = bins[current] {
            names.append(bin.name)
            cursor = bin.parentID
        }
        return names.reversed().joined(separator: " / ")
    }
}
