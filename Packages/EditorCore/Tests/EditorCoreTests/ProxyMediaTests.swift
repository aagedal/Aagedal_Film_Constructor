import Foundation
import Testing
@testable import EditorCore

private func proxyFixture() throws -> MediaProxy {
    MediaProxy(url: URL(fileURLWithPath: "/tmp/proxy.mov"), preset: .proResProxy,
               sourceFingerprint: .init(fileSize: 1234, modificationTime: 1700000000),
               videoStreamIndex: 3, width: 960, height: 540, frameRate: try RationalTime(24000, 1001), frameCount: 240)
}

@Test func proxyModelsRoundTripAndLegacyAssetsDecode() throws {
    let proxy = try proxyFixture()
    let asset = MediaAsset(name: "Source", originalURL: URL(fileURLWithPath: "/tmp/original.mov"),
                           duration: try RationalTime(30), streams: [.init(index: 3, kind: .video)], proxy: proxy)
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    #expect(try decoder.decode(MediaAsset.self, from: encoder.encode(asset)) == asset)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(asset)) as? [String: Any])
    legacy.removeValue(forKey: "proxy")
    #expect(try decoder.decode(MediaAsset.self, from: JSONSerialization.data(withJSONObject: legacy)).proxy == nil)
    let project = Project(settings: try SequenceSettings(), assets: [asset])
    #expect(try decoder.decode(Project.self, from: encoder.encode(project)) == project)
}

@Test func proxyValidationRejectsInvalidMetadataAndRemoteURLs() throws {
    let valid = try proxyFixture()
    try valid.validate()
    var invalid: [MediaProxy] = []
    for url in ["https://example.com/proxy.mov", "file://server/tmp/proxy.mov", "file:///tmp/proxy.mov?token=1", "file:///tmp/proxy.mov#fragment", "file:///"] {
        var proxy = valid; proxy.url = try #require(URL(string: url)); invalid.append(proxy)
    }
    var proxy = valid; proxy.width = 0; invalid.append(proxy)
    proxy = valid; proxy.height = 65537; invalid.append(proxy)
    proxy = valid; proxy.videoStreamIndex = -1; invalid.append(proxy)
    proxy = valid; proxy.frameCount = 0; invalid.append(proxy)
    proxy = valid; proxy.frameRate = .zero; invalid.append(proxy)
    proxy = valid; proxy.frameRate = try RationalTime(1001); invalid.append(proxy)
    proxy = valid; proxy.frameCount = .max; invalid.append(proxy)
    proxy = valid; proxy.sourceFingerprint.fileSize = -1; invalid.append(proxy)
    proxy = valid; proxy.sourceFingerprint.modificationTime = .infinity; invalid.append(proxy)
    for proxy in invalid { #expect(throws: (any Error).self) { try proxy.validate() } }
    for proxy in invalid where proxy.sourceFingerprint.modificationTime.isFinite {
        let data = try JSONEncoder().encode(proxy)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MediaProxy.self, from: data) }
    }
    var asset = MediaAsset(name: "Source", duration: try RationalTime(30), streams: [.init(index: 3, kind: .video)], proxy: valid)
    try Project(settings: SequenceSettings(), assets: [asset]).validate()
    asset.proxy?.videoStreamIndex = 1
    #expect(throws: (any Error).self) { try Project(settings: SequenceSettings(), assets: [asset]).validate() }
    asset.streams = [.init(index: 1, kind: .audio, audioLayout: .stereo)]
    #expect(throws: (any Error).self) { try Project(settings: SequenceSettings(), assets: [asset]).validate() }
}

@Test func proxyResolutionRequiresExistingMatchingMediaAndFallsBackToOriginal() throws {
    let proxy = try proxyFixture()
    let original = URL(fileURLWithPath: "/tmp/original.mov")
    var asset = MediaAsset(name: "Source", originalURL: original, duration: try RationalTime(30),
                           streams: [.init(index: 3, kind: .video)], proxy: proxy)
    let fingerprint = proxy.sourceFingerprint
    #expect(asset.resolvePlayback(representation: .original, sourceFingerprint: fingerprint, proxyExists: true) == .init(url: original, status: .original, usesProxy: false))
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: fingerprint, proxyExists: true) == .init(url: proxy.url, status: .available, usesProxy: true))
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: fingerprint, proxyExists: false) == .init(url: original, status: .missing, usesProxy: false))
    for stale in [MediaSourceFingerprint(fileSize: 1235, modificationTime: fingerprint.modificationTime),
                  MediaSourceFingerprint(fileSize: fingerprint.fileSize, modificationTime: fingerprint.modificationTime + 1)] {
        #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: stale, proxyExists: true) == .init(url: original, status: .stale, usesProxy: false))
    }
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: nil, proxyExists: true) == .init(url: original, status: .unavailable, usesProxy: false))
    asset.originalURL = nil
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: fingerprint, proxyExists: true) == .init(url: nil, status: .unavailable, usesProxy: false))
    asset.originalURL = original; asset.proxy = nil
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: fingerprint, proxyExists: true).status == .unavailable)
}

@Test func proxyMetadataNeverChangesRenderPlanOrFCPXMLOriginalReferences() throws {
    let template = TrackTemplate(kind: .video)
    let family = TrackFamily(baseName: "Video", template: template)
    let asset = MediaAsset(name: "Source", originalURL: URL(fileURLWithPath: "/tmp/original.mov"),
                           duration: try RationalTime(30), streams: [.init(index: 3, kind: .video)])
    let clip = TimelineClip(assetID: asset.id, sourceRange: try TimeRange(start: RationalTime(2), duration: RationalTime(5)), selection: .video(streamIndex: 3))
    var project = Project(settings: try SequenceSettings(), assets: [asset], families: [family],
                          tracks: [.init(familyID: family.id, template: template, clips: [clip])])
    let originalPlan = try TimelineRenderPlan(project: project)
    let originalXML = try FCPXMLExporter.export(project: project)
    project.assets[0].proxy = try proxyFixture()
    #expect(try TimelineRenderPlan(project: project) == originalPlan)
    #expect(try FCPXMLExporter.export(project: project) == originalXML)
    #expect(!originalXML.xml.contains("proxy.mov"))
    let output = URL(fileURLWithPath: "/tmp/final-render.mov")
    let originalCommand = try FFmpegRenderCompiler.compile(originalPlan, outputURL: output)
    let proxyCommand = try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    #expect(proxyCommand == originalCommand)
    #expect(proxyCommand.inputs.allSatisfy { $0.url == asset.originalURL })
    #expect(!proxyCommand.arguments.contains(project.assets[0].proxy!.url.path))
    // A usable proxy does not silently authorize a lower-resolution final render.
    project.assets[0].originalURL = nil
    #expect(throws: (any Error).self) {
        try FFmpegRenderCompiler.compile(TimelineRenderPlan(project: project), outputURL: output)
    }
}

@Test func proxyOutputIntegrityPersistsWithoutInventingLegacyHashes() throws {
    var proxy = try proxyFixture()
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    #expect(try decoder.decode(MediaProxy.self, from: encoder.encode(proxy)).outputIntegrity == nil)
    proxy.outputIntegrity = .init(fileSize: 4000, sha256Hex: String(repeating: "a", count: 64))
    #expect(try decoder.decode(MediaProxy.self, from: encoder.encode(proxy)) == proxy)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(proxy)) as? [String: Any])
    legacy.removeValue(forKey: "outputIntegrity")
    #expect(try decoder.decode(MediaProxy.self, from: JSONSerialization.data(withJSONObject: legacy)).outputIntegrity == nil)
    for integrity in [MediaProxyFileIntegrity(fileSize: 0, sha256Hex: String(repeating: "a", count: 64)),
                      .init(fileSize: 100, sha256Hex: String(repeating: "g", count: 64)),
                      .init(fileSize: 100, sha256Hex: String(repeating: "a", count: 63))] {
        proxy.outputIntegrity = integrity
        #expect(throws: (any Error).self) { try proxy.validate() }
        #expect(throws: (any Error).self) { try decoder.decode(MediaProxy.self, from: encoder.encode(proxy)) }
    }
}

@Test func proxyResolutionRequiresVerifiedOutputIntegrityForNewProxies() throws {
    var proxy = try proxyFixture()
    proxy.outputIntegrity = .init(fileSize: 4000, sha256Hex: String(repeating: "a", count: 64))
    let asset = MediaAsset(name: "Source", originalURL: URL(fileURLWithPath: "/tmp/original.mov"),
                          duration: try RationalTime(30), streams: [.init(index: 3, kind: .video)], proxy: proxy)
    for matches in [Optional<Bool>.none, false] {
        let resolution = asset.resolvePlayback(representation: .proxy, sourceFingerprint: proxy.sourceFingerprint,
                                               proxyExists: true, proxyIntegrityMatches: matches)
        #expect(resolution.status == .modified)
        #expect(resolution.url == asset.originalURL && !resolution.usesProxy)
    }
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: proxy.sourceFingerprint,
                                  proxyExists: true, proxyIntegrityMatches: true).usesProxy)
    #expect(asset.resolvePlayback(representation: .proxy, sourceFingerprint: proxy.sourceFingerprint,
                                  proxyExists: false, proxyIntegrityMatches: false).status == .missing)
    #expect(asset.resolvePlayback(representation: .original, sourceFingerprint: proxy.sourceFingerprint,
                                  proxyExists: true, proxyIntegrityMatches: false).status == .original)
}

@Test func hiresPreferenceFallsBackOnlyToVerifiedProxyWhenOriginalIsMissing() throws {
    var proxy = try proxyFixture()
    proxy.outputIntegrity = .init(fileSize: 4000, sha256Hex: String(repeating: "a", count: 64))
    var asset = MediaAsset(name: "Source", originalURL: URL(fileURLWithPath: "/tmp/original.mov"),
                           duration: try RationalTime(30), streams: [.init(index: 3, kind: .video)], proxy: proxy)
    for preference in PlaybackRepresentation.allCases {
        let resolution = asset.resolvePlayback(representation: preference, sourceFingerprint: nil,
            proxyExists: true, proxyIntegrityMatches: true, originalExists: false)
        #expect(resolution == .init(url: proxy.url, status: .originalUnavailable, usesProxy: true))
        for verified in [Optional<Bool>.none, false] {
            let unsafe = asset.resolvePlayback(representation: preference, sourceFingerprint: nil,
                proxyExists: true, proxyIntegrityMatches: verified, originalExists: false)
            #expect(unsafe.url == nil && !unsafe.usesProxy && unsafe.status == .modified)
        }
        let missing = asset.resolvePlayback(representation: preference, sourceFingerprint: nil,
            proxyExists: false, proxyIntegrityMatches: true, originalExists: false)
        #expect(missing.url == nil && missing.status == .missing)
        let stale = asset.resolvePlayback(representation: preference,
            sourceFingerprint: .init(fileSize: 9999, modificationTime: 1),
            proxyExists: true, proxyIntegrityMatches: true, originalExists: false)
        #expect(stale.url == nil && stale.status == .stale)
    }
    asset.proxy?.outputIntegrity = nil
    let legacy = asset.resolvePlayback(representation: .original, sourceFingerprint: nil,
        proxyExists: true, proxyIntegrityMatches: true, originalExists: false)
    #expect(legacy.url == nil && !legacy.usesProxy && legacy.status == .unavailable)
    // Online HiRes preference remains HiRes, even when the proxy is unavailable.
    #expect(asset.resolvePlayback(representation: .original, sourceFingerprint: nil,
        proxyExists: false, originalExists: true).url == asset.originalURL)
}
