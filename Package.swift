// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "core",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "AgentsDescription", targets: ["AgentsDescription"]),
    .library(name: "AgentsManifest", targets: ["AgentsManifest"]),
    .library(name: "AgentsCore", targets: ["AgentsCore"]),
    .library(name: "AgentsSkills", targets: ["AgentsSkills"]),
    .library(name: "AgentsInstructions", targets: ["AgentsInstructions"]),
    .library(name: "AgentsUpdates", targets: ["AgentsUpdates"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
  ],
  targets: [
    .target(name: "CPlatform"),
    .target(name: "AgentsDescription"),
    .target(
      name: "AgentsManifest",
      dependencies: [
        "AgentsDescription", "AgentsCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
      ]),
    .target(
      name: "AgentsCore",
      dependencies: ["CPlatform", .product(name: "Crypto", package: "swift-crypto")]
    ),
    .target(
      name: "AgentsInstructions",
      dependencies: ["AgentsCore", .product(name: "Markdown", package: "swift-markdown")]
    ),
    .target(name: "AgentsSkills", dependencies: ["AgentsCore", "Yams"]),
    .target(
      name: "AgentsUpdates",
      dependencies: ["AgentsCore", "AgentsSkills", "AgentsInstructions", "CPlatform"]),
    .executableTarget(
      name: "StateTestProcess",
      dependencies: [
        "AgentsCore", "AgentsInstructions", "AgentsSkills", "AgentsUpdates", "CPlatform",
      ],
      path: "Tests/StateTestProcess"),
    .testTarget(
      name: "AgentsCoreTests", dependencies: ["AgentsCore", "StateTestProcess", "CPlatform"]),
    .testTarget(name: "AgentsInstructionsTests", dependencies: ["AgentsInstructions"]),
    .executableTarget(
      name: "ManifestTestProcess",
      dependencies: ["AgentsManifest", "AgentsCore", "AgentsDescription"],
      path: "Tests/ManifestTestProcess"),
    .testTarget(
      name: "AgentsManifestTests",
      dependencies: [
        "AgentsManifest", "AgentsDescription", "AgentsCore", "ManifestTestProcess",
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "AgentsUpdatesTests", dependencies: ["AgentsUpdates", "StateTestProcess", "CPlatform"]),
    .testTarget(
      name: "AgentsSkillsTests",
      dependencies: [
        "AgentsSkills", "AgentsCore", "AgentsInstructions", "Yams", "StateTestProcess", "CPlatform",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
