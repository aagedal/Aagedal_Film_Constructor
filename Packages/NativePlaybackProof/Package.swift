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
        // aagedal-1.1.0-n9.0.2-editor.2: MPV 0.41, FFmpeg n9.0.2. The same FFmpeg configure run built
        // the bundled helpers (Configuration/MediaHelpers.json), so the app carries one FFmpeg build.
        .package(url: "https://github.com/aagedal/MPVKit", revision: "1406082db63e9014e90fca6021d9ad4b6aff415a")
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
