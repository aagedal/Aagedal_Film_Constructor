// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EditorCore", platforms: [.macOS(.v14)], products: [.library(name: "EditorCore", targets: ["EditorCore"])], targets: [.target(name: "EditorCore"), .executableTarget(name: "RenderPlanProof", dependencies: ["EditorCore"]), .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"])])
