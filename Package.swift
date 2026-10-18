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
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams", from: "6.0.0")
  ],
  targets: [
    .target(name: "AgentsCore"),
    .target(name: "AgentsSkills", dependencies: ["AgentsCore", "Yams"]),
    .testTarget(name: "AgentsCoreTests", dependencies: ["AgentsCore"]),
    .testTarget(name: "AgentsSkillsTests", dependencies: ["AgentsSkills", "AgentsCore", "Yams"]),
  ],
  swiftLanguageModes: [.v6]
)
