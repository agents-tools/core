import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction lifecycle safety")
struct InstructionLifecycleSafetyTests {
  @Test func unavailablePinAndDigestMismatchStopBeforeAnyTargetReplacement() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(agents: [.codex, .geminiCLI])
    let original = try fixture.store().loadResolved()
    var lock = original
    lock.instructions.sections[0].revision = String(repeating: "a", count: 40)
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), resolved: lock)
    try fixture.write("Custom target.\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
    let before = try fixture.snapshot(fixture.project, excludingCache: true)
    #expect(throws: (any Error).self) {
      try InstructionOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.snapshot(fixture.project, excludingCache: true) == before)
    lock = original
    lock.instructions.sections[0].hash = "sha256:" + String(repeating: "a", count: 64)
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), resolved: lock)
    #expect(throws: (any Error).self) {
      try InstructionOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.text() == "Custom target.\n")
  }

  @Test func targetChangesInsideCallbackCancelCommit() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let lock = try Data(contentsOf: fixture.store().resolvedURL)
    #expect(throws: (any Error).self) {
      try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true) {
        _ in
        try fixture.write(
          "Concurrent edit.\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
      }
    }
    #expect(try fixture.text() == "Concurrent edit.\n")
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lock)
  }

  @Test func installRestoresTheLockedRenderingOverEdits() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let locked = try fixture.bytes()
    try fixture.write("", to: fixture.project.appendingPathComponent("AGENTS.md"))
    _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(try fixture.bytes() == locked)
    try fixture.write(
      "## rules\n\nEdited.\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
    let report = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(report.targets.first?.drift == .drifted)
    #expect(try fixture.bytes() == locked)
  }

  @Test func addPreservesOtherPinsAndSharedSkillState() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    try fixture.add(names: ["one"])
    var declaration = try fixture.store().loadDeclaration()
    var lock = try fixture.store().loadResolved()
    let previous = lock.instructions.sections[0]
    declaration.skills = ["rules": SkillDeclaration(select: .names([]))]
    lock.skills["example"] = LockedSkill(
      source: previous.source, revision: previous.revision,
      path: "skills/example", hash: previous.hash, installs: ["codex": .copy])
    try fixture.store().save(declaration: declaration, resolved: lock)
    try fixture.section("one", body: "Changed")
    try fixture.commit()
    try fixture.add(names: ["two"])
    #expect(try fixture.store().loadResolved().instructions.sections[0] == previous)
    #expect(try fixture.store().loadResolved().skills == lock.skills)
    #expect(try fixture.store().loadDeclaration().skills == declaration.skills)
    #expect(try !fixture.text().contains("Changed"))
  }

  @Test func sourceInspectionAndSelectionStopDoNotDeclareAnything() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    let before = try fixture.snapshot()
    let outcome = try InstructionOperations.add(
      InstructionAddOptions(source: fixture.repo.path, environment: fixture.environment))
    #expect(outcome.result == nil)
    #expect(outcome.available.map(\.record.name) == ["one", "two"])
    #expect(try fixture.snapshot() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.store().declarationURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent("AGENTS.md").path))
  }

  @Test func automaticSelectionAppliesCommittedInstructions() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let revision = try fixture.git(["rev-parse", "HEAD"])
    try fixture.section("rules", body: "Uncommitted")
    let outcome = try InstructionOperations.add(
      InstructionAddOptions(
        source: fixture.repo.path, agents: [.codex], environment: fixture.environment))
    #expect(outcome.result?.hasChanges == true)
    #expect(outcome.available.map(\.record.name) == ["rules"])
    #expect(try fixture.store().loadResolved().instructions.sections.first?.revision == revision)
    #expect(try fixture.text().contains("Original"))
    #expect(try !fixture.text().contains("Uncommitted"))
  }

  @Test func invalidSourceAndDuplicateNamesNeverPublishTargets() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("one", container: ".agents/instructions")
    try fixture.commit()
    #expect(throws: (any Error).self) { try fixture.add() }
    try FileManager.default.removeItem(
      at: fixture.repo.appendingPathComponent(".agents/instructions/one.md"))
    try fixture.write("No title.\n", to: fixture.repo.appendingPathComponent("instructions/one.md"))
    try fixture.commit()
    #expect(throws: (any Error).self) { try fixture.add() }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
  }

  @Test func removalKeepsAnEditedTargetAndCleansForwarder() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.write("Claude custom.\n", to: fixture.project.appendingPathComponent("CLAUDE.md"))
    try fixture.add()
    let edited = try fixture.text() + "\n# Custom\n\nKeep.\n"
    try fixture.write(edited, to: fixture.project.appendingPathComponent("AGENTS.md"))
    try InstructionOperations.remove(names: ["rules"], environment: fixture.environment)
    #expect(try fixture.text() == edited)
    #expect(try fixture.text("CLAUDE.md") == "Claude custom.\n")
  }

  @Test func unsafeTargetsDoNotEscapeScope() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let outside = fixture.root.appendingPathComponent("outside.md")
    try fixture.write("Owner content.\n", to: outside)
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent("AGENTS.md"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try fixture.add() }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "Owner content.\n")
  }

  @Test func promptAppendCannotEscapeScopeThroughSymlinks() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    var declaration = try fixture.store().loadDeclaration()
    declaration.instructions?.chatgpt = [
      "prompt": PromptDeclaration(sections: ["rules:rules"], append: "custom.md")
    ]
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    let outside = fixture.root.appendingPathComponent("outside.md")
    try fixture.write("Owner content.\n", to: outside)
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent("custom.md"), withDestinationURL: outside)
    #expect(throws: (any Error).self) {
      try InstructionOperations.renderChatGPT(prompt: "prompt", environment: fixture.environment)
    }
  }

  @Test func sourceInstructionsDirectoryCannotBeATarget() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    var runtime = fixture.environment
    runtime.projectDirectory = fixture.repo.appendingPathComponent("instructions")
    #expect(throws: (any Error).self) { try fixture.add(environment: runtime) }
    #expect(
      !FileManager.default.fileExists(
        atPath: runtime.projectDirectory.appendingPathComponent("AGENTS.md").path))
  }
}
