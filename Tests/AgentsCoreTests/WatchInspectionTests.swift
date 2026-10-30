import Foundation
import Testing

@testable import AgentsCore

@Suite("Read-only watch inspection")
struct WatchInspectionTests {
  @Test(arguments: [
    TransactionCheckpoint.publication(0, .exchanged).name,
    TransactionCheckpoint.phase(.committed).name,
  ])
  func pendingTransactionLeavesStateUnchanged(_ step: String) throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["watch-seen", step])
    try fixture.kill(child, at: step)
    try #require(
      FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
    let before = try FileHash.folderHash(fixture.store.directory)
    let pending = CoreError.invalidState("transaction recovery is required before inspection")

    #expect(throws: pending) { try fixture.watch.status(environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
    #expect(throws: pending) { try fixture.watch.diff("source", environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
  }

  @Test(arguments: [TransactionCheckpoint.journalRemoved.name, "watch.references.0.0.deleted"])
  func pendingRefCleanupLeavesStateUnchanged(_ step: String) throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    let committed = try fixture.head()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["watch-seen", step])
    try fixture.kill(child, at: step)
    try #require(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
    try #require(
      FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path))
    let refs: Set<String> =
      step == TransactionCheckpoint.journalRemoved.name ? [first, committed] : [committed]
    try #require(try fixture.watchRefs() == refs)
    try fixture.rewrite("later")
    let before = try FileHash.folderHash(fixture.store.directory)
    let pending = CoreError.invalidState("transaction recovery is required before inspection")

    #expect(throws: pending) { try fixture.watch.status(environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
    #expect(throws: pending) { try fixture.watch.diff("source", environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
    #expect(try fixture.watchRefs() == refs)
  }

  @Test(arguments: [InstallScope.project, .user], [false, true])
  func inspectionDoesNotCreateState(_ scope: InstallScope, _ existingDirectory: Bool) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let store = StateStore(scope: scope, environment: environment)
    if existingDirectory {
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
    }
    let before = try FileHash.folderHash(root)
    let watch = WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in throw CoreError.unsupported("no subscribed sources") })

    #expect(try watch.status(scope: scope, environment: environment).isEmpty)
    #expect(try FileHash.folderHash(root) == before)
    #expect(throws: CoreError.notFound("source is not subscribed: ./source")) {
      try watch.diff("./source", scope: scope, environment: environment)
    }
    #expect(try FileHash.folderHash(root) == before)
  }
}
