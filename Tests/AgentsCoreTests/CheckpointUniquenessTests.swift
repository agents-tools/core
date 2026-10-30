import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

/// The recorder fails on a repeated name, so repeated work in one process must name each
/// repetition. Every scenario completes under the recorder and can stop at a second repetition.
@Suite("Recorded checkpoint uniqueness")
struct CheckpointUniquenessTests {
  @Test func eachStaleWatchReferenceHasItsOwnPoint() throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    var stale = [try fixture.head()]
    try fixture.rewrite("second")
    try fixture.watch.seen("source", environment: fixture.environment)
    stale.append(try fixture.head())
    try fixture.rewrite("third")
    try fixture.watch.seen("source", environment: fixture.environment)
    let current = try fixture.head()
    func restoreStaleReferences() throws {
      for revision in stale {
        try fixture.mirrorGit(["update-ref", "refs/agents-watch/" + revision, revision])
      }
      try Data().write(to: fixture.store.directory.appendingPathComponent("watch-refs.pending"))
    }
    try restoreStaleReferences()
    try fixture.recordCompletely("watch-recover")
    #expect(try fixture.watchRefs() == [current])
    try restoreStaleReferences()
    let second = "watch.references.0.1.deleted"
    try fixture.kill(
      try stateTestProcess(root: fixture.root, arguments: ["watch-recover", second]), at: second)
    #expect(try fixture.recoveredWatch().sources[fixture.id]?.seen == .revision(current))
    #expect(try fixture.watchRefs() == [current])
  }

  @Test func eachAbandonedGitLockHasItsOwnPoint() throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    let locks = ["config.lock", "objects/pack/abandoned.lock"].map {
      fixture.mirror.appendingPathComponent($0)
    }
    func abandonLocks() throws {
      for lock in locks { try Data("abandoned".utf8).write(to: lock) }
    }
    try abandonLocks()
    try fixture.recordCompletely("watch-recover")
    try abandonLocks()
    let second = "watch.git-lock.0.1.unlinked"
    try fixture.kill(
      try stateTestProcess(root: fixture.root, arguments: ["watch-recover", second]), at: second)
    for lock in locks { #expect(!FileManager.default.fileExists(atPath: lock.path)) }
    _ = try fixture.recoveredWatch()
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path))
  }

  /// Payload, content and watch transactions write the same transaction names; the two nested
  /// cache transactions are scoped by artifact and role.
  @Test func nestedArtifactTransactionsHaveScopedPoints() throws {
    let ready = TransactionCheckpoint.progress(0, .ready).name
    let complete = try ArtifactWatchFixture()
    let trace = try complete.record("never")
    for point in [
      "watch.artifact.0.payload.0." + ready, "watch.artifact.0.content." + ready, ready,
    ] {
      #expect(trace.contains(point))
    }
    #expect(try complete.store.loadWatch().sources.count == 1)

    let interrupted = try ArtifactWatchFixture()
    let content = "watch.artifact.0.content." + ready
    let child = try stateTestProcess(
      root: interrupted.root, arguments: ["watch-add-artifact", content])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      interrupted.root.appendingPathComponent("ready"), child: child, root: interrupted.root)
    try ProcessWait.stopped(child, root: interrupted.root)
    terminateProcess(child)
    #expect(throws: CoreError.transactionRecovered(interrupted.store.directory.path)) {
      try interrupted.store.loadWatch()
    }
    #expect(try interrupted.store.loadWatch().sources.isEmpty)
    let contents = interrupted.store.cacheDirectory.appendingPathComponent("artifact-content")
    #expect((try? FileManager.default.contentsOfDirectory(atPath: contents.path)) ?? [] == [])
  }
}

private final class ArtifactWatchFixture {
  let root: URL
  let store: StateStore

  init() throws {
    root = try temporaryDirectory()
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
        environment: [:]))
    do {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }

  deinit { removeTemporaryDirectory(root) }

  func record(_ point: String) throws -> [String] {
    let child = try stateTestProcess(root: root, arguments: ["watch-add-artifact", point])
    defer { terminateProcess(child) }
    try ProcessWait.exit(child, root: root)
    #expect(child.terminationStatus == 0)
    return try String(
      contentsOf: root.appendingPathComponent("checkpoint-\(child.processIdentifier).log"),
      encoding: .utf8
    ).split(separator: "\n").map(String.init)
  }
}

extension WatchGitFixture {
  /// Runs `command` to completion under the recorder, which fails on any repeated name.
  fileprivate func recordCompletely(_ command: String) throws {
    let child = try stateTestProcess(root: root, arguments: [command, "never"])
    defer { terminateProcess(child) }
    try ProcessWait.exit(child, root: root)
    #expect(child.terminationStatus == 0)
  }
}
