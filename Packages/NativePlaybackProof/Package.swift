// swift-tools-version: 6.0
import PackageDescription

// Development experiment. Xcode Debug can explicitly select this runtime:
// pkg-config libraries are not a release-certified redistributable bundle.
let package = Package(
    name: "NativePlaybackProof",
    platforms: [.macOS("27.0")],
    products: [.library(name: "NativePlaybackRuntime", type: .dynamic, targets: ["NativePlaybackRuntime"])],
    dependencies: [.package(path: "../EditorCore")],
    targets: [
        .systemLibrary(name: "CFFmpeg", pkgConfig: "libavformat"),
        .target(name: "CNativeDecoder", dependencies: ["CFFmpeg"]),
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
