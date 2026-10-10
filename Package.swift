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
    dependencies: [
        // Encrypts the local mail store (AES-256). Pinned to an exact, checksum-verified release from Zetetic.
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0"),
    ],
    targets: [
        // Everything that isn't UI: storage, Gmail, sync, MIME, search, tagging.
        .target(
            name: "NookCore",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
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
