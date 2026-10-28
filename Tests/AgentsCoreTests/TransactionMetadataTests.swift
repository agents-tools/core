import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Transaction metadata")
struct TransactionMetadataTests {
  @Test(arguments: ["complete", "journal.applying", "replace.1", "journal.committed"])
  func dataReplacementPreservesPermissionsACLsAndExtendedAttributes(_ point: String) throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent("AGENTS.md")
    let created = fixture.root.appendingPathComponent("GEMINI.md")
    try Data("owner content".utf8).write(to: target)
    let files = [target, fixture.store.declarationURL, fixture.store.resolvedURL]
    for (file, mode) in zip(files, [0o644, 0o440, 0o600]) {
      try setFixtureMetadata(file, mode: mode_t(mode), value: Data("owner metadata".utf8))
    }
    let before = try files.map(metadata)
    let original = try files.map { try Data(contentsOf: $0) }
    let replacement = Data("replacement bytes".utf8)
    try fixture.store.withLock {
      let transaction = FileTransaction(store: fixture.store) { step in
        if step == point { throw CoreError.invalidState("injected failure") }
      }
      for file in files + [created] {
        try transaction.replace(file, content: nil, data: replacement)
      }
      if point == "complete" {
        try transaction.commit()
      } else {
        #expect(throws: CoreError.self) { try transaction.commit() }
      }
    }
    let committed = point == "complete" || point == "journal.committed"
    #expect(try files.map(metadata) == before)
    #expect(
      try files.map { try Data(contentsOf: $0) }
        == (committed ? Array(repeating: replacement, count: files.count) : original))
    if committed {
      var info = stat()
      try #require(lstat(created.path, &info) == 0)
      #expect(info.st_mode & 0o7777 == 0o600)
    } else {
      #expect(!FileManager.default.fileExists(atPath: created.path))
    }
    try expectRecoveryMaterialRemoved(fixture)
  }

  @Test(arguments: ["complete", "journal.committed", "cleanup.0"])
  func committedCleanupDiscardsReadOnlyDirectories(_ point: String) throws {
    let fixture = try TransactionFixture()
    defer { makeWritableForTeardown(fixture.root) }
    let target = fixture.root.appendingPathComponent(".agents/skills/target")
    let source = fixture.root.appendingPathComponent("new")
    let targets = try makeReadOnlyTree(target)
    let sources = try makeReadOnlyTree(source)
    _ = try makeReadOnlyTree(
      fixture.store.cacheDirectory.appendingPathComponent("artifact-content/pruned"))
    let expectedMetadata = try sources.map(metadata)
    let expectedContent = try FileHash.folderHash(source)

    if point == "complete" {
      try fixture.commit { _ in }
    } else {
      try interrupt(fixture, command: "crash", at: point)
      #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
        try fixture.store.loadResolved()
      }
    }

    try fixture.check(committed: true)
    #expect(try targets.map(metadata) == expectedMetadata)
    #expect(try sources.map(metadata) == expectedMetadata)
    #expect(try FileHash.folderHash(target) == expectedContent)
    try expectRecoveryMaterialRemoved(fixture)
  }

  @Test(arguments: ["restore.3.renamed", "restore.0.renamed", "journal.rolledBack.renamed"])
  func interruptedRollbackPreservesReadOnlyMetadata(_ point: String) throws {
    let fixture = try TransactionFixture()
    defer { makeWritableForTeardown(fixture.root) }
    let target = fixture.root.appendingPathComponent(".agents/skills/target")
    let pruned = fixture.store.cacheDirectory.appendingPathComponent("artifact-content/pruned")
    let originals = try makeReadOnlyTree(target) + makeReadOnlyTree(pruned)
    _ = try makeReadOnlyTree(fixture.root.appendingPathComponent("new"))
    let originalMetadata = try originals.map(metadata)
    let originalContent = try [target, pruned].map(FileHash.folderHash)
    let declaration = try Data(contentsOf: fixture.store.declarationURL)
    let resolved = try Data(contentsOf: fixture.store.resolvedURL)

    try interrupt(fixture, command: "crash", at: "replace.4")
    try interrupt(fixture, command: "recover", at: point)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }

    try fixture.check(committed: false)
    #expect(try originals.map(metadata) == originalMetadata)
    #expect(try [target, pruned].map(FileHash.folderHash) == originalContent)
    #expect(try Data(contentsOf: fixture.store.declarationURL) == declaration)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == resolved)
    try expectRecoveryMaterialRemoved(fixture)
  }

  @Test(arguments: ["journal.applying", "replace.0", "replace.2"])
  func rollbackPreservesPermissionsACLsAndExtendedAttributes(_ point: String) throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent(".agents/skills/target")
    let file = target.appendingPathComponent("SKILL.md")
    let nested = target.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let link = target.appendingPathComponent("ref")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "SKILL.md")
    let urls = [target, file, nested, link]
    for (url, mode) in zip(urls, [0o750, 0o666, 0o775, 0o751]) {
      try setFixtureMetadata(
        url, mode: mode_t(mode), value: Data("metadata:\(url.lastPathComponent)".utf8))
    }
    let before = try urls.map(metadata)
    let bytes = try FileHash.folderHash(target)
    #expect(throws: CoreError.self) {
      try fixture.commit { step in
        if step == point { throw CoreError.invalidState("injected failure") }
      }
    }
    #expect(try urls.map(metadata) == before)
    #expect(try FileHash.folderHash(target) == bytes)
    try fixture.check(committed: false)
  }

  private func makeReadOnlyTree(_ root: URL) throws -> [URL] {
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("content")
    try Data("nested content".utf8).write(to: file)
    let link = root.appendingPathComponent("ref")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "SKILL.md")
    let urls = [root, root.appendingPathComponent("SKILL.md"), nested, file, link]
    for (url, mode) in zip(urls, [0o555, 0o444, 0o555, 0o444, 0o751]) {
      try setFixtureMetadata(url, mode: mode_t(mode), value: Data("preserved metadata".utf8))
    }
    return urls
  }

  private func interrupt(_ fixture: TransactionFixture, command: String, at point: String) throws {
    let child = try stateTestProcess(root: fixture.root, arguments: [command, point])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = fixture.root.appendingPathComponent(
      command == "recover" ? "recovery-ready" : "ready")
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline, child.isRunning {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
  }

  private func expectRecoveryMaterialRemoved(_ fixture: TransactionFixture) throws {
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
    let entries = try #require(FileManager.default.enumerator(atPath: fixture.root.path))
    #expect(
      !entries.contains { entry in
        guard let path = entry as? String else { return false }
        return URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".agents-")
      })
  }

  private func makeWritableForTeardown(_ root: URL) {
    guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      return
    }
    for case let entry as URL in entries {
      var info = stat()
      if lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
        _ = chmod(entry.path, (info.st_mode & 0o7777) | S_IRWXU)
      }
    }
  }

  private func metadata(_ url: URL) throws -> FixtureMetadata {
    try fixtureMetadata(url)
  }
}
