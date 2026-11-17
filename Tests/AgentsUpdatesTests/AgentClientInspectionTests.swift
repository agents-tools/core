import AgentsCore
import AgentsUpdates
import CPlatform
import Foundation
import Testing

struct AgentClientInspectionTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func missingClientsKeepFiveRecordsAndStaticEvidence() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("absent-home"), environment: [:])
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let report = try AgentClientOperations.inspect(environment: environment)
    #expect(report.clients.map(\.agent) == AgentID.allCases)
    #expect(report.startedAt <= report.finishedAt)
    #expect(!report.pathCoverage.pathWasSupplied)
    #expect(
      report.clients.flatMap(\.commands).allSatisfy {
        $0.status == .unavailable && $0.version.rawVersion == nil
          && $0.version.unknownReason == .unavailable
      })
    #expect(report.clients.flatMap(\.configurationLocations).allSatisfy { $0.status == .notFound })
    let claude = try #require(report.clients.first { $0.agent == .claudeCode })
    #expect(
      claude.schemaEvidence.contains {
        $0.kind == .mcpServer && $0.scope == "local" && $0.revision == "installed:2.1.309"
      })
    #expect(claude.commands.allSatisfy { $0.version.rawVersion == nil })
    #expect(claude.schemaEvidence.contains { $0.kind == .skills && $0.status == .unverified })
    let codex = try #require(report.clients.first { $0.agent == .codex })
    #expect(
      codex.configurationLocations.contains {
        $0.identity == "codex.mcp.user"
          && $0.location?.path
            == environment.homeDirectory.appendingPathComponent(".codex/config.toml").path
      })
    #expect(
      codex.schemaEvidence.contains {
        $0.kind == .command && $0.status == .unsupportedUnderEvidence
      })
    let cursor = try #require(report.clients.first { $0.agent == .cursor })
    #expect(
      cursor.schemaEvidence.contains {
        $0.surface.identifier == "cursorCloud" && $0.kind == .mcpServer && $0.status == .unverified
      })
    #expect(
      cursor.schemaEvidence.contains {
        $0.surface.identifier == "cursorEditor" && $0.kind == .command && $0.scope == "user"
          && $0.placement == .standalone && $0.status == .unverified
      })
    #expect(
      cursor.schemaEvidence.contains {
        $0.surface.identifier == "cursorEditor" && $0.kind == .command && $0.scope == "user"
          && $0.placement == .pluginMember && $0.status == .recorded
      })
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
  }

  @Test func pathOrderSymlinksAndCursorRolesNeverExecuteClients() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let sentinel = root.appendingPathComponent("executed")
    let executable = second.appendingPathComponent("codex")
    try Data("#!/bin/sh\ntouch '\(sentinel.path)'\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try FileManager.default.createSymbolicLink(
      at: first.appendingPathComponent("codex"), withDestinationURL: executable)
    try Data("not executable".utf8).write(to: first.appendingPathComponent("cursor"))
    let bundle = root.appendingPathComponent("Cursor.app")
    let launcher = bundle.appendingPathComponent("Contents/Resources/app/bin/cursor")
    try FileManager.default.createDirectory(
      at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: executable, to: launcher)
    try FileManager.default.createSymbolicLink(
      at: second.appendingPathComponent("cursor"), withDestinationURL: launcher)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.todesktop.230313mzl4w4u92",
        "CFBundleShortVersionString": "3.27-test", "CFBundleVersion": "42",
      ], format: .xml, options: 0
    ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    try FileManager.default.createDirectory(
      at: first.appendingPathComponent("cursor-agent"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: first.appendingPathComponent("gemini").path,
      withDestinationPath: root.appendingPathComponent("missing").path)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root,
      environment: ["PATH": ":relative:\(first.path):\(second.path)"])
    let bytes = try Data(contentsOf: executable)
    let report = try AgentClientOperations.inspect(environment: environment)
    #expect(report.pathCoverage.excludedEntries == ["", "relative"])
    #expect(report.pathCoverage.absoluteDirectories.map(\.path) == [first.path, second.path])
    let codex = try #require(report.clients.first { $0.agent == .codex }?.commands.first)
    #expect(codex.location == first.appendingPathComponent("codex"))
    #expect(codex.resolvedLocation == executable)
    #expect(codex.version.unknownReason == .unrecognizedLayout)
    let cursor = try #require(report.clients.first { $0.agent == .cursor })
    #expect(
      cursor.commands.first { $0.role == .editorLauncher }?.location
        == second.appendingPathComponent("cursor"))
    #expect(cursor.commands.first { $0.role == .editorLauncher }?.version.rawVersion == "3.27-test")
    #expect(cursor.commands.first { $0.role == .editorLauncher }?.version.build == "42")
    #expect(cursor.commands.first { $0.name == "cursor-agent" }?.status == .notFound)
    #expect(cursor.commands.first { $0.name == "cursor-agent" }?.version.rawVersion == nil)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try Data(contentsOf: executable) == bytes)
  }

  @Test func pathSearchPermissionsAndExistingConfigurationRemainLocalObservations() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let denied = root.appendingPathComponent("denied")
    let bin = root.appendingPathComponent("bin")
    let state = root.appendingPathComponent(".agents/transaction.json")
    let configuration = root.appendingPathComponent(".codex/config.toml")
    for directory in [
      denied, bin, state.deletingLastPathComponent(), configuration.deletingLastPathComponent(),
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let canary = Data("not configuration; never parse or recover".utf8)
    try canary.write(to: state)
    try canary.write(to: configuration)
    let executable = bin.appendingPathComponent("codex")
    try Data("never execute".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
    }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root,
      environment: ["PATH": "\(denied.path):\(bin.path)"])
    let report = try AgentClientOperations.inspect(environment: environment)
    let command = try #require(report.clients.first { $0.agent == .codex }?.commands.first)
    #expect(command.location == executable)
    #expect(
      command.lookupIssues.contains { $0.path.hasPrefix(denied.path) && $0.status == .inaccessible }
        == (access(denied.path, X_OK) != 0)
    )
    #expect(
      report.clients.first { $0.agent == .codex }?.configurationLocations.contains {
        $0.identity == "codex.mcp.user" && $0.status == .present
      } == true)
    #expect(try Data(contentsOf: state) == canary)
    #expect(try Data(contentsOf: configuration) == canary)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: state.deletingLastPathComponent().path)
        == ["transaction.json"])
  }

  @Test func ownerLocationsPreserveOverridesAlternativesAndSemanticRecords() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"),
      environment: [
        "CODEX_HOME": root.appendingPathComponent("codex-override").path,
        "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude-override").path,
        "GEMINI_CLI_HOME": root.appendingPathComponent("gemini-native").path,
        "OPENCODE_CONFIG_DIR": root.appendingPathComponent("opencode-native").path,
        "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
      ])
    let report = try AgentClientOperations.inspect(environment: environment)
    let claude = try #require(report.clients.first { $0.agent == .claudeCode })
    let regions = claude.configurationLocations.filter { $0.identity.hasPrefix("claude.mcp.") }
    #expect(regions.count == 2)
    #expect(Set(regions.compactMap(\.location)).count == 1)
    #expect(Set(regions.map(\.scope)) == ["local", "user"])
    let opencode = try #require(report.clients.first { $0.agent == .opencode })
    #expect(
      opencode.configurationLocations.contains {
        $0.location?.path == root.appendingPathComponent("opencode-native/opencode.jsonc").path
      })
    #expect(
      opencode.configurationLocations.contains {
        $0.location?.path == root.appendingPathComponent("xdg/opencode/skills").path
      })
    let codex = try #require(report.clients.first { $0.agent == .codex })
    #expect(
      codex.configurationLocations.contains {
        $0.identity == "codex.mcp.user"
          && $0.location?.path == root.appendingPathComponent("codex-override/config.toml").path
      })
    #expect(
      codex.configurationLocations.contains {
        $0.purpose == .instructions
          && $0.location?.path == root.appendingPathComponent("codex-override/AGENTS.md").path
      })
    let project = try AgentClientOperations.inspect(scope: .project, environment: environment)
    #expect(
      project.clients.first { $0.agent == .claudeCode }?.configurationLocations.contains {
        $0.identity == "instructions.CLAUDE.local.md"
      } == true)
    environment.environment["CODEX_HOME"] = "relative"
    let invalid = try AgentClientOperations.inspect(environment: environment)
    #expect(
      invalid.clients.first { $0.agent == .codex }?.configurationLocations.contains {
        $0.identity == "codex.mcp.user" && $0.status == .invalid && $0.location == nil
          && $0.diagnostic?.contains("CODEX_HOME") == true
      } == true)
    #expect(invalid.clients.first { $0.agent == .claudeCode }?.schemaEvidence.isEmpty == false)
    #expect(
      report.clients.first { $0.agent == .cursor }?.configurationLocations.contains {
        $0.identity == "claudeAgent.user"
          && $0.location?.path == root.appendingPathComponent("claude-override/agents").path
      } == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
}
