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
    var proxyBookmarks: [UUID: Data]
    var proxyJobs: [ProxyGenerationJob]

    init(project: Project = Project(settings: try! SequenceSettings()), mediaBookmarks: [UUID: Data] = [:], proxyBookmarks: [UUID: Data] = [:], proxyJobs: [ProxyGenerationJob] = []) {
        self.project = project
        self.mediaBookmarks = mediaBookmarks
        self.proxyBookmarks = proxyBookmarks
        self.proxyJobs = proxyJobs
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
        try Self.validateJobs(payload.proxyJobs ?? [])
        proxyJobs = payload.proxyJobs ?? []
        project = payload.project
        // Removed assets must not retain grants to unrelated files.
        let assetIDs = Set(project.assets.map(\.id))
        mediaBookmarks = payload.mediaBookmarks.filter { assetIDs.contains($0.key) }
        let proxyAssetIDs = Set(project.assets.filter { $0.proxy != nil }.map(\.id))
        proxyBookmarks = (payload.proxyBookmarks ?? [:]).filter { proxyAssetIDs.contains($0.key) }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try encodedData())
    }

    func encodedData() throws -> Data {
        try project.validate()
        try Self.validateJobs(proxyJobs)
        let assetIDs = Set(project.assets.map(\.id))
        let payload = Payload(formatVersion: 1, project: project,
                              mediaBookmarks: mediaBookmarks.filter { assetIDs.contains($0.key) },
                              proxyBookmarks: proxyBookmarks.filter { id, _ in project.assets.contains { $0.id == id && $0.proxy != nil } },
                              proxyJobs: proxyJobs)
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

    /// Proxy grants are independent of originals, so replacing either representation
    /// cannot redirect the other when the project is reopened.
    mutating func resolveProxyURL(for assetID: UUID) throws -> URL? {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }),
              project.assets[index].proxy != nil else { return nil }
        guard let bookmark = proxyBookmarks[assetID] else { return project.assets[index].proxy?.url }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            proxyBookmarks[assetID] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        project.assets[index].proxy?.url = url
        return url
    }

    private static func validateJobs(_ jobs: [ProxyGenerationJob]) throws {
        guard Set(jobs.map(\.id)).count == jobs.count,
              Set(jobs.map { $0.outputURL.standardizedFileURL }).count == jobs.count else {
            throw EditorCoreError.invalidModel("Duplicate proxy queue job identity or destination")
        }
        for job in jobs { try job.validate() }
    }

    private struct VersionHeader: Decodable { var formatVersion: Int }
    private struct Payload: Codable {
        var formatVersion: Int
        var project: Project
        var mediaBookmarks: [UUID: Data]
        var proxyBookmarks: [UUID: Data]?
        var proxyJobs: [ProxyGenerationJob]?
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
