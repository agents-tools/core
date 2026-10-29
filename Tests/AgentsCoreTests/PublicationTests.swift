import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Journal publication and ownership")
struct PublicationTests {
  @Test(arguments: ["create", "replace", "delete"])
  func killedPublicationAtEachStageRecoversPhysicalGeneration(_ operation: String) throws {
    var points = [
      "journal.preparing", "atomic.0.created.1", "atomic.0.created.2", "atomic.0.exchanged",
      "atomic.0.exclusive", "atomic.0.verified", "stage.1.ready", "journal.applying",
      "stage.1.sealed",
      "journal.applying.renamed", "stage.1.preimage", "stage.1", "publication.preconditions",
      "publish.1.intent",
      "publish.1.validated", "replace.1.renamed", "publish.1.synced", "replace.1",
      "journal.committing", "journal.committed.renamed", "journal.committed",
      "journal.terminalSynced",
      "cleanup.0.intent", "cleanup.1.intent", "cleanup.1",
      "cleanup.0.probe-b.unlinked", "cleanup.0.probe-c.synced",
    ]
    if operation == "replace" { points += ["publish.1.displaced", "publish.1.retained"] }
    if operation != "delete" { points += ["stage.1.written"] }
    if operation != "create" { points += ["cleanup.1.old.unlinked", "cleanup.1.old.synced"] }
    for point in points {
      let fixture = try PublicationFixture(operation: operation)
      let original = try FileSnapshot.read(at: fixture.target)
      let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
      let child = try fixture.pause("publication", at: point)
      terminateProcess(child)
      let journal = try fixture.journal()
      let entries = try #require(journal["entries"] as? [[String: Any]])
      let staged = try entries[1]["staged"].map { try fixture.snapshot($0) }
      let committed =
        point.hasPrefix("journal.committed") || point.hasPrefix("cleanup.")
        || point == "journal.terminalSynced"
      let outcome = try fixture.outcome()
      #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
        try fixture.store.withLock(outcome: outcome, {})
      }
      #expect(
        outcome.disposition == (committed ? .committed : .unchanged), "\(operation): \(point)")
      #expect(try FileSnapshot.read(at: fixture.target) == (committed ? staged : original))
      if committed {
        #expect(try Data(contentsOf: fixture.auxiliary) == Data("auxiliary postimage".utf8))
      } else {
        #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
      }
      try fixture.expectClean()
    }
  }

  @Test(arguments: ["create", "replace", "delete"])
  func recoveryCanBeKilledAtEachStageAndRepeated(_ operation: String) throws {
    var points = [
      "restore.1.intent", "restore.1.validated", "restore.1.synced", "restore.1",
      "restore.0.renamed", "journal.rolledBack.renamed", "journal.terminalSynced",
      "cleanup.0.intent", "cleanup.1.intent", "cleanup.1",
    ]
    if operation == "create" {
      points += [
        "restore.1.remove.unlinked", "restore.1.remove.synced", "cleanup.1.removed.unlinked",
      ]
    } else {
      points += ["restore.1.renamed"]
      if operation == "replace" { points += ["cleanup.1.old.unlinked"] }
    }
    for point in points {
      let fixture = try PublicationFixture(operation: operation)
      let target = try FileSnapshot.read(at: fixture.target)
      let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
      terminateProcess(try fixture.pause("publication", at: "replace.1"))
      let outcome = try fixture.outcome()
      terminateProcess(try fixture.pause("publication-recover", at: point))
      #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
        try fixture.store.withLock(outcome: outcome, {})
      }
      #expect(outcome.disposition == .unchanged)
      #expect(try FileSnapshot.read(at: fixture.target) == target, "\(operation): \(point)")
      #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
      #expect(try !FileTransaction.recover(store: fixture.store))
      try fixture.expectClean()
    }
  }

  @Test(arguments: ["external", "postimage"])
  func concurrentCreatorKeepsItsBytesAndInode(_ bytes: String) throws {
    let fixture = try PublicationFixture(operation: "create")
    let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
    let child = try fixture.pause("publication", at: "publish.1.validated")
    defer { terminateProcess(child) }
    try Data(bytes.utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.resume(child)
    #expect(try fixture.result("publication-result").hasPrefix("unchanged\n"))
    #expect(try FileSnapshot.read(at: fixture.target) == external)
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
    try fixture.expectClean()
  }

  @Test(arguments: [false, true], [false, true])
  func exchangedUnexpectedPreimageIsNeverDiscarded(_ inPlace: Bool, _ killAfterExchange: Bool)
    throws
  {
    let fixture = try PublicationFixture(operation: "replace")
    let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
    let child = try fixture.pause("publication", at: "publish.1.validated")
    defer { terminateProcess(child) }
    let original = try FileSnapshot.read(at: fixture.target)
    if !inPlace {
      try FileManager.default.moveItem(
        at: fixture.target, to: fixture.root.appendingPathComponent("saved-original"))
    }
    try Data("external preimage".utf8).write(to: fixture.target)
    let external = try #require(try FileSnapshot.read(at: fixture.target))
    if killAfterExchange {
      try fixture.restop(child, at: "replace.1.renamed")
      terminateProcess(child)
    } else {
      try fixture.resume(child)
      #expect(try fixture.result("publication-result").hasPrefix("unresolved\n"))
    }
    #expect(try Data(contentsOf: fixture.target) == Data("postimage".utf8))
    #expect(try fixture.scratch("new", index: 1) == external)
    try fixture.expectUnresolved()
    if !inPlace {
      #expect(
        try FileSnapshot.read(at: fixture.root.appendingPathComponent("saved-original")) == original
      )
    }
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
  }

  @Test(arguments: ["postimage", "changed postimage"])
  func externalRecoveryDestinationEvenWithEqualBytesIsPreserved(_ bytes: String) throws {
    let fixture = try PublicationFixture(operation: "replace")
    let preimage = try FileSnapshot.read(at: fixture.target)
    terminateProcess(try fixture.pause("publication", at: "replace.1"))
    let published = try FileSnapshot.read(at: fixture.target)
    try FileManager.default.moveItem(
      at: fixture.target, to: fixture.root.appendingPathComponent("saved-postimage"))
    try Data(bytes.utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    #expect(external?.identity != published?.identity)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == external)
    #expect(try fixture.scratch("old", index: 1) == preimage)
    #expect(
      try FileSnapshot.read(at: fixture.root.appendingPathComponent("saved-postimage")) == published
    )
  }

  @Test(arguments: ["replace", "delete", "create"])
  func externalWriterRacingRestorationRetainsBothVersions(_ operation: String) throws {
    let fixture = try PublicationFixture(operation: operation)
    let preimage = try FileSnapshot.read(at: fixture.target)
    terminateProcess(try fixture.pause("publication", at: "replace.1"))
    let recovery = try fixture.pause("publication-recover", at: "restore.1.validated")
    defer { terminateProcess(recovery) }
    if operation != "delete" {
      try FileManager.default.moveItem(
        at: fixture.target, to: fixture.root.appendingPathComponent("saved-postimage"))
    }
    try Data("postimage".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.resume(recovery)
    #expect(try fixture.result("recovery-result").hasPrefix("unresolved:"))
    if operation == "delete" {
      #expect(try FileSnapshot.read(at: fixture.target) == external)
      #expect(try fixture.scratch("old", index: 1) == preimage)
    } else if operation == "replace" {
      #expect(try FileSnapshot.read(at: fixture.target) == preimage)
      #expect(try fixture.scratch("old", index: 1) == external)
    } else {
      #expect(try FileSnapshot.read(at: fixture.target) == nil)
      #expect(try fixture.scratch("removed", index: 1) == external)
    }
    try fixture.expectUnresolved()
  }

  @Test(arguments: ["replace", "create"])
  func killedRecoveryBeforeVerificationRetainsUnexpectedDisplacedObject(_ operation: String) throws
  {
    let fixture = try PublicationFixture(operation: operation)
    let preimage = try FileSnapshot.read(at: fixture.target)
    terminateProcess(try fixture.pause("publication", at: "replace.1"))
    let recovery = try fixture.pause("publication-recover", at: "restore.1.validated")
    defer { terminateProcess(recovery) }
    try FileManager.default.moveItem(
      at: fixture.target, to: fixture.root.appendingPathComponent("saved-postimage"))
    try Data("postimage".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    let point = operation == "replace" ? "restore.1.renamed" : "restore.1.remove.unlinked"
    try fixture.restop(recovery, at: point, markerName: "recovery-ready")
    terminateProcess(recovery)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == preimage)
    #expect(try fixture.scratch(operation == "replace" ? "old" : "removed", index: 1) == external)
  }

  @Test func interruptedDirectoryCleanupPreservesNewExternalDescendants() throws {
    let fixture = try TransactionFixture()
    let child = try stateTestProcess(root: fixture.root, arguments: ["crash", "cleanup.0.intent"])
    defer { terminateProcess(child) }
    let marker = fixture.root.appendingPathComponent("ready")
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
    terminateProcess(child)
    let json = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.store.directory.appendingPathComponent("transaction.json")))
        as? [String: Any])
    let id = try #require(json["id"] as? String)
    let original = fixture.root.appendingPathComponent(".agents/skills/.agents-\(id)-0.old")
    let childURL = original.appendingPathComponent("external")
    try Data("keep external descendant".utf8).write(to: childURL)
    let before = try FileSnapshot.read(at: original)
    let outcome = TransactionOutcome()
    outcome.journalID = UUID(uuidString: id)
    for _ in 0..<2 {
      #expect(throws: CoreError.self) { try fixture.store.withLock(outcome: outcome, {}) }
      #expect(outcome.disposition == .recoveryRequired)
      #expect(try FileSnapshot.read(at: original) == before)
      #expect(
        try String(contentsOf: original.appendingPathComponent("SKILL.md"), encoding: .utf8)
          == "target")
    }
  }

  @Test(arguments: ["new", "old", "missing"])
  func replacedOrMissingRecoveryEvidenceNeverGrantsOwnership(_ suffix: String) throws {
    let fixture = try PublicationFixture(operation: suffix == "new" ? "create" : "replace")
    let point = suffix == "new" ? "journal.applying" : "replace.1"
    terminateProcess(try fixture.pause("publication", at: point))
    let actualSuffix = suffix == "missing" ? "old" : suffix
    let path = try fixture.scratchURL(actualSuffix, index: 1)
    let saved = fixture.root.appendingPathComponent("saved-evidence")
    let original = try #require(try FileSnapshot.read(at: path))
    try FileManager.default.moveItem(at: path, to: saved)
    var external: FileSnapshot?
    if suffix != "missing" {
      try Data(contentsOf: saved).write(to: path)
      external = try FileSnapshot.read(at: path)
      #expect(external?.identity != original.identity)
    }
    let target = try FileSnapshot.read(at: fixture.target)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: path) == external)
    #expect(try FileSnapshot.read(at: saved) == original)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
  }

  @Test func deletionNeverAdoptsAnUnexpectedStagingObject() throws {
    let fixture = try PublicationFixture(operation: "delete")
    let target = try FileSnapshot.read(at: fixture.target)
    let outcome = TransactionOutcome()
    var external: FileSnapshot?
    #expect(throws: CoreError.self) {
      try fixture.store.withLock(outcome: outcome) {
        let transaction = FileTransaction(store: fixture.store, outcome: outcome) { step in
          if step == "stage.0.preimage" {
            let url = try fixture.scratchURL("new", index: 0)
            try Data("external object".utf8).write(to: url)
            external = try FileSnapshot.read(at: url)
          }
        }
        try transaction.replace(fixture.target, content: nil)
        try transaction.commit()
      }
    }
    #expect(outcome.disposition == .recoveryRequired)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(try fixture.scratch("new", index: 0) == external)
    try fixture.expectUnresolved()
  }

  @Test(arguments: ["preparing", "committed", "rolledBack", "unsealed"])
  func inconsistentJournalStagesPreserveAllEvidence(_ phase: String) throws {
    let fixture = try PublicationFixture(operation: "replace")
    terminateProcess(try fixture.pause("publication", at: "replace.0"))
    let outcome = try fixture.outcome()
    var journal = try fixture.journal()
    if phase == "unsealed" {
      var entries = try #require(journal["entries"] as? [[String: Any]])
      entries[1]["progress"] = "verifying"
      journal["entries"] = entries
    } else {
      journal["phase"] = phase
    }
    try JSONSerialization.data(withJSONObject: journal).write(
      to: fixture.store.directory.appendingPathComponent("transaction.json"))
    let before = try FileHash.folderHash(fixture.root)
    let target = try FileSnapshot.read(at: fixture.target)
    let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
    #expect(throws: CoreError.self) { try fixture.store.withLock(outcome: outcome, {}) }
    #expect(outcome.disposition == .recoveryRequired)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
  }

  @Test(arguments: ["preimage", "staged", "parentIdentity", "probes"])
  func missingJournalEvidenceReportsUnresolvedBeforeReplay(_ field: String) throws {
    let fixture = try PublicationFixture(operation: "replace")
    terminateProcess(try fixture.pause("publication", at: "replace.1"))
    let outcome = try fixture.outcome()
    var journal = try fixture.journal()
    var entries = try #require(journal["entries"] as? [[String: Any]])
    entries[1].removeValue(forKey: field)
    journal["entries"] = entries
    try JSONSerialization.data(withJSONObject: journal).write(
      to: fixture.store.directory.appendingPathComponent("transaction.json"))
    let before = try FileHash.folderHash(fixture.root)
    #expect(throws: CoreError.self) { try fixture.store.withLock(outcome: outcome, {}) }
    #expect(outcome.disposition == .recoveryRequired)
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func cleanupConflictAfterCommitReportsUnresolvedAndKeepsPreimage() throws {
    let fixture = try PublicationFixture(operation: "replace")
    let preimage = try FileSnapshot.read(at: fixture.target)
    let child = try fixture.pause("publication", at: "journal.committed")
    defer { terminateProcess(child) }
    let path = try fixture.scratchURL("old", index: 1)
    let saved = fixture.root.appendingPathComponent("saved-preimage")
    try FileManager.default.moveItem(at: path, to: saved)
    try Data(contentsOf: saved).write(to: path)
    let external = try FileSnapshot.read(at: path)
    try fixture.resume(child)
    #expect(try fixture.result("publication-result").hasPrefix("unresolved\n"))
    #expect(try Data(contentsOf: fixture.target) == Data("postimage".utf8))
    #expect(try FileSnapshot.read(at: saved) == preimage)
    #expect(try FileSnapshot.read(at: path) == external)
    try fixture.expectUnresolved()
  }

  @Test func movedScopeAfterCommitReportsUnresolvedUntilItsIdentityIsRestored() throws {
    let fixture = try PublicationFixture(operation: "replace")
    let moved = fixture.root.appendingPathComponent("moved-state")
    let outcome = TransactionOutcome()
    #expect(throws: CoreError.self) {
      try fixture.store.withLock(outcome: outcome) {
        let transaction = FileTransaction(store: fixture.store, outcome: outcome) { step in
          if step == "journal.committed" {
            try FileManager.default.moveItem(at: fixture.store.directory, to: moved)
            throw CoreError.invalidState("scope moved")
          }
        }
        try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
        try transaction.commit()
      }
    }
    #expect(outcome.disposition == .recoveryRequired)
    #expect(try Data(contentsOf: fixture.target) == Data("postimage".utf8))
    #expect(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("transaction.json").path))
    try FileManager.default.moveItem(at: moved, to: fixture.store.directory)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.withLock(outcome: outcome, {})
    }
    #expect(outcome.disposition == .committed)
    try fixture.expectClean()
  }

  @Test(arguments: ["create", "replace", "delete"])
  func unsupportedAtomicsFailBeforeAnyTransactionMutation(_ operation: String) throws {
    let fixture = try PublicationFixture(operation: operation)
    let before = try FileHash.folderHash(fixture.root)
    let outcome = TransactionOutcome()
    let transaction = FileTransaction(store: fixture.store, outcome: outcome)
    transaction.atomicPreflight = { _ in throw CoreError.unsupported("injected atomic primitive") }
    try transaction.replace(
      fixture.target, content: nil, data: operation == "delete" ? nil : Data("postimage".utf8))
    #expect(throws: CoreError.unsupported("injected atomic primitive")) { try transaction.commit() }
    #expect(outcome.disposition == .unchanged)
    #expect(try FileHash.folderHash(fixture.root) == before)
    try fixture.expectClean()
  }

  @Test(arguments: ["agents.json", "agents.resolved", "agents.watch", "AGENTS.md"])
  func queuedPreconditionsRejectChangedBytesOrEqualByteExternalInodes(_ path: String) throws {
    for equalBytes in [false, true] {
      let fixture = try PublicationFixture(operation: "replace")
      let target =
        path == "AGENTS.md" ? fixture.target : fixture.store.directory.appendingPathComponent(path)
      let transaction = FileTransaction(store: fixture.store)
      try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
      let bytes = try Data(contentsOf: target)
      if equalBytes {
        try FileManager.default.moveItem(
          at: target, to: fixture.root.appendingPathComponent("saved-input"))
      }
      try (equalBytes ? bytes : bytes + Data(" ".utf8)).write(to: target)
      let external = try FileSnapshot.read(at: target)
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(try FileSnapshot.read(at: target) == external)
      try fixture.expectClean()
    }
  }

  @Test(arguments: ["publication.preconditions", "publish.1.validated"], [false, true])
  func unchangedStateInputsAreRecheckedBeforePublicationAndCommit(
    _ point: String, _ equalBytes: Bool
  )
    throws
  {
    let fixture = try PublicationFixture(operation: "replace")
    let target = try FileSnapshot.read(at: fixture.target)
    let auxiliary = try FileSnapshot.read(at: fixture.auxiliary)
    let outcome = TransactionOutcome()
    var external: FileSnapshot?
    try fixture.store.withLock(outcome: outcome) {
      let transaction = FileTransaction(store: fixture.store, outcome: outcome) { step in
        if step == point {
          let bytes = try Data(contentsOf: fixture.store.watchURL)
          if equalBytes {
            try FileManager.default.moveItem(
              at: fixture.store.watchURL, to: fixture.root.appendingPathComponent("saved-watch"))
          }
          try (equalBytes ? bytes : bytes + Data(" ".utf8)).write(to: fixture.store.watchURL)
          external = try FileSnapshot.read(at: fixture.store.watchURL)
        }
      }
      for file in [fixture.auxiliary, fixture.target] {
        try transaction.replace(file, content: nil, data: Data("postimage".utf8))
      }
      #expect(throws: CoreError.self) { try transaction.commit() }
    }
    #expect(outcome.disposition == .unchanged)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == auxiliary)
    #expect(try FileSnapshot.read(at: fixture.store.watchURL) == external)
    try fixture.expectClean()
  }
}

private final class PublicationFixture {
  let root: URL
  let store: StateStore
  let operation: String
  var target: URL { root.appendingPathComponent("AGENTS.md") }
  var auxiliary: URL { root.appendingPathComponent("GEMINI.md") }

  init(operation: String) throws {
    root = try temporaryDirectory()
    self.operation = operation
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    do {
      try store.save(declaration: Declaration(), resolved: ResolvedState(), watch: WatchState())
      if operation != "create" { try Data("preimage".utf8).write(to: target) }
      try Data("auxiliary preimage".utf8).write(to: auxiliary)
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }

  deinit { removeTemporaryDirectory(root) }

  func pause(_ command: String, at step: String) throws -> Process {
    let marker = root.appendingPathComponent(command == "publication" ? "ready" : "recovery-ready")
    try? FileManager.default.removeItem(at: marker)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("stop-at"))
    let child = try stateTestProcess(root: root, arguments: [command, step, operation])
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if !FileManager.default.fileExists(atPath: marker.path) {
      terminateProcess(child)
      throw CoreError.invalidState("publication subprocess did not reach \(step)")
    }
    return child
  }

  func restop(_ child: Process, at step: String, markerName: String = "ready") throws {
    let marker = root.appendingPathComponent(markerName)
    try Data(step.utf8).write(to: root.appendingPathComponent("stop-at"))
    try FileManager.default.removeItem(at: marker)
    kill(child.processIdentifier, SIGCONT)
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
  }

  func resume(_ child: Process) throws {
    kill(child.processIdentifier, SIGCONT)
    try finishProcesses([child])
  }

  func result(_ name: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
  }

  func journal() throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: store.directory.appendingPathComponent("transaction.json")))
        as? [String: Any])
  }

  func outcome() throws -> TransactionOutcome {
    let result = TransactionOutcome()
    result.journalID = try UUID(uuidString: #require(journal()["id"] as? String))
    return result
  }

  func snapshot(_ json: Any) throws -> FileSnapshot {
    try JSONDecoder().decode(FileSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func scratchURL(_ suffix: String, index: Int) throws -> URL {
    let id = try #require(journal()["id"] as? String)
    return root.appendingPathComponent(".agents-\(id)-\(index).\(suffix)")
  }

  func scratch(_ suffix: String, index: Int) throws -> FileSnapshot? {
    try FileSnapshot.read(at: scratchURL(suffix, index: index))
  }

  func expectUnresolved() throws {
    let outcome = try outcome()
    for _ in 0..<2 {
      #expect(throws: CoreError.self) {
        try store.withLock(outcome: outcome, {})
      }
      #expect(outcome.disposition == .recoveryRequired)
      let before = try FileHash.folderHash(root)
      #expect(throws: CoreError.self) {
        try store.withReadLock { Issue.record("must not inspect") }
      }
      #expect(try FileHash.folderHash(root) == before)
    }
  }

  func expectClean() throws {
    #expect(try store.openDirectoryIfPresent()?.info("transaction.json") == nil)
    #expect(try store.openDirectoryIfPresent()?.info("transaction.new") == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!names.contains { $0.hasPrefix(".agents-") })
  }
}
