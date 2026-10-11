import Foundation

public enum ProxyGenerationJobState: String, Codable, Sendable {
    case queued, running, interrupted, cancelled, failed, completed
    public var canResume: Bool { self != .completed && self != .running }
}

/// Operational state is persisted separately from timeline editing and its undo history.
public struct ProxyGenerationJob: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var sourceSnapshot: MediaAsset
    public var sourceFingerprint: MediaSourceFingerprint
    public var preset: ProxyPreset
    public var scaleDivisor: Int
    public var outputURL: URL
    public var outputFolderBookmark: Data?
    public var state: ProxyGenerationJobState
    public var message: String?
    /// Saved before publication, allowing exact-byte recovery after an interrupted registration.
    public var verifiedProxy: MediaProxy?
    public init(id: UUID = UUID(), sourceSnapshot: MediaAsset, sourceFingerprint: MediaSourceFingerprint,
                preset: ProxyPreset, scaleDivisor: Int, outputURL: URL, outputFolderBookmark: Data? = nil,
                state: ProxyGenerationJobState = .queued, message: String? = nil, verifiedProxy: MediaProxy? = nil) {
        self.id = id; self.sourceSnapshot = sourceSnapshot; self.sourceFingerprint = sourceFingerprint
        self.preset = preset; self.scaleDivisor = scaleDivisor; self.outputURL = outputURL
        self.outputFolderBookmark = outputFolderBookmark; self.state = state; self.message = message
        self.verifiedProxy = verifiedProxy
    }
    public func validate() throws {
        try sourceFingerprint.validate()
        guard let source = sourceSnapshot.originalURL, source.isFileURL,
              sourceSnapshot.duration.numerator > 0, sourceSnapshot.streams.contains(where: { $0.kind == .video }),
              [1, 2, 4].contains(scaleDivisor), outputURL.isFileURL,
              outputURL.host == nil || outputURL.host == "" || outputURL.host == "localhost",
              outputURL.query == nil, outputURL.fragment == nil,
              outputURL.user == nil, outputURL.password == nil, outputURL.port == nil,
              outputURL.path.hasPrefix("/"), outputURL.path != "/",
              outputURL.pathExtension.lowercased() == "mov",
              source.standardizedFileURL != outputURL.standardizedFileURL else {
            throw EditorCoreError.invalidModel("Invalid proxy generation job")
        }
        if let proxy = verifiedProxy {
            try proxy.validate()
            guard proxy.url == outputURL, proxy.preset == preset, proxy.sourceFingerprint == sourceFingerprint,
                  proxy.outputIntegrity != nil,
                  sourceSnapshot.streams.first(where: { $0.kind == .video })?.index == proxy.videoStreamIndex else {
                throw EditorCoreError.invalidModel("Proxy queue publication metadata does not match its job")
            }
        }
        guard state != .completed || verifiedProxy != nil else {
            throw EditorCoreError.invalidModel("Completed proxy job has no verified rendition")
        }
    }
    public func matchesSource(_ asset: MediaAsset, fingerprint: MediaSourceFingerprint) -> Bool {
        asset.id == sourceSnapshot.id && asset.originalURL == sourceSnapshot.originalURL &&
        asset.duration == sourceSnapshot.duration && asset.streams == sourceSnapshot.streams &&
        fingerprint == sourceFingerprint
    }
    public mutating func prepareAfterReopen() {
        if state == .running {
            state = .interrupted
            message = "Interrupted. Resume manually to validate any published proxy or continue generation."
        }
    }
}
