import Foundation
import EditorCore

/// Caller supplies only integrity-verified renditions. This layer performs no
/// file discovery and keeps original coordinates, spatial conform and audio.
struct NativeProxySelection: Sendable {
    let proxy: MediaProxy
    let originalFormat: VideoSourceFormat

    static func compile(project: Project, videoProxies: [UUID: MediaProxy]) throws -> [UUID: Self] {
        var selections: [UUID: Self] = [:]
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let clips = Dictionary(grouping: project.tracks.flatMap(\.clips), by: \.assetID)
        for (assetID, proxy) in videoProxies {
            try proxy.validate()
            guard let asset = assets[assetID],
                  asset.originalURL != nil, proxy.outputIntegrity != nil,
                  let stream = asset.streams.first(where: { $0.index == proxy.videoStreamIndex && $0.kind == .video }),
                  let format = stream.videoFormat,
                  format.frameRate == project.settings.frameRate,
                  proxy.frameRate == format.frameRate.value,
                  format.width <= 4096, format.height <= 4096,
                  proxy.width <= 4096, proxy.height <= 4096,
                  proxy.width * format.height == proxy.height * format.width else {
                throw ProofFailure("Sequence proxy requires verified integrity, matching cadence and square-pixel source geometry")
            }
            try format.validate()
            for clip in clips[assetID] ?? [] {
                guard case .video(let index) = clip.selection, index == proxy.videoStreamIndex else { continue }
                let end = try clip.sourceRange.end().multiplied(by: proxy.frameRate)
                guard end.denominator == 1, end.numerator <= proxy.frameCount else {
                    throw ProofFailure("Proxy does not cover the original source trim")
                }
                // Validate the original geometry even though only proxy bytes will be decoded.
                _ = try NativeVideoGeometry(sourceWidth: format.width, sourceHeight: format.height,
                                            width: project.settings.width, height: project.settings.height,
                                            mode: clip.scalingMode)
                selections[clip.id] = Self(proxy: proxy, originalFormat: format)
            }
        }
        return selections
    }
}
