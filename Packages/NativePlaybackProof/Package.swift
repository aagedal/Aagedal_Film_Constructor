// swift-tools-version: 6.0
import PackageDescription

// FFmpeg comes from the pinned aagedal/MPVKit GPL build as static archives linked
// into the runtime. Xcode Debug can explicitly select this runtime; it is not yet
// a release-certified redistributable bundle.
let package = Package(
    name: "NativePlaybackProof",
    platforms: [.macOS("27.0")],
    products: [.library(name: "NativePlaybackRuntime", type: .dynamic, targets: ["NativePlaybackRuntime"])],
    dependencies: [
        .package(path: "../EditorCore"),
        // aagedal-1.1.0-n9.0.2-editor.1: MPV 0.41, FFmpeg n9.0.2 (matches the bundled helpers)
        // with editorial demuxers/decoders and PNG/JPEG encoders.
        .package(url: "https://github.com/aagedal/MPVKit", revision: "7f5d3f53bd2676aa5c569271ada72752a2e83267")
    ],
    targets: [
        .target(name: "CNativeDecoder", dependencies: [.product(name: "MPVKit-GPL", package: "MPVKit")]),
        .target(name: "NativePlaybackRuntime", dependencies: [
            "CNativeDecoder", .product(name: "EditorCore", package: "EditorCore")
        ]),
        .executableTarget(name: "NativeSequenceProof", dependencies: ["NativePlaybackRuntime", "CNativeDecoder",
            .product(name: "EditorCore", package: "EditorCore")]),
        .executableTarget(name: "NativeLiveProof", dependencies: ["NativePlaybackRuntime",
            .product(name: "EditorCore", package: "EditorCore")]),
        .testTarget(name: "NativePlaybackRuntimeTests", dependencies: ["NativePlaybackRuntime"])
    ]
)
