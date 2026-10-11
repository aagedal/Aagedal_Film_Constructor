// swift-tools-version: 6.0
import PackageDescription

// Development experiment only. The app deliberately does not link this package:
// pkg-config libraries are not an attributed, signed, redistributable bundle.
let package = Package(
    name: "NativePlaybackProof",
    platforms: [.macOS(.v14)],
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
