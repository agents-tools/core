import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@Suite("Native plugin export")
struct NativePluginExportTests {
  private let package = BundlePackage(
    name: "plugin-workbench", version: "1.0.0",
    description: "Discoverable author description", author: "Fixture Author")

  @Test(arguments: NativePluginTarget.allCases)
  func checkedTreePreservesFilesAndWiresTheLocalListing(_ target: NativePluginTarget) throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author")
    var environment = fixture.environment
    environment.projectDirectory = project
    let scaffold = try AuthorPackageOperations.scaffold(
      package, at: project, environment: environment)
    let skill = project.appendingPathComponent(scaffold.skills[0])
    let assets = skill.appendingPathComponent("assets")
    try FileManager.default.createDirectory(
      at: assets.appendingPathComponent("empty"), withIntermediateDirectories: true)
    let bytes = Data([0, 255, 22, 4])
    try bytes.write(to: assets.appendingPathComponent("bytes.bin"))
    try FileManager.default.createSymbolicLink(
      atPath: assets.appendingPathComponent("linked.bin").path, withDestinationPath: "bytes.bin")
    let script = skill.appendingPathComponent("run.sh")
    try fixture.write("#!/bin/sh\ntouch never-created\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try fixture.write(
      """
      version: 1
      components:
        - kind: mcpServer
          name: docs
          transport: {kind: streamableHTTP, url: 'https://example.invalid/mcp'}
      """,
      to: project.appendingPathComponent(".agent/agents.yaml"))
    let artifact = try AuthorPackageOperations.preview(
      .init(package: package, skills: scaffold.skills, mcpServers: ["docs"]),
      environment: environment)
    let marketplace = NativePluginMarketplace(name: "example-team", category: "Productivity")
    let before = try FileHash.folderHash(fixture.root)
    let checked = try NativePluginOperations.preview(
      artifact, for: target, marketplace: marketplace, environment: environment)
    #expect(try FileHash.folderHash(fixture.root) == before)
    let repeated = try NativePluginOperations.preview(
      artifact, for: target, marketplace: marketplace, environment: environment)
    #expect(repeated.digest == checked.digest)
    let (manifest, listing): (String, String)
    switch target {
    case .claudeCode:
      (manifest, listing) = (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json")
    case .codex:
      (manifest, listing) = (".codex-plugin/plugin.json", ".agents/plugins/marketplace.json")
    }
    let prefix = "plugins/plugin-workbench/"
    let metadata = try json(checked, prefix + manifest)
    #expect(metadata["description"] as? String == package.description)
    #expect(metadata["skills"] as? String == "./skills/")
    #expect(metadata["mcpServers"] as? String == "./.mcp.json")
    let mcp = try json(checked, prefix + ".mcp.json")
    let servers = try #require(mcp["mcpServers"] as? [String: [String: String]])
    #expect(servers["docs"]?["url"] == "https://example.invalid/mcp")
    let catalog = try json(checked, listing)
    let entries = try #require(catalog["plugins"] as? [[String: Any]])
    let entry = try #require(entries.first)
    if target == .codex {
      #expect((entry["source"] as? [String: String])?["path"] == "./plugins/plugin-workbench")
      #expect(
        (metadata["interface"] as? [String: String])?["longDescription"] == package.description)
    } else {
      #expect(entry["source"] as? String == "./plugins/plugin-workbench")
      #expect(entry["description"] as? String == package.description)
    }

    let destination = fixture.root.appendingPathComponent("distribution")
    try FileManager.default.removeItem(at: project)
    #expect(throws: CoreError.self) {
      try NativePluginOperations.write(
        checked, to: destination, expectedDigest: artifact.digest, environment: fixture.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    try NativePluginOperations.write(
      checked, to: destination, expectedDigest: checked.digest, environment: fixture.environment)
    try NativePluginOperations.write(checked, to: destination, environment: fixture.environment)
    let copied = destination.appendingPathComponent(prefix + "skills/getting-started")
    #expect(try fixture.bytes(copied.appendingPathComponent("assets/linked.bin")) == bytes)
    #expect(
      FileManager.default.fileExists(atPath: copied.appendingPathComponent("assets/empty").path))
    let mode = try #require(
      FileManager.default.attributesOfItem(atPath: copied.appendingPathComponent("run.sh").path)[
        .posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 != 0)
    #expect(
      !FileManager.default.fileExists(atPath: copied.appendingPathComponent("never-created").path))
    let extra = destination.appendingPathComponent("occupied")
    try fixture.write("Preserve me", to: extra)
    #expect(throws: CoreError.self) {
      try NativePluginOperations.write(checked, to: destination, environment: fixture.environment)
    }
    #expect(try fixture.bytes(extra) == Data("Preserve me".utf8))
  }

  @Test func claudePreservesSymbolicBindingsAndItsBundledProgramWithoutLaunchingIt() throws {
    let fixture = try UpdateFixture()
    let program = fixture.root.appendingPathComponent("mcp/fixture")
    try fixture.write("#!/bin/sh\ntouch never-created\n", to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    try fixture.write(
      """
      version: 1
      components:
        - kind: mcpServer
          name: fixture
          transport:
            kind: stdio
            executable: ./mcp/fixture
            arguments: ['--token=redact-me', serve]
            environment:
              REGION: {env: FIXTURE_REGION}
              TOKEN: {secret: fixture_token}
      """,
      to: fixture.store.declarationURL)
    let artifact = try AuthorPackageOperations.preview(
      .init(package: package, mcpServers: ["fixture"]), environment: fixture.environment)
    #expect(artifact.warnings.map(\.count) == [1])
    let plugin = try NativePluginOperations.preview(
      artifact, for: .claudeCode, environment: fixture.environment)
    let mcp = try json(plugin, ".mcp.json")
    let servers = try #require(mcp["mcpServers"] as? [String: [String: Any]])
    let fields = try #require(servers["fixture"])
    #expect(
      fields["command"] as? String == "${CLAUDE_PLUGIN_ROOT}/mcp-resources/fixture/mcp/fixture")
    #expect(
      fields["env"] as? [String: String] == [
        "REGION": "${FIXTURE_REGION}", "TOKEN": "${user_config.fixture_token}",
      ])
    #expect(fields["args"] as? [String] == ["serve"])
    #expect(try plugin.contents(at: "mcp-resources/fixture/mcp/fixture") == fixture.bytes(program))
    let manifest = try json(plugin, ".claude-plugin/plugin.json")
    let config = try #require(manifest["userConfig"] as? [String: [String: Any]])
    #expect(config["fixture_token"]?["sensitive"] as? Bool == true)
    #expect(
      !String(decoding: try #require(plugin.contents(at: ".mcp.json")), as: UTF8.self).contains(
        "redact-me"))
  }

  private func json(_ artifact: NativePluginArtifact, _ path: String) throws -> [String: Any] {
    let data = try #require(artifact.contents(at: path))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
