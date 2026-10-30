import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Declaration state")
struct DeclarationStateTests {
  @Test(arguments: ["lock", "watch"])
  func stateWithoutADeclarationStopsEveryAccessWithoutWriting(_ kind: String) throws {
    let fixture = try ScopeFixture()
    let store = fixture.store
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    if kind == "lock" {
      try StateStore.encodeState(ResolvedState()).write(to: store.resolvedURL)
    } else {
      try StateStore.encode(WatchState()).write(to: store.watchURL)
    }
    let missing = CoreError.missingDeclaration(store.declarationURL.path)
    let before = try FileHash.folderHash(fixture.root)
    #expect(throws: missing) { try store.loadDeclaration() }
    #expect(throws: missing) { try store.loadManifest() }
    #expect(throws: missing) { try store.loadResolved() }
    #expect(throws: missing) { try store.loadWatch() }
    #expect(throws: missing) { try store.readDeclaration() }
    #expect(throws: missing) { try store.withLock {} }
    #expect(throws: missing) {
      try store.save(declaration: Declaration(agents: [.codex]), resolved: ResolvedState())
    }
    #expect(try FileHash.folderHash(fixture.root) == before)

    // A writer that already owns the scope lock recovers first, then reaches the same rule.
    FileManager.default.createFile(atPath: fixture.scopeLock.path, contents: nil)
    let locked = try FileHash.folderHash(fixture.root)
    #expect(throws: missing) { try store.withLock { _ = try store.readDeclaration() } }
    #expect(throws: missing) {
      try store.save(declaration: Declaration(agents: [.codex]), resolved: ResolvedState())
    }
    #expect(try FileHash.folderHash(fixture.root) == locked)
  }

  @Test func scopeWithoutStateIsEmptyAndADeclarationAloneIsComplete() throws {
    let fixture = try ScopeFixture()
    let store = fixture.store
    let before = try FileHash.folderHash(fixture.root)
    #expect(try store.loadDeclaration() == Declaration())
    #expect(try store.loadManifest() == nil)
    #expect(try store.loadResolved() == ResolvedState())
    #expect(try store.loadWatch() == WatchState())
    #expect(try FileHash.folderHash(fixture.root) == before)

    let bytes = manifestText("defaultAgents: [.cursor]")
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try bytes.write(to: store.declarationURL)
    let declared = try FileHash.folderHash(fixture.root)
    #expect(try store.loadDeclaration() == Declaration(agents: [.cursor]))
    #expect(try store.loadManifest()?.bytes == Array(bytes))
    #expect(try store.loadResolved() == ResolvedState())
    #expect(try FileHash.folderHash(fixture.root) == declared)
    #expect(try store.withLock { try store.readDeclaration() } == Declaration(agents: [.cursor]))
  }

  /// A writer interrupted after moving the declaration aside leaves lock state without a
  /// declaration. Readers report the pending recovery without touching any file, and the next
  /// writer recovers before the missing-declaration rule applies.
  @Test func pendingRecoveryPrecedesTheMissingDeclarationRule() throws {
    let fixture = try ScopeFixture()
    let store = fixture.store
    try store.save(declaration: Declaration(agents: [.cursor]), resolved: ResolvedState())
    struct Interrupted: Error {}
    try FileLock.withLock(at: fixture.scopeLock) {
      let transaction = FileTransaction(store: store) { point in
        if point == TransactionCheckpoint.progress(0, .applied).name || point.hasPrefix("recovery.")
        {
          throw Interrupted()
        }
      }
      try transaction.delete(store.declarationURL)
      #expect(throws: Interrupted.self) { try transaction.commit() }
    }
    try FileManager.default.removeItem(at: fixture.scopeLock)
    let journal = store.directory.appendingPathComponent(TransactionJournal.fileName)
    let recorded = try #require(try FileSnapshot.read(at: journal))
    #expect(!FileManager.default.fileExists(atPath: store.declarationURL.path))
    #expect(FileManager.default.fileExists(atPath: store.resolvedURL.path))
    let before = try FileHash.folderHash(fixture.root)

    #expect(throws: pendingRecovery) { try store.loadDeclaration() }
    #expect(throws: pendingRecovery) { try store.loadManifest() }
    #expect(throws: pendingRecovery) { try store.loadResolved() }
    #expect(throws: pendingRecovery) { try store.loadWatch() }
    #expect(try FileSnapshot.read(at: journal) == recorded)
    #expect(try FileHash.folderHash(fixture.root) == before)

    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    #expect(try store.loadDeclaration() == Declaration(agents: [.cursor]))
    #expect(!FileManager.default.fileExists(atPath: journal.path))
  }

  /// Planning from a declaration that the prepared document no longer projects to is a stale
  /// preparation, and nothing is planned over the other writer's intent.
  @Test func planningFromAnotherGenerationIsAStalePreparation() throws {
    let fixture = try ScopeFixture()
    let store = fixture.store
    try store.save(declaration: Declaration(agents: [.cursor]), resolved: ResolvedState())
    let baseline = try StatePrecondition(store: store)
    #expect(
      throws: CoreError.invalidState(
        "declaration changed during preparation: \(store.declarationURL.path)")
    ) {
      try store.planDeclaration(
        Declaration(agents: [.codex]), replacing: Declaration(), prepared: baseline)
    }
    #expect(
      try store.planDeclaration(
        Declaration(agents: [.cursor]), replacing: Declaration(agents: [.cursor]),
        prepared: baseline) == nil)
  }

  /// A first add killed after publishing the lock but before its commit is recovered by the
  /// next writer; neither readers nor writers report a missing declaration.
  @Test func interruptedFirstCreationIsPendingRecoveryNotAMissingDeclaration() throws {
    let fixture = try StateOperationFixture(.freshSkillAdd)
    let store = fixture.store
    terminateProcess(
      try fixture.pause("skill-add", at: TransactionCheckpoint.publication(2, .created).name))
    #expect(FileManager.default.fileExists(atPath: store.resolvedURL.path))
    #expect(throws: pendingRecovery) { try store.loadDeclaration() }
    #expect(throws: pendingRecovery) { try store.loadResolved() }
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    try fixture.check(committed: false)
  }

  /// Ref reconciliation reads watch state and the lock only, so an unreadable declaration
  /// cannot hold it back.
  @Test func watchReferenceRecoveryDoesNotReadTheDeclaration() throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    let stale = try fixture.head()
    try fixture.rewrite("second")
    try fixture.watch.seen("source", environment: fixture.environment)
    let current = try fixture.head()
    try fixture.mirrorGit(["update-ref", "refs/agents-watch/" + stale, stale])
    let marker = fixture.store.directory.appendingPathComponent("watch-refs.pending")
    try Data().write(to: marker)
    let unreadable = Data("let agents = \n".utf8)
    try unreadable.write(to: fixture.store.declarationURL)

    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.withLock {}
    }
    #expect(try fixture.watchRefs() == [current])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: fixture.store.declarationURL) == unreadable)
    #expect(throws: ManifestFailure.self) { try fixture.store.loadDeclaration() }
  }

  @Test func stateTransactionsAcceptOnlyTheCurrentStateFiles() throws {
    let fixture = try ScopeFixture()
    let paths = TransactionPaths(store: fixture.store)
    #expect(try paths.path(for: fixture.store.declarationURL) == "state/Agents.swift")
    for name in ["Agents.swift", "agents.resolved", "agents.watch"] {
      #expect(try paths.components("state/" + name).descendants == [name])
    }
    for name in ["other.json", "agents.swift", "Agents.swift.new"] {
      #expect(throws: CoreError.unsafePath("unmanaged state transaction path")) {
        try paths.components("state/" + name)
      }
    }
  }
}

private final class ScopeFixture {
  let root: URL
  let store: StateStore
  var scopeLock: URL { store.directory.appendingPathComponent(".agents.lock") }

  init() throws {
    root = try temporaryDirectory()
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
        environment: [:]))
  }

  deinit { removeTemporaryDirectory(root) }
}
