import EditorCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let filmConstructorProject = UTType(exportedAs: "com.aagedal.filmconstructor.project", conformingTo: .json)
}

struct ProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.filmConstructorProject] }
    var project: Project
    var mediaBookmarks: [UUID: Data]

    init(project: Project = Project(settings: try! SequenceSettings()), mediaBookmarks: [UUID: Data] = [:]) {
        self.project = project
        self.mediaBookmarks = mediaBookmarks
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }

    init(data: Data) throws {
        let header = try JSONDecoder().decode(VersionHeader.self, from: data)
        guard header.formatVersion == 1 else { throw ProjectFileError.unsupportedVersion(header.formatVersion) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try payload.project.validate()
        project = payload.project
        // Removed assets must not retain grants to unrelated files.
        let assetIDs = Set(project.assets.map(\.id))
        mediaBookmarks = payload.mediaBookmarks.filter { assetIDs.contains($0.key) }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try encodedData())
    }

    func encodedData() throws -> Data {
        try project.validate()
        let assetIDs = Set(project.assets.map(\.id))
        let payload = Payload(formatVersion: 1, project: project,
                              mediaBookmarks: mediaBookmarks.filter { assetIDs.contains($0.key) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Returns a persistent grant's URL; the editor must start and later stop scoped access.
    /// Updating stale grants here allows the next save to retain the refreshed bookmark.
    mutating func resolveMediaURL(for assetID: UUID) throws -> URL? {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return nil }
        guard let bookmark = mediaBookmarks[assetID] else { return project.assets[index].originalURL }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            mediaBookmarks[assetID] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                          includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        project.assets[index].originalURL = url
        return url
    }

    private struct VersionHeader: Decodable { var formatVersion: Int }
    private struct Payload: Codable {
        var formatVersion: Int
        var project: Project
        var mediaBookmarks: [UUID: Data]
    }
}

enum ProjectFileError: LocalizedError {
    case unsupportedVersion(Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This project uses unsupported file format version \(version)."
        }
    }
}
