import Foundation
import Darwin
import EditorCore

/// Runs inside a disposable app bundle using the production default helper lookup.
@main struct BundledProxySmoke {
    static func main() async throws {
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
            print("Bundled proxy smoke timed out")
            Darwin.exit(1)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let presets = ProxyGenerationService.availablePresets()
        guard presets.contains(.proResProxy) else {
            throw SequenceExportError.verification("Bundle did not advertise ProRes Proxy")
        }
        let source = directory.appendingPathComponent("source.mov")
        let original = try Data(contentsOf: source)
        let asset = MediaAsset(name: "Bundled fixture", originalURL: source,
                               duration: try RationalTime(1), streams: [.init(index: 0, kind: .video)])
        let service = ProxyGenerationService()
        for preset in presets {
            let output = directory.appendingPathComponent("\(preset.rawValue).mov")
            let proxy = try await service.generate(asset: asset, preset: preset, scaleDivisor: 2, to: output)
            guard proxy.width == 80, proxy.height == 48, proxy.frameCount == 24,
                  proxy.frameRate == (try RationalTime(24000, 1001)),
                  try await ProxyGenerationService.validateProxyFile(proxy) == proxy.outputIntegrity else {
                throw SequenceExportError.verification("Bundled proxy metadata/integrity mismatch")
            }
            print("Bundled \(preset.rawValue) generation passed: 24 fractional-rate frames, 80x48, verified SHA256")
        }
        guard try Data(contentsOf: source) == original else {
            throw SequenceExportError.verification("Original source changed")
        }
        print("Production Bundle.main lookup passed; originals preserved")
    }
}
