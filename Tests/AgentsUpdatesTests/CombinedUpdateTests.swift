import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation
import Testing

@testable import AgentsUpdates

@Suite("Combined updates")
struct CombinedUpdateTests {
  @Test func sharedSourceRequirementAndEditToCopyTransitionUseMergedState() throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .edit, agents: [.codex])
    try fixture.advance()
    var declaration = try fixture.store.loadDeclaration()
    declaration.skills?["fixture"]?.mode = .copy
    declaration.sources["fixture"]?.requirement = .branch("main")
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    let before = try fixture.snapshot()
    let preview = try fixture.preview()
    let skill = try #require(preview.skills.first)
    #expect(preview.hasChanges && preview.instructions.hasChanges)
    #expect(skill.membership.map(\.before) == [.installed(mode: .edit)])
    #expect(skill.membership.map(\.after) == [.installed(mode: .copy)])
    #expect(try fixture.snapshot() == before)
    let receipt = try UpdateOperations.withPreparedUpdate(environment: fixture.environment) {
      update in
      #expect(update.report == preview)
      #expect(try fixture.snapshot() == before)
      return try update.apply()
    }
    #expect(receipt.report == preview && receipt.installedSkills.count == 1)
    let lock = try fixture.store.loadResolved()
    let installed = try #require(lock.skills["demo"])
    let revision = try fixture.git(["rev-parse", "main"])
    #expect(lock.sources[installed.source]?.requirement == .branch("main"))
    #expect(installed.installs == [AgentID.codex.rawValue: .copy])
    #expect(installed.revision == revision)
    #expect(lock.instructions.sections.first?.revision == revision)
    #expect(lock.instructions.chatgpt["weekly"]?.sections.first?.revision == revision)
    #expect(
      try FileManager.default.attributesOfItem(atPath: fixture.target().path)[.type]
        as? FileAttributeType == .typeDirectory)
    #expect(
      try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md"))
        == fixture.bytes(fixture.repo.appendingPathComponent("skills/demo/SKILL.md")))
    #expect(
      String(decoding: try fixture.bytes(fixture.instruction()), as: UTF8.self).contains("new"))
    #expect(try !fixture.preview().hasChanges)
  }

  @Test(arguments: [false, true])
  func standaloneInstructionsValidateRetainedSkills(_ apply: Bool) throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .edit, agents: [.codex])
    var declaration = try fixture.store.loadDeclaration()
    declaration.skills?["fixture"]?.mode = .copy
    declaration.sources["fixture"]?.requirement = .branch("main")
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    let before = try fixture.snapshot()
    var called = false
    #expect(throws: CoreError.invalidState("edit installs must be local, unpinned live links")) {
      try InstructionOperations.updateInstalled(
        environment: fixture.environment, apply: apply, beforeApply: { _ in called = true })
    }
    #expect(!called)
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [false, true])
  func standaloneNamedSkillsValidateRetainedSkills(_ apply: Bool) throws {
    let fixture = try UpdateFixture()
    try fixture.write(
      "---\nname: other\ndescription: fixture\n---\nother\n",
      to: fixture.repo.appendingPathComponent("skills/other/SKILL.md"))
    try fixture.commit()
    try fixture.install(mode: .edit, agents: [.codex])
    var declaration = try fixture.store.loadDeclaration()
    declaration.skills?["fixture"]?.mode = .copy
    declaration.sources["fixture"]?.requirement = .branch("main")
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    let before = try fixture.snapshot()
    var called = false
    #expect(throws: CoreError.invalidState("edit installs must be local, unpinned live links")) {
      try SkillOperations.updateInstalled(
        environment: fixture.environment, skillNames: ["demo"], apply: apply,
        beforeApply: { _ in called = true })
    }
    #expect(!called)
    #expect(try fixture.snapshot() == before)
  }

  @Test func exchangingALiveSymlinkDestinationInvalidatesPreparation() throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .edit)
    let logical = fixture.repo.appendingPathComponent("skills/demo")
    let actual = fixture.repo.appendingPathComponent("live-source")
    try FileManager.default.moveItem(at: logical, to: actual)
    try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: actual)
    let before = try fixture.bytes(fixture.store.resolvedURL)
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      let displaced = fixture.repo.appendingPathComponent("displaced-source")
      try FileManager.default.moveItem(at: actual, to: displaced)
      try FileManager.default.copyItem(at: displaced, to: actual)
      #expect(throws: UpdateApplyError.self) { try update.apply() }
    }
    #expect(try fixture.bytes(fixture.store.resolvedURL) == before)
  }

  @Test func cachePublicationFailureLeavesBothKindsUnchanged() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    let before = try fixture.snapshot()
    let parent = fixture.store.cacheDirectory.appendingPathComponent("materialized")
    let moved = fixture.root.appendingPathComponent("existing-cache")
    do {
      try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
        try FileManager.default.moveItem(at: parent, to: moved)
        try Data("blocks cache publication".utf8).write(to: parent)
        _ = try update.apply()
      }
      Issue.record("unsafe cache parent was accepted")
    } catch let error as UpdateApplyError { #expect(error.disposition == .unchanged) }
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.moveItem(at: moved, to: parent)
    #expect(try fixture.snapshot() == before)
  }

  @Test func pruningUsesMergedPinsWatchAndLiveSourcesAndRollsBack() throws {
    let fixture = try UpdateFixture()
    let rules = try UpdateFixture()
    try fixture.install()
    let cache = fixture.store.cacheDirectory
    let live = cache.appendingPathComponent("artifact-content/" + String(repeating: "a", count: 64))
    let watched = cache.appendingPathComponent(
      "artifact-content/" + String(repeating: "b", count: 64))
    let unused = cache.appendingPathComponent(
      "artifact-content/" + String(repeating: "c", count: 64))
    try fixture.write(
      "---\nname: live\ndescription: fixture\n---\nlive\n",
      to: live.appendingPathComponent("SKILL.md"))
    for path in [watched, unused] {
      try fixture.write("kept", to: path.appendingPathComponent("content"))
    }
    var declaration = try fixture.store.loadDeclaration()
    declaration.sources["live"] = SourceDeclaration(kind: .local, location: live.path)
    declaration.skills?["live"] = SkillDeclaration(select: .all, agents: [.codex], mode: .edit)
    declaration.sources["rules"] = SourceDeclaration(kind: .local, location: rules.repo.path)
    declaration.instructions?.sections = ["rules:rules"]
    declaration.instructions?.chatgpt?["weekly"]?.sections = ["rules:rules"]
    declaration.sources["watched"] = SourceDeclaration(
      kind: .wellKnown, location: "https://example.test")
    declaration.watch = ["watched"]
    let watch = WatchState(sources: [
      "https://example.test": WatchSourceState(
        seen: .artifacts(["observed": "sha256:" + String(repeating: "b", count: 64)]))
    ])
    try fixture.store.save(
      declaration: declaration, resolved: fixture.store.loadResolved(), watch: watch)
    try fixture.advance()
    let before = try fixture.snapshot()
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { step in
          // Pruning is queued after both kinds and the merged state; rollback restores it too.
          if step == "journal.committed.renamed" { return }
          if step.hasPrefix("replace."), !step.hasSuffix(".renamed"),
            !FileManager.default.fileExists(atPath: unused.path)
          {
            throw CoreError.invalidState("pruning interrupted")
          }
        },
        { try $0.apply() })
    }
    #expect(try fixture.snapshot() == before)
    for path in [live, watched, unused] {
      #expect(FileManager.default.fileExists(atPath: path.path))
    }
    _ = try fixture.apply()
    for path in [live, watched] { #expect(FileManager.default.fileExists(atPath: path.path)) }
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    let lock = try fixture.store.loadResolved()
    let records = lock.instructions.sections + lock.instructions.chatgpt.values.flatMap(\.sections)
    for record in records {
      let path = SourceCache(store: fixture.store).materializedURL(
        sourceID: record.source, revision: record.revision!)
      #expect(FileManager.default.fileExists(atPath: path.path))
    }
    #expect(try fixture.store.loadWatch() == watch)
  }

  @Test(arguments: [false, true])
  func previewDiscardsAnUnlockedAttemptWhenTheFirstWriterAppears(_ throwFirst: Bool) throws {
    let fixture = try UpdateFixture()
    var attempts = 0
    let report = try UpdateOperations.preview(
      environment: fixture.environment,
      checkpoint: { step in
        guard step == "plan.skills" else { return }
        attempts += 1
        if attempts == 1 {
          try fixture.declare()
          if throwFirst { throw CoreError.invalidState("discarded read") }
        }
      })
    #expect(attempts == 2 && report.skills.count == 1 && report.hasChanges)
    #expect(try fixture.store.loadResolved().skills.isEmpty)
    let cache = fixture.store.cacheDirectory.appendingPathComponent("materialized")
    #expect(!FileManager.default.fileExists(atPath: cache.path))
  }

  @Test func independentSourcesContributeTheirOwnedRecords() throws {
    let fixture = try UpdateFixture()
    let other = try UpdateFixture()
    try fixture.declare()
    var declaration = try fixture.store.loadDeclaration()
    declaration.sources["rules"] = SourceDeclaration(kind: .local, location: other.repo.path)
    declaration.instructions?.sections = ["rules:rules"]
    declaration.instructions?.chatgpt?["weekly"]?.sections = ["rules:rules"]
    try fixture.store.save(declaration: declaration, resolved: ResolvedState())
    _ = try fixture.apply()
    try fixture.advance()
    try other.advance()
    _ = try fixture.apply()
    let lock = try fixture.store.loadResolved()
    #expect(lock.sources.count == 2)
    #expect(try lock.skills["demo"]?.revision == fixture.git(["rev-parse", "HEAD"]))
    #expect(try lock.instructions.sections.first?.revision == other.git(["rev-parse", "HEAD"]))
    #expect(lock.skills["demo"]?.source != lock.instructions.sections.first?.source)
    #expect(try !fixture.preview().hasChanges)
  }

  @Test func crossKindOverlapIsRejectedBeforeTheConsumer() throws {
    let fixture = try UpdateFixture(scope: .user)
    var environment = fixture.environment
    environment.environment["CLAUDE_CONFIG_DIR"] = fixture.target().path
    let store = StateStore(scope: .user, environment: environment)
    try store.save(
      declaration: Declaration(
        sources: ["fixture": SourceDeclaration(kind: .local, location: fixture.repo.path)],
        skills: ["fixture": SkillDeclaration(select: .all, agents: [.codex], mode: .copy)],
        instructions: InstructionsDeclaration(agents: [.claudeCode], sections: ["fixture:rules"])),
      resolved: ResolvedState())
    var called = false
    #expect(throws: CoreError.self) {
      try UpdateOperations.withPreparedUpdate(scope: .user, environment: environment) { _ in
        called = true
      }
    }
    #expect(!called)
    #expect(try store.loadResolved().skills.isEmpty)
  }

  @Test func liveContentsStayLiveButSourceIdentityAndMetadataAreRequired() throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .edit)
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      try fixture.writeSource("live edit")
      _ = try update.apply()
    }
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("live edit"))
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      try fixture.write("invalid", to: fixture.repo.appendingPathComponent("skills/demo/SKILL.md"))
      #expect(throws: UpdateApplyError.self) { try update.apply() }
    }
  }

  @Test func aWrongThreadAttemptConsumesTheHandle() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    let before = try fixture.snapshot()
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      let transfer = TransferredHandle(update)
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        #expect(throws: CoreError.self) { try transfer.update.apply() }
        finished.signal()
      }
      #expect(finished.wait(timeout: .now() + 10) == .success)
      #expect(throws: CoreError.self) { try update.apply() }
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [false, true])
  func forwardingDecisionInputsAreRevalidated(_ higherPriority: Bool) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    let file = fixture.root.appendingPathComponent(
      higherPriority ? ".claude/CLAUDE.md" : "CLAUDE.md")
    try fixture.write(higherPriority ? "@../AGENTS.md\n" : "@AGENTS.md\n", to: file)
    _ = try fixture.apply()
    try fixture.advance()
    let lock = try fixture.bytes(fixture.store.resolvedURL)
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      try fixture.write(
        "custom instructions\n", to: fixture.root.appendingPathComponent("CLAUDE.md"))
      #expect(throws: UpdateApplyError.self) { try update.apply() }
    }
    #expect(try fixture.bytes(fixture.store.resolvedURL) == lock)
  }

  @Test(arguments: ["bytes", "mode"])
  func stagedLinkedContentIsVerifiedBeforeEitherKindPublishes(_ dimension: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .link)
    try fixture.advance()
    let before = try fixture.snapshot()
    let id = try #require(fixture.store.loadResolved().skills["demo"]?.source)
    let cache = try SourceCache(store: fixture.store).materializedURL(
      sourceID: id, revision: fixture.git(["rev-parse", "HEAD"]))
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { step in
          if step == "stage.0.ready" {
            let file = cache.appendingPathComponent("skills/demo/run.sh")
            if dimension == "bytes" {
              try fixture.write("corrupt", to: file)
            } else {
              try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
          }
        },
        { try $0.apply() })
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [InstallScope.project, .user])
  func rendersBothKindsAndCommitsOneGeneration(_ scope: InstallScope) throws {
    let fixture = try UpdateFixture(scope: scope)
    try fixture.install(agents: [.codex, .claudeCode, .cursor])
    let before = try fixture.snapshot()
    try fixture.advance()
    let preview = try fixture.preview()
    #expect(preview.hasChanges && preview.skills.count == 1)
    #expect(preview.instructions.changedPrompts == ["weekly"])
    #expect(try fixture.snapshot() == before)
    var journals = 0
    let receipt = try UpdateOperations.withPreparedUpdate(
      scope: scope, environment: fixture.environment,
      checkpoint: { if $0 == "journal.preparing" { journals += 1 } },
      { update in
        #expect(update.report == preview)
        #expect(try fixture.snapshot() == before)
        let receipt = try update.apply()
        #expect(throws: CoreError.self) { try update.apply() }
        return receipt
      })
    #expect(journals == 1 && receipt.report == preview && receipt.installedSkills.count == 3)
    #expect(
      String(decoding: try fixture.bytes(fixture.instruction()), as: UTF8.self).contains("new"))
    let lock = try fixture.store.loadResolved()
    #expect(lock.skills["demo"]?.revision == lock.instructions.sections.first?.revision)
    #expect(
      lock.instructions.chatgpt["weekly"]?.sections.first?.revision == lock.skills["demo"]?.revision
    )
    let after = try fixture.snapshot()
    let unchanged = try fixture.apply()
    #expect(!unchanged.report.hasChanges && unchanged.installedSkills.count == 3)
    #expect(try fixture.snapshot() == after)
  }

  @Test func sharedSourceAdvancingBetweenPlannersUsesOnePin() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    let pin = try fixture.git(["rev-parse", "HEAD"])
    try UpdateOperations.withPreparedUpdate(
      environment: fixture.environment,
      checkpoint: { step in
        if step == "plan.skills" {
          try fixture.writeSource("later")
          try fixture.commit()
        }
      },
      { update in
        #expect(update.report.skills.first?.newRevision == pin)
        #expect(update.report.instructions.sections.first?.after?.revision == pin)
        _ = try update.apply()
      })
    #expect(try fixture.store.loadResolved().skills["demo"]?.revision == pin)
    #expect(try fixture.preview().hasChanges)
  }

  @Test(arguments: ["skills", "instructions", "assembly"])
  func preparationFailureNeverExposesAPartialReport(_ kind: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    if kind == "skills" {
      try fixture.write("invalid", to: fixture.repo.appendingPathComponent("skills/demo/SKILL.md"))
      var declaration = try fixture.store.loadDeclaration()
      declaration.skills?["fixture"]?.select = .names(["demo"])
      try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
      try fixture.commit()
    } else if kind == "instructions" {
      try fixture.write("invalid", to: fixture.repo.appendingPathComponent("instructions/rules.md"))
      try fixture.commit()
    } else {
      try fixture.write(
        "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->\nbroken",
        to: fixture.instruction())
    }
    let before = try fixture.snapshot()
    var called = false
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { _ in called = true
      }
    }
    #expect(!called)
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [false, true])
  func cancellationInvalidatesEscapedHandles(_ throwing: Bool) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    let before = try fixture.snapshot()
    var escaped: PreparedUpdate?
    struct Cancelled: Error {}
    do {
      try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
        escaped = update
        if throwing { throw Cancelled() }
      }
      #expect(!throwing)
    } catch is Cancelled { #expect(throwing) }
    #expect(throws: CoreError.self) { try escaped?.apply() }
    #expect(try fixture.snapshot() == before)
  }

  @Test func callerErrorAfterApplyKeepsTheCommittedGeneration() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    struct ConsumerError: Error {}
    #expect(throws: ConsumerError.self) {
      try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
        _ = try update.apply()
        throw ConsumerError()
      }
    }
    #expect(try !fixture.preview().hasChanges)
  }

  @Test(arguments: ["instruction", "skill-mode", "skill-link", "declaration", "resolved", "watch"])
  func stalePlansPreserveExternalEdits(_ kind: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: kind == "skill-link" ? .link : .copy)
    try fixture.advance()
    let lock = try fixture.bytes(fixture.store.resolvedURL)
    let instruction = try fixture.bytes(fixture.instruction())
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      switch kind {
      case "instruction": try fixture.write("external", to: fixture.instruction())
      case "skill-mode":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: fixture.target().appendingPathComponent("run.sh").path)
      case "skill-link":
        try FileManager.default.removeItem(at: fixture.target())
        try FileManager.default.createSymbolicLink(
          at: fixture.target(),
          withDestinationURL: fixture.repo.appendingPathComponent("skills/demo"))
      case "declaration": try fixture.write("{}\n", to: fixture.store.declarationURL)
      case "resolved": try fixture.write("{}\n", to: fixture.store.resolvedURL)
      default: try fixture.write("{}\n", to: fixture.store.watchURL)
      }
      let edited = try fixture.snapshot()
      do {
        _ = try update.apply()
        Issue.record("stale plan applied")
      } catch let error as UpdateApplyError {
        #expect(error.disposition == .unchanged)
      }
      #expect(try fixture.snapshot() == edited)
      #expect(throws: CoreError.self) { try update.apply() }
    }
    if kind != "resolved" { #expect(try fixture.bytes(fixture.store.resolvedURL) == lock) }
    if kind != "instruction" { #expect(try fixture.bytes(fixture.instruction()) == instruction) }
  }

  @Test func lockLossReportsMembershipAndRejectsExistingLiveTargets() throws {
    let fixture = try UpdateFixture()
    try fixture.install(mode: .edit)
    try FileManager.default.removeItem(at: fixture.store.resolvedURL)
    let before = try fixture.snapshot()
    let preview = try fixture.preview()
    #expect(preview.lockMissing && preview.hasChanges)
    #expect(preview.skills[0].changes.isEmpty)
    #expect(preview.skills[0].membership.allSatisfy { $0.before == .absent })
    var called = false
    #expect(throws: CoreError.self) {
      try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { _ in called = true
      }
    }
    #expect(!called)
    #expect(try fixture.snapshot() == before)
    for path in Set(preview.skills[0].membership.map(\.path)) {
      try FileManager.default.removeItem(atPath: path)
    }
    _ = try fixture.apply()
    #expect(try !fixture.preview().hasChanges)
    #expect(try fixture.store.loadResolved().instructions.targets.values.allSatisfy { !$0.created })
  }

  @Test func emptyScopeAndSingleKinds() throws {
    let fixture = try UpdateFixture()
    #expect(try !fixture.preview().hasChanges)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
    _ = try fixture.apply()
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    try fixture.declare()
    var declaration = try fixture.store.loadDeclaration()
    declaration.skills = nil
    try fixture.store.save(declaration: declaration, resolved: ResolvedState())
    #expect(try fixture.apply().report.skills.isEmpty)
    declaration.instructions = nil
    declaration.skills = ["fixture": SkillDeclaration(select: .all, agents: [.codex], mode: .copy)]
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    _ = try fixture.apply()
    #expect(try fixture.store.loadResolved().instructions == LockedInstructions())
    #expect(try !fixture.preview().hasChanges)
  }

  @Test func promptRepinsAndSectionOrderAreStateChanges() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    var declaration = try fixture.store.loadDeclaration()
    declaration.skills = nil
    declaration.instructions?.sections = []
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    _ = try fixture.apply()
    try fixture.git(["commit", "--allow-empty", "-m", "repin"])
    let prompt = try fixture.preview()
    #expect(prompt.hasChanges && prompt.skills.isEmpty && prompt.instructions.targets.isEmpty)
    #expect(prompt.instructions.changedPrompts.isEmpty)
    _ = try fixture.apply()
    try fixture.write(
      "# Second\n\nSecond body\n", to: fixture.repo.appendingPathComponent("instructions/second.md")
    )
    try fixture.commit()
    declaration.instructions?.chatgpt?["weekly"]?.sections = ["fixture:rules", "fixture:second"]
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    _ = try fixture.apply()
    declaration.instructions?.chatgpt?["weekly"]?.sections.reverse()
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    #expect(try fixture.preview().hasChanges)
    _ = try fixture.apply()
    #expect(try !fixture.preview().hasChanges)
  }
}

/// Deliberately violates the public non-Sendable contract to test its runtime guard.
private final class TransferredHandle: @unchecked Sendable {
  let update: PreparedUpdate
  init(_ update: PreparedUpdate) { self.update = update }
}
