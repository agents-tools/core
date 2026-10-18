// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "core",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "AgentsCore", targets: ["AgentsCore"]),
    .library(name: "AgentsSkills", targets: ["AgentsSkills"]),
    .library(name: "AgentsInstructions", targets: ["AgentsInstructions"]),
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
  ],
  targets: [
    .target(name: "AgentsCore"),
    .target(
      name: "AgentsInstructions",
      dependencies: ["AgentsCore", .product(name: "Markdown", package: "swift-markdown")]
    ),
    .target(name: "AgentsSkills", dependencies: ["AgentsCore", "Yams"]),
    .executableTarget(
      name: "StateTestProcess", dependencies: ["AgentsCore"], path: "Tests/StateTestProcess"),
    .testTarget(name: "AgentsCoreTests", dependencies: ["AgentsCore", "StateTestProcess"]),
    .testTarget(name: "AgentsInstructionsTests", dependencies: ["AgentsInstructions"]),
    .testTarget(name: "AgentsSkillsTests", dependencies: ["AgentsSkills", "AgentsCore", "Yams"]),
  ],
  swiftLanguageModes: [.v6]
)
