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
    ],
    targets: [
        .target(name: "BifoldCore", swiftSettings: strict),
        .target(name: "BifoldWorkspace", dependencies: ["BifoldCore"], swiftSettings: strict),
        .testTarget(name: "BifoldCoreTests", dependencies: ["BifoldCore"], swiftSettings: strict),
        .testTarget(name: "BifoldWorkspaceTests", dependencies: ["BifoldWorkspace"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
