import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsUpdates

struct NativeAuthorityIntegrationTests {
  private struct Bindings: RuntimeBindingProvider {
    let value: String
    func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
      Data(value.utf8)
    }
  }
  private struct Refuse: RuntimeBindingProvider {
    func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
      throw CoreError.invalidState("unselected provider called")
    }
  }

  @Test func equalHooksKeepDistinctAuthorityAndRemoveOnlySelectedOccurrence() throws {
    let f = try UpdateFixture()
    let file = f.root.appendingPathComponent(".claude/settings.json")
    try f.write(
      #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"same"}]}]}}"#, to: file)
    try f.store.save(
      declaration: Declaration(
        components: ["first", "second"].map {
          .hook(
            name: $0, event: .native("SessionStart"), run: .init(executable: "same"),
            agents: [.claudeCode])
        }), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    let first = try #require(snapshot.components.first { $0.name == "first" })
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [first.selection]), environment: f.environment
    ) { try $0.apply() }
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var hooks = try #require(object["hooks"] as? [String: Any])
    #expect((hooks["SessionStart"] as? [Any])?.count == 2)
    let remaining = try UpdateOperations.inspect(environment: f.environment)
    #expect(remaining.deployments.allSatisfy { $0.status == .current })
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(remaining.components.first?.selection)]),
      environment: f.environment
    ) { try $0.apply() }
    object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    hooks = try #require(object["hooks"] as? [String: Any])
    #expect((hooks["SessionStart"] as? [Any])?.count == 1)
  }

  @Test func privateHookColdRestoreAndRemovalUseActualArrayEvidence() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .hook(
          name: "check", event: .native("SessionStart"),
          run: .init(executable: "never-run", environment: ["TOKEN": .secret("token")]),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    let preview = try f.preview()
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: Bindings(value: "actual-private-array-canary")
    ) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let file = f.root.appendingPathComponent(".claude/settings.json")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("actual-private-array-canary"))
    let bytes = try Data(contentsOf: f.store.resolvedURL)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("actual-private-array-canary"))
    #expect(text.contains("privateArray"))
    #expect(!text.contains("semanticDigest"))
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    try FileManager.default.removeItem(at: file)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .restore), environment: f.environment,
      bindingProvider: Bindings(value: "restored-private-array-canary")
    ) { try $0.apply() }
    #expect(try String(contentsOf: file, encoding: .utf8).contains("restored-private-array-canary"))
    let restored = try UpdateOperations.inspect(environment: f.environment)
    #expect(restored.deployments.allSatisfy { $0.status == .current })
    _ = snapshot
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(restored.components.first?.selection)]),
      environment: f.environment, bindingProvider: Refuse()
    ) { try $0.apply() }
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["hooks"] == nil)
    #expect(try f.store.readLedger().nativeAuthorities == nil)
  }

  @Test func pruneRightsRetireWhenUnmanagedContainerContentRemains() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: "Review", prompt: .literal("Body"), agents: [.opencode])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let file = f.root.appendingPathComponent("opencode.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var commands = try #require(object["commands"] as? [String: Any])
    commands["user"] = ["template": "unmanaged"]
    object["commands"] = commands
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(snapshot.components.first?.selection)]),
      environment: f.environment
    ) { try $0.apply() }
    #expect(try f.store.readLedger().nativeAuthorities == nil)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("unmanaged"))
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: "Review", prompt: .literal("Again"), agents: [.opencode])
      ]), ledger: try f.store.readLedger())
    _ = try f.apply()
    #expect(
      try f.store.readLedger().nativeAuthorities?.flatMap(\.createdContainers).isEmpty == true)
  }

  @Test func independentScopeSiblingEditRetainsPrivateArrayTokenAndFreshRemoval() throws {
    let f = try UpdateFixture(scope: .user)
    try f.store.save(
      declaration: Declaration(components: [
        .hook(
          name: "private", event: .native("SessionStart"),
          run: .init(executable: "never-run", environment: ["TOKEN": .secret("token")]),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      scope: .user, environment: f.environment,
      bindingProvider: Bindings(value: "cross-scope-private-canary")
    ) { try $0.apply() }
    func receipt(_ store: StateStore) throws -> MaterializationReceipt {
      try store.withLock(footprint: [.claudeSettingsUser]) {
        let target = try store.nativeTarget(for: .claudeSettingsUser)
        return try #require(try store.materializationReceipt(for: target))
      }
    }
    let before = try receipt(f.store)
    let ledgerBytes = try Data(contentsOf: f.store.resolvedURL)
    var other = f.environment
    other.homeDirectory = f.root.appendingPathComponent("other-home")
    try FileManager.default.createDirectory(
      at: other.homeDirectory, withIntermediateDirectories: true)
    let store = StateStore(scope: .user, environment: other)
    try store.save(
      declaration: Declaration(components: [
        .permissions(
          name: "read", rules: [], agents: [.claudeCode],
          native: ["claude-code": ["allow": .array([.string("Read")])]])
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      scope: .user, environment: other, bindingProvider: Refuse()
    ) { try $0.apply() }
    let after = try receipt(f.store)
    #expect(before.generation != after.generation)
    #expect(before.nativeArrays == after.nativeArrays)
    #expect(try Data(contentsOf: f.store.resolvedURL) == ledgerBytes)
    let current = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(current.deployments.allSatisfy { $0.status == .current })
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(current.components.first?.selection)]),
      scope: .user, environment: f.environment, bindingProvider: Refuse()
    ) { try $0.apply() }
    let file = try f.store.withLock(footprint: [.claudeSettingsUser]) {
      try f.store.nativeTarget(for: .claudeSettingsUser).url
    }
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("cross-scope-private-canary"))
    #expect(text.contains("Read"))
  }

  @Test func staleArrayAuthorityDoesNotBlockAnIndependentSelectedSibling() throws {
    let f = try UpdateFixture(scope: .user)
    func declaration(_ allowed: String) -> Declaration {
      Declaration(components: [
        .hook(
          name: "private", event: .native("SessionStart"),
          run: .init(executable: "never-run", environment: ["TOKEN": .secret("token")]),
          agents: [.claudeCode]),
        .permissions(
          name: "read", rules: [], agents: [.claudeCode],
          native: ["claude-code": ["allow": .array([.string(allowed)])]]),
      ])
    }
    try f.store.save(declaration: declaration("Read"), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      scope: .user, environment: f.environment,
      bindingProvider: Bindings(value: "stale-array-private-canary")
    ) { try $0.apply() }
    var other = f.environment
    other.homeDirectory = f.root.appendingPathComponent("other-home")
    try FileManager.default.createDirectory(
      at: other.homeDirectory, withIntermediateDirectories: true)
    let otherStore = StateStore(scope: .user, environment: other)
    try otherStore.save(
      declaration: Declaration(components: [
        .hook(
          name: "foreign", event: .native("SessionStart"),
          run: .init(executable: "foreign-never-run"), agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      scope: .user, environment: other, bindingProvider: Refuse()
    ) { try $0.apply() }
    let ledger = try f.store.readLedger()
    try f.store.save(declaration: declaration("Write"), ledger: ledger)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(kinds: [.permissions], names: ["read"]), scope: .user, environment: f.environment,
      bindingProvider: Refuse()
    ) { try $0.apply() }
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(
        .init(kinds: [.hook], names: ["private"]), scope: .user, environment: f.environment,
        bindingProvider: Refuse()
      ) { try $0.apply() }
    }
    let file = try f.store.withLock(footprint: [.claudeSettingsUser]) {
      try f.store.nativeTarget(for: .claudeSettingsUser).url
    }
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("stale-array-private-canary"))
    #expect(text.contains("foreign-never-run"))
    #expect(text.contains("Write"))
  }

  @Test func privateArrayRollbackRestoresTargetLedgerAndReceiptTogether() throws {
    let f = try UpdateFixture()
    func declaration(_ command: String) -> Declaration {
      Declaration(components: [
        .hook(
          name: "check", event: .native("SessionStart"),
          run: .init(executable: command, environment: ["TOKEN": .secret("token")]),
          agents: [.claudeCode])
      ])
    }
    try f.store.save(declaration: declaration("before"), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: Bindings(value: "before-private")
    ) { try $0.apply() }
    let file = f.root.appendingPathComponent(".claude/settings.json")
    let before = try Data(contentsOf: file)
    let ledger = try Data(contentsOf: f.store.resolvedURL)
    let receipt = try Data(contentsOf: f.store.materializationReceiptURL)
    try f.store.save(declaration: declaration("after"), ledger: try f.store.readLedger())
    var reached = false
    var receiptIndex: Int?
    let result = UpdateOperations.perform(
      environment: f.environment, bindingProvider: Bindings(value: "after-private"),
      checkpoint: { point in
        if point == TransactionCheckpoint.phase(.preparing).name {
          let journal = try #require(
            JSONSerialization.jsonObject(
              with: Data(contentsOf: f.store.directory.appendingPathComponent("transaction.json")))
              as? [String: Any])
          let entries = try #require(journal["entries"] as? [[String: Any]])
          receiptIndex = try #require(
            entries.firstIndex { ($0["path"] as? String) == "state/materializations.json" })
        }
        if let receiptIndex, point == TransactionCheckpoint.progress(receiptIndex, .applied).name {
          reached = true
          throw CoreError.invalidState("injected native publication failure")
        }
      }, { try $0.apply() })
    #expect(reached)
    #expect(result.disposition == .rolledBack)
    #expect(!result.recovery.pending)
    #expect(try Data(contentsOf: file) == before)
    #expect(try Data(contentsOf: f.store.resolvedURL) == ledger)
    #expect(try Data(contentsOf: f.store.materializationReceiptURL) == receipt)
  }

  @Test func deferredLedgerNoopPreservesCapturedEncodingDuringColdRestore() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .command(
          name: "review", description: "Review", prompt: .literal("Frozen body"),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    var original = try Data(contentsOf: f.store.resolvedURL)
    original.append(Data("\n  \n".utf8))
    try original.write(to: f.store.resolvedURL)
    let inspection = try UpdateOperations.inspect(environment: f.environment)
    let target = try #require(inspection.deployments.first?.location)
    let output = try Data(contentsOf: target)
    try FileManager.default.removeItem(at: target)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try Data(contentsOf: target) == output)
    #expect(try Data(contentsOf: f.store.resolvedURL) == original)
  }

  @Test func generatedPrivatePluginUsesProductionBindingsAndRetainsFrozenTree() throws {
    let f = try UpdateFixture()
    let source = f.root.appendingPathComponent("bundle")
    try f.write(
      #"{"name":"upstream","mcpServers":{"native":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/server","env":{"TOKEN":"source-private-canary"}}}}"#,
      to: source.appendingPathComponent(".claude-plugin/plugin.json"))
    try f.write(
      "#!/bin/sh\n# fixture source; never executed\n",
      to: source.appendingPathComponent("bin/server"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("bin/server").path)
    try f.store.save(
      declaration: Declaration(components: [
        .plugin(
          name: "selected", path: "bundle", source: ".", mode: .components, agents: [.claudeCode]),
        .command(
          name: "independent", description: "Independent", prompt: .literal("Body"),
          agents: [.claudeCode]),
      ]), ledger: ResolvedLedger())
    let before = try FileHash.folderHash(f.root)
    let preview = try f.preview()
    #expect(try FileHash.folderHash(f.root) == before)
    let text = try #require(preview.components.first { $0.kind == "plugin" }?.symbolicAfter)
    #expect(text.contains("mcpServers"))
    #expect(text.contains("«binding:"))
    #expect(!text.contains("source-private-canary"))
    #expect(!text.contains("actual-generated-private-canary"))
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment,
      bindingProvider: Bindings(value: "actual-generated-private-canary")
    ) { try $0.apply(ifUnchangedFrom: preview.displayedFingerprint) }
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    let plugin = try #require(snapshot.components.first { $0.kind == .plugin })
    let tree = try #require(
      snapshot.deployments.first { $0.ownerRecords.contains(plugin.record) }?.location)
    let manifest = tree.appendingPathComponent(".claude-plugin/plugin.json")
    #expect(
      try String(contentsOf: manifest, encoding: .utf8).contains("actual-generated-private-canary"))
    #expect(
      !String(decoding: try Data(contentsOf: f.store.resolvedURL), as: UTF8.self).contains(
        "actual-generated-private-canary"))
    #expect(
      !String(decoding: try Data(contentsOf: f.store.resolvedURL), as: UTF8.self).contains(
        "source-private-canary"))
    _ = try UpdateOperations.withPreparedUpdate(
      .init(kinds: [.command], names: ["independent"]), environment: f.environment,
      bindingProvider: Refuse()
    ) { try $0.apply() }
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: tree)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .restore), environment: f.environment,
      bindingProvider: Bindings(value: "cold-generated-private-canary")
    ) { try $0.apply() }
    #expect(
      try String(contentsOf: manifest, encoding: .utf8).contains("cold-generated-private-canary"))
  }

  @Test func generatedGeminiAuthoredVersionOverridesProducerAndSurvivesColdRestore() throws {
    let f = try UpdateFixture(scope: .user)
    let source = f.store.directory.appendingPathComponent("bundle")
    try f.write(
      #"{"name":"upstream","version":"1.2.3"}"#,
      to: source.appendingPathComponent("gemini-extension.json"))
    try f.store.save(
      declaration: Declaration(components: [
        .plugin(
          name: "selected", path: "bundle", source: ".", mode: .components,
          agents: [.geminiCLI], native: ["gemini-cli": ["version": .string("9.8.7")]])
      ]), ledger: ResolvedLedger())
    let preview = try f.preview()
    #expect(preview.components.first?.symbolicAfter?.contains("9.8.7") == true)
    _ = try UpdateOperations.withPreparedUpdate(scope: .user, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installed = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    let tree = try #require(installed.deployments.first?.location)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: tree)
    _ = try UpdateOperations.restore(scope: .user, environment: f.environment)
    let manifest = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: tree.appendingPathComponent("gemini-extension.json")))
        as? [String: Any])
    #expect(manifest["version"] as? String == "9.8.7")
  }

  @Test(arguments: [AgentID.claudeCode, .cursor, .geminiCLI], [false, true])
  func generatedPluginPublishesOnlySelectedMembersAndColdRestores(
    _ agent: AgentID, _ supportingLink: Bool
  ) throws {
    let f = try UpdateFixture(scope: .user)
    let root = f.store.directory.appendingPathComponent("bundle")
    let manifest: String
    let command: String
    switch agent {
    case .claudeCode:
      manifest = ".claude-plugin/plugin.json"
      command = "commands/review.md"
    case .cursor:
      manifest = ".cursor-plugin/plugin.json"
      command = "commands/review.md"
    default:
      manifest = "gemini-extension.json"
      command = "commands/review.toml"
    }
    try f.write(
      #"{"name":"upstream","version":"1.2.3"}"#, to: root.appendingPathComponent(manifest))
    try f.write(
      agent == .geminiCLI
        ? "description = \"Review\"\nprompt = \"Frozen member\"\n"
        : (agent == .cursor ? "Frozen member\n" : "---\ndescription: Review\n---\nFrozen member\n"),
      to: root.appendingPathComponent(command)
    )
    try f.write(
      "---\nname: helper\ndescription: Helper\n---\nFrozen skill\n",
      to: root.appendingPathComponent("skills/helper/SKILL.md"))
    if supportingLink {
      try f.write("Frozen supporting resource", to: root.appendingPathComponent("shared/tool.txt"))
      try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("skills/helper/reference.txt").path,
        withDestinationPath: "../../shared/tool.txt")
    }
    try f.store.save(declaration: Declaration(), ledger: ResolvedLedger())
    try f.write(
      """
      version: 1
      components:
        - kind: plugin
          name: selected
          source: "."
          path: bundle
          agents: ["\(agent.rawValue)"]
        - kind: mcpServer
          name: independent
          transport: {kind: stdio, executable: fixture-command}
          agents: ["\(agent.rawValue)"]
      """, to: f.store.declarationURL)
    let preview = try f.preview()
    _ = try UpdateOperations.withPreparedUpdate(scope: .user, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let memberPreview = try #require(
      preview.components.first { $0.kind == "plugin" }?.symbolicAfter)
    #expect(memberPreview.contains("Target: "))
    #expect(memberPreview.contains(command))
    #expect(memberPreview.contains("Frozen member"))
    #expect(memberPreview.contains("skills/helper/SKILL.md"))
    #expect(memberPreview.contains("Frozen skill"))
    #expect(!memberPreview.contains("\"kind\":\"object\""))
    let ledger = try f.store.readLedger()
    #expect(ledger.lowerings.filter { $0.format.hasSuffix("-generated-plugin@1") }.count == 1)
    #expect(ledger.deployments.filter { $0.route == "agents/skill@1" }.isEmpty)
    #expect(ledger.deployments.count == 2)
    let snapshot = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    let plugin = try #require(snapshot.components.first { $0.kind == .plugin })
    let tree = try #require(
      snapshot.deployments.first { $0.ownerRecords.contains(plugin.record) }?.location)
    #expect(
      try String(contentsOf: tree.appendingPathComponent(command), encoding: .utf8).contains(
        "Frozen member"))
    #expect(
      try String(contentsOf: tree.appendingPathComponent("skills/helper/SKILL.md"), encoding: .utf8)
        .contains("Frozen skill"))
    if supportingLink {
      #expect(
        try String(
          contentsOf: tree.appendingPathComponent("skills/helper/reference.txt"), encoding: .utf8)
          == "Frozen supporting resource")
    }
    let unmanaged = tree.appendingPathComponent("unmanaged-empty")
    try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: true)
    #expect(
      try UpdateOperations.inspect(scope: .user, environment: f.environment).deployments.contains {
        $0.location == tree && $0.status == .drifted
      })
    #expect(throws: (any Error).self) { try f.preview() }
    try FileManager.default.removeItem(at: unmanaged)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.removeItem(at: tree)
    _ = try UpdateOperations.restore(scope: .user, environment: f.environment)
    #expect(
      try String(contentsOf: tree.appendingPathComponent(command), encoding: .utf8).contains(
        "Frozen member"))
    let restored = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(restored.deployments.allSatisfy { $0.status == .current })
    if agent == .geminiCLI {
      let native = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: tree.appendingPathComponent(manifest)))
          as? [String: Any])
      #expect(native["version"] as? String == "1.2.3")
    }
    if supportingLink {
      #expect(
        try String(
          contentsOf: tree.appendingPathComponent("skills/helper/reference.txt"), encoding: .utf8)
          == "Frozen supporting resource")
    }
    _ = try UpdateOperations.withPreparedUpdate(
      .init(
        operation: .remove,
        selections: [try #require(restored.components.first { $0.kind == .plugin }?.selection)]),
      scope: .user, environment: f.environment
    ) { try $0.apply() }
    #expect(!FileManager.default.fileExists(atPath: tree.path))
    #expect(
      try UpdateOperations.inspect(scope: .user, environment: f.environment).deployments.count == 1)
  }
}
