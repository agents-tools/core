import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

@testable import AgentsCore

struct WatchConfirmationTests {
  @Test func newSubscriptionPreviewIsPureAndConfirmationUsesTheExactContent() throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    let before = try FileHash.folderHash(f.root)
    let preview = try operations.previewAdd(
      f.repo.path, alias: "watched", environment: f.environment)
    let repeated = try operations.previewAdd(
      f.repo.path, alias: "watched", environment: f.environment)
    #expect(preview.displayedFingerprint == repeated.displayedFingerprint)
    #expect(preview.readLocations.map(\.path).contains(f.repo.path))
    #expect(try FileHash.folderHash(f.root) == before)
    #expect(!FileManager.default.fileExists(atPath: f.store.directory.path))
    let completion = UpdateOperations.performWatch(preview)
    #expect(completion.disposition == .committed && !completion.recovery.pending)
    #expect(try completion.result.get().seen == preview.seen)
    #expect(try f.store.loadWatch().sources[preview.sourceID]?.seen == preview.seen)
    #expect(try f.store.loadDeclaration().watch == ["watched"])
    #expect(!FileManager.default.fileExists(atPath: f.target().path))
    let removal = try operations.previewRemove("watched", environment: f.environment)
    let subscribed = try FileHash.folderHash(f.root)
    _ = try operations.previewRemove("watched", environment: f.environment)
    #expect(try FileHash.folderHash(f.root) == subscribed)
    let removed = UpdateOperations.performWatch(removal)
    #expect(removed.disposition == .committed && !removed.recovery.pending)
    #expect(try removed.result.get().seen == nil)
    #expect(try f.store.loadWatch().sources.isEmpty)
    #expect(try f.store.loadDeclaration().sources["watched"] != nil)
  }

  @Test func upstreamChangesAfterPreviewCannotBeAcknowledged() throws {
    let f = try UpdateFixture()
    try f.declare()
    let operations = SkillOperations.watchOperations()
    let preview = try operations.previewAdd("fixture", environment: f.environment)
    let before = try f.snapshot()
    try f.advance()
    let completion = UpdateOperations.performWatch(preview)
    #expect(completion.disposition == .unchanged && !completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(try f.snapshot() == before)
    #expect(try f.store.loadWatch().sources.isEmpty)
  }

  @Test func declarationEditsAfterPreviewPreventSubscriptionPublication() throws {
    let f = try UpdateFixture()
    try f.declare()
    let operations = SkillOperations.watchOperations()
    let preview = try operations.previewAdd("fixture", environment: f.environment)
    let edited =
      try String(contentsOf: f.store.declarationURL, encoding: .utf8) + "# External edit.\n"
    try f.write(edited, to: f.store.declarationURL)
    let before = try f.snapshot()
    let completion = UpdateOperations.performWatch(preview)
    #expect(completion.disposition == .unchanged && !completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(try f.snapshot() == before)
    #expect(try f.store.loadDeclaration().watch == nil)
  }

  @Test func removalRejectsAnAcknowledgmentChangedAfterConfirmation() throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
    let preview = try operations.previewRemove("watched", environment: f.environment)
    try f.advance()
    _ = try operations.seen("watched", environment: f.environment)
    let before = try f.snapshot()
    let completion = UpdateOperations.performWatch(preview)
    #expect(completion.disposition == .unchanged && !completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(try f.snapshot() == before)
    #expect(try f.store.loadDeclaration().watch == ["watched"])
  }

  @Test(arguments: [false, true])
  func committedWatchDisposalFailureHasAnOuterTerminalAndRetainedRecovery(_ acknowledging: Bool)
    throws
  {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    let preview: WatchMutationPreview
    if acknowledging {
      _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
      try f.advance()
      preview = operations.previewSeen(
        try #require(operations.status(environment: f.environment).first))
    } else {
      preview = try operations.previewAdd(
        f.repo.path, alias: "watched", environment: f.environment)
    }
    let displaced = f.root.appendingPathComponent("displaced-watch")
    let interrupted = WatchOperations(
      discoverSkills: { _ in throw CoreError.invalidState("unexpected discovery") },
      fetchArtifacts: { _ in throw CoreError.invalidState("unexpected artifact fetch") },
      declarations: .manifest,
      checkpoint: { [watchURL = f.store.watchURL] point in
        if point == TransactionCheckpoint.phase(.committed).name {
          try FileManager.default.moveItem(at: watchURL, to: displaced)
          throw CoreError.invalidState("fixture disposal interruption")
        }
      })
    let completion = UpdateOperations.performWatch(preview, operations: interrupted)
    #expect(completion.disposition == .committed && completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(throws: (any Error).self) {
      try operations.previewRemove("watched", environment: f.environment)
    }
    let blocked = UpdateOperations.performWatch(preview)
    #expect(blocked.disposition == .unchanged && blocked.recovery.pending)
    try FileManager.default.moveItem(at: displaced, to: f.store.watchURL)
    let recovered = UpdateOperations.performWatch(preview)
    #expect(recovered.disposition == .unchanged && recovered.recoveredBeforePreparation)
    #expect(!recovered.recovery.pending)
    #expect(try f.store.loadWatch().sources[preview.sourceID]?.seen == preview.seen)
  }
}

extension WatchConfirmationTests {
  @Test(arguments: [InstallScope.project, .user])
  func displayedStatusRetainsDurableInputsAndAcknowledgesInItsCapturedScope(_ scope: InstallScope)
    throws
  {
    let f = try UpdateFixture(scope: scope)
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", scope: scope, environment: f.environment)
    try f.advance()
    let before = try f.snapshot()
    let inspection = try operations.inspectStatus(scope: scope, environment: f.environment)
    let displayed = try #require(inspection.statuses.first)
    let diff = try operations.diff(
      "watched", name: "demo", kind: .skill, scope: scope, environment: f.environment)
    let expected = Set(
      [f.store.declarationURL, f.store.resolvedURL, f.store.watchURL, f.repo].map(\.path))
    #expect(Set(inspection.readLocations.map(\.path)) == expected)
    #expect(Set(displayed.readLocations.map(\.path)) == expected)
    #expect(diff.readLocations == displayed.readLocations)
    #expect(diff.changes.count == 1)
    #expect(try f.snapshot() == before)
    let preview = operations.previewSeen(diff)
    #expect(preview == operations.previewSeen(displayed))
    let completion = UpdateOperations.performWatch(diff)
    #expect(completion.disposition == .committed && !completion.recovery.pending)
    #expect(!completion.recoveredBeforePreparation)
    #expect(try completion.result.get().seen == displayed.current)
    #expect(try f.store.loadWatch().sources[displayed.sourceID]?.seen == displayed.current)
    #expect(!FileManager.default.fileExists(atPath: f.target().path))
  }

  @Test(arguments: ["content", "source", "declaration", "baseline"])
  func displayedAcknowledgmentRejectsChangedEvidence(_ changed: String) throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
    try f.advance()
    let displayed = try operations.diff("watched", environment: f.environment)
    switch changed {
    case "content":
      try f.writeSource("later")
      try f.commit()
    case "source":
      let other = f.root.appendingPathComponent("other-source")
      try FileManager.default.copyItem(at: f.repo, to: other)
      var declaration = try f.store.loadDeclaration()
      declaration.sources["watched"]?.location = other.path
      try f.store.save(declaration: declaration, ledger: f.store.loadLedger())
    case "declaration":
      let bytes = try Data(contentsOf: f.store.declarationURL) + Data("# External edit.\n".utf8)
      try bytes.write(to: f.store.declarationURL)
    default:
      _ = try operations.seen("watched", environment: f.environment)
    }
    let before = try f.snapshot()
    let completion = UpdateOperations.performWatch(displayed)
    #expect(completion.disposition == .unchanged && !completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(try f.snapshot() == before)
  }

  @Test(arguments: ["scope", "project", "home", "environment"])
  func displayedAcknowledgmentRejectsAnotherContext(_ changed: String) throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
    let displayed = try operations.diff("watched", environment: f.environment)
    var environment = f.environment
    var scope = InstallScope.project
    switch changed {
    case "scope": scope = .user
    case "project": environment.projectDirectory = f.root.appendingPathComponent("other-project")
    case "home": environment.homeDirectory = f.root.appendingPathComponent("other-home")
    default: environment.environment["WATCH_TEST_CONTEXT"] = "changed"
    }
    let before = try FileHash.folderHash(f.root)
    #expect(throws: (any Error).self) {
      try operations.seen(displayed, scope: scope, environment: environment)
    }
    #expect(try FileHash.folderHash(f.root) == before)
  }

  @Test func unrelatedSecretVariationPreservesPublicFingerprintAndPrivateContextGuard() throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
    var originalEnvironment = f.environment
    originalEnvironment.environment["UNRELATED_CREDENTIAL"] = "first-private-value"
    var changedEnvironment = originalEnvironment
    changedEnvironment.environment["UNRELATED_CREDENTIAL"] = "second-private-value"
    let original = try operations.diff("watched", environment: originalEnvironment)
    let changed = try operations.diff("watched", environment: changedEnvironment)
    let originalPreview = operations.previewSeen(original)
    let changedPreview = operations.previewSeen(changed)
    #expect(originalPreview.displayedFingerprint == changedPreview.displayedFingerprint)
    #expect(originalPreview != changedPreview)
    let before = try f.snapshot()
    #expect(throws: (any Error).self) {
      try operations.seen(original, environment: changedEnvironment)
    }
    #expect(try f.snapshot() == before)
    let completion = UpdateOperations.performWatch(original)
    #expect(completion.disposition == .committed && !completion.recovery.pending)
    #expect(try completion.result.get().seen == original.current)
  }

  @Test func displayedAcknowledgmentReportsRollbackAfterPublicationFailure() throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    _ = try operations.add(f.repo.path, alias: "watched", environment: f.environment)
    try f.advance()
    let displayed = try operations.diff("watched", environment: f.environment)
    let before = try f.snapshot()
    let interrupted = WatchOperations(
      discoverSkills: { _ in [] }, fetchArtifacts: { _ in [] }, declarations: .manifest,
      checkpoint: { point in
        if point == TransactionCheckpoint.publication(0, .exchanged).name {
          throw CoreError.invalidState("fixture publication interruption")
        }
      })
    let completion = UpdateOperations.performWatch(displayed, operations: interrupted)
    #expect(completion.disposition == .rolledBack && !completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(try f.snapshot() == before)
  }
}

extension WatchConfirmationTests {
  @Test func artifactAcknowledgmentUsesTheOuterOutcomeAndRevalidatesDigests() throws {
    let f = try UpdateFixture()
    func operations(_ body: String, failPreparation: Bool = false) -> WatchOperations {
      let bytes = Data(body.utf8)
      let digest = "sha256:" + FileHash.sha256Hex(data: bytes)
      return WatchOperations(
        discoverSkills: { _ in [] },
        fetchArtifacts: { _ in
          [
            WatchArtifact(
              name: "demo",
              artifact: LockedArtifact(
                type: .skillMD, url: "https://example.invalid/demo.md", digest: digest),
              files: ["SKILL.md": bytes], payloads: [digest: bytes])
          ]
        }, declarations: .manifest,
        checkpoint: { point in
          if failPreparation && point == "watch.artifact.0.content.journal.committed" {
            throw CoreError.invalidState("fixture artifact preparation interruption")
          }
        })
    }
    let original = operations("original")
    _ = try original.add(
      "https://example.invalid/index", alias: "watched", environment: f.environment)
    let originalStatus = try original.diff("watched", environment: f.environment)
    let advanced = operations("advanced")
    let before = try f.snapshot()
    let stale = UpdateOperations.performWatch(originalStatus, operations: advanced)
    #expect(stale.disposition == .unchanged && !stale.recovery.pending)
    #expect(throws: (any Error).self) { try stale.result.get() }
    #expect(try f.snapshot() == before)
    let displayed = try advanced.diff("watched", environment: f.environment)
    #expect(
      Set(displayed.readLocations.map(\.path))
        == Set([f.store.declarationURL, f.store.resolvedURL, f.store.watchURL].map(\.path)))
    let interrupted = UpdateOperations.performWatch(
      displayed, operations: operations("advanced", failPreparation: true))
    #expect(interrupted.disposition == .unchanged && !interrupted.recovery.pending)
    #expect(throws: (any Error).self) { try interrupted.result.get() }
    #expect(try f.snapshot() == before)
    let completed = UpdateOperations.performWatch(displayed, operations: advanced)
    #expect(completed.disposition == .committed && !completed.recovery.pending)
    #expect(try completed.result.get().seen == displayed.current)
  }
}
