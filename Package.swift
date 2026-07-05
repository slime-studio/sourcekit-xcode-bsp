// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-xcode-bsp",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "xcode-bsp",
            targets: ["xcode-bsp"]
        ),
        .library(
            name: "XcodeBSP",
            targets: ["XcodeBSP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-build.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-tools-protocols.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Main executable
        .executableTarget(
            name: "xcode-bsp",
            dependencies: [
                "XcodeBSP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftBuild", package: "swift-build"),
                .product(name: "SWBBuildServiceBundle", package: "swift-build"), // must be co-located for out-of-process launch
                .product(name: "BuildServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols"),
            ]
        ),

        // Core library - testable BSP server implementation
        .target(
            name: "XcodeBSP",
            dependencies: [
                .product(name: "SwiftBuild", package: "swift-build"),
                .product(name: "BuildServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols"),
            ]
        ),

        // Minimal IPC test — not shipped, used for debugging
        .executableTarget(
            name: "test-ipc",
            dependencies: [
                .product(name: "SwiftBuild", package: "swift-build"),
                .product(name: "SWBBuildServiceBundle", package: "swift-build"),
            ]
        ),

        // Tests
        .testTarget(
            name: "XcodeBSPTests",
            dependencies: ["XcodeBSP"]
        ),
    ]
)
