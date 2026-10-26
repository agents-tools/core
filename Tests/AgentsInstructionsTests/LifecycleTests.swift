import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction lifecycle")
struct InstructionLifecycleTests {
  @Test func recipientOnlyUpdateReportsAndAppliesLockChanges() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(agents: [.codex])
    let bytes = try fixture.bytes()
    let lock = try Data(contentsOf: fixture.store().resolvedURL)
    let declaration = try Data(contentsOf: fixture.store().declarationURL)
    let preview = try InstructionOperations.updateInstalled(
      agents: [.cursor], environment: fixture.environment)
    let target = try #require(preview.targets.first)
    #expect(preview.targets.count == 1)
    #expect(target.target == "AGENTS.md")
    #expect(target.beforeAgents == [.codex])
    #expect(target.afterAgents == [.cursor])
    #expect(target.agentsChanged)
    #expect(!target.changed)
    #expect(preview.sections.isEmpty && preview.changedPrompts.isEmpty && !preview.lockMissing)
    #expect(preview.hasChanges)
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lock)
    #expect(try Data(contentsOf: fixture.store().declarationURL) == declaration)
    _ = try InstructionOperations.updateInstalled(
      agents: [.cursor], environment: fixture.environment, apply: true
    ) { report in
      #expect(report == preview)
    }
    #expect(try fixture.bytes() == bytes)
    #expect(
      try fixture.store().loadResolved().instructions.targets["AGENTS.md"]?.agents == [.cursor])
    #expect(try fixture.store().loadDeclaration().instructions?.agents == [.cursor])
    let unchanged = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(!unchanged.hasChanges)
    #expect(unchanged.targets.allSatisfy { !$0.changed && !$0.agentsChanged })
  }

  @Test func recipientOrderDoesNotReportChanges() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(agents: [.opencode, .cursor, .codex])
    let report = try InstructionOperations.updateInstalled(
      agents: [.cursor, .codex, .opencode], environment: fixture.environment)
    let target = try #require(report.targets.first)
    #expect(target.beforeAgents == [.codex, .cursor, .opencode])
    #expect(target.afterAgents == [.codex, .cursor, .opencode])
    #expect(!target.agentsChanged)
    #expect(!report.hasChanges)
  }

  @Test func sectionOrderChangesAreReportedWithoutPhysicalTargets() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    try fixture.add(names: ["one", "two"], scope: .user, agents: [.cursor])
    let store = fixture.store(.user)
    var declaration = try store.loadDeclaration()
    declaration.instructions?.sections.reverse()
    try store.save(declaration: declaration, resolved: store.loadResolved())
    let report = try InstructionOperations.updateInstalled(
      scope: .user, environment: fixture.environment)
    #expect(report.sections.isEmpty && report.targets.isEmpty && report.changedPrompts.isEmpty)
    #expect(report.hasChanges)
    _ = try InstructionOperations.updateInstalled(
      scope: .user, environment: fixture.environment, apply: true)
    #expect(try store.loadResolved().instructions.sections.map(\.name) == ["two", "one"])
    #expect(
      try !InstructionOperations.updateInstalled(scope: .user, environment: fixture.environment)
        .hasChanges)
  }

  @Test func promptPinChangesAreReportedWhenRenderedBytesAreIdentical() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let store = fixture.store()
    try store.save(
      declaration: Declaration(
        sources: ["rules": SourceDeclaration(kind: .local, location: fixture.repo.path)],
        instructions: InstructionsDeclaration(
          chatgpt: ["daily": PromptDeclaration(sections: ["rules:rules"])])),
      resolved: ResolvedState())
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    let original = try InstructionOperations.renderChatGPT(
      prompt: "daily", environment: fixture.environment)
    try fixture.git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "new revision"])
    let report = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(report.sections.isEmpty && report.targets.isEmpty && report.changedPrompts.isEmpty)
    #expect(report.hasChanges)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try store.loadResolved().instructions.chatgpt["daily"]?.sections.first?.revision
        == fixture.git(["rev-parse", "HEAD"]))
    #expect(
      try InstructionOperations.renderChatGPT(prompt: "daily", environment: fixture.environment)
        == original)
    #expect(try !InstructionOperations.updateInstalled(environment: fixture.environment).hasChanges)
  }

  @Test func emptyScopeHasNoUpdateChanges() throws {
    let fixture = try InstructionFixture()
    let report = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(report.lockMissing)
    #expect(!report.hasChanges)
  }

  @Test func generatedTargetRestoresLockedContentAndReplacesDrift() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    try fixture.add(names: ["two", "one"])
    let first = try fixture.bytes()
    #expect(try fixture.text() == generated(["# two\n\nOriginal", "# one\n\nOriginal"]))
    let lock = try Data(contentsOf: fixture.store().resolvedURL)
    _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(try fixture.bytes() == first)
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lock)
    try fixture.write(
      try fixture.text().replacingOccurrences(of: "Original", with: "Drift"),
      to: fixture.project.appendingPathComponent("AGENTS.md"))
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .drift
      })
    try fixture.section("one", body: "Upstream")
    try fixture.commit()
    let preview = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(preview.targets[0].drift == .drifted)
    #expect(!preview.targets[0].foreign)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.text() == generated(["# two\n\nOriginal", "# one\n\nUpstream"]))
    let applied = try fixture.bytes()
    try fixture.write("Drift\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
    _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(try fixture.bytes() == applied)
  }

  @Test(arguments: ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"])
  func claudeFilesReceiveOnlyRelativeImports(_ path: String) throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.write("Custom Claude guidance.\n", to: fixture.project.appendingPathComponent(path))
    try fixture.add()
    let text = try fixture.text(path)
    #expect(text.contains(path == ".claude/CLAUDE.md" ? "@../AGENTS.md" : "@AGENTS.md"))
    #expect(!text.contains("# rules"))
    #expect(text.hasSuffix("Custom Claude guidance.\n"))
    let before = try fixture.bytes(path)
    _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(try fixture.bytes(path) == before)
  }

  @Test func claudeSymlinkAndExistingImportNeedNoManagedForwarder() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let file = fixture.project.appendingPathComponent("CLAUDE.md")
    try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "AGENTS.md")
    try fixture.add()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "AGENTS.md")
    #expect(try fixture.store().loadResolved().instructions.targets.count == 1)
    try FileManager.default.removeItem(at: file)
    try fixture.write("@AGENTS.md\n\nCustom.\n", to: file)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.text("CLAUDE.md") == "@AGENTS.md\n\nCustom.\n")
    #expect(try fixture.store().loadResolved().instructions.targets.count == 1)
  }

  @Test func userMappingHonorsConfiguredHomesAndCoalescesPhysicalFiles() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    var runtime = fixture.environment
    let config = fixture.root.appendingPathComponent("external-config")
    runtime.environment = [
      "CODEX_HOME": config.appendingPathComponent("opencode").path,
      "CLAUDE_CONFIG_DIR": fixture.home.appendingPathComponent("claude-config").path,
      "XDG_CONFIG_HOME": config.path,
    ]
    try fixture.add(scope: .user, agents: AgentID.allCases, environment: runtime)
    let lock = try fixture.store(.user, environment: runtime).loadResolved()
    #expect(lock.instructions.targets.count == 3)
    let common = try #require(
      lock.instructions.targets[config.appendingPathComponent("opencode/AGENTS.md").path])
    #expect(Set(common.agents) == [.codex, .opencode])
    let codex = try Data(contentsOf: config.appendingPathComponent("opencode/AGENTS.md"))
    #expect(
      try codex == Data(contentsOf: fixture.home.appendingPathComponent("claude-config/CLAUDE.md")))
    #expect(try codex == Data(contentsOf: fixture.home.appendingPathComponent(".gemini/GEMINI.md")))
    _ = try InstructionOperations.installResolvedReport(scope: .user, environment: runtime)
    #expect(try fixture.store(.user, environment: runtime).loadResolved() == lock)
  }

  @Test func previewAndCallbackAreReadOnlyAndPromptsTrackChangedContent() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    try fixture.add(agents: [.codex, .geminiCLI])
    var declaration = try fixture.store().loadDeclaration()
    declaration.instructions?.chatgpt = [
      "daily": PromptDeclaration(sections: ["rules:one", "rules:two"], append: ".agent/custom.md"),
      "stable": PromptDeclaration(sections: ["rules:two"]),
    ]
    try fixture.write(
      "Custom prompt.\r\n", to: fixture.project.appendingPathComponent(".agent/custom.md"))
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    let old = try fixture.snapshot(fixture.project, excludingCache: true)
    try fixture.section("one", body: "Changed")
    try fixture.commit()
    let preview = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(preview.changedPrompts == ["daily"])
    #expect(preview.hasChanges)
    #expect(preview.targets.count == 2 && preview.targets.allSatisfy(\.changed))
    #expect(try fixture.snapshot(fixture.project, excludingCache: true) == old)
    struct Cancelled: Error {}
    #expect(throws: Cancelled.self) {
      try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true) {
        report in
        #expect(report == preview)
        #expect(try fixture.snapshot(fixture.project, excludingCache: true) == old)
        throw Cancelled()
      }
    }
    #expect(try fixture.snapshot(fixture.project, excludingCache: true) == old)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true) {
      report in
      #expect(report == preview)
      let beforeAgents = try fixture.bytes()
      let beforeGemini = try fixture.bytes("GEMINI.md")
      #expect(beforeAgents == beforeGemini)
    }
    #expect(try fixture.bytes() == fixture.bytes("GEMINI.md"))
    let rendered = try InstructionOperations.renderChatGPT(
      prompt: "daily", environment: fixture.environment)
    #expect(rendered == Data("# one\n\nChanged\n\n# two\n\nOriginal\n\nCustom prompt.\r\n".utf8))
    try fixture.section("one", body: "Uncommitted")
    #expect(
      try InstructionOperations.renderChatGPT(prompt: "daily", environment: fixture.environment)
        == rendered)
    #expect(throws: InstructionError.emptyPrompt) {
      try InstructionOperations.renderChatGPT(prompt: "unknown", environment: fixture.environment)
    }
  }

  @Test func lostLockIsReportedAndIdenticalBlocksAreAdoptedWithoutDeletionOwnership() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let bytes = try fixture.bytes()
    try FileManager.default.removeItem(at: fixture.store().resolvedURL)
    let preview = try InstructionOperations.updateInstalled(environment: fixture.environment)
    #expect(preview.lockMissing)
    #expect(preview.hasChanges)
    #expect(preview.targets.allSatisfy { $0.beforeAgents == nil && $0.agentsChanged })
    #expect(preview.targets.allSatisfy { !$0.changed })
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.bytes() == bytes)
    #expect(try fixture.store().loadResolved().instructions.targets["AGENTS.md"]?.created == false)
    try InstructionOperations.remove(names: ["rules"], environment: fixture.environment)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent("AGENTS.md").path))
  }

  @Test func foreignFileStopsAddAndReplaceTakesItOver() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.write(
      "# rules\n\nCustom rule.\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
    let before = try fixture.bytes()
    #expect(throws: InstructionError.unownedTargets(["AGENTS.md"])) { try fixture.add() }
    #expect(try fixture.bytes() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.store().declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
    let outcome = try fixture.add(replace: true)
    #expect(outcome.result?.targets.first?.foreign == true)
    #expect(try fixture.text() == generated(["# rules\n\nOriginal"]))
  }

  @Test func generatedFileWithoutLockIsOwnedAndIdenticalFileIsKept() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.write(
      generated(["# old\n\nStale"]), to: fixture.project.appendingPathComponent("AGENTS.md"))
    try fixture.add()
    #expect(try fixture.text() == generated(["# rules\n\nOriginal"]))
  }

  @Test func removingLastSectionDeletesOnlyTheLockedRendering() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one")
    try fixture.section("two")
    try fixture.commit()
    try fixture.add()
    try InstructionOperations.remove(names: ["one"], environment: fixture.environment)
    #expect(try fixture.text() == generated(["# two\n\nOriginal"]))
    try fixture.write("Edited\n", to: fixture.project.appendingPathComponent("AGENTS.md"))
    try InstructionOperations.remove(names: ["two"], environment: fixture.environment)
    #expect(try fixture.text() == "Edited\n")
    #expect(try fixture.store().loadResolved().instructions.targets.isEmpty)
  }

  @Test func discoveryReadsCommittedContainersRecursivelyFromSearchPath() throws {
    let fixture = try InstructionFixture()
    try fixture.section("one", container: "bundle/instructions")
    try fixture.section("two", container: "bundle/.agents/instructions")
    try fixture.section("three", container: "bundle/instructions/nested")
    try fixture.section("outside")
    try fixture.commit()
    try fixture.section("one", body: "Dirty", container: "bundle/instructions")
    let available = try InstructionOperations.list(
      source: SourceDeclaration(kind: .local, location: fixture.repo.path, path: "bundle"),
      environment: fixture.environment)
    #expect(available.map(\.record.name) == ["nested/three", "one", "two"])
    #expect(available.map(\.section.description).first == "Instructions for three.")
    try fixture.add(names: ["one"], path: "bundle")
    #expect(try !fixture.text().contains("Dirty"))
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .uncommittedSource
      })
    #expect(throws: (any Error).self) {
      try InstructionOperations.list(
        source: SourceDeclaration(kind: .local, location: fixture.home.path),
        environment: fixture.environment)
    }
  }

  @Test func discoveryRejectsInvalidNamesSymbolicLinksAndDuplicates() throws {
    let fixture = try InstructionFixture()
    try fixture.section("Upper")
    try fixture.commit()
    let source = SourceDeclaration(kind: .local, location: fixture.repo.path)
    #expect(throws: (any Error).self) {
      try InstructionOperations.list(source: source, environment: fixture.environment)
    }
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("instructions"))
    try fixture.section("rules")
    try fixture.section("rules", container: ".agents/instructions")
    try fixture.git(["add", "-A"])
    try fixture.commit()
    #expect(throws: (any Error).self) {
      try InstructionOperations.list(source: source, environment: fixture.environment)
    }
    try FileManager.default.removeItem(
      at: fixture.repo.appendingPathComponent(".agents/instructions"))
    try FileManager.default.createSymbolicLink(
      atPath: fixture.repo.appendingPathComponent("instructions/link.md").path,
      withDestinationPath: "rules.md")
    try fixture.git(["add", "-A"])
    try fixture.commit()
    #expect(throws: (any Error).self) {
      try InstructionOperations.list(source: source, environment: fixture.environment)
    }
  }

  @Test func initializeCreatesValidatedSkeletonAndNeverOverwrites() throws {
    let fixture = try InstructionFixture()
    let file = try InstructionOperations.initializeInstructions(
      named: "new-rules", directory: fixture.repo.appendingPathComponent("instructions"))
    let section = try Instructions.validateSource(Data(contentsOf: file), id: "new-rules")
    #expect(section.heading == "new-rules")
    #expect(section.level == 1)
    #expect(throws: (any Error).self) {
      try InstructionOperations.initializeInstructions(
        named: "new-rules", directory: file.deletingLastPathComponent())
    }
    #expect(throws: (any Error).self) {
      try InstructionOperations.initializeInstructions(named: "../escape", directory: fixture.repo)
    }
  }
}
