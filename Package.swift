// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpaceSense",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SpaceSenseCore",
            targets: ["SpaceSenseCore"]
        ),
        .executable(
            name: "SpaceSense",
            targets: ["SpaceSense"]
        )
    ],
    targets: [
        .target(
            name: "SpaceSenseCore",
            path: "Sources/SpaceSenseCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security"),
                .linkedFramework("Charts"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "SpaceSense",
            dependencies: ["SpaceSenseCore"],
            path: "Sources/SpaceSense"
        ),
        .testTarget(
            name: "SpaceSenseTests",
            dependencies: ["SpaceSenseCore"],
            path: "Tests/SpaceSenseTests"
        )
    ]
)
