import Darwin
import Foundation
import Testing

@testable import AgentsCore

@Suite("Durable cache publication")
struct CachePublicationTests {
  @Test(
    arguments: ["cache-content", "cache-git"],
    [
      "stage.0.copy.directory", "stage.0.copy.entry", "stage.0.verified", "replace.0.renamed",
      "journal.committed.renamed",
    ])
  func interruptedTreePublicationRecoversAndRetries(_ kind: String, _ point: String) throws {
    let fixture = try CacheFixture(git: kind == "cache-git")
    try interrupt(fixture, kind: kind, point: point)
    if point.hasPrefix("stage.") {
      #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
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
    "stage.0.written", "stage.0.verified", "replace.0.renamed", "journal.committed.renamed",
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

  @Test(arguments: ["prepare.0.directory", "prepare.0.ready"])
  func interruptedExtractionCleansJournalOwnedScratch(_ point: String) throws {
    let fixture = try CacheFixture(git: true)
    try interrupt(fixture, kind: "cache-git", point: point)
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
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
    let cache = SourceCache(store: fixture.store) { step in
      if step == "stage.0.copy.entry" {
        let parent = fixture.destination.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path)
        where name.hasSuffix(".new") {
          try Data("tampered".utf8).write(to: parent.appendingPathComponent(name + "/injected"))
        }
      }
    }
    #expect(throws: CoreError.self) {
      try fixture.store.withLock {
        try cache.materializeArtifact(
          fixture.root.appendingPathComponent("new"), digest: fixture.digest,
          hash: "sha256:" + fixture.hash)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.destination.deletingLastPathComponent().path
      ).isEmpty)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == fixture.lockBytes)
  }

  @Test func verifiesPrivateBytesBeforePublication() throws {
    let fixture = try CacheFixture()
    let cache = SourceCache(store: fixture.store) { step in
      if step == "stage.0.written" {
        let parent = fixture.store.cacheDirectory.appendingPathComponent("artifacts")
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path)
        where name.hasSuffix(".new") {
          try Data("tampered".utf8).write(to: parent.appendingPathComponent(name))
        }
      }
    }
    #expect(throws: CoreError.self) {
      try fixture.store.withLock {
        try cache.storeArtifact(
          Data(contentsOf: fixture.root.appendingPathComponent("payload")), digest: fixture.digest)
      }
    }
    let final = try cache.artifactURL(digest: fixture.digest)
    #expect(!FileManager.default.fileExists(atPath: final.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        .isEmpty)
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
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
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
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
  deinit { try? FileManager.default.removeItem(at: root) }

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
