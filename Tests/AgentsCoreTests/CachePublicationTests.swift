import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Durable cache publication")
struct CachePublicationTests {
  @Test(
    arguments: ["cache-content", "cache-git"],
    [
      "stage.0.copy.entry.0.staged.directoryCreated",
      "stage.0.copy.entry.0.staged/SKILL.md.entryCopied", "entry.0.ready", "publish.0.created",
      "journal.committed.terminal.renamed",
    ])
  func interruptedTreePublicationRecoversAndRetries(_ kind: String, _ point: String) throws {
    let fixture = try CacheFixture(git: kind == "cache-git")
    try interrupt(fixture, kind: kind, point: point)
    if point.hasPrefix("stage.") || point.hasPrefix("entry.") {
      #expect(try FileSnapshot.read(at: fixture.destination) == nil)
    } else {
      #expect(try FileHash.folderHash(fixture.destination) == fixture.hash)
    }
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
    let committed = point.hasPrefix("journal.committed")
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path) == committed)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
    try fixture.publish()
    #expect(try FileHash.folderHash(fixture.destination) == fixture.hash)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.destination.deletingLastPathComponent().path) == [
          fixture.destination.lastPathComponent
        ])
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
  }

  @Test(arguments: [
    "stage.0.constructed", "entry.0.ready", "publish.0.created",
    "journal.committed.terminal.renamed",
  ])
  func interruptedArtifactBytesAreNeverPublishedPartially(_ point: String) throws {
    let fixture = try CacheFixture()
    try interrupt(fixture, kind: "cache-bytes", point: point)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
    let cache = SourceCache(store: fixture.store)
    let payload = try Data(contentsOf: fixture.root.appendingPathComponent("payload"))
    let url = try fixture.store.withLock {
      try cache.storeArtifact(payload, digest: fixture.digest)
    }
    #expect(try Data(contentsOf: url) == payload)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
  }

  @Test(arguments: ["stage.0.workCreated", "stage.0.workPrepared"])
  func interruptedExtractionCleansJournalOwnedScratch(_ point: String) throws {
    let fixture = try CacheFixture(git: true)
    try interrupt(fixture, kind: "cache-git", point: point)
    #expect(try FileSnapshot.read(at: fixture.destination) == nil)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.destination.deletingLastPathComponent().path
      ).isEmpty)
    try fixture.publish()
    #expect(try FileHash.folderHash(fixture.destination) == fixture.hash)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
  }

  @Test func verifiesPrivateCopyBeforePublication() throws {
    let fixture = try CacheFixture()
    let beforeState = try FileSnapshot.read(at: fixture.store.resolvedURL)
    let cache = SourceCache(store: fixture.store) { step in
      if step == "stage.0.constructed" {
        let parent = fixture.destination.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path)
        where name.hasPrefix(".agents-") {
          try Data("tampered".utf8).write(
            to: parent.appendingPathComponent(name).appendingPathComponent(
              "entry.0.staged/injected"))
        }
      }
    }
    #expect(throws: CoreError.invalidState("staged content digest mismatch")) {
      try fixture.store.withLock {
        try cache.materializeArtifact(
          fixture.root.appendingPathComponent("new"), digest: fixture.digest,
          hash: "sha256:" + fixture.hash)
      }
    }
    #expect(try FileSnapshot.read(at: fixture.destination) == nil)
    #expect(try FileSnapshot.read(at: fixture.store.resolvedURL) == beforeState)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.destination.deletingLastPathComponent().path
      ).isEmpty)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
  }

  @Test func verifiesPrivateBytesBeforePublication() throws {
    let fixture = try CacheFixture()
    let beforeState = try FileSnapshot.read(at: fixture.store.resolvedURL)
    let cache = SourceCache(store: fixture.store) { step in
      if step == "stage.0.constructed" {
        let parent = fixture.store.cacheDirectory.appendingPathComponent("artifacts")
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path)
        where name.hasPrefix(".agents-") {
          try Data("tampered".utf8).write(
            to: parent.appendingPathComponent(name).appendingPathComponent("entry.0.staged"))
        }
      }
    }
    #expect(throws: CoreError.invalidState("staged content bytes mismatch")) {
      try fixture.store.withLock {
        try cache.storeArtifact(
          Data(contentsOf: fixture.root.appendingPathComponent("payload")), digest: fixture.digest)
      }
    }
    let final = try cache.artifactURL(digest: fixture.digest)
    #expect(try FileSnapshot.read(at: final) == nil)
    #expect(try FileSnapshot.read(at: fixture.store.resolvedURL) == beforeState)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        .isEmpty)
  }

  @Test(arguments: [false, true])
  func concurrentCacheCreatorKeepsItsBytesAndInode(_ equalBytes: Bool) throws {
    let fixture = try CacheFixture()
    let beforeState = try FileSnapshot.read(at: fixture.store.resolvedURL)
    let payload = try Data(contentsOf: fixture.root.appendingPathComponent("payload"))
    let final = try SourceCache(store: fixture.store).artifactURL(digest: fixture.digest)
    var external: FileSnapshot?
    let cache = SourceCache(store: fixture.store) { step in
      if step == "publish.0.validated" {
        try (equalBytes ? payload : Data("external cache bytes".utf8)).write(to: final)
        external = try FileSnapshot.read(at: final)
      }
    }
    #expect {
      try fixture.store.withLock { try cache.storeArtifact(payload, digest: fixture.digest) }
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("transaction destination already exists")
    }
    #expect(external != nil)
    #expect(try FileSnapshot.read(at: final) == external)
    #expect(try FileSnapshot.read(at: fixture.store.resolvedURL) == beforeState)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        == [final.lastPathComponent])
  }

  private func interrupt(_ fixture: CacheFixture, kind: String, point: String) throws {
    let child = try stateTestProcess(root: fixture.root, arguments: [kind, point])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = fixture.root.appendingPathComponent("ready")
    try ProcessWait.marker(marker, child: child, root: fixture.root)
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
  }
}

private final class CacheFixture {
  let root: URL
  let store: StateStore
  let hash: String
  let digest: String
  let destination: URL
  let lockBytes: Data
  private let sourceID: String
  private let revision: String?

  init(git: Bool = false) throws {
    root = try temporaryDirectory()
    do {
      let tree = root.appendingPathComponent("new")
      try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
      for name in ["SKILL.md", "z-reference.md"] {
        try Data(name.utf8).write(to: tree.appendingPathComponent(name))
      }
      hash = try FileHash.folderHash(tree)
      let payload = Data(repeating: 42, count: 256 * 1024)
      try payload.write(to: root.appendingPathComponent("payload"))
      digest = "sha256:" + FileHash.sha256Hex(data: payload)
      store = StateStore(
        scope: .project,
        environment: RuntimeEnvironment(
          projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
          environment: [:]))
      let source: LockedSource
      let skill: LockedSkill
      let cache = SourceCache(store: store)
      if git {
        try initGitRepo(tree)
        revision = try gitHead(tree)
        sourceID = "local:" + tree.path
        source = LockedSource(kind: .local)
        skill = LockedSkill(
          source: sourceID, revision: revision, path: ".", hash: "sha256:" + hash,
          installs: ["codex": .link])
        destination = cache.materializedURL(sourceID: sourceID, revision: revision!)
      } else {
        revision = nil
        sourceID = "https://example.test"
        source = LockedSource(kind: .wellKnown)
        skill = LockedSkill(
          source: sourceID,
          artifact: LockedArtifact(
            type: .archive, url: sourceID + "/archive.tar.gz", digest: digest),
          hash: "sha256:" + hash, installs: ["codex": .link])
        destination = store.cacheDirectory.appendingPathComponent(
          "artifact-content/" + digest.dropFirst(7))
      }
      try store.save(
        declaration: Declaration(),
        resolved: ResolvedState(sources: [sourceID: source], skills: ["demo": skill]))
      lockBytes = try Data(contentsOf: store.resolvedURL)
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }
  deinit { removeTemporaryDirectory(root) }

  func publish() throws {
    let cache = SourceCache(store: store)
    try store.withLock {
      if let revision {
        _ = try cache.materialize(
          sourceID: sourceID, source: LockedSource(kind: .local), revision: revision)
      } else {
        _ = try cache.materializeArtifact(
          root.appendingPathComponent("new"), digest: digest, hash: "sha256:" + hash)
      }
    }
  }
}
