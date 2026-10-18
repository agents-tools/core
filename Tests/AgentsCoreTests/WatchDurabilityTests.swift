import AgentsCore
import Darwin
import Foundation
import Testing

@Suite("Watch Git durability")
struct WatchDurabilityTests {
  @Test(
    arguments: [false, true],
    [
      "watch.mirror.fetched", "watch.objects.synced", "watch.ref.updated", "watch.ref.synced",
      "watch.mirror.synced", "journal.applying", "replace.0.renamed",
      "journal.committed.renamed", "journal.committed", "journal.removed",
    ])
  func interruptedAcknowledgmentRetainsTheRecoveredBaseline(_ advancing: Bool, _ step: String)
    throws
  {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    if advancing {
      try fixture.watch.add(fixture.repo.path, alias: "source", environment: fixture.environment)
      try fixture.rewrite("replacement")
    }
    let current = try fixture.head()
    let before = try fixture.stateBytes()
    let child = try stateTestProcess(
      root: fixture.root, arguments: [advancing ? "watch-seen" : "watch-add", step])
    try fixture.kill(child, at: step)
    let committed = step.hasPrefix("journal.committed") || step == "journal.removed"
    let state = try fixture.recoveredWatch()
    let expected = committed ? current : advancing ? first : nil
    #expect(state.sources[fixture.id]?.seen == expected.map(WatchSeen.revision))
    if !committed { #expect(try fixture.stateBytes() == before) }
    if let expected {
      // Neither a deleted upstream nor collection of unreachable mirror objects can
      // substitute for the baseline selected by transaction recovery.
      try FileManager.default.removeItem(at: fixture.repo)
      try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
      try fixture.mirrorGit(["gc", "--prune=now"])
      let content = try fixture.cachedInstruction(expected)
      #expect(content.contains(expected == first ? "initial" : "replacement"))
    }
    if step != "watch.mirror.fetched" {
      #expect(
        try fixture.mirrorGit(["config", "--local", "--get", "core.fsync"])
          == "objects,reference,pack-metadata")
      #expect(try fixture.mirrorGit(["config", "--local", "--get", "core.fsyncMethod"]) == "fsync")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
  }

  @Test func acknowledgesObjectsAlreadyFetchedWithWeakDurability() throws {
    let fixture = try WatchGitFixture()
    let source = SourceDeclaration(kind: .local, location: fixture.repo.path)
    let cache = SourceCache(store: fixture.store)
    _ = try fixture.store.withLock { try cache.resolve(source) }
    try fixture.mirrorGit(["config", "--local", "core.fsync", "none"])
    try fixture.mirrorGit(["config", "--local", "core.fsyncMethod", "writeout-only"])
    let revision = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    #expect(try fixture.mirrorGit(["config", "--local", "--get", "core.fsyncMethod"]) == "fsync")
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(revision))
    try fixture.mirrorGit(["pack-refs", "--all"])
    // Acknowledging an already packed ref still flushes its durable representation.
    try fixture.watch.seen("source", revision: revision, environment: fixture.environment)
    try FileManager.default.removeItem(at: fixture.repo)
    #expect(try fixture.cachedInstruction(revision).contains("initial"))
  }

  @Test func durabilityFailurePreventsWatchPublication() throws {
    let fixture = try WatchGitFixture()
    let before = try fixture.stateBytes()
    let watch = WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") },
      checkpoint: { step in
        if step == "watch.ref.updated" {
          throw CoreError.invalidState("injected durability failure")
        }
      })
    #expect(throws: CoreError.self) {
      try watch.add("source", environment: fixture.environment)
    }
    #expect(try fixture.stateBytes() == before)
  }

  @Test func localSourceWithAlternatesProducesSelfContainedMirror() throws {
    let fixture = try WatchGitFixture()
    let borrowed = fixture.root.appendingPathComponent("borrowed")
    try ProcessRunner.run(
      "/usr/bin/env",
      arguments: ["git", "clone", "--shared", "--bare", fixture.repo.path, borrowed.path])
    let id = "local:" + borrowed.path
    let revision = try fixture.head()
    try fixture.watch.add(borrowed.path, alias: "borrowed", environment: fixture.environment)
    try FileManager.default.removeItem(at: borrowed)
    try FileManager.default.removeItem(at: fixture.repo)
    let content = try SourceCache(store: fixture.store).withSnapshot(
      sourceID: id, source: LockedSource(kind: .local), revision: revision
    ) {
      try String(contentsOf: $0.appendingPathComponent("instructions/rule.md"), encoding: .utf8)
    }
    #expect(content.contains("initial"))
  }
}

final class WatchGitFixture {
  let root: URL
  let repo: URL
  let environment: RuntimeEnvironment
  let watch = WatchOperations(
    discoverSkills: { _ in [] },
    fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") })
  var store: StateStore { StateStore(scope: .project, environment: environment) }
  var id: String { "local:" + repo.path }
  var mirror: URL { SourceCache(store: store).mirrorURL(sourceID: id) }

  init() throws {
    root = try temporaryDirectory()
    repo = root.appendingPathComponent("source")
    environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    do {
      try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("instructions"), withIntermediateDirectories: true)
      try Data("# Rule\ninitial\n".utf8).write(
        to: repo.appendingPathComponent("instructions/rule.md"))
      try initGitRepo(repo)
      try store.save(
        declaration: Declaration(sources: [
          "source": SourceDeclaration(kind: .local, location: repo.path)
        ]), resolved: ResolvedState())
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func head() throws -> String { try gitHead(repo) }

  func rewrite(_ name: String) throws {
    try git(["checkout", "--orphan", name])
    try git(["rm", "-rf", "."])
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("instructions"), withIntermediateDirectories: true)
    try Data("# Rule\n\(name)\n".utf8).write(
      to: repo.appendingPathComponent("instructions/rule.md"))
    try git(["add", "."])
    try git(["commit", "-m", name])
    for branch in try git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]).split(
      separator: "\n") where branch != name
    {
      try git(["branch", "-D", String(branch)])
    }
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path] + arguments).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func mirrorGit(_ arguments: [String]) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", mirror.path] + arguments).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func stateBytes() throws -> [Data?] {
    try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil
    }
  }

  func recoveredWatch() throws -> WatchState {
    do { return try store.loadWatch() } catch CoreError.transactionRecovered {
      return try store.loadWatch()
    }
  }

  func cachedInstruction(_ revision: String) throws -> String {
    try SourceCache(store: store).withSnapshot(
      sourceID: id, source: LockedSource(kind: .local), revision: revision
    ) {
      try String(contentsOf: $0.appendingPathComponent("instructions/rule.md"), encoding: .utf8)
    }
  }

  func kill(_ child: Process, at step: String) throws {
    defer {
      if child.isRunning {
        Darwin.kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = root.appendingPathComponent("ready")
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path), "did not reach \(step)")
    #expect(try String(contentsOf: marker, encoding: .utf8) == step)
    Darwin.kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    try FileManager.default.removeItem(at: marker)
  }
}
