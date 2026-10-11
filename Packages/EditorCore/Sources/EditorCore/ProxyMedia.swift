import Foundation

public enum ProxyPreset: String, Codable, CaseIterable, Sendable { case proResProxy, h264 }

/// File metadata recorded when generating a proxy. The application supplies current metadata.
public struct MediaSourceFingerprint: Equatable, Codable, Sendable {
    public var fileSize: Int64
    public var modificationTime: Double
    public init(fileSize: Int64, modificationTime: Double) {
        self.fileSize = fileSize; self.modificationTime = modificationTime
    }
    public func validate() throws {
        guard fileSize >= 0, modificationTime.isFinite else {
            throw EditorCoreError.invalidModel("Invalid proxy source fingerprint")
        }
    }
}

/// Derived video media; original source coordinates remain authoritative for editing and export.
public struct MediaProxy: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var url: URL
    public var preset: ProxyPreset
    public var sourceFingerprint: MediaSourceFingerprint
    /// The original source's selected video stream, not the proxy's stream index.
    public var videoStreamIndex: Int
    public var width: Int
    public var height: Int
    public var frameRate: RationalTime
    public var frameCount: Int64
    public init(id: UUID = UUID(), url: URL, preset: ProxyPreset, sourceFingerprint: MediaSourceFingerprint,
                videoStreamIndex: Int, width: Int, height: Int, frameRate: RationalTime, frameCount: Int64) {
        self.id = id; self.url = url; self.preset = preset; self.sourceFingerprint = sourceFingerprint
        self.videoStreamIndex = videoStreamIndex; self.width = width; self.height = height
        self.frameRate = frameRate; self.frameCount = frameCount
    }
    public func validate() throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.path != "/", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              videoStreamIndex >= 0, width > 0, height > 0, width <= 65536, height <= 65536,
              frameRate.numerator > 0, frameRate.seconds.isFinite, frameRate.seconds <= 1000,
              frameCount > 0 else { throw EditorCoreError.invalidModel("Invalid proxy media") }
        try sourceFingerprint.validate()
        // Reject counts/rates that cannot express their duration in the core's exact time model.
        _ = try RationalTime(frameCount).divided(by: frameRate)
    }
    private enum CodingKeys: String, CodingKey {
        case id, url, preset, sourceFingerprint, videoStreamIndex, width, height, frameRate, frameCount
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), url: try c.decode(URL.self, forKey: .url),
                  preset: try c.decode(ProxyPreset.self, forKey: .preset),
                  sourceFingerprint: try c.decode(MediaSourceFingerprint.self, forKey: .sourceFingerprint),
                  videoStreamIndex: try c.decode(Int.self, forKey: .videoStreamIndex),
                  width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  frameRate: try c.decode(RationalTime.self, forKey: .frameRate),
                  frameCount: try c.decode(Int64.self, forKey: .frameCount))
        try validate()
    }
}

public enum PlaybackRepresentation: String, Codable, CaseIterable, Sendable { case original, proxy }
public enum ProxyPlaybackStatus: Equatable, Sendable { case original, available, missing, stale, unavailable }
public struct ProxyPlaybackResolution: Equatable, Sendable {
    public var url: URL?
    public var status: ProxyPlaybackStatus
    public var usesProxy: Bool
    public init(url: URL?, status: ProxyPlaybackStatus, usesProxy: Bool) {
        self.url = url; self.status = status; self.usesProxy = usesProxy
    }
}

extension MediaAsset {
    /// Pure resolution: filesystem checks are supplied by the application, never performed by the core.
    public func resolvePlayback(representation: PlaybackRepresentation, sourceFingerprint: MediaSourceFingerprint?, proxyExists: Bool) -> ProxyPlaybackResolution {
        func fallback(_ status: ProxyPlaybackStatus) -> ProxyPlaybackResolution {
            .init(url: originalURL, status: status, usesProxy: false)
        }
        guard representation == .proxy else { return fallback(.original) }
        guard originalURL != nil, let proxy, let sourceFingerprint,
              (try? sourceFingerprint.validate()) != nil, (try? proxy.validate()) != nil,
              streams.contains(where: { $0.index == proxy.videoStreamIndex && $0.kind == .video }) else {
            return fallback(.unavailable)
        }
        guard sourceFingerprint == proxy.sourceFingerprint else { return fallback(.stale) }
        guard proxyExists else { return fallback(.missing) }
        return .init(url: proxy.url, status: .available, usesProxy: true)
    }
}
