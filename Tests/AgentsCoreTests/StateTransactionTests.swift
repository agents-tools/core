import Darwin
import Foundation
import Testing

@testable import AgentsCore

@Suite("State transactions")
struct StateTransactionTests {
  @Test func failuresAtEveryCheckpointRecoverOneGeneration() throws {
    var checkpoints: [String] = []
    do {
      let fixture = try TransactionFixture()
      try fixture.commit { checkpoints.append($0) }
    }
    #expect(checkpoints.contains("journal.committed"))
    for failure in checkpoints {
      let fixture = try TransactionFixture()
      var committed = false
      #expect(throws: CoreError.self) {
        try fixture.commit { step in
          if step == "journal.committed" { committed = true }
          if step == failure { throw CoreError.invalidState("injected failure") }
        }
      }
      try fixture.check(committed: committed)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
    }
  }

  @Test(arguments: [
    "journal.preparing", "directory.0", "stage.0", "stage.4", "journal.applying", "replace.0",
    "replace.1", "replace.2",
    "replace.3", "replace.4", "journal.committed", "cleanup.0",
  ])
  func killedWriterRecoversOnNextStateRead(_ step: String) throws {
    let fixture = try TransactionFixture()
    let child = try process(root: fixture.root, arguments: ["crash", step])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("ready").path), Date() < deadline, child.isRunning
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(
      FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ready").path))
    // At every interruption point the replaced installation still has a directory entry.
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("target/SKILL.md").path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      _ = try fixture.store.loadResolved()
    }
    try fixture.check(committed: step == "journal.committed" || step == "cleanup.0")
  }

  @Test func serializesSeparateWriterProcesses() throws {
    let fixture = try TransactionFixture()
    let children = try (0..<4).map {
      try process(root: fixture.root, arguments: ["writer", "writer-\($0)"])
    }
    for child in children {
      child.waitUntilExit()
      #expect(child.terminationStatus == 0)
    }
    #expect(try fixture.store.loadDeclaration().sources.count == 20)
  }

  private func process(root: URL, arguments: [String]) throws -> Process {
    var directory = Bundle(for: TransactionTestBundle.self).bundleURL.deletingLastPathComponent()
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let process = Process()
    process.executableURL = directory.appendingPathComponent("StateTestProcess")
    process.arguments = [root.path] + arguments
    try process.run()
    return process
  }
}

private final class TransactionFixture {
  let root: URL
  let store: StateStore
  init() throws {
    root = try temporaryDirectory()
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root,
        homeDirectory: root.appendingPathComponent("home"), environment: [:]))
    do {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
      for name in ["target", "new", "pruned"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
      }
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func commit(checkpoint: @escaping (String) throws -> Void) throws {
    try store.withLock {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(
        root.appendingPathComponent("target"), content: root.appendingPathComponent("new"))
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
      try transaction.replace(
        store.resolvedURL, content: nil,
        data: StateStore.encode(ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
      try transaction.replace(root.appendingPathComponent("pruned"), content: nil)
      try transaction.replace(
        root.appendingPathComponent("created/skill"), content: root.appendingPathComponent("new"),
        link: true)
      try transaction.commit()
    }
  }
  func check(committed: Bool) throws {
    #expect(
      try String(contentsOf: root.appendingPathComponent("target/SKILL.md"), encoding: .utf8)
        == (committed ? "new" : "target"))
    #expect(try store.loadDeclaration().agents == (committed ? [.codex] : nil))
    #expect(try store.loadResolved().sources.isEmpty == !committed)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("created/skill/SKILL.md").path) == committed)
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("pruned").path)
        == !committed)
  }
}

private final class TransactionTestBundle: NSObject {}

extension StateTransactionTests {
  @Test func recoversAnInterruptedInitialJournalWrite() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let before = try Data(contentsOf: store.resolvedURL)
    let staging = store.directory.appendingPathComponent("transaction.new")
    try Data("partial journal".utf8).write(to: staging)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) {
      try store.loadDeclaration()
    }
    #expect(try Data(contentsOf: store.resolvedURL) == before)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
  }

  @Test(arguments: [
    "{broken",
    "{\"id\":\"00000000-0000-0000-0000-000000000000\",\"phase\":\"committed\",\"entries\":[],\"directories\":[],\"discarded\":true}",
  ])
  func corruptJournalDoesNotChangeState(_ json: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let before = try Data(contentsOf: store.resolvedURL)
    let journal = store.directory.appendingPathComponent("transaction.json")
    try Data(json.utf8).write(to: journal)
    #expect(throws: (any Error).self) { try store.loadResolved() }
    #expect(try Data(contentsOf: store.resolvedURL) == before)
    #expect(try Data(contentsOf: journal) == Data(json.utf8))
  }
}
