// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "CommittoCore", targets: ["CommittoCore"]),
    .executable(name: "committo", targets: ["committo-cli"]),
]
var targets: [Target] = [
    // Foundation-first engine: git, providers, agents, scanning, CI, MCP. Builds on macOS and Linux.
    .target(name: "CommittoCore"),
    // `committo mcp` (stdio MCP server), `committo ci-serve`, `committo scan`.
    .executableTarget(name: "committo-cli", dependencies: ["CommittoCore"]),
    .testTarget(name: "CommittoCoreTests", dependencies: ["CommittoCore"]),
]
#if os(macOS)
// SwiftUI menu-bar + window app.
products.append(.executable(name: "Committo", targets: ["Committo"]))
targets.append(.executableTarget(name: "Committo", dependencies: ["CommittoCore"]))
#endif

let package = Package(name: "Committo", platforms: [.macOS(.v14)], products: products, targets: targets)
