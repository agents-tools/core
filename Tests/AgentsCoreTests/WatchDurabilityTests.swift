import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Watch Git durability")
struct WatchDurabilityTests {
  @Test(
    arguments: [false, true],
    [
      "watch.mirror.fetched", "watch.references.pending", "watch.objects.synced",
      "watch.ref.updated", "watch.ref.synced",
      "watch.mirror.synced", TransactionCheckpoint.progress(0, .publishing).name,
      TransactionCheckpoint.publication(0, .exchanged).name,
      TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name,
      TransactionCheckpoint.phase(.committed).name, TransactionCheckpoint.journalRemoved.name,
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
    let committed = [
      TransactionCheckpoint.persisted(.committed, .terminal, .renamed), .phase(.committed),
      .journalRemoved,
    ].map(\.name).contains(step)
    let state = try fixture.recoveredWatch()
    let expected = committed ? current : advancing ? first : nil
    #expect(state.sources[fixture.id]?.seen == expected.map(WatchSeen.revision))
    #expect(try fixture.watchRefs() == Set(expected.map { [$0] } ?? []))
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
    let configURL = fixture.mirror.appendingPathComponent("config")
    let config = try Data(contentsOf: configURL)
    let revision = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    #expect(try Data(contentsOf: configURL) == config)
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(revision))
    try fixture.mirrorGit(["pack-refs", "--all"])
    // Acknowledging an already packed ref still flushes its durable representation.
    try fixture.watch.seen("source", revision: revision, environment: fixture.environment)
    try FileManager.default.removeItem(at: fixture.repo)
    #expect(try fixture.cachedInstruction(revision).contains("initial"))
    try fixture.watch.remove("source", environment: fixture.environment)
    #expect(try Data(contentsOf: configURL) == config)
  }

  @Test(arguments: [false, true])
  func rejectsEscapingConfigurationBeforeAcknowledgment(_ subscribed: Bool) throws {
    let fixture = try WatchGitFixture()
    if subscribed {
      try fixture.watch.add("source", environment: fixture.environment)
    } else {
      _ = try fixture.store.withLock {
        try SourceCache(store: fixture.store).resolve(
          SourceDeclaration(kind: .local, location: fixture.repo.path))
      }
    }
    let config = fixture.mirror.appendingPathComponent("config")
    let external = fixture.root.appendingPathComponent("external-config")
    let original = try Data(contentsOf: config)
    try original.write(to: external)
    try FileManager.default.removeItem(at: config)
    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: external)
    let state = try fixture.stateBytes()
    let tree = try FileHash.folderHash(fixture.store.directory)
    #expect(throws: CoreError.self) {
      if subscribed {
        try fixture.watch.seen("source", environment: fixture.environment)
      } else {
        try fixture.watch.add("source", environment: fixture.environment)
      }
    }
    #expect(try Data(contentsOf: external) == original)
    #expect(try fixture.stateBytes() == state)
    #expect(try FileHash.folderHash(fixture.store.directory) == tree)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == external.path)
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
      try Data("---\ndescription: Fixture instructions.\n---\n# Rule\ninitial\n".utf8).write(
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
    try Data("---\ndescription: Fixture instructions.\n---\n# Rule\n\(name)\n".utf8).write(
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

  func watchRefs() throws -> Set<String> {
    Set(
      try mirrorGit(["for-each-ref", "--format=%(objectname)", "refs/agents-watch/"])
        .split(separator: "\n").map(String.init))
  }

  func kill(_ child: Process, at step: String) throws {
    defer { terminateProcess(child) }
    let marker = root.appendingPathComponent("ready")
    try ProcessWait.marker(marker, child: child, root: root)
    #expect(try String(contentsOf: marker, encoding: .utf8) == step)
    terminateProcess(child)
    try FileManager.default.removeItem(at: marker)
  }
}
