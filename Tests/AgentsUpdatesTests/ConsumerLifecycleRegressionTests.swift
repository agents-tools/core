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
