// swift-tools-version:6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "BifoldKit",
    defaultLocalization: "pl",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BifoldCore", targets: ["BifoldCore"]),
        .library(name: "BifoldWorkspace", targets: ["BifoldWorkspace"]),
        .library(name: "BifoldAgent", targets: ["BifoldAgent"]),
        .library(name: "BifoldBridgeKit", targets: ["BifoldBridgeKit"]),
        .library(name: "BifoldMarkdown", targets: ["BifoldMarkdown"]),
        .executable(name: "bifold-mcp", targets: ["bifold-mcp"]),
        .library(name: "BifoldHelperKit", targets: ["BifoldHelperKit"]),
        .executable(name: "bifold-helper", targets: ["bifold-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.0"),
        // Markdown w przeglądarce F3: cmark-gfm (parser GitHuba) w wydaniu swiftlang, BSD-2-Clause.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "BifoldCore", swiftSettings: strict),
        .target(name: "BifoldWorkspace", dependencies: ["BifoldCore"], swiftSettings: strict),
        .target(name: "BifoldBridgeKit", swiftSettings: strict),
        .target(
            name: "BifoldMarkdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            swiftSettings: strict),
        .target(
            name: "BifoldAgent",
            dependencies: [
                "BifoldWorkspace", "BifoldBridgeKit",
                .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strict),
        .executableTarget(name: "bifold-mcp", dependencies: ["BifoldBridgeKit"], swiftSettings: strict),
        .target(name: "BifoldHelperKit", swiftSettings: strict),
        .executableTarget(name: "bifold-helper", dependencies: ["BifoldHelperKit"], swiftSettings: strict),
        .testTarget(name: "BifoldHelperKitTests", dependencies: ["BifoldHelperKit"], swiftSettings: strict),
        .testTarget(name: "BifoldCoreTests", dependencies: ["BifoldCore"], swiftSettings: strict),
        .testTarget(name: "BifoldMarkdownTests", dependencies: ["BifoldMarkdown"], swiftSettings: strict),
        .testTarget(name: "BifoldWorkspaceTests", dependencies: ["BifoldWorkspace"], swiftSettings: strict),
        .testTarget(name: "BifoldAgentTests", dependencies: ["BifoldAgent", "bifold-mcp"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
