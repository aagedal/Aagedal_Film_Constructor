import Foundation

extension Project {
    /// Explicit first-picture matching. Never reinterpret an existing edit or
    /// guess which of several video streams the user intended to use.
    public mutating func matchSequence(to assetID: UUID, streamIndex: Int) throws {
        guard tracks.allSatisfy({ $0.clips.isEmpty }) else {
            throw EditorCoreError.invalidModel("Match source before adding timeline clips")
        }
        guard let asset = assets.first(where: { $0.id == assetID }),
              let stream = asset.streams.first(where: { $0.index == streamIndex && $0.kind == .video }),
              let format = stream.videoFormat else {
            throw EditorCoreError.invalidModel("This source has no qualified constant-frame-rate picture format")
        }
        try format.validate()
        var candidate = self
        candidate.settings.width = format.width
        candidate.settings.height = format.height
        candidate.settings.frameRate = format.frameRate
        // Audio routing and start timecode remain explicit user choices. A DF
        // timecode incompatible with the source rate rejects the entire edit.
        try candidate.validate()
        self = candidate
    }
}
