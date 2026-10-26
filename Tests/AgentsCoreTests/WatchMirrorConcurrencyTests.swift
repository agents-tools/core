import AgentsCore
import Darwin
import Foundation
import Testing

@Suite("Watch mirror exclusion")
struct WatchMirrorConcurrencyTests {
  @Test(arguments: [false, true])
  func parentDeathKeepsGitDeletionExclusive(_ packed: Bool) throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    _ = try fixture.watch.status(environment: fixture.environment)
    if packed { try fixture.mirrorGit(["pack-refs", "--all"]) }
    let pause = try GitTransactionPause(
      root: fixture.root, hooks: fixture.mirror.appendingPathComponent("hooks"),
      condition:
        "[ \"$ref\" = \"refs/agents-watch/\(first)\" ] && [ \"$new\" = \"\(String(repeating: "0", count: first.count))\" ]"
    )
    defer { pause.terminate() }
    let parent = try stateTestProcess(root: fixture.root, arguments: ["watch-seen", ""])
    defer { terminateProcess(parent) }
    try pause.wait()
    let locks = try gitLocks(fixture)
    try #require(!locks.isEmpty)
    let committed = try fixture.stateBytes()

    // Kill only Swift. Git and its prepared hook remain alive with the real deletion locks.
    terminateProcess(parent)
    try #require(kill(pause.git, 0) == 0)
    try #require(kill(pause.hook, 0) == 0)
    let contention = try ProcessSignal(at: fixture.root.appendingPathComponent("writer-contended"))
    let acknowledger = try stateTestProcess(
      root: fixture.root, arguments: ["watch-acknowledge", first])
    defer { terminateProcess(acknowledger) }
    #expect(try contention.receive() == "contended")
    #expect(acknowledger.isRunning)
    #expect(!exists(fixture.root.appendingPathComponent("writer-finished")))
    #expect(try fixture.stateBytes() == committed)
    let currentLocks = try gitLocks(fixture)
    #expect(currentLocks == locks)

    // Recovery and re-acknowledgment must follow the surviving Git child's completion.
    try finishProcesses([acknowledger], resuming: pause)
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(first))
    #expect(try fixture.watchRefs() == [first])
    #expect(try gitLocks(fixture).isEmpty)
    try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
    try fixture.mirrorGit(["gc", "--prune=now"])
    #expect(try fixture.cachedInstruction(first).contains("initial"))
  }

  @Test(arguments: [false, true])
  func listingAndFirstWatchMutationShareMirrorLock(_ existingMirror: Bool) throws {
    let fixture = try WatchGitFixture()
    try FileManager.default.removeItem(at: fixture.store.directory)
    let scopeLock = fixture.store.directory.appendingPathComponent(".agents.lock")
    let template = fixture.root.appendingPathComponent("template")
    if existingMirror {
      let listing = try stateTestProcess(root: fixture.root, arguments: ["instruction-list", ""])
      defer { terminateProcess(listing) }
      try finishProcesses([listing])
      try #require(exists(fixture.mirror))
      try #require(!exists(scopeLock))
      try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("listing-finished"))
      try Data("---\ndescription: Fixture instructions.\n---\n# Rule\nupdated\n".utf8).write(
        to: fixture.repo.appendingPathComponent("instructions/rule.md"))
      try fixture.git(["commit", "-am", "update"])
    }
    let pause = try GitTransactionPause(
      root: fixture.root,
      hooks: (existingMirror ? fixture.mirror : template).appendingPathComponent("hooks"),
      condition: "[ \"${ref#refs/heads/}\" != \"$ref\" ]")
    defer { pause.terminate() }
    let listing = try stateTestProcess(
      root: fixture.root, arguments: ["instruction-list", ""],
      environment: existingMirror ? [:] : ["GIT_TEMPLATE_DIR": template.path])
    defer { terminateProcess(listing) }
    try pause.wait()
    try #require(!exists(scopeLock))
    let mirrorLock = fixture.store.cacheDirectory.appendingPathComponent("locks")
      .appendingPathComponent(fixture.mirror.deletingPathExtension().lastPathComponent + ".lock")
    try #require(exists(mirrorLock))
    let contention = try ProcessSignal(at: fixture.root.appendingPathComponent("writer-contended"))

    let writer = try stateTestProcess(root: fixture.root, arguments: ["watch-subscribe", ""])
    defer { terminateProcess(writer) }
    #expect(try contention.receive() == "contended")
    #expect(exists(scopeLock))
    #expect(writer.isRunning)
    #expect(!exists(fixture.store.watchURL))
    #expect(!exists(fixture.root.appendingPathComponent("writer-finished")))

    try finishProcesses([listing, writer], resuming: pause)
    #expect(
      try String(
        contentsOf: fixture.root.appendingPathComponent("listing-finished"), encoding: .utf8)
        == "rule")
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(fixture.head()))
    #expect(try fixture.watchRefs() == [fixture.head()])
    #expect(try gitLocks(fixture).isEmpty)
  }

  private func gitLocks(_ fixture: WatchGitFixture) throws -> [String: Data] {
    let directory = fixture.store.cacheDirectory.appendingPathComponent("mirrors")
    let entries = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    var result: [String: Data] = [:]
    for case let entry as URL in entries where entry.lastPathComponent.hasSuffix(".lock") {
      result[entry.path] = try Data(contentsOf: entry)
    }
    return result
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
