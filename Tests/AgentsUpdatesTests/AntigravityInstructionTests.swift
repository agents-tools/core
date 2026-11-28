import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

struct AntigravityInstructionTests {
  private let ruleDirectory = ".gemini/config/rules"
  private let memexPath = ".agent/instructions/general/managed.md"

  @Test func installsOnlySelectedGlobalRulesAndRestoresLockedReferenceBytes() throws {
    let f = try UpdateFixture(scope: .user)
    try f.write(
      """
      ---
      description: A separate rule.
      ---

      # Modular

      @[Shared](../includes/shared.md)
      """, to: f.repo.appendingPathComponent("instructions/modular.md"))
    let includes = f.repo.appendingPathComponent("includes")
    try f.write(
      "---\ndescription: Included frontmatter.\n---\nLocked @[body](body.txt).",
      to: includes.appendingPathComponent("shared.md"))
    let body = includes.appendingPathComponent("body.txt")
    try f.write("nested content. Notify @reviewer and open @guide.md or `@./code.md`", to: body)
    try f.commit()
    try f.write(
      """
      version: 1
      sources:
        fixture: {path: \(f.repo.path.debugDescription)}
      components:
        - kind: instructions
          agents: [codex, gemini-cli, antigravity]
          sections:
            - {source: fixture, name: rules, condition: {agents: [codex, gemini-cli]}}
            - {source: fixture, name: modular, condition: {agents: [antigravity]}}
      """, to: f.store.declarationURL)
    let rules = f.environment.homeDirectory.appendingPathComponent(ruleDirectory)
    let personal = rules.appendingPathComponent("handwritten.md")
    try f.write("Handwritten rule", to: personal)
    let preview = try f.preview()
    let rule = try #require(preview.instructions.targets.first { $0.afterAgents == [.antigravity] })
    #expect(rule.url.deletingLastPathComponent().path == rules.path)
    #expect(preview.instructions.advisories.contains { $0.contains("20,000-token") })
    #expect(preview.instructions.conflicts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rule.url.path))
    let output = try #require(rule.after)
    let text = String(decoding: output, as: UTF8.self)
    #expect(text.hasPrefix("---\ntrigger: always_on\n"))
    #expect(text.contains("Locked nested content."))
    #expect(text.contains("Notify @reviewer and open @guide.md or `@./code.md`"))
    #expect(!text.contains("Included frontmatter"))
    #expect(!text.contains("# Rules"))
    try apply(f, preview: preview)
    let legacy = try f.bytes(f.instruction(.geminiCLI))
    #expect(String(decoding: legacy, as: UTF8.self).contains("# Rules"))
    #expect(!String(decoding: legacy, as: UTF8.self).contains("# Modular"))
    #expect(try f.bytes(personal) == Data("Handwritten rule".utf8))
    #expect(!(try f.preview()).hasChanges)
    let lock = try f.store.loadLedger()
    let deployment = try #require(lock.deployments.first { $0.recipients == [.antigravity] })
    let owner = try #require(deployment.owners.first.flatMap { lock.components[$0] })
    #expect(deployment.owners.count == 1)
    #expect(deployment.expectedHash == "sha256:" + FileHash.sha256Hex(data: output))
    #expect(owner.revision == (try f.git(["rev-parse", "HEAD"])))
    #expect(owner.resources.count == 3)
    #expect(owner.resources.allSatisfy { lock.resources[$0]?.kind == .embedded })

    try f.write("new upstream bytes", to: body)
    try f.commit()
    try FileManager.default.removeItem(at: rule.url)
    #expect(try doctor(f).diagnostics.contains { $0.kind == .missingTarget && $0.path == rule.url })
    let restored = try InstructionOperations.installResolvedReport(
      scope: .user, environment: f.environment)
    #expect(restored.targets.contains { $0.target == rule.target && $0.changed })
    #expect(try f.bytes(rule.url) == output)
    #expect(try f.bytes(f.instruction(.geminiCLI)) == legacy)
    let inspection = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(
      inspection.deployments.contains { $0.location.path == rule.url.path && $0.status == .current }
    )
    let mapping = InstructionOperations.export(projectRoots: [], environment: f.environment)
    #expect(
      mapping[0].targets.first { $0.target == rule.target }?.sections.map(\.name) == ["modular"])
    try (output + Data("Changed contents.\n".utf8)).write(to: rule.url)
    #expect(try doctor(f).diagnostics.contains { $0.kind == .drift && $0.path == rule.url })
  }

  @Test func exactByteLimitIncludesDescriptionAndMultibyteExpansion() throws {
    let f = try UpdateFixture(scope: .user)
    let file = f.repo.appendingPathComponent("instructions/rules.md")
    let include = f.repo.appendingPathComponent("instructions/content.txt")
    try f.write("---\ndescription: Boundary.\n---\n\n# Limit\n\n@[size](content.txt)\n", to: file)
    try f.write("x", to: include)
    try f.commit()
    try declare(f, name: "rules")
    let sample = try #require(f.preview().instructions.targets.first?.after)
    let budget = 24_000 - sample.count + 1
    let body = String(repeating: "界", count: budget / 3) + String(repeating: "x", count: budget % 3)
    try f.write(body, to: include)
    try f.commit()
    let exact = try f.preview()
    #expect(exact.instructions.targets.first?.after?.count == 24_000)
    let before = try f.bytes(f.store.resolvedURL)
    try f.write(body + "x", to: include)
    try f.commit()
    do {
      _ = try f.preview()
      Issue.record("accepted 24,001 bytes")
    } catch {
      #expect(String(describing: error).contains("agents-rules-"))
      #expect(String(describing: error).contains("24001 UTF-8 bytes"))
      #expect(String(describing: error).contains("limit 24000 bytes"))
    }
    #expect(try f.bytes(f.store.resolvedURL) == before)
  }

  @Test func adoptsExactMemexBytesAndRejectsStalePreview() throws {
    let f = try UpdateFixture(scope: .user)
    let legacy = try seedMemex(f)
    let before = try f.bytes(legacy)
    let initial = try f.preview()
    #expect(initial.instructions.conflicts.isEmpty)
    #expect(
      initial.instructions.targets.contains {
        $0.url == legacy && $0.before == before && $0.after == nil
      })
    let rule = try #require(initial.instructions.targets.first { $0.afterAgents == [.antigravity] })
    // Replacement with the same bytes changes the file generation.
    try before.write(to: legacy, options: .atomic)
    #expect(throws: UpdateApplyError.self) { try apply(f, preview: initial) }
    #expect(try f.bytes(legacy) == before)
    #expect(!FileManager.default.fileExists(atPath: rule.url.path))

    try apply(f, preview: f.preview())
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try f.bytes(rule.url) == rule.after)
    #expect(!(try f.preview()).hasChanges)
    let removed = try InstructionOperations.remove(
      names: ["general/managed"], scope: .user, environment: f.environment)
    let removal = try #require(removed.targets.first { $0.target == rule.target })
    #expect(removal.beforeAgents == [.antigravity] && removal.afterAgents.isEmpty)
    #expect(removal.after == nil && removal.changed && !removal.foreign && removal.drift == .clean)
    #expect(!FileManager.default.fileExists(atPath: rule.url.path))
  }

  @Test func interruptedMemexMigrationRollsBackBothFilesAndLock() throws {
    let f = try UpdateFixture(scope: .user)
    let legacy = try seedMemex(f)
    let preview = try f.preview()
    let rule = try #require(preview.instructions.targets.first { $0.afterAgents == [.antigravity] })
    let legacyBytes = try f.bytes(legacy)
    let lock = try f.bytes(f.store.resolvedURL)
    var interrupted = false
    let result = UpdateOperations.perform(
      scope: .user, environment: f.environment,
      checkpoint: { step in
        if step.contains(".applied"), FileManager.default.fileExists(atPath: rule.url.path),
          !FileManager.default.fileExists(atPath: legacy.path)
        {
          interrupted = true
          throw CoreError.invalidState("fixture interrupted after moving the Memex rule")
        }
      }, { try $0.apply(ifUnchangedFrom: preview.displayedFingerprint) })
    #expect(interrupted)
    #expect(result.disposition == .rolledBack)
    #expect(!result.recovery.pending)
    #expect(try f.bytes(legacy) == legacyBytes)
    #expect(try f.bytes(f.store.resolvedURL) == lock)
    #expect(!FileManager.default.fileExists(atPath: rule.url.path))
  }

  @Test func refusesMemexMismatchAndDestinationCollisionEvenWithReplace() throws {
    let f = try UpdateFixture(scope: .user)
    let legacy = try seedMemex(f)
    let altered = try f.bytes(legacy) + Data("Personal edits\n".utf8)
    try altered.write(to: legacy)
    let preview = try f.preview()
    let rule = try #require(preview.instructions.targets.first { $0.afterAgents == [.antigravity] })
    #expect(preview.instructions.conflicts.contains { $0.contains(legacy.lastPathComponent) })
    #expect(throws: UpdateApplyError.self) { try apply(f, preview: preview) }
    #expect(try f.bytes(legacy) == altered)
    #expect(!FileManager.default.fileExists(atPath: rule.url.path))

    try FileManager.default.removeItem(at: legacy)
    try f.write("Handwritten collision", to: rule.url)
    let replace = UpdateRequest(kinds: [.instructions], replace: true)
    let collision = try UpdateOperations.preview(replace, scope: .user, environment: f.environment)
    #expect(collision.instructions.targets.first?.foreign == true)
    #expect(collision.instructions.conflicts.contains { $0.contains(rule.url.lastPathComponent) })
    #expect(throws: UpdateApplyError.self) { try apply(f, request: replace, preview: collision) }
    #expect(try f.bytes(rule.url) == Data("Handwritten collision".utf8))
  }

  @Test func refusesUnresolvedReferencesAndSymlinkedRulesDirectory() throws {
    let f = try UpdateFixture(scope: .user)
    let input = f.repo.appendingPathComponent("instructions/rules.md")
    try declare(f, name: "rules")
    for test in ["@[missing](absent.md)", "@[escape](../../outside.md)", "@[incomplete]("] {
      try f.write("---\ndescription: Rules.\n---\n# Rule\n\n" + test, to: input)
      try f.commit()
      #expect(throws: (any Error).self) { try f.preview() }
    }
    try f.write("---\ndescription: Rules.\n---\n# Rule\n", to: input)
    try f.commit()
    let outside = f.root.appendingPathComponent("outside-rules")
    let rules = f.environment.homeDirectory.appendingPathComponent(ruleDirectory)
    for directory in [outside, rules.deletingLastPathComponent()] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(at: rules, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try f.preview() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func projectRulesRequireOptInAndUseNativeGlobs() throws {
    let f = try UpdateFixture()
    let source = f.repo.appendingPathComponent("instructions/rules.md")
    try f.write(
      """
      ---
      description: Scoped rules.
      paths: ["Sources/**/*.swift", "Tests/*.swift"]
      ---
      # Rule

      Project rules.
      """, to: source)
    try f.commit()
    try declare(f, name: "rules", agents: nil)
    #expect(
      try f.preview().instructions.targets.allSatisfy { !$0.afterAgents.contains(.antigravity) })

    try declare(f, name: "rules")
    let native = f.root.appendingPathComponent(".agents/rules")
    let handwritten = native.appendingPathComponent("handwritten.md")
    try f.write("# Handwritten rule\n", to: handwritten)
    let preview = try f.preview()
    let rule = try #require(preview.instructions.targets.first { $0.afterAgents == [.antigravity] })
    let installed = rule.url
    #expect(installed.deletingLastPathComponent().path == native.resolvingSymlinksInPath().path)
    #expect(!FileManager.default.fileExists(atPath: installed.path))
    try UpdateOperations.withPreparedUpdate(environment: f.environment) {
      _ = try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let expected = try f.bytes(installed)
    let text = String(decoding: expected, as: UTF8.self)
    #expect(text.contains(#"globs: "Sources/**/*.swift, Tests/*.swift""#))
    #expect(text.contains("trigger: glob"))
    #expect(
      !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AGENTS.md").path))
    try FileManager.default.removeItem(at: installed)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try f.bytes(installed) == expected)
    _ = try InstructionOperations.remove(
      names: ["rules"], agents: [.antigravity], environment: f.environment)
    #expect(!FileManager.default.fileExists(atPath: installed.path))
    #expect(try f.bytes(handwritten) == Data("# Handwritten rule\n".utf8))
  }

  @Test func addPreservesSiblingRecipientsAndSeparatesSameNamedSections() throws {
    let f = try UpdateFixture(scope: .user)
    try declare(f, name: "rules", agents: [.codex, .geminiCLI])
    _ = try f.apply()
    let before = try f.bytes(f.instruction(.codex))
    let second = try UpdateFixture()
    let firstAdd = try InstructionOperations.add(
      InstructionAddOptions(
        source: f.repo.path, names: ["rules"], agents: [.antigravity, .codex],
        scope: .user, environment: f.environment))
    let firstRule = try #require(
      firstAdd.result?.targets.first { $0.afterAgents == [.antigravity] })
    #expect(try doctor(f).diagnostics.allSatisfy { $0.kind != .invalidTarget })
    let secondAdd = try InstructionOperations.add(
      InstructionAddOptions(
        source: second.repo.path, alias: "second", names: ["rules"],
        agents: [.antigravity], scope: .user, environment: f.environment))
    let secondRules = try #require(
      secondAdd.result?.targets.filter { $0.afterAgents == [.antigravity] })
    #expect(secondRules.count == 2)
    #expect(Set(secondRules.map(\.target)).count == 2)
    #expect(secondRules.contains { $0.target == firstRule.target && !$0.changed })
    #expect(try f.bytes(f.instruction(.codex)) == before)
    #expect(try f.bytes(f.instruction(.geminiCLI)) == before)
  }

  @Test func addingExplicitAliasPreservesBothDiscoveryRootsAndLegacyTarget() throws {
    let f = try UpdateFixture(scope: .user)
    for root in ["first", "second"] {
      try f.write(
        "---\ndescription: Review.\n---\n# Review\n\n\(root) instructions.\n",
        to: f.repo.appendingPathComponent(root + "/instructions/review.md"))
    }
    try f.commit()
    let a = SourceDeclaration(kind: .local, location: f.repo.path, path: "first")
    let b = SourceDeclaration(kind: .local, location: f.repo.path, path: "second")
    let sameRoot = SourceDeclaration(kind: .local, location: f.repo.path, path: "./first")
    #expect(throws: CoreError.self) {
      try Declaration(sources: ["a": a, "duplicate": sameRoot]).validate(environment: f.environment)
    }
    try f.store.save(
      declaration: Declaration(
        sources: ["a": a, "b": b],
        instructions: .init(agents: [.codex], sections: ["a:review"])),
      ledger: ResolvedLedger())
    _ = try f.apply()
    let codex = try f.bytes(f.instruction(.codex))
    for source in ["b", f.repo.path + "@path:second"] {
      let addition = try InstructionOperations.add(
        .init(
          source: source, names: ["review"], agents: [.antigravity],
          scope: .user, environment: f.environment))
      let rule = try #require(addition.result?.targets.first { $0.afterAgents == [.antigravity] })
      #expect(
        String(decoding: try #require(rule.after), as: UTF8.self).contains("second instructions."))
      #expect(try f.bytes(f.instruction(.codex)) == codex)
      let declaration = try f.store.loadDeclaration()
      #expect(
        declaration.sources["a"]?.path == "first" && declaration.sources["b"]?.path == "second")
      let references = declaration.components.flatMap { component -> [String] in
        guard case .instructions(let instructions) = component else { return [] }
        return instructions.sectionReferences.map(\.reference)
      }
      #expect(references == ["a:review", "b:review"])
    }
  }

  private func declare(
    _ f: UpdateFixture, name: String, agents: [AgentID]? = [.antigravity], subpath: String? = nil
  ) throws {
    try f.store.save(
      declaration: Declaration(
        sources: ["fixture": SourceDeclaration(kind: .local, location: f.repo.path, path: subpath)],
        instructions: InstructionsDeclaration(agents: agents, sections: ["fixture:" + name])),
      ledger: ResolvedLedger())
  }

  private func seedMemex(_ f: UpdateFixture) throws -> URL {
    try f.write(
      "---\ndescription: Managed.\n---\n\n# Managed\n\nPinned contents.\n",
      to: f.repo.appendingPathComponent(memexPath))
    try f.commit()
    let revision = try f.git(["rev-parse", "HEAD"])
    let legacy = f.environment.homeDirectory.appendingPathComponent(
      ruleDirectory + "/memex-managed.md")
    try f.write(
      """
      ---
      trigger: always_on
      description: "Managed."
      ---

      <!-- Generated from Memex \(memexPath) at \(revision); temporary standalone installation. -->

      # Managed

      Pinned contents.

      """, to: legacy)
    try declare(f, name: "general/managed", subpath: ".agent")
    return legacy
  }

  private func doctor(_ f: UpdateFixture) throws -> InstructionDoctorReport {
    try InstructionOperations.doctor(scope: .user, environment: f.environment)
  }

  private func apply(
    _ f: UpdateFixture, request: UpdateRequest = UpdateRequest(), preview: CombinedUpdateReport
  ) throws {
    _ = try UpdateOperations.withPreparedUpdate(request, scope: .user, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
  }
}
