import AgentsCore
import Foundation
import Testing

@Suite("Watch Git ref retention")
struct WatchReferenceTests {
  @Test(
    arguments: [false, true],
    ["watch.references.deleted", "watch.references.synced", "watch.references.cleared"])
  func interruptedCleanupUsesCommittedBaselines(_ removing: Bool, _ step: String) throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    let replacement = try fixture.head()
    if removing {
      // Leave the acknowledged commit reachable only through its watch ref.
      try fixture.watch.seen("source", environment: fixture.environment)
      try fixture.rewrite("later")
      _ = try fixture.watch.status(environment: fixture.environment)
    }
    let obsolete = removing ? replacement : first
    #expect(try fixture.watchRefs().contains(obsolete))
    // Exercise packed refs as well as loose retention refs.
    try fixture.mirrorGit(["pack-refs", "--all"])
    let child = try stateTestProcess(
      root: fixture.root, arguments: [removing ? "watch-remove" : "watch-seen", step])
    try fixture.kill(child, at: step)
    let state = try fixture.recoveredWatch()
    #expect(state.sources[fixture.id]?.seen == (removing ? nil : .revision(replacement)))
    #expect(try fixture.watchRefs() == (removing ? [] : [replacement]))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path))
    try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
    try fixture.mirrorGit(["gc", "--prune=now"])
    #expect(throws: (any Error).self) {
      try fixture.mirrorGit(["cat-file", "-e", obsolete])
    }
    if !removing { #expect(try fixture.cachedInstruction(replacement).contains("replacement")) }
  }

  @Test func interruptedRollbackCleanupPreservesThePreviousBaseline() throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    let before = try fixture.stateBytes()
    try fixture.rewrite("replacement")
    let replacement = try fixture.head()
    let writer = try stateTestProcess(
      root: fixture.root, arguments: ["watch-seen", "replace.0.renamed"])
    try fixture.kill(writer, at: "replace.0.renamed")
    #expect(try fixture.watchRefs() == [first, replacement])
    let recovery = try stateTestProcess(
      root: fixture.root, arguments: ["watch-recover", "watch.references.deleted"])
    try fixture.kill(recovery, at: "watch.references.deleted")
    #expect(try fixture.recoveredWatch().sources[fixture.id]?.seen == .revision(first))
    #expect(try fixture.stateBytes() == before)
    #expect(try fixture.watchRefs() == [first])
    try FileManager.default.removeItem(at: fixture.repo)
    try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
    try fixture.mirrorGit(["gc", "--prune=now"])
    #expect(try fixture.cachedInstruction(first).contains("initial"))
  }

  @Test func corruptWatchStateStopsPendingRefCleanup() throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    let replacement = try fixture.head()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["watch-seen", "watch.mirror.synced"])
    try fixture.kill(child, at: "watch.mirror.synced")
    let corrupt = Data("invalid watch state".utf8)
    try corrupt.write(to: fixture.store.watchURL)
    #expect(throws: CoreError.self) { try fixture.store.loadWatch() }
    #expect(try Data(contentsOf: fixture.store.watchURL) == corrupt)
    #expect(try fixture.watchRefs() == [first, replacement])
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path))
  }
}
