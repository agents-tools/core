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

  @Test func committedWatchDisposalFailureHasAnOuterTerminalAndRetainedRecovery() throws {
    let f = try UpdateFixture()
    let operations = SkillOperations.watchOperations()
    let preview = try operations.previewAdd(
      f.repo.path, alias: "watched", environment: f.environment)
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
