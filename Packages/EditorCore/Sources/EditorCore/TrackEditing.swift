import Foundation

extension Project {
    /// Empty custom names restore automatic family numbering.
    public mutating func renameTrack(id: UUID, name: String) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingTrack }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[index].customName = trimmed.isEmpty ? nil : trimmed
    }

    /// Family naming never overwrites independently named siblings.
    public mutating func renameTrackFamily(id: UUID, name: String) throws {
        guard let index = families.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingFamily }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorCoreError.invalidModel("Enter a track family name.") }
        families[index].baseName = trimmed
    }

    public mutating func setTrackRetention(id: UUID, retained: Bool) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingTrack }
        tracks[index].retained = retained
        if !retained && preferences.automaticallyRemoveEmptyTracks && tracks[index].clips.isEmpty {
            tracks.remove(at: index)
        }
    }

    /// Linear amplitude, including zero for silence. Existing siblings remain independent.
    public mutating func setTrackGain(id: UUID, gain: Double) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.missingTrack }
        guard tracks[index].kind == .audio, gain.isFinite, gain >= 0 else {
            throw EditorCoreError.invalidModel("Audio gain must be a finite, nonnegative amplitude.")
        }
        tracks[index].template.gain = gain
    }
}
