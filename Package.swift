// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GoIDE", targets: ["GoIDE"]),
        .library(name: "GoIDECore", targets: ["GoIDECore"]),
    ],
    targets: [
        // UI-independent pieces: LSP client, Go highlighter, text/position math, file tree.
        .target(name: "GoIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "GoIDE", dependencies: ["GoIDECore"]),
        .testTarget(name: "GoIDECoreTests", dependencies: ["GoIDECore"]),
        .testTarget(name: "GoIDETests", dependencies: ["GoIDE", "GoIDECore"]),
    ]
)
