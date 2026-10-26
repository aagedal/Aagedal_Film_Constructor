import Foundation

public enum TitlePosition: String, Codable, CaseIterable, Sendable {
    case top, center, lowerThird, bottom
}

/// Text drawn over the picture. The app renders it to a transparent PNG at the sequence
/// raster and references that image as the title asset's original, so render, preview,
/// thumbnails and interchange treat a title like any other still.
public struct TitleDefinition: Equatable, Codable, Sendable {
    public var text: String
    /// Cap height scale: point size as a fraction of the frame height.
    public var fontSize: Double
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var color: String
    public var position: TitlePosition
    public var bold: Bool
    /// A translucent black band behind the text for legibility.
    public var background: Bool
    public init(text: String = "Title", fontSize: Double = 0.07, color: String = "#FFFFFF",
                position: TitlePosition = .lowerThird, bold: Bool = true, background: Bool = false) {
        self.text = text; self.fontSize = fontSize; self.color = color
        self.position = position; self.bold = bold; self.background = background
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000,
              fontSize.isFinite, (0.01...0.5).contains(fontSize), rgba != nil else {
            throw EditorCoreError.invalidModel("A title needs text (up to 2000 characters), a size from 1% to 50% of the frame height and a #RRGGBB colour")
        }
    }
    /// Components in 0...1, or nil for an invalid colour.
    public var rgba: (red: Double, green: Double, blue: Double, alpha: Double)? {
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let full = hex.count == 6 ? value << 8 | 0xFF : value
        return (Double(full >> 24 & 0xFF) / 255, Double(full >> 16 & 0xFF) / 255,
                Double(full >> 8 & 0xFF) / 255, Double(full & 0xFF) / 255)
    }
    /// A short bin name from the first line of text.
    public var displayName: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return "Title: " + (line.count > 40 ? String(line.prefix(39)) + "…" : line)
    }
}

public extension Project {
    static let titleFamilyName = "Titles"

    /// Adds a title asset and places it for the default still duration at `start`, on a
    /// Titles track in front of all other pictures. Returns the new clip's ID.
    @discardableResult
    mutating func addTitle(_ title: TitleDefinition, imageURL: URL, at start: RationalTime, assetID: UUID = UUID()) throws -> UUID {
        try title.validate()
        var asset = MediaAsset(id: assetID, name: title.displayName, originalURL: imageURL, duration: try MediaAsset.stillSourceExtent())
        asset.title = title
        try addAsset(asset)
        let family: TrackFamily
        if let existing = families.first(where: { $0.baseName == Self.titleFamilyName && $0.template.kind == .video }) {
            family = existing
        } else {
            family = TrackFamily(baseName: Self.titleFamilyName, template: TrackTemplate(kind: .video))
            families.append(family)
        }
        if !tracks.contains(where: { $0.familyID == family.id }) {
            tracks.insert(TimelineTrack(familyID: family.id, template: family.template), at: 0)
        }
        let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: .zero, duration: MediaAsset.defaultStillDuration()),
                                timelineStart: start, selection: .still)
        var engine = try TimelineEditEngine(project: self)
        try engine.apply(.placeInFamily(clip: clip, familyID: family.id))
        self = engine.project
        return clip.id
    }

    /// Changes a title's text or style and points it at the re-rendered image.
    mutating func updateTitle(assetID: UUID, to title: TitleDefinition, imageURL: URL) throws {
        try title.validate()
        guard let index = assets.firstIndex(where: { $0.id == assetID }), assets[index].title != nil else {
            throw EditorCoreError.invalidModel("The title no longer exists")
        }
        assets[index].title = title
        assets[index].name = title.displayName
        assets[index].originalURL = imageURL
        try validate()
    }
}
