// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Nook", targets: ["Nook"]),
        .executable(name: "nook-mcp", targets: ["NookMCP"]),
        .library(name: "NookCore", targets: ["NookCore"]),
    ],
    targets: [
        // Everything that isn't UI: storage, Gmail, sync, MIME, search, tagging.
        .target(
            name: "NookCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "Nook",
            dependencies: ["NookCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The local MCP server, shipped inside Nook.app.
        .executableTarget(
            name: "NookMCP",
            dependencies: ["NookCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NookCoreTests",
            dependencies: ["NookCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
