import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Journal publication and ownership")
struct PublicationTests {
  @Test(arguments: PublicationMatrix.publications)
  func killedPublicationAtEachStageRecoversPhysicalGeneration(_ fault: PublicationFault) throws {
    try fault.checkSetup()
    let fixture = try PublicationFixture(fault.operation)
    let child = try fixture.pause("publication", at: fault.point)
    defer { terminateProcess(child) }
    terminateProcess(child)
    let journal = try fixture.lastJournal()
    try fixture.recover(expected: fault.committed ? .committed : .unchanged)
    try fixture.check(committed: fault.committed, journal: journal)
    try fixture.expectClean()
  }

  @Test(arguments: PublicationMatrix.recoveries)
  func recoveryCanBeKilledAtEachStageAndRepeated(_ fault: PublicationFault) throws {
    try fault.checkSetup()
    let fixture = try PublicationFixture(fault.operation)
    terminateProcess(try fixture.pause("publication", at: fault.seed!))
    terminateProcess(try fixture.pause("publication-recover", at: fault.point))
    try fixture.recover(expected: .unchanged)
    try fixture.check(committed: false, journal: nil)
    #expect(try !FileTransaction.recover(store: fixture.store))
    try fixture.expectClean()
  }

  @Test(arguments: ["external", "postimage"])
  func concurrentCreatorKeepsItsBytesAndInode(_ bytes: String) throws {
    let fixture = try PublicationFixture(.fileCreate)
    let child = try fixture.pause("publication", at: "publish.1.validated")
    defer { terminateProcess(child) }
    try Data(bytes.utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.resume(child)
    #expect(try fixture.result("publication-result").hasPrefix("unchanged\n"))
    #expect(try FileSnapshot.read(at: fixture.target) == external)
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == fixture.beforeAuxiliary)
    try fixture.expectClean()
  }

  @Test(arguments: [false, true])
  func exchangedUnexpectedPreimageIsNeverDiscarded(_ inPlace: Bool) throws {
    let fixture = try PublicationFixture(.fileReplace)
    let child = try fixture.pause("publication", at: "publish.1.validated")
    defer { terminateProcess(child) }
    if !inPlace {
      try FileManager.default.moveItem(
        at: fixture.target, to: fixture.root.appendingPathComponent("original"))
    }
    try Data("external preimage".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.restop(child, at: "publish.1.exchanged")
    terminateProcess(child)
    let journal = try #require(try fixture.lastJournal())
    let postimage = try #require(journal.entries[1].staged)
    #expect(try FileSnapshot.read(at: fixture.target) == postimage)
    #expect(
      try FileSnapshot.read(at: fixture.scratch(.staged, entry: 1, journal: journal)) == external)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == postimage)
    #expect(
      try FileSnapshot.read(at: fixture.scratch(.staged, entry: 1, journal: journal)) == external)
    if !inPlace {
      #expect(
        try FileSnapshot.read(at: fixture.root.appendingPathComponent("original"))
          == fixture.beforeTarget)
    }
  }

  @Test(arguments: [PublicationOperation.fileReplace, .directoryDelete])
  func missingAppliedPreimageIsUnresolvedBeforeTerminalIntent(_ operation: PublicationOperation)
    throws
  {
    let fixture = try PublicationFixture(operation)
    let child = try fixture.pause("publication", at: "entry.1.applied")
    defer { terminateProcess(child) }
    let journal = try #require(try fixture.lastJournal())
    let slot: TransactionScratch = operation == .directoryDelete ? .preimage : .staged
    let original = fixture.scratch(slot, entry: 1, journal: journal)
    let saved = fixture.root.appendingPathComponent("saved-preimage")
    let before = try #require(fixture.beforeTarget)
    if before.needsDirectoryWriteLease {
      try FileManager.default.setAttributes(
        [.posixPermissions: before.mode | 0o200], ofItemAtPath: original.path)
    }
    try FileManager.default.moveItem(at: original, to: saved)
    if before.needsDirectoryWriteLease {
      try FileManager.default.setAttributes(
        [.posixPermissions: before.mode], ofItemAtPath: saved.path)
    }
    let published = try FileSnapshot.read(at: fixture.target)
    terminateProcess(child)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == published)
    #expect(try FileSnapshot.read(at: saved) == fixture.beforeTarget)
    #expect(try fixture.lastJournal()?.phase == .applying)
  }

  @Test func missingRollbackQuarantineIsUnresolvedBeforeTerminalIntent() throws {
    let fixture = try PublicationFixture(.fileCreate)
    terminateProcess(try fixture.pause("publication", at: "publish.1.created"))
    let recovery = try fixture.pause("publication-recover", at: "entry.1.restored")
    defer { terminateProcess(recovery) }
    let journal = try #require(try fixture.lastJournal())
    let quarantined = fixture.scratch(.removed, entry: 1, journal: journal)
    let saved = fixture.root.appendingPathComponent("saved-postimage")
    try FileManager.default.moveItem(at: quarantined, to: saved)
    terminateProcess(recovery)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == nil)
    #expect(try FileSnapshot.read(at: saved) == journal.entries[1].staged)
  }

  @Test(arguments: [PublicationOperation.fileCreate, .fileReplace, .directoryDelete])
  func externalRecoveryDestinationPreservesBothVersions(_ operation: PublicationOperation) throws {
    let fixture = try PublicationFixture(operation)
    terminateProcess(try fixture.pause("publication", at: "entry.1.applied"))
    let recovery = try fixture.pause("publication-recover", at: "restore.1.validated")
    defer { terminateProcess(recovery) }
    let journal = try #require(try fixture.lastJournal())
    if try FileSnapshot.read(at: fixture.target) != nil {
      try FileManager.default.moveItem(
        at: fixture.target, to: fixture.root.appendingPathComponent("saved-postimage"))
    }
    try Data("external recovery writer".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.resume(recovery, marker: "recovery-ready")
    #expect(try fixture.result("recovery-result").hasPrefix("unresolved:"))
    let location: URL
    switch operation {
    case .fileCreate: location = fixture.scratch(.removed, entry: 1, journal: journal)
    case .fileReplace: location = fixture.scratch(.staged, entry: 1, journal: journal)
    default: location = fixture.target
    }
    #expect(try FileSnapshot.read(at: location) == external)
    if operation == .fileReplace {
      #expect(try FileSnapshot.read(at: fixture.target) == fixture.beforeTarget)
    }
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: location) == external)
    if operation == .directoryDelete {
      #expect(
        try FileSnapshot.read(at: fixture.scratch(.preimage, entry: 1, journal: journal))
          == fixture.beforeTarget)
    } else {
      #expect(
        try FileSnapshot.read(at: fixture.root.appendingPathComponent("saved-postimage"))
          == journal.entries[1].staged)
    }
  }

  @Test func committedFailureRetainsUserDataAndRecordsConflict() throws {
    let fixture = try PublicationFixture(.fileReplace)
    let child = try fixture.pause("publication", at: "journal.committed")
    defer { terminateProcess(child) }
    let journal = try #require(try fixture.lastJournal())
    let saved = fixture.root.appendingPathComponent("saved-published")
    try FileManager.default.moveItem(at: fixture.target, to: saved)
    try Data("external committed target".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    terminateProcess(child)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == external)
    #expect(try FileSnapshot.read(at: saved) == journal.entries[1].staged)
    #expect(
      try FileSnapshot.read(at: fixture.scratch(.staged, entry: 1, journal: journal))
        == fixture.beforeTarget)
  }

  @Test(arguments: [false, true])
  func plannedUnidentifiedContainerOnlyAdmitsEmptyRmdir(_ populate: Bool) throws {
    let fixture = try PublicationFixture(.fileCreate)
    terminateProcess(try fixture.pause("publication", at: "container.0.created"))
    let journal = try #require(try fixture.lastJournal())
    #expect(journal.containers[0].identity == nil)
    let container = fixture.root.appendingPathComponent(journal.containerName(0))
    if populate {
      let file = container.appendingPathComponent("keep")
      try Data("unidentified bytes".utf8).write(to: file)
      let before = try FileSnapshot.read(at: file)
      try fixture.expectUnresolved(containing: "unidentified private container is not empty")
      #expect(try FileSnapshot.read(at: file) == before)
    } else {
      try fixture.recover(expected: .unchanged)
      try fixture.expectClean()
    }
    #expect(try FileSnapshot.read(at: fixture.target) == fixture.beforeTarget)
  }

  @Test func sealedPrivateObjectChangesAreUnresolved() throws {
    let fixture = try PublicationFixture(.fileReplace)
    terminateProcess(try fixture.pause("publication", at: "entry.1.ready"))
    let journal = try #require(try fixture.lastJournal())
    let file = fixture.scratch(.staged, entry: 1, journal: journal)
    try Data("changed after sealing".utf8).write(to: file)
    let changed = try FileSnapshot.read(at: file)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: file) == changed)
    #expect(try FileSnapshot.read(at: fixture.target) == fixture.beforeTarget)
  }

  @Test func directoryPermissionChangesOutsideIntentRemainExternal() throws {
    let fixture = try PublicationFixture(.directoryReplace)
    let child = try fixture.pause("publication", at: "permissions.1.publish.grant.target.synced")
    defer { terminateProcess(child) }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o770], ofItemAtPath: fixture.target.path)
    let external = try FileSnapshot.read(at: fixture.target)
    terminateProcess(child)
    let beforeDiagnosis = try FileSnapshot.read(at: fixture.root)
    let diagnosis = FileTransaction.recoveryDiagnostic(store: fixture.store)
    #expect(diagnosis.requiresOwner)
    #expect(diagnosis.message.contains("directory permissions changed beyond transaction intent"))
    #expect(try FileSnapshot.read(at: fixture.root) == beforeDiagnosis)
    try fixture.expectUnresolved(
      containing: "directory permissions changed beyond transaction intent")
    #expect(try FileSnapshot.read(at: fixture.target) == external)
  }

  @Test(
    arguments: [EINVAL, ENOSYS, ENOTSUP, EOPNOTSUPP, EIO],
    [DirectoryHandle.RenameMode.exchange, .exclusive])
  func primitiveFailuresCleanPrivateResourcesBeforeChangingUserData(
    _ code: Int32, _ mode: DirectoryHandle.RenameMode
  ) throws {
    let fixture = try PublicationFixture(.fileReplace)
    let outcome = TransactionOutcome()
    let transaction = FileTransaction(store: fixture.store, outcome: outcome)
    try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
    let operation =
      mode == .exchange ? "exchange atomic probe" : "check exclusive atomic probe collision"
    let expected: CoreError =
      code == EIO
      ? .invalidState("cannot \(operation): \(code) (\(String(cString: strerror(code))))")
      : .unsupported(
        "atomic rename is required: \(operation): \(code) (\(String(cString: strerror(code))))")
    DirectoryHandle.$atomicRenameFailure.withValue(
      { $0 == mode ? code : nil },
      operation: { #expect(throws: expected) { try transaction.commit() } })
    #expect(outcome.disposition == .unchanged)
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  @Test(arguments: ["staged", "parent", "container"])
  func missingJournalEvidenceReachesSemanticValidation(_ field: String) throws {
    let fixture = try PublicationFixture(.fileReplace)
    terminateProcess(try fixture.pause("publication", at: "entry.1.ready"))
    var journal = try #require(try fixture.lastJournal())
    switch field {
    case "staged": journal.entries[1].staged = nil
    case "parent": journal.entries[1].parentIdentity = ""
    default: journal.entries[1].container = journal.containers.count
    }
    // Encode a valid current-format value; failure cannot be a missing Decodable key.
    try StateStore.encode(journal).write(
      to: fixture.store.directory.appendingPathComponent("transaction.json"))
    let before = try FileSnapshot.read(at: fixture.root)
    let reason: String
    switch field {
    case "staged": reason = "operation progress contradicts its evidence or journal phase"
    case "parent": reason = "destination parent changed"
    default: reason = "overlapping destinations or invalid container"
    }
    let location =
      field == "container"
      ? "<invalid container reference \(journal.entries[1].container)>"
      : "instructions-project/" + journal.containerName(0)
    #expect(
      throws: CoreError.invalidState(
        "transaction conflict at instructions-project/AGENTS.md: \(reason); retained container: \(location)"
      )
    ) {
      try fixture.store.loadResolved()
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test(arguments: [Optional<Int>.none, .some(999)])
  func oldJournalVersionRequiresItsWritingVersionWithoutMutation(_ version: Int?) throws {
    let fixture = try PublicationFixture(.fileReplace)
    // This is the unversioned Journal/Entry schema and scratch naming written by ed859e6.
    let id = UUID()
    let directory = try #require(try fixture.store.openDirectoryIfPresent())
    let backup = directory.url.appendingPathComponent(".agents-\(id.uuidString)-0.old")
    try FileManager.default.moveItem(at: fixture.store.declarationURL, to: backup)
    try Data("{\"agents\":[\"codex\"]}".utf8).write(to: fixture.store.declarationURL)
    var old = try StateStore.encode(
      LegacyJournal(
        id: id, scope: directory.identity,
        roots: ["state": directory.identity], phase: "applying",
        entries: [.init(path: "state/agents.json", existed: true, replacement: true)]))
    if let version {
      var encoded = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
      encoded["version"] = version
      old = try JSONSerialization.data(withJSONObject: encoded)
    }
    try old.write(to: directory.url.appendingPathComponent("transaction.json"))
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(
      throws: CoreError.invalidState(
        "transaction journal was written by another version; recover it with the version that wrote it (journal version: \(version.map(String.init) ?? "missing"))"
      )
    ) {
      try fixture.store.loadResolved()
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    let diagnostic = FileTransaction.recoveryDiagnostic(store: fixture.store)
    #expect(diagnostic.requiresOwner)
    #expect(diagnostic.message.contains("version that wrote it"))
  }

  @Test(arguments: ["identity", "disposal"])
  func missingContainerEvidenceCannotAuthorizeTerminalDeletion(_ field: String) throws {
    let fixture = try PublicationFixture(.fileReplace)
    terminateProcess(try fixture.pause("publication", at: "journal.committed"))
    var journal = try #require(try fixture.lastJournal())
    if field == "identity" {
      journal.containers[0].identity = nil
    } else {
      journal.containers[0].cleanup = nil
    }
    try StateStore.encode(journal).write(
      to: fixture.store.directory.appendingPathComponent("transaction.json"))
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(
      throws: CoreError.invalidState(
        field == "identity"
          ? "sealed operation is missing private container identity"
          : "terminal container is missing user-object disposal evidence")
    ) { try fixture.store.loadResolved() }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test func unchangedStateIsNotAnImplicitCachePrecondition() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let cache = SourceCache(store: fixture.store)
    let bytes = Data("artifact".utf8)
    let digest = "sha256:" + FileHash.sha256Hex(data: Data("artifact".utf8))
    let transaction = FileTransaction(store: fixture.store)
    let target = try cache.artifactURL(digest: digest)
    try transaction.replace(target, content: nil, data: bytes, expectedHash: digest)
    try Data("{\"agents\":[]}".utf8).write(to: fixture.store.declarationURL)
    let state = try FileSnapshot.read(at: fixture.store.declarationURL)
    try transaction.commit()
    #expect(try Data(contentsOf: target) == bytes)
    #expect(try FileSnapshot.read(at: fixture.store.declarationURL) == state)
  }
}

enum PublicationOperation: String, CaseIterable, Sendable {
  case fileReplace, directoryReplace, directoryDelete, symlinkCreate, fileCreate
  var renamePoint: String {
    switch self {
    case .directoryDelete: "publish.1.quarantined"
    case .fileReplace, .directoryReplace: "publish.1.exchanged"
    default: "publish.1.created"
    }
  }
}

struct PublicationFault: Sendable, CustomTestStringConvertible {
  let operation: PublicationOperation
  let point: String
  var committed = false
  var seed: String?
  var setupFailure: String?
  var testDescription: String {
    "\(operation.rawValue), \(seed.map { "from \($0), " } ?? "")\(point)"
  }
  func checkSetup() throws {
    if let setupFailure {
      throw CoreError.invalidState("checkpoint recording failed: " + setupFailure)
    }
  }
}

private enum PublicationMatrix {
  static let publications = record(recovery: false)
  static let recoveries = record(recovery: true)

  private static func record(recovery: Bool) -> [PublicationFault] {
    var cases: [PublicationFault] = []
    for operation in PublicationOperation.allCases {
      var seeds: [String?] = recovery ? [operation.renamePoint, "entry.1.applied"] : [nil]
      if recovery, operation == .directoryReplace || operation == .directoryDelete {
        seeds.append("permissions.1.publish.grant.target.changed")
      }
      for seed in seeds {
        do {
          let fixture = try PublicationFixture(operation)
          if let seed { terminateProcess(try fixture.pause("publication", at: seed)) }
          let command = recovery ? "publication-recover" : "publication"
          let child = try fixture.launch(command, at: "never")
          defer { terminateProcess(child) }
          try ProcessWait.exit(child, root: fixture.root)
          guard child.terminationStatus == 0 else {
            throw CoreError.invalidState("checkpoint recorder exited \(child.terminationStatus)")
          }
          let trace = try String(
            contentsOf: fixture.root.appendingPathComponent(
              "checkpoint-\(child.processIdentifier).log"), encoding: .utf8
          )
          .split(separator: "\n").map(String.init)
          guard !trace.isEmpty, Set(trace).count == trace.count else {
            throw CoreError.invalidState("checkpoint names are empty or repeated")
          }
          var committed = false
          for point in trace {
            if point == "journal.committed.terminal.renamed" { committed = true }
            cases.append(
              PublicationFault(operation: operation, point: point, committed: committed, seed: seed)
            )
          }
        } catch {
          cases.append(
            PublicationFault(
              operation: operation, point: "recording", seed: seed,
              setupFailure: String(describing: error)))
        }
      }
    }
    return cases
  }
}

final class PublicationFixture {
  let operation: PublicationOperation
  let root: URL
  let store: StateStore
  let target: URL
  let auxiliary: URL
  let beforeTarget: FileSnapshot?
  let beforeAuxiliary: FileSnapshot?
  let state: [(URL, FileSnapshot?)]

  init(_ operation: PublicationOperation) throws {
    self.operation = operation
    root = try temporaryDirectory()
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    target = root.appendingPathComponent("AGENTS.md")
    auxiliary = root.appendingPathComponent("GEMINI.md")
    do {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
      try Data("auxiliary preimage".utf8).write(to: auxiliary)
      let source = root.appendingPathComponent("new")
      try FileManager.default.createDirectory(
        at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
      try Data("tree postimage".utf8).write(to: source.appendingPathComponent("nested/file"))
      try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/file")
      if operation == .fileReplace { try Data("preimage".utf8).write(to: target) }
      if operation == .directoryReplace || operation == .directoryDelete {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("tree preimage".utf8).write(to: target.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
      }
      if operation == .directoryReplace {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
      }
      beforeTarget = try FileSnapshot.read(at: target)
      beforeAuxiliary = try FileSnapshot.read(at: auxiliary)
      state = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
        ($0, try FileSnapshot.read(at: $0))
      }
    } catch {
      makeDirectoriesWritable(root)
      removeTemporaryDirectory(root)
      throw error
    }
  }
  deinit {
    makeDirectoriesWritable(root)
    removeTemporaryDirectory(root)
  }

  func launch(_ command: String, at point: String) throws -> Process {
    try stateTestProcess(root: root, arguments: [command, point, operation.rawValue])
  }

  func pause(_ command: String, at point: String) throws -> Process {
    let marker = root.appendingPathComponent(command == "publication" ? "ready" : "recovery-ready")
    try? FileManager.default.removeItem(at: marker)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("stop-at"))
    let child = try launch(command, at: point)
    do {
      try ProcessWait.marker(marker, child: child, root: root)
      return child
    } catch {
      terminateProcess(child)
      throw error
    }
  }

  func resume(_ child: Process, marker: String = "ready") throws {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(marker))
    kill(child.processIdentifier, SIGCONT)
    try ProcessWait.exit(child, root: root)
    #expect(child.terminationStatus == 0)
  }

  func restop(_ child: Process, at point: String) throws {
    let marker = root.appendingPathComponent("ready")
    try? FileManager.default.removeItem(at: marker)
    try Data(point.utf8).write(to: root.appendingPathComponent("stop-at"))
    kill(child.processIdentifier, SIGCONT)
    try ProcessWait.marker(marker, child: child, root: root)
  }

  func result(_ name: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
  }

  func lastJournal() throws -> TransactionJournal? {
    for url in [
      store.directory.appendingPathComponent("transaction.json"),
      store.directory.appendingPathComponent("transaction.new"),
      root.appendingPathComponent("last-journal"),
    ] {
      if FileManager.default.fileExists(atPath: url.path) {
        return try StateStore.decode(Data(contentsOf: url), as: TransactionJournal.self)
      }
    }
    return nil
  }

  func scratch(_ slot: TransactionScratch, entry index: Int, journal: TransactionJournal) -> URL {
    root.appendingPathComponent(journal.containerName(journal.entries[index].container))
      .appendingPathComponent(slot.name(index))
  }

  func recover(expected: TransactionOutcome.Disposition) throws {
    let outcome = TransactionOutcome()
    outcome.journalID = try lastJournal()?.id
    let directory = try #require(try store.openDirectoryIfPresent())
    let pending =
      try directory.info("transaction.json") != nil || directory.info("transaction.new") != nil
    if pending {
      #expect(throws: CoreError.transactionRecovered(store.directory.path)) {
        try store.withLock(outcome: outcome, {})
      }
      #expect(outcome.disposition == expected)
    } else {
      try store.withLock(outcome: outcome, {})
      if expected == .committed { #expect(try result("stopped-outcome") == "committed") }
    }
  }

  func expectUnresolved(
    containing expected: String =
      "missing or changed expected target, preimage or rollback quarantine"
  ) throws {
    let outcome = TransactionOutcome()
    outcome.journalID = try lastJournal()?.id
    #expect { try store.withLock(outcome: outcome, {}) } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains(expected)
    }
    #expect(outcome.disposition == .recoveryRequired)
    let diagnostic = FileTransaction.recoveryDiagnostic(store: store)
    #expect(diagnostic.requiresOwner)
    #expect(diagnostic.message.contains("owner action"))
    let journal = try #require(try lastJournal())
    let conflicts = journal.entries.compactMap(\.conflict)
    #expect(conflicts.contains { $0.reason.contains(expected) && !$0.locations.isEmpty })
    #expect(try store.openDirectoryIfPresent()?.info("transaction.json") != nil)
    #expect(
      try FileSnapshot.read(at: auxiliary)
        == (journal.phase == .committed ? journal.entries[0].staged : beforeAuxiliary))
    for (url, before) in state { #expect(try FileSnapshot.read(at: url) == before) }
  }

  func check(committed: Bool, journal: TransactionJournal?) throws {
    #expect(
      try FileSnapshot.read(at: target) == (committed ? journal?.entries[1].staged : beforeTarget))
    #expect(
      try FileSnapshot.read(at: auxiliary)
        == (committed ? journal?.entries[0].staged : beforeAuxiliary))
    for (url, before) in state { #expect(try FileSnapshot.read(at: url) == before) }
  }

  func expectClean() throws {
    #expect(try store.openDirectoryIfPresent()?.info("transaction.json") == nil)
    #expect(try store.openDirectoryIfPresent()?.info("transaction.new") == nil)
    #expect(
      try !FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.hasPrefix(".agents-")
      })
  }
}

private struct LegacyJournal: Encodable {
  let id: UUID
  let scope: String
  let roots: [String: String]
  let phase: String
  let entries: [Entry]
  struct Entry: Encodable {
    let path: String
    let existed: Bool
    let replacement: Bool
  }
}
