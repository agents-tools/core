import AgentsCore
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

struct NativeCompositionIntegrationTests {
  @Test(arguments: [AgentID.claudeCode, .geminiCLI, .cursor, .opencode])
  func concreteCommandLifecycleUsesPublicOperations(_ agent: AgentID) throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: agent == .cursor ? "" : "Review sources",
          prompt: .literal("Review exact sources."), agents: [agent])
      ]), ledger: ResolvedLedger())
    let before = try FileHash.folderHash(f.root)
    let preview = try f.preview()
    #expect(preview.components.first?.kind == "command")
    #expect(try FileHash.folderHash(f.root) == before)
    _ = try UpdateOperations.withPreparedUpdate(environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let inspection = try UpdateOperations.inspect(environment: f.environment)
    let deployment = try #require(inspection.deployments.first)
    #expect(deployment.status == .current)
    let bytes = try Data(contentsOf: deployment.location)
    #expect(String(decoding: bytes, as: UTF8.self).contains("Review exact sources."))
    try FileManager.default.removeItem(at: deployment.location)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try Data(contentsOf: deployment.location) == bytes)
    let current = try UpdateOperations.inspect(environment: f.environment)
    let selection = try #require(current.components.first?.selection)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [selection]), environment: f.environment
    ) { try $0.apply() }
    #expect(try UpdateOperations.inspect(environment: f.environment).components.isEmpty)
  }

  @Test func codexRoleAndMCPShareOnePhysicalDocumentWithoutLosingSiblings() throws {
    let f = try UpdateFixture()
    let config = f.root.appendingPathComponent(".codex/config.toml")
    try f.write("# Preserve this native setting.\ntheme = 'fixture'\n", to: config)
    try f.store.save(
      declaration: Declaration(components: [
        .subagent(
          name: "researcher", description: "Research sources", prompt: .literal("Read sources."),
          agents: [.codex]),
        .mcpServer(name: "db", transport: .stdio(.init(executable: "never-run")), agents: [.codex]),
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let contents = try String(contentsOf: config, encoding: .utf8)
    #expect(contents.hasPrefix("# Preserve this native setting.\ntheme = 'fixture'\n"))
    #expect(contents.contains("researcher"))
    #expect(contents.contains("db"))
    let inspection = try UpdateOperations.inspect(environment: f.environment)
    #expect(inspection.deployments.filter { $0.location == config }.count == 2)
    let role = try #require(inspection.components.first { $0.kind == .subagent })
    let request = UpdateRequest(operation: .remove, selections: [role.selection])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let after = try String(contentsOf: config, encoding: .utf8)
    #expect(after.contains("theme = 'fixture'"))
    #expect(after.contains("db"))
    #expect(!after.contains("researcher"))
    #expect(
      !FileManager.default.fileExists(
        atPath: f.root.appendingPathComponent(".codex/agents/researcher.toml").path))
  }

  @Test func nativePermissionCategoriesPreserveUnselectedCategoriesAndSettings() throws {
    let f = try UpdateFixture()
    let settings = f.root.appendingPathComponent(".claude/settings.json")
    try f.write("{\"telemetry\":false,\"permissions\":{\"deny\":[\"Bash(rm *)\"]}}", to: settings)
    try f.store.save(
      declaration: Declaration(components: [
        .permissions(
          name: "read", rules: [], agents: [.claudeCode],
          native: ["claude-code": ["allow": .array([.string("Read")])]])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    #expect(value?["telemetry"] as? Bool == false)
    #expect((value?["permissions"] as? [String: Any])?["deny"] as? [String] == ["Bash(rm *)"])
    let inspected = try UpdateOperations.inspect(environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(inspected.components.first?.selection)]),
      environment: f.environment
    ) { try $0.apply() }
    let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    #expect((after?["permissions"] as? [String: Any])?["allow"] == nil)
    #expect((after?["permissions"] as? [String: Any])?["deny"] as? [String] == ["Bash(rm *)"])
  }

  @Test(arguments: [AgentID.geminiCLI, .cursor])
  func ignoreBlockPreservesUnmanagedPatternsThroughRemoval(_ agent: AgentID) throws {
    let f = try UpdateFixture()
    let file = f.root.appendingPathComponent(agent == .cursor ? ".cursorignore" : ".geminiignore")
    let custom = "# Preserve user patterns.\nuser-local\n"
    try f.write(custom, to: file)
    try f.store.save(
      declaration: Declaration(components: [
        .ignore(name: "generated", patterns: ["build", "!build/keep"], agents: [agent])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix(custom))
    let current = try UpdateOperations.inspect(environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(current.components.first?.selection)]),
      environment: f.environment
    ) { try $0.apply() }
    #expect(try String(contentsOf: file, encoding: .utf8) == custom)
  }
}

extension NativeCompositionIntegrationTests {
  @Test func opaqueNativePluginRetainsItsWholeFrozenTreeAndExecutionBits() throws {
    let f = try UpdateFixture()
    let source = f.root.appendingPathComponent("plugin-source")
    let tree = source.appendingPathComponent("plugins/demo-plugin")
    try f.write(
      "{\"name\":\"demo-plugin\",\"version\":\"1.0.0\"}",
      to: tree.appendingPathComponent(".claude-plugin/plugin.json"))
    try f.write("#!/bin/sh\n# Never executed.\n", to: tree.appendingPathComponent("scripts/check"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("scripts/check").path)
    try f.store.save(
      declaration: Declaration(
        sources: ["producer": .init(kind: .local, location: source.path)],
        components: [
          .plugin(
            name: "demo-plugin", path: "plugins/demo-plugin", source: "producer", mode: .native,
            agents: [.claudeCode])
        ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let deployment = try #require(snapshot.deployments.first)
    #expect(deployment.status == .current)
    let hash = try FileHash.folderHash(deployment.location)
    let flags = try FileHash.executableFlags(deployment.location)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: f.store.cacheDirectory)
    try FileManager.default.removeItem(at: deployment.location)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try FileHash.folderHash(deployment.location) == hash)
    #expect(try FileHash.executableFlags(deployment.location) == flags)
    try f.write("Unmanaged child", to: deployment.location.appendingPathComponent("user-child"))
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(
        .init(operation: .remove, selections: [try #require(snapshot.components.first?.selection)]),
        environment: f.environment
      ) { try $0.apply() }
    }
    #expect(
      try String(
        contentsOf: deployment.location.appendingPathComponent("user-child"), encoding: .utf8)
        == "Unmanaged child")
  }

  @Test func normalLSPProgramUsesProductionStagedConversion() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .lspServer(
          name: "language", run: .init(executable: "never-run"), languages: [:], agents: [.opencode]
        )
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
  }
}

extension NativeCompositionIntegrationTests {
  @Test(arguments: [false, true])
  func createdNativeContainerPruningPreservesPreexistingContainers(_ existingContainer: Bool) throws
  {
    let f = try UpdateFixture()
    let config = f.root.appendingPathComponent("opencode.json")
    if existingContainer { try f.write("{\"commands\":{},\"userSetting\":false}", to: config) }
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: "Review", prompt: .literal("Review sources."),
          agents: [.opencode])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(snapshot.components.first?.selection)]),
      environment: f.environment
    ) { try $0.apply() }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
    #expect((object?["commands"] != nil) == existingContainer)
    if existingContainer { #expect(object?["userSetting"] as? Bool == false) }
  }

  @Test func normalHookPreservesExistingUnmanagedOccurrence() throws {
    let f = try UpdateFixture()
    let config = f.root.appendingPathComponent(".claude/settings.json")
    try f.write(
      "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"user-hook\"}]}]}}",
      to: config)
    try f.store.save(
      declaration: Declaration(components: [
        .hook(
          name: "check", event: .native("SessionStart"), run: .init(executable: "never-run"),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let text = try String(contentsOf: config, encoding: .utf8)
    #expect(text.contains("user-hook"))
    #expect(text.contains("never-run"))
  }
}

extension NativeCompositionIntegrationTests {
  @Test(arguments: AgentID.allCases, [InstallScope.project, .user])
  func concreteSubagentUsesRegisteredScopeAndColdRestore(_ agent: AgentID, _ scope: InstallScope)
    throws
  {
    let f = try UpdateFixture(scope: scope)
    try f.store.save(
      declaration: Declaration(components: [
        .subagent(
          name: "researcher", description: "Research exact sources",
          prompt: .literal("Read exact sources."), agents: [agent])
      ]), ledger: ResolvedLedger())
    let preview = try f.preview()
    _ = try UpdateOperations.withPreparedUpdate(scope: scope, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let snapshot = try UpdateOperations.inspect(scope: scope, environment: f.environment)
    #expect(!snapshot.deployments.isEmpty)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    let before = try snapshot.deployments.map { try Data(contentsOf: $0.location) }
    let locked = try Data(contentsOf: f.store.resolvedURL)
    for deployment in snapshot.deployments {
      try FileManager.default.removeItem(at: deployment.location)
    }
    _ = try UpdateOperations.restore(scope: scope, environment: f.environment)
    #expect(try snapshot.deployments.map { try Data(contentsOf: $0.location) } == before)
    #expect(try Data(contentsOf: f.store.resolvedURL) == locked)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(snapshot.components.first?.selection)]),
      scope: scope, environment: f.environment
    ) { try $0.apply() }
    #expect(
      try UpdateOperations.inspect(scope: scope, environment: f.environment).components.isEmpty)
  }
}

extension NativeCompositionIntegrationTests {
  @Test func ordinaryRoleEditPreservesAnUnselectedPrivateMCPRegionWithoutProviderReplay() throws {
    struct InitialBindings: RuntimeBindingProvider {
      func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
        Data("private-native-sibling-canary".utf8)
      }
    }
    struct NoReplay: RuntimeBindingProvider {
      func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
        throw CoreError.invalidState("unselected provider was replayed")
      }
    }
    let f = try UpdateFixture()
    func declaration(_ body: String) -> Declaration {
      Declaration(components: [
        .mcpServer(
          name: "private",
          transport: .stdio(
            .init(executable: "never-run", environment: ["TOKEN": .secret("token")])),
          agents: [.codex]),
        .subagent(
          name: "researcher", description: "Research sources", prompt: .literal(body),
          agents: [.codex]),
      ])
    }
    try f.store.save(declaration: declaration("Before."), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: InitialBindings()
    ) { try $0.apply() }
    let request = UpdateRequest(operation: .declaration(declaration("After.")), kinds: [.subagent])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    #expect(
      !String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(
        "private-native-sibling-canary"))
    _ = try UpdateOperations.withPreparedUpdate(
      request, environment: f.environment, bindingProvider: NoReplay()
    ) { try $0.apply(ifUnchangedFrom: preview.displayedFingerprint) }
    let config = f.root.appendingPathComponent(".codex/config.toml")
    #expect(
      try String(contentsOf: config, encoding: .utf8).contains("private-native-sibling-canary"))
    let mode =
      try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
    #expect((mode?.intValue ?? 0) & 0o777 == 0o600)
    #expect(
      try UpdateOperations.inspect(environment: f.environment).deployments.allSatisfy {
        $0.status == .current
      })
  }
}

extension NativeCompositionIntegrationTests {
  @Test func existingOpenCodeJSONCIsOneRecordedPhysicalTargetForMCPAndCommands() throws {
    let f = try UpdateFixture()
    let config = f.root.appendingPathComponent("opencode.jsonc")
    try f.write("// User comment\n{\"userSetting\":true,}\n", to: config)
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: "Review", prompt: .literal("Review sources."),
          agents: [.opencode]),
        .mcpServer(
          name: "db", transport: .stdio(.init(executable: "never-run")), agents: [.opencode]),
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.location == config && $0.status == .current })
    #expect(
      !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("opencode.json").path))
    let bytes = try Data(contentsOf: config)
    #expect(String(decoding: bytes, as: UTF8.self).hasPrefix("// User comment\n"))
    let locked = try Data(contentsOf: f.store.resolvedURL)
    try FileManager.default.removeItem(at: config)
    _ = try UpdateOperations.restore(environment: f.environment)
    let restored = try UpdateOperations.inspect(environment: f.environment)
    #expect(restored.deployments.allSatisfy { $0.location == config && $0.status == .current })
    #expect(try Data(contentsOf: f.store.resolvedURL) == locked)
    #expect(
      !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("opencode.json").path))
  }
}
