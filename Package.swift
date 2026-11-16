// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "core",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "AgentsManifest", targets: ["AgentsManifest"]),
    .library(name: "AgentsCore", targets: ["AgentsCore"]),
    .library(name: "AgentsSkills", targets: ["AgentsSkills"]),
    .library(name: "AgentsInstructions", targets: ["AgentsInstructions"]),
    .library(name: "AgentsUpdates", targets: ["AgentsUpdates"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      revision: "a0ae212ebf6eab5f754c3129608bc5557637e605"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
  ],
  targets: [
    .target(
      name: "TOMLSemantics",
      exclude: ["LICENSE", "provenance.json", "PATCHES.md", "upstream.patch"]),
    .target(
      name: "TreeSitterTOML", exclude: ["LICENSE", "provenance.json"],
      sources: ["parser.c", "scanner.c"], publicHeadersPath: "include",
      cSettings: [.headerSearchPath(".")]),
    .target(
      name: "NativeDocuments",
      dependencies: [
        "AgentsCore", "TOMLSemantics", "TreeSitterTOML",
        .product(name: "TreeSitter", package: "tree-sitter"),
      ]),
    .testTarget(
      name: "NativeDocumentsTests",
      dependencies: ["NativeDocuments", "TOMLSemantics", "AgentsCore"]),
    .target(name: "CPlatform"),
    .target(
      name: "TreeSitterYAML", exclude: ["LICENSE", "provenance.json"],
      sources: ["parser.c", "scanner.c"], publicHeadersPath: "include",
      cSettings: [.headerSearchPath(".")]),
    .target(
      name: "AgentsManifest",
      dependencies: [
        "AgentsCore", "TreeSitterYAML", "Yams",
        .product(name: "TreeSitter", package: "tree-sitter"),
      ], exclude: ["Resources/agents.schema.json"]),
    .target(
      name: "AgentsCore",
      dependencies: ["CPlatform", .product(name: "Crypto", package: "swift-crypto")]
    ),
    .target(
      name: "AgentsInstructions",
      dependencies: [
        "AgentsCore", "AgentsManifest", .product(name: "Markdown", package: "swift-markdown"),
      ]
    ),
    .target(name: "AgentsSkills", dependencies: ["AgentsCore", "AgentsManifest", "Yams"]),
    .target(
      name: "AgentsUpdates",
      dependencies: [
        "AgentsCore", "AgentsManifest", "AgentsSkills", "AgentsInstructions", "CPlatform",
        "Components",
      ]),
    .target(
      name: "Components",
      dependencies: [
        "AgentsCore", "AgentsManifest", "AgentsSkills", "AgentsInstructions", "NativeDocuments",
        .product(name: "MCP", package: "swift-sdk"),
      ]),
    .testTarget(
      name: "ComponentsTests",
      dependencies: [
        "Components", "AgentsCore", "AgentsManifest", "AgentsSkills", "AgentsInstructions",
        "StateTestProcess", "StateTestSupport", "MCPTestProcess",
      ], resources: [.copy("Fixtures")]),
    .executableTarget(
      name: "MCPTestProcess", dependencies: ["CPlatform"], path: "Tests/MCPTestProcess"),
    .target(name: "StateTestSupport", path: "Tests/StateTestSupport"),
    .executableTarget(
      name: "StateTestProcess",
      dependencies: [
        "AgentsCore", "AgentsManifest", "AgentsInstructions", "AgentsSkills", "AgentsUpdates",
        "CPlatform", "StateTestSupport", "Components",
      ],
      path: "Tests/StateTestProcess"),
    .testTarget(
      name: "AgentsCoreTests",
      dependencies: [
        "AgentsCore", "AgentsManifest", "StateTestProcess", "StateTestSupport", "CPlatform",
      ]),
    .testTarget(
      name: "AgentsInstructionsTests", dependencies: ["AgentsInstructions", "AgentsManifest"]),
    .target(
      name: "ManifestTestSupport", dependencies: ["AgentsManifest"],
      path: "Tests/ManifestTestSupport"),
    .executableTarget(
      name: "ManifestTestProcess",
      dependencies: ["AgentsManifest", "AgentsCore", "ManifestTestSupport"],
      path: "Tests/ManifestTestProcess"),
    .testTarget(
      name: "AgentsManifestTests",
      dependencies: [
        "AgentsManifest", "AgentsCore", "ManifestTestProcess",
        "ManifestTestSupport",
      ]),
    .testTarget(
      name: "AgentsUpdatesTests",
      dependencies: [
        "AgentsUpdates", "AgentsManifest", "StateTestProcess", "StateTestSupport", "CPlatform",
        "MCPTestProcess",
      ]),
    .testTarget(
      name: "AgentsSkillsTests",
      dependencies: [
        "AgentsSkills", "AgentsCore", "AgentsManifest", "AgentsInstructions", "Yams",
        "StateTestProcess", "StateTestSupport", "CPlatform",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
