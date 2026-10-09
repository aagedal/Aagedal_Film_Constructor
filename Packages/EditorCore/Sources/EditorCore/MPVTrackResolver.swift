import Foundation

/// The relevant subset of MPV's runtime `track-list`. Other MPV properties are ignored.
/// `type` remains a string because the list can also contain subtitle tracks.
public struct MPVTrackListEntry: Equatable, Codable, Sendable {
    public let id: Int
    public let type: String
    public let ffIndex: Int?
    public let external: Bool
    public let externalFilename: String?

    public init(id: Int, type: String, ffIndex: Int? = nil, external: Bool = false, externalFilename: String? = nil) {
        self.id = id
        self.type = type
        self.ffIndex = ffIndex
        self.external = external
        self.externalFilename = externalFilename
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, external
        case ffIndex = "ff-index"
        case externalFilename = "external-filename"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        ffIndex = try values.decodeIfPresent(Int.self, forKey: .ffIndex)
        external = try values.decodeIfPresent(Bool.self, forKey: .external) ?? false
        externalFilename = try values.decodeIfPresent(String.self, forKey: .externalFilename)
    }
}

public enum MPVTrackResolver {
    /// `ff-index` denotes a container stream index only with the libavformat
    /// demuxer. The caller must load the primary and external files with lavf and
    /// attest that contract here; enumeration order is never a substitute.
    /// File identity uses absolute, standardized paths, without resolving symlinks.
    public static func resolve(inputs: [RenderSourceInput], trackList: [MPVTrackListEntry], primaryURL: URL, demuxer: String) throws -> [MPVTrackBinding] {
        guard demuxer == "lavf" else {
            throw EditorCoreError.invalidModel("MPV track resolution requires the libavformat (lavf) demuxer for every source")
        }
        let primary = try identity(primaryURL)
        var bindings: [MPVTrackBinding] = []
        var sources: [RenderSourceInput] = []
        var labels: Set<String> = []
        for source in inputs {
            guard source.streamIndex >= 0 else {
                throw EditorCoreError.invalidModel("Invalid MPV source stream index")
            }
            if sources.contains(source) { continue }
            let sourceURL = try identity(source.url)
            var candidates: [MPVTrackListEntry] = []
            for entry in trackList where entry.type == source.kind.rawValue {
                let entryURL: URL
                if entry.external {
                    guard let filename = entry.externalFilename, !filename.isEmpty else {
                        throw EditorCoreError.invalidModel("External MPV track has no explicit filename")
                    }
                    entryURL = try filenameIdentity(filename)
                } else {
                    guard entry.externalFilename == nil else {
                        throw EditorCoreError.invalidModel("Internal MPV track unexpectedly has an external filename")
                    }
                    entryURL = primary
                }
                guard entryURL == sourceURL else { continue }
                guard entry.id > 0, let ffIndex = entry.ffIndex, ffIndex >= 0 else {
                    throw EditorCoreError.invalidModel("MPV source track requires a positive ID and explicit nonnegative ff-index")
                }
                if ffIndex == source.streamIndex { candidates.append(entry) }
            }
            guard candidates.count == 1, let match = candidates.first else {
                throw EditorCoreError.invalidModel("Missing or ambiguous MPV track for \(source.kind.rawValue) stream \(source.streamIndex) at \(source.url)")
            }
            let label = "\(source.kind.rawValue):\(match.id)"
            guard labels.insert(label).inserted else {
                throw EditorCoreError.invalidModel("MPV track ID aliases different source streams")
            }
            sources.append(source)
            bindings.append(MPVTrackBinding(url: source.url, streamIndex: source.streamIndex, kind: source.kind, trackID: match.id))
        }
        return bindings
    }

    private static func identity(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost" else {
            throw EditorCoreError.invalidModel("MPV proof track resolution requires absolute local file URLs")
        }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    private static func filenameIdentity(_ filename: String) throws -> URL {
        if filename.hasPrefix("/") { return try identity(URL(fileURLWithPath: filename)) }
        guard let url = URL(string: filename), url.isFileURL else {
            throw EditorCoreError.invalidModel("MPV external filename must be an absolute path or file URL")
        }
        return try identity(url)
    }
}
