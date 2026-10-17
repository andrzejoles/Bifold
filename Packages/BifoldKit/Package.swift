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
        .executable(name: "bifold-mcp", targets: ["bifold-mcp"]),
        .library(name: "BifoldHelperKit", targets: ["BifoldHelperKit"]),
        .executable(name: "bifold-helper", targets: ["bifold-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "BifoldCore", swiftSettings: strict),
        .target(name: "BifoldWorkspace", dependencies: ["BifoldCore"], swiftSettings: strict),
        .target(name: "BifoldBridgeKit", swiftSettings: strict),
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
        .testTarget(name: "BifoldWorkspaceTests", dependencies: ["BifoldWorkspace"], swiftSettings: strict),
        .testTarget(name: "BifoldAgentTests", dependencies: ["BifoldAgent", "bifold-mcp"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
