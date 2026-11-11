// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSpotlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentSpotlight", targets: ["AgentSpotlight"]),
        .executable(name: "spotlight-index", targets: ["AgentSpotlightCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentSpotlightCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AgentSpotlight", dependencies: ["AgentSpotlightCore"]),
        .executableTarget(name: "AgentSpotlightCLI", dependencies: ["AgentSpotlightCore"]),
        .testTarget(name: "AgentSpotlightCoreTests", dependencies: ["AgentSpotlightCore"])
    ],
    swiftLanguageModes: [.v5]
)
