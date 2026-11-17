import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ConsumerLifecycleRegressionTests {
  @Test(arguments: ["valid", "missing", "escape"])
  func frozenRestoreValidatesReceivingCheckoutLinks(mode: String) throws {
    let f = try UpdateFixture()
    let guide = f.root.appendingPathComponent("guide.md")
    try f.write("Guide", to: guide)
    try f.write(
      "---\ndescription: Rules.\n---\n# Rules\n\n[Guide](guide.md)\n",
      to: f.repo.appendingPathComponent("instructions/rules.md"))
    try f.commit()
    try f.install(agents: [.codex])
    let locked = try f.bytes(f.instruction())
    try f.write(
      "mutable author must not be read", to: f.repo.appendingPathComponent("instructions/rules.md"))
    try f.write(String(decoding: locked, as: UTF8.self) + "\nEdited\n", to: f.instruction())
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "restore-link-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: outside) }
    if mode != "valid" { try FileManager.default.removeItem(at: guide) }
    if mode == "escape" {
      try f.write("Outside", to: outside)
      try FileManager.default.createSymbolicLink(at: guide, withDestinationURL: outside)
    }
    let before = try f.snapshot()
    var delivered = false
    do {
      _ = try UpdateOperations.withPreparedUpdate(
        UpdateRequest(operation: .restore), environment: f.environment
      ) {
        delivered = true
        return try $0.apply()
      }
      #expect(mode == "valid")
      #expect(try f.bytes(f.instruction()) == locked)
    } catch {
      if mode == "valid" { throw error }
      #expect(!delivered)
      #expect(try f.snapshot() == before)
    }
  }

  @Test func restoreRechecksLinkDestinationBeforePublication() throws {
    let f = try UpdateFixture()
    let guide = f.root.appendingPathComponent("guide.md")
    try f.write("Guide", to: guide)
    try f.write(
      "---\ndescription: Rules.\n---\n# Rules\n\n[Guide](guide.md)\n",
      to: f.repo.appendingPathComponent("instructions/rules.md"))
    try f.commit()
    try f.install(agents: [.codex])
    try f.write(
      String(decoding: f.bytes(f.instruction()), as: UTF8.self) + "\nEdited\n", to: f.instruction())
    let before = try f.snapshot()
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(
        UpdateRequest(operation: .restore), environment: f.environment
      ) {
        try FileManager.default.removeItem(at: guide)
        return try $0.apply()
      }
    }
    #expect(try f.snapshot() == before)
  }

  @Test func ordinaryPartialRemovalKeepsSharedInstructionTargetAndSurvivingPins() throws {
    let f = try UpdateFixture()
    try f.write(
      "---\ndescription: Other.\n---\n# Other\n\nFrozen survivor\n",
      to: f.repo.appendingPathComponent("instructions/other.md"))
    try f.commit()
    try f.declare(agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    try declaration.updateInstructions { $0?.sections.append("fixture:other") }
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    let previous = try f.store.readLedger()
    let skillBytes = try f.bytes(f.target().appendingPathComponent("SKILL.md"))
    try f.advance()
    try f.write(
      "---\ndescription: Other.\n---\n# Other\n\nMutable producer changed\n",
      to: f.repo.appendingPathComponent("instructions/other.md"))
    try f.commit()
    let before = try f.snapshot()
    let preview = try UpdateOperations.preview(
      .init(operation: .remove, kinds: [.instructions], names: ["rules"]),
      environment: f.environment)
    let target = try #require(preview.instructions.targets.first { $0.url == f.instruction() })
    let after = try #require(target.after)
    #expect(String(decoding: after, as: UTF8.self).contains("Frozen survivor"))
    #expect(!String(decoding: after, as: UTF8.self).contains("# Rules"))
    #expect(target.afterAgents == [.codex])
    #expect(try f.snapshot() == before)
    _ = try InstructionOperations.remove(names: ["rules"], environment: f.environment)
    #expect(try f.bytes(f.instruction()) == after)
    #expect(try f.bytes(f.target().appendingPathComponent("SKILL.md")) == skillBytes)
    let next = try f.store.readLedger()
    for (id, component) in previous.components
    where component.kind == "skills" || component.name == "other" {
      #expect(next.components[id] == component)
      #expect(next.sources[component.source] == previous.sources[component.source])
    }
    let deployment = try #require(
      next.deployments.first {
        $0.route == "agents/instructions@1" && $0.target.path == "AGENTS.md"
      })
    #expect(deployment.expectedHash == "sha256:" + FileHash.sha256Hex(data: after))
    #expect(
      try UpdateOperations.inspect(environment: f.environment).deployments.filter {
        $0.location == f.instruction()
      }.allSatisfy { $0.status == .current })
  }

  @Test func handwrittenSharedInstructionPartialRemovalRefusesBeforeCallback() throws {
    let f = try UpdateFixture()
    try f.write(
      "---\ndescription: Other.\n---\n# Other\n",
      to: f.repo.appendingPathComponent("instructions/other.md"))
    try f.commit()
    try f.declare(agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    try declaration.updateInstructions { $0?.sections.append("fixture:other") }
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    try f.write("Handwritten shared destination", to: f.instruction())
    let before = try f.snapshot()
    let preview = try UpdateOperations.preview(
      .init(operation: .remove, kinds: [.instructions], names: ["rules"]),
      environment: f.environment)
    let target = try #require(preview.instructions.targets.first { $0.url == f.instruction() })
    #expect(target.foreign)
    #expect(target.after != nil)
    var callbacks = 0
    #expect(throws: InstructionError.self) {
      try InstructionOperations.remove(names: ["rules"], environment: f.environment) { _ in
        callbacks += 1
      }
    }
    #expect(callbacks == 0)
    #expect(try f.snapshot() == before)
  }

  @Test func explicitRemovalRetargetsSurvivorsAndKeepsSkillPin() throws {
    let f = try UpdateFixture()
    try f.write(
      "---\ndescription: Other.\n---\n# Other\n",
      to: f.repo.appendingPathComponent("instructions/other.md"))
    try f.commit()
    try f.declare(agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    try declaration.updateInstructions { $0?.sections.append("fixture:other") }
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    let previous = try f.store.readLedger()
    let skill = try f.bytes(f.target().appendingPathComponent("SKILL.md"))
    try f.advance()
    _ = try InstructionOperations.remove(
      names: ["other"], agents: [.geminiCLI], environment: f.environment)
    #expect(!FileManager.default.fileExists(atPath: f.instruction().path))
    #expect(
      String(decoding: try f.bytes(f.instruction(.geminiCLI)), as: UTF8.self).contains("# Rules"))
    #expect(try f.bytes(f.target().appendingPathComponent("SKILL.md")) == skill)
    let next = try f.store.readLedger()
    for (id, component) in previous.components where component.kind == "skills" {
      #expect(next.components[id] == component)
    }
  }

  @Test func survivorRetargetDoesNotAuthorizeChangedOwnContent() throws {
    let f = try UpdateFixture()
    let own = f.root.appendingPathComponent(".agent/instructions/guide.md")
    try f.write("---\ndescription: Own.\n---\n# Own\n\nLocked\n", to: own)
    try f.declare(agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    try declaration.updateInstructions { $0?.sections = ["guide", "fixture:rules"] }
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    try f.write("---\ndescription: Own.\n---\n# Own\n\nChanged\n", to: own)
    let before = try f.snapshot()
    var delivered = false
    #expect(throws: (any Error).self) {
      try InstructionOperations.remove(
        names: ["rules"], agents: [.geminiCLI], environment: f.environment
      ) { _ in delivered = true }
    }
    #expect(!delivered)
    #expect(try f.snapshot() == before)
  }

  @Test func instructionMutationRefusesUnappliedSkillRecipientChange() throws {
    let f = try UpdateFixture()
    try f.install(agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    declaration.components = declaration.components.map {
      guard case .skills(let source, var selection) = $0 else { return $0 }
      selection.agents = [.cursor]
      return .skills(source: source, selection)
    }
    try f.store.save(declaration: declaration, ledger: f.store.readLedger())
    let before = try f.snapshot()
    var delivered = false
    #expect(throws: (any Error).self) {
      try InstructionOperations.add(
        InstructionAddOptions(
          source: f.repo.path, alias: "fixture", names: ["rules"], environment: f.environment)
      ) { _ in delivered = true }
    }
    #expect(!delivered)
    #expect(try f.snapshot() == before)
  }

  @Test func retainedEditedOutputReportsNoManagedRecipients() throws {
    let f = try UpdateFixture()
    try f.install(agents: [.codex])
    try f.write("edited generated output", to: f.instruction())
    let report = try InstructionOperations.remove(names: ["rules"], environment: f.environment)
    let target = try #require(report.targets.first { $0.url == f.instruction() })
    #expect(target.before == target.after)
    #expect(target.afterAgents.isEmpty)
    #expect(try f.bytes(f.instruction()) == Data("edited generated output".utf8))
  }

  @Test func foreignTakeoverRefusesBeforeCallbackButPreviewRemainsAvailable() throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.codex])
    try f.write("handwritten", to: f.instruction())
    let before = try f.snapshot()
    #expect(try f.preview().instructions.targets.contains { $0.foreign })
    var delivered = false
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(environment: f.environment) {
        delivered = true
        return try $0.apply()
      }
    }
    #expect(!delivered)
    #expect(try f.snapshot() == before)
  }

  @Test func missingLiveSkillReconciliationReplaysOnlyPreviousNativeResources() throws {
    let f = try UpdateFixture()
    try f.declare(mode: .edit, agents: [.codex])
    var declaration = try f.store.loadDeclaration()
    declaration.components.append(
      .command(
        name: "review", description: "Review", prompt: .literal("Frozen review"),
        agents: [.claudeCode]))
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    let ledger = try f.store.readLedger()
    let command = try #require(ledger.deployments.first { $0.route.hasSuffix("-components@1") })
    let commandURL = try command.target.resolve(roots: f.store.ledgerRoots)
    let commandBytes = try f.bytes(commandURL)
    try FileManager.default.removeItem(at: f.repo.appendingPathComponent("skills/demo"))
    let before = try f.snapshot()
    #expect(throws: (any Error).self) { try UpdateOperations.restore(environment: f.environment) }
    #expect(try f.snapshot() == before)
    _ = try SkillOperations.updateInstalled(environment: f.environment, apply: true)
    #expect(try f.store.loadResolved().skills.isEmpty)
    #expect(try f.bytes(commandURL) == commandBytes)
  }

  @Test func namedSkillActionsDoNotReadUnselectedFIFO() throws {
    let f = try UpdateFixture()
    try f.write(
      "---\nname: broken\ndescription: Broken.\n---\nBroken\n",
      to: f.repo.appendingPathComponent("skills/broken/SKILL.md"))
    try f.commit()
    try f.declare(agents: [.codex])
    _ = try f.apply()
    let broken = f.target().deletingLastPathComponent().appendingPathComponent("broken")
    let fifo = broken.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let brokenBytes = try f.bytes(broken.appendingPathComponent("SKILL.md"))
    try f.advance()
    let updated = try SkillOperations.updateInstalled(
      environment: f.environment, skillNames: ["demo"], apply: true)
    #expect(updated.map(\.skill) == ["demo"])
    _ = try SkillOperations.remove(skillNames: ["demo"], environment: f.environment)
    #expect(try f.bytes(broken.appendingPathComponent("SKILL.md")) == brokenBytes)
    var info = stat()
    #expect(lstat(fifo.path, &info) == 0)
    #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    let before = try f.snapshot()
    #expect(throws: (any Error).self) {
      try SkillOperations.updateInstalled(
        environment: f.environment, skillNames: ["broken"], apply: true)
    }
    #expect(try f.snapshot() == before)
  }
}

extension ConsumerLifecycleRegressionTests {
  private func finiteRules(_ f: UpdateFixture) -> Declaration {
    Declaration(
      sources: ["fixture": SourceDeclaration(kind: .local, location: f.repo.path)],
      components: [
        .instructions(InstructionsDeclaration(agents: [.codex], sections: ["fixture:extra"]))
      ])
  }

  private func writeFiniteRules(_ f: UpdateFixture) throws {
    try f.write(
      "---\ndescription: Extra.\n---\n# Extra\n\nSelected addition\n",
      to: f.repo.appendingPathComponent("instructions/extra.md"))
    try f.commit()
  }

  @Test func finiteAdditionPreservesPinsAndSharedInstructionSurvivors() throws {
    let f = try UpdateFixture()
    try f.install(agents: [.codex])
    let previous = try f.store.loadLedger()
    let original = try f.store.loadDeclaration()
    try f.advance()
    try writeFiniteRules(f)
    let before = try FileHash.folderHash(f.root)
    let scope = try UpdateOperations.inspect(environment: f.environment)
    let discovery = try #require(try UpdateOperations.captureAddition(finiteRules(f), in: scope))
    #expect(try FileHash.folderHash(f.root) == before)
    var request = discovery.updateRequest()
    request.replace = true
    request.changingAccess = true
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    let target = try #require(preview.instructions.targets.first { $0.url == f.instruction() })
    let bytes = try #require(target.after)
    #expect(String(decoding: bytes, as: UTF8.self).contains("Selected addition"))
    #expect(String(decoding: bytes, as: UTF8.self).contains("old"))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("\nnew\n"))
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(try f.bytes(f.instruction()) == bytes)
    let next = try f.store.loadLedger()
    for (id, component) in previous.components {
      #expect(next.components[id] == component)
      #expect(next.sources[component.source] == previous.sources[component.source])
    }
    let declaration = try f.store.loadDeclaration()
    #expect(Array(declaration.components.prefix(original.components.count)) == original.components)
    #expect(declaration.sources["fixture"] == original.sources["fixture"])
  }

  @Test func capturedAdditionRejectsForeignDestinationAndMutatedRequest() throws {
    let f = try UpdateFixture()
    let other = try UpdateFixture()
    try writeFiniteRules(f)
    for fixture in [f, other] {
      try fixture.store.save(declaration: Declaration(agents: [.codex]), ledger: ResolvedLedger())
    }
    #expect(try f.bytes(f.store.declarationURL) == other.bytes(other.store.declarationURL))
    var environment = f.environment
    environment.environment["INSPECTION_SECRET"] = "CAPTURED_ENVIRONMENT_CANARY"
    let inspection = try UpdateOperations.inspect(environment: environment)
    #expect(!String(reflecting: inspection).contains("CAPTURED_ENVIRONMENT_CANARY"))
    let discovery = try #require(
      try UpdateOperations.captureAddition(finiteRules(f), in: inspection))
    #expect(!String(reflecting: discovery).contains("CAPTURED_ENVIRONMENT_CANARY"))
    let otherBefore = try FileHash.folderHash(other.root)
    var called = false
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(
        discovery.updateRequest(), environment: other.environment
      ) {
        _ in called = true
      }
    }
    #expect(!called)
    #expect(try FileHash.folderHash(other.root) == otherBefore)
    var modified = discovery.updateRequest()
    modified.operation = .update
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(modified, environment: f.environment)
    }
    _ = try UpdateOperations.withPreparedUpdate(
      discovery.updateRequest(), environment: f.environment
    ) {
      try $0.apply()
    }
    #expect(try f.store.loadDeclaration().sources["fixture"] != nil)
  }

  @Test(arguments: ["declaration", "ledger", "source"])
  func capturedAdditionRejectsChangedEvidence(_ changed: String) throws {
    let f = try UpdateFixture()
    try f.install(agents: [.codex])
    try writeFiniteRules(f)
    let discovery = try #require(
      try UpdateOperations.captureAddition(
        finiteRules(f), in: UpdateOperations.inspect(environment: f.environment)))
    if changed == "declaration" {
      try f.write(
        String(decoding: f.bytes(f.store.declarationURL), as: UTF8.self) + "\n# changed\n",
        to: f.store.declarationURL)
    } else if changed == "ledger" {
      try f.write(
        String(decoding: f.bytes(f.store.resolvedURL), as: UTF8.self) + "\n",
        to: f.store.resolvedURL)
    } else {
      try f.write(
        "---\ndescription: Extra.\n---\n# Extra\n\nChanged selected source\n",
        to: f.repo.appendingPathComponent("instructions/extra.md"))
      try f.commit()
    }
    var called = false
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(discovery.updateRequest(), environment: f.environment)
      {
        _ in called = true
      }
    }
    #expect(!called)
  }

  @Test func emptyAdditionDoesNotInitializeAndPendingAuthoredGraphIsProtected() throws {
    let f = try UpdateFixture()
    let scope = try UpdateOperations.inspect(environment: f.environment)
    let before = try FileHash.folderHash(f.root)
    #expect(
      try UpdateOperations.captureAddition(
        Declaration(sources: ["unused": .init(kind: .local, location: "/absent")]), in: scope)
        == nil)
    #expect(try FileHash.folderHash(f.root) == before)
    try f.declare(agents: [.codex])
    try writeFiniteRules(f)
    #expect(throws: (any Error).self) {
      try UpdateOperations.captureAddition(
        finiteRules(f), in: UpdateOperations.inspect(environment: f.environment))
    }
  }
}

extension ConsumerLifecycleRegressionTests {
  @Test(arguments: [false, true])
  func finiteAdditionProtectsConditionalProducerUsesAndConflictingPins(_ sharedSource: Bool) throws
  {
    let f = try UpdateFixture()
    let producerFixture = try sharedSource ? f : UpdateFixture()
    try producerFixture.write(
      """
      version: 1
      groups:
        tools:
          components: [{kind: mcpServer, name: protected-tool, transport: {kind: stdio, executable: never-run}, agents: [claude-code]}]
      exports: [tools]
      """, to: producerFixture.repo.appendingPathComponent(".agent/agents.yaml"))
    try producerFixture.commit()
    try f.declare(agents: [.codex])
    var original = try f.store.loadDeclaration()
    let alias = sharedSource ? "fixture" : "producer"
    if !sharedSource {
      original.sources[alias] = .init(kind: .local, location: producerFixture.repo.path)
    }
    original.uses = [.init(name: "tools", source: alias, condition: .init(scopes: [.project]))]
    try f.store.save(declaration: original, ledger: ResolvedLedger())
    _ = try f.apply()
    let previous = try UpdateOperations.inspect(environment: f.environment)
    let producer = try #require(previous.components.first { $0.name == "protected-tool" })
    #expect(producer.occurrences.allSatisfy { !$0.consumerEditable })
    try writeFiniteRules(f)
    let scope = try UpdateOperations.inspect(environment: f.environment)
    var conflicting = finiteRules(f)
    conflicting.sources["fixture"]?.location = f.root.path
    #expect(throws: (any Error).self) {
      try UpdateOperations.captureAddition(conflicting, in: scope)
    }
    if sharedSource {
      let before = try f.snapshot()
      #expect(throws: (any Error).self) {
        try UpdateOperations.captureAddition(finiteRules(f), in: scope)
      }
      #expect(try f.snapshot() == before)
      return
    }
    let discovery = try #require(try UpdateOperations.captureAddition(finiteRules(f), in: scope))
    let preview = try UpdateOperations.preview(
      discovery.updateRequest(), environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      discovery.updateRequest(), environment: f.environment
    ) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let next = try UpdateOperations.inspect(environment: f.environment)
    let retained = try #require(next.components.first { $0.name == "protected-tool" })
    #expect(retained.revision == producer.revision)
    #expect(retained.configuration == producer.configuration)
    #expect(retained.conditions == producer.conditions)
    #expect(retained.occurrences.allSatisfy { !$0.consumerEditable })
    #expect(try f.store.loadDeclaration().uses == original.uses)
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(
        .init(operation: .remove, selections: [retained.selection]),
        environment: f.environment)
    }
  }

}

extension ConsumerLifecycleRegressionTests {
  @Test func finiteAdditionRefusesNewForeignTargetBeforeCallback() throws {
    let f = try UpdateFixture()
    try writeFiniteRules(f)
    let discovery = try #require(
      try UpdateOperations.captureAddition(
        finiteRules(f), in: UpdateOperations.inspect(environment: f.environment)))
    _ = try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
    try f.write("Handwritten after preview\n", to: f.instruction())
    var called = false
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(discovery.updateRequest(), environment: f.environment)
      {
        _ in called = true
      }
    }
    #expect(!called)
    #expect(try f.bytes(f.instruction()) == Data("Handwritten after preview\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: f.store.declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: f.store.resolvedURL.path))
  }
}

extension ConsumerLifecycleRegressionTests {
  @Test func finiteNamedCommandAdmitsItsNewClosedRoute() throws {
    let f = try UpdateFixture()
    let scope = try UpdateOperations.inspect(environment: f.environment)
    let discovery = try #require(
      try UpdateOperations.captureAddition(
        Declaration(components: [
          .command(
            name: "review", description: "Review sources",
            prompt: .literal("Review exact sources."), agents: [.claudeCode])
        ]), in: scope))
    let before = try FileHash.folderHash(f.root)
    let preview = try UpdateOperations.preview(
      discovery.updateRequest(), environment: f.environment)
    #expect(try FileHash.folderHash(f.root) == before)
    _ = try UpdateOperations.withPreparedUpdate(
      discovery.updateRequest(), environment: f.environment
    ) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installed = try UpdateOperations.inspect(environment: f.environment)
    let deployment = try #require(installed.deployments.first)
    #expect(deployment.status == .current)
    #expect(
      try String(contentsOf: deployment.location, encoding: .utf8).contains("Review exact sources.")
    )
  }
}
