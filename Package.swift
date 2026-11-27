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
    .target(name: "CPlatform", linkerSettings: [.linkedLibrary("z")]),
    .target(name: "CSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
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
      dependencies: [
        "CPlatform", "CSQLite", "TOMLSemantics", .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Markdown", package: "swift-markdown"), "Yams",
      ]
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
        "Components", "NativeDocuments",
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
        "StateTestSupport",
      ], resources: [.copy("Fixtures")]),
    // SwiftPM builds the process fixtures as executables. Tests launch them by path.
    .executableTarget(
      name: "MCPTestProcess", dependencies: ["CPlatform"], path: "Tests/MCPTestProcess"),
    .target(
      name: "StateTestSupport", dependencies: ["AgentsCore", "AgentsManifest"],
      path: "Tests/StateTestSupport"),
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
        "AgentsCore", "AgentsManifest", "StateTestSupport", "CPlatform",
      ]),
    .testTarget(
      name: "AgentsInstructionsTests",
      dependencies: [
        "AgentsInstructions", "AgentsSkills", "AgentsManifest", "AgentsUpdates", "StateTestSupport",
      ]),
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
        "AgentsManifest", "AgentsCore", "ManifestTestSupport",
      ]),
    .testTarget(
      name: "AgentsUpdatesTests",
      dependencies: [
        "AgentsUpdates", "AgentsManifest", "StateTestSupport", "CPlatform",
      ]),
    .testTarget(
      name: "AgentsSkillsTests",
      dependencies: [
        "AgentsSkills", "AgentsCore", "AgentsManifest", "AgentsInstructions", "AgentsUpdates",
        "Yams",
        "StateTestSupport", "CPlatform",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
