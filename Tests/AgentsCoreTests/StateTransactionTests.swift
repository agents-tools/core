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
      try fixture.commit {
        if !$0.contains(fixture.root.lastPathComponent) { checkpoints.append($0) }
      }
    }
    #expect(checkpoints.contains("journal.committed"))
    for failure in Set(checkpoints).sorted() {
      let fixture = try TransactionFixture()
      var committed = false
      #expect(throws: CoreError.self) {
        try fixture.commit { step in
          if step == "journal.committed.renamed" { committed = true }
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
    "journal.preparing", "journal.preparing.renamed", "stage.0", "stage.4", "journal.applying",
    "replace.0",
    "replace.1", "replace.2",
    "replace.3", "replace.4", "replace.0.renamed", "journal.applying.renamed",
    "journal.committed.renamed", "journal.committed", "cleanup.0",
  ])
  func killedWriterRecoversOnNextStateRead(_ step: String) throws {
    let fixture = try TransactionFixture()
    let child = try stateTestProcess(root: fixture.root, arguments: ["crash", step])
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
        atPath: fixture.root.appendingPathComponent(".agents/skills/target/SKILL.md").path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      _ = try fixture.store.loadResolved()
    }
    try fixture.check(committed: step.hasPrefix("journal.committed") || step == "cleanup.0")
  }

  @Test func serializesSeparateWriterProcesses() throws {
    let fixture = try TransactionFixture()
    let children = try (0..<4).map {
      try stateTestProcess(root: fixture.root, arguments: ["writer", "writer-\($0)"])
    }
    for child in children {
      child.waitUntilExit()
      #expect(child.terminationStatus == 0)
    }
    #expect(try fixture.store.loadDeclaration().sources.count == 20)
  }

}

final class TransactionFixture {
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
      for name in [".agents/skills/target", "new", ".agent/cache/artifact-content/pruned"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(directory.lastPathComponent.utf8).write(
          to: directory.appendingPathComponent("SKILL.md"))
      }
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }
  deinit { removeTemporaryDirectory(root) }
  func commit(checkpoint: @escaping (String) throws -> Void) throws {
    try store.withLock {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(
        root.appendingPathComponent(".agents/skills/target"),
        content: root.appendingPathComponent("new"))
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
      try transaction.replace(
        store.resolvedURL, content: nil,
        data: StateStore.encode(ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
      try transaction.replace(
        root.appendingPathComponent(".agent/cache/artifact-content/pruned"), content: nil)
      try transaction.replace(
        root.appendingPathComponent(".claude/skills/created"),
        content: root.appendingPathComponent("new"),
        link: true)
      try transaction.commit()
    }
  }
  func check(committed: Bool) throws {
    #expect(
      try String(
        contentsOf: root.appendingPathComponent(".agents/skills/target/SKILL.md"), encoding: .utf8)
        == (committed ? "new" : "target"))
    #expect(try store.loadDeclaration().agents == (committed ? [.codex] : nil))
    #expect(try store.loadResolved().sources.isEmpty == !committed)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".claude/skills/created/SKILL.md").path) == committed)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".agent/cache/artifact-content/pruned").path)
        == !committed)
  }
}

extension StateTransactionTests {
  @Test func recoversAnInterruptedInitialJournalWrite() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
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
    defer { removeTemporaryDirectory(root) }
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

extension StateTransactionTests {
  private func waitFor(_ marker: String, root: URL, child: Process) throws {
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path),
      Date() < deadline, child.isRunning
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path))
  }

  private func abandon(
    _ fixture: TransactionFixture, at step: String = "replace.2", scope: InstallScope = .project
  ) throws {
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["crash", step, scope.rawValue])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    try waitFor("ready", root: fixture.root, child: child)
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
  }

  @Test(arguments: [InstallScope.project, .user])
  func replayedDeletionSyncsParentBeforeTerminalPhase(_ scope: InstallScope) throws {
    let fixture = try TransactionFixture()
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent("configured-claude").path
    let store = StateStore(scope: scope, environment: environment)
    if scope == .user { try store.save(declaration: Declaration(), resolved: ResolvedState()) }
    let declaration = try Data(contentsOf: store.declarationURL)
    let resolved = try Data(contentsOf: store.resolvedURL)
    let projectState = try Data(contentsOf: fixture.store.resolvedURL)
    let target = AgentRegistry.installSkillsDirectory(
      for: .claudeCode, scope: scope, environment: environment
    ).appendingPathComponent("created")
    try abandon(fixture, at: "replace.4", scope: scope)
    try #require(FileManager.default.fileExists(atPath: target.path))

    let recovery = try stateTestProcess(
      root: fixture.root, arguments: ["recover", "restore.4.remove.unlinked", scope.rawValue])
    defer {
      if recovery.isRunning {
        kill(recovery.processIdentifier, SIGKILL)
        recovery.waitUntilExit()
      }
    }
    try waitFor("recovery-ready", root: fixture.root, child: recovery)
    #expect(try DirectoryHandle(at: target.deletingLastPathComponent()).info("created") == nil)
    kill(recovery.processIdentifier, SIGKILL)
    recovery.waitUntilExit()
    #expect(recovery.terminationReason == .uncaughtSignal)

    var steps: [String] = []
    try FileLock.withLock(at: store.directory.appendingPathComponent(".agents.lock")) {
      let recovered = try FileTransaction.recover(store: store) { steps.append($0) }
      #expect(recovered)
    }
    #expect(!steps.contains("restore.4.remove.unlinked"))
    let synced = try #require(steps.firstIndex(of: "restore.4.remove.synced"))
    let terminal = try #require(steps.firstIndex(of: "journal.rolledBack.renamed"))
    let cleanup = try #require(steps.firstIndex(of: "journal.terminalSynced"))
    #expect(synced < terminal && terminal < cleanup)
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
    #expect(try Data(contentsOf: store.resolvedURL) == resolved)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == projectState)
    #expect(try store.loadResolved() == ResolvedState())
    #expect(try DirectoryHandle(at: target.deletingLastPathComponent()).info("created") == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent("transaction.json").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        .isEmpty)
  }

  @Test(arguments: [
    "restore.2.renamed", "restore.0", "journal.rolledBack.renamed", "journal.terminalSynced",
    "cleanup.0",
  ])
  func interruptedRecoverySerializesCompetingReader(_ point: String) throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let recovery = try stateTestProcess(root: fixture.root, arguments: ["recover", point])
    defer {
      if recovery.isRunning {
        kill(recovery.processIdentifier, SIGKILL)
        recovery.waitUntilExit()
      }
    }
    try waitFor("recovery-ready", root: fixture.root, child: recovery)
    let reader = try stateTestProcess(root: fixture.root, arguments: ["read", ""])
    defer {
      if reader.isRunning {
        kill(reader.processIdentifier, SIGKILL)
        reader.waitUntilExit()
      }
    }
    try waitFor("reader-started", root: fixture.root, child: reader)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("reader-finished").path))
    kill(recovery.processIdentifier, SIGKILL)
    recovery.waitUntilExit()
    try waitFor("reader-finished", root: fixture.root, child: reader)
    reader.waitUntilExit()
    #expect(reader.terminationStatus == 0)
    try fixture.check(committed: false)
  }

  @Test(arguments: ["journal.terminalSynced", "cleanup.0"])
  func committedRecoverySyncsObservedMarkerBeforeCleanup(_ point: String) throws {
    let fixture = try TransactionFixture()
    try abandon(fixture, at: "journal.committed.renamed")
    let recovery = try stateTestProcess(root: fixture.root, arguments: ["recover", point])
    defer {
      if recovery.isRunning {
        kill(recovery.processIdentifier, SIGKILL)
        recovery.waitUntilExit()
      }
    }
    try waitFor("recovery-ready", root: fixture.root, child: recovery)
    if point == "journal.terminalSynced" {
      let names = try FileManager.default.contentsOfDirectory(
        atPath: fixture.root.appendingPathComponent(".agents/skills").path)
      #expect(names.contains { $0.hasSuffix(".old") })
    }
    kill(recovery.processIdentifier, SIGKILL)
    recovery.waitUntilExit()
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
    try fixture.check(committed: true)
  }

  @Test func rejectsForgedPathsBeforeAnyRecoveryMutation() throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let journalURL = fixture.store.directory.appendingPathComponent("transaction.json")
    let original = try Data(contentsOf: journalURL)
    let before = try FileHash.folderHash(fixture.root)
    let victim = fixture.root.appendingPathComponent("Documents/victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: victim.appendingPathComponent("sentinel"))
    let maliciousPaths = [
      victim.path, "file://" + victim.path, "state/../../Documents/victim", "state/cache/../victim",
      "state/agents.json/child", "codex/../victim", "codex/other/child", "unknown/victim",
      "state/cache/artifact-content/../../victim",
    ]
    for path in maliciousPaths {
      var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var entries = try #require(json["entries"] as? [[String: Any]])
      entries[entries.count - 1]["path"] = path
      json["entries"] = entries
      let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
      try bytes.write(to: journalURL)
      let snapshot = try FileHash.folderHash(fixture.root)
      #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
      #expect(try FileHash.folderHash(fixture.root) == snapshot)
    }
    var directories = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    directories["directories"] = [victim.absoluteString]
    try JSONSerialization.data(withJSONObject: directories).write(to: journalURL)
    let directorySnapshot = try FileHash.folderHash(fixture.root)
    #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
    #expect(try FileHash.folderHash(fixture.root) == directorySnapshot)
    // The absolute-parent counterexample is rejected as a foreign schema, too.
    let forged =
      #"{"id":"00000000-0000-0000-0000-000000000000","phase":"applying","entries":[{"parent":""#
      + victim.deletingLastPathComponent().absoluteString
      + #"","name":"victim","existed":false,"replacement":false}],"directories":[]}"#
    try Data(forged.utf8).write(to: journalURL)
    #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
    #expect(
      try String(contentsOf: victim.appendingPathComponent("sentinel"), encoding: .utf8) == "keep")
    try FileManager.default.removeItem(at: victim.deletingLastPathComponent())
    try original.write(to: journalURL)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
  }

  @Test func rejectsOverlappingJournalDestinationsBeforeRollback() throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let pin = fixture.store.cacheDirectory.appendingPathComponent("materialized/source/pin")
    try FileManager.default.createDirectory(at: pin, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: pin.appendingPathComponent("sentinel"))
    let url = fixture.store.directory.appendingPathComponent("transaction.json")
    var journal = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var entries = try #require(journal["entries"] as? [[String: Any]])
    for path in ["state/cache/materialized/source", "state/cache/materialized/source/pin"] {
      entries.append(["path": path, "existed": false, "replacement": false])
    }
    journal["entries"] = entries
    try JSONSerialization.data(withJSONObject: journal).write(to: url)
    let before = try FileHash.folderHash(fixture.root)
    #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func rejectsCopiedJournalWithoutTouchingEitherLocation() throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let container = try temporaryDirectory()
    defer { removeTemporaryDirectory(container) }
    let copy = container.appendingPathComponent("copy")
    try FileManager.default.copyItem(at: fixture.root, to: copy)
    let originalHash = try FileHash.folderHash(fixture.root)
    let copyHash = try FileHash.folderHash(copy)
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: copy))
    #expect(throws: (any Error).self) { try store.loadDeclaration() }
    #expect(try FileHash.folderHash(fixture.root) == originalHash)
    #expect(try FileHash.folderHash(copy) == copyHash)
  }

  @Test(arguments: ["journal", "scratch", "cache", "agent"])
  func rejectsSymlinkedRecoveryPaths(_ component: String) throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let original: URL
    switch component {
    case "journal": original = fixture.store.directory.appendingPathComponent("transaction.json")
    case "scratch":
      original = fixture.store.directory.appendingPathComponent("transaction.new")
      try Data("incomplete".utf8).write(to: original)
    case "cache": original = fixture.store.cacheDirectory.appendingPathComponent("artifact-content")
    default: original = fixture.root.appendingPathComponent(".agents/skills")
    }
    let external = fixture.root.appendingPathComponent("external")
    try FileManager.default.moveItem(at: original, to: external)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
    let snapshot = try FileHash.folderHash(fixture.root)
    #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
    #expect(try FileHash.folderHash(fixture.root) == snapshot)
  }

  @Test func journalEncodingAndDuplicateKeysCannotBypassRecoveryValidation() throws {
    let fixture = try TransactionFixture()
    try abandon(fixture)
    let url = fixture.store.directory.appendingPathComponent("transaction.json")
    let original = try Data(contentsOf: url)
    let json = String(decoding: original, as: UTF8.self)
    let duplicate = json.replacingOccurrences(
      of: "\"phase\" : \"applying\"", with: "\"phase\" : \"committed\", \"phase\" : \"applying\"")
    #expect(duplicate != json)
    for text in [json, duplicate] {
      let encodings = [
        Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), text.data(using: .utf16)!,
        text.data(using: .utf16BigEndian)!, text.data(using: .utf32)!,
        Data(text.utf8) + Data(" {}".utf8),
      ]
      for bytes in encodings {
        try bytes.write(to: url)
        let snapshot = try FileHash.folderHash(fixture.root)
        #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
        #expect(try FileHash.folderHash(fixture.root) == snapshot)
      }
    }
    try Data(duplicate.utf8).write(to: url)
    #expect(throws: (any Error).self) { try fixture.store.loadResolved() }
    try original.write(to: url)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.loadResolved()
    }
    try fixture.check(committed: false)
  }

  @Test func scopeCreationSyncsParentBeforeAllowingTargets() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
    let child = try stateTestProcess(
      root: root, arguments: ["create-scope", "directory.created..agent"])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    try waitFor("ready", root: root, child: child)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-acquired").path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    var steps: [String] = []
    try FileLock.withLock(
      at: root.appendingPathComponent(".agent/.agents.lock"), checkpoint: { steps.append($0) },
      {
        #expect(steps.contains("directory.synced..agent"))
      })
    let new = root.appendingPathComponent("new/ancestry/.agents")
    steps = []
    try FileLock.withLock(
      at: new.appendingPathComponent(".agents.lock"), checkpoint: { steps.append($0) },
      {
        for name in ["new", "ancestry", ".agents"] {
          let created = try #require(steps.firstIndex(of: "directory.created.\(name)"))
          let synced = try #require(steps.firstIndex(of: "directory.synced.\(name)"))
          #expect(created < synced)
        }
      })
  }
}

extension StateTransactionTests {
  @Test func userRecoveryBindsConfiguredTargetsAndPreservesProjectState() throws {
    let fixture = try TransactionFixture()
    let projectBefore = try Data(contentsOf: fixture.store.resolvedURL)
    var environment = fixture.store.environment
    let configured = fixture.root.appendingPathComponent("configured-claude")
    environment.environment["CLAUDE_CONFIG_DIR"] = configured.path
    let store = StateStore(scope: .user, environment: environment)
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let targets = [
      environment.homeDirectory.appendingPathComponent(".agents/skills/demo"),
      configured.appendingPathComponent("skills/demo"),
    ]
    for target in targets {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data("original".utf8).write(to: target.appendingPathComponent("SKILL.md"))
    }
    let before = try Data(contentsOf: store.resolvedURL)
    #expect(throws: CoreError.self) {
      try store.withLock {
        let transaction = FileTransaction(store: store) { step in
          if step == "replace.3.renamed" {
            let journal = try String(
              contentsOf: store.directory.appendingPathComponent("transaction.json"),
              encoding: .utf8)
            #expect(!journal.contains(fixture.root.path))
            throw CoreError.invalidState("interrupted user write")
          }
        }
        for target in targets {
          try transaction.replace(target, content: fixture.root.appendingPathComponent("new"))
        }
        try transaction.replace(
          store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex]))
        )
        try transaction.replace(
          store.resolvedURL, content: nil,
          data: StateStore.encode(
            ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
        try transaction.commit()
      }
    }
    for target in targets {
      #expect(
        try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
          == "original")
    }
    #expect(try Data(contentsOf: store.resolvedURL) == before)
    #expect(try Data(contentsOf: fixture.store.resolvedURL) == projectBefore)
    #expect(try store.loadDeclaration().agents == nil)
  }
}
