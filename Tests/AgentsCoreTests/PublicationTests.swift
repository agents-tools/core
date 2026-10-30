import AgentsManifest
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
    terminateProcess(try fixture.pause("publication", at: fault.point))
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
    let journal = try fixture.lastJournal()
    terminateProcess(try fixture.pause("publication-recover", at: fault.point))
    try fixture.recover(expected: fault.committed ? .committed : .unchanged, afterRecovery: true)
    try fixture.check(committed: fault.committed, journal: journal)
    #expect(try !FileTransaction.recover(store: fixture.store))
    try fixture.expectClean()
  }

  /// An observed `restoring` journal may still lack its directory barrier. Resumed undo syncs
  /// it before it grants directory write access or reverses any rename.
  @Test func resumedUndoSyncsTheObservedJournalFirst() throws {
    let fixture = try PublicationFixture(.directoryReplace)
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.progress(1, .applied).name))
    terminateProcess(
      try fixture.pause(
        "publication-recover",
        at: TransactionCheckpoint.persisted(.applying, .entry(1, .restoring), .renamed).name))
    #expect(try fixture.lastJournal()?.entries[1].progress == .restoring)
    let recovery = try fixture.launch("publication-recover", at: "never")
    defer { terminateProcess(recovery) }
    try ProcessWait.exit(recovery, root: fixture.root)
    let trace = try fixture.trace(recovery)
    #expect(trace.first == TransactionCheckpoint.journalSynced.name)
    let grant = try #require(
      trace.firstIndex(
        of: TransactionCheckpoint.permissions(1, .undoGrant, .target, .changed).name))
    let undo = try #require(
      trace.firstIndex(of: TransactionCheckpoint.restoration(1, .exchanged).name))
    #expect(grant < undo)
    #expect(try fixture.result("recovery-result") == "recovered")
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  /// A preparation that becomes stale before its entry publishes cancels from `ready`:
  /// nothing is leased or moved, the journal is removed and the scope stays writable.
  @Test(arguments: [PublicationOperation.directoryDelete, .directoryReplace])
  func stalePreparationBeforePublicationCancelsWithoutConflict(_ operation: PublicationOperation)
    throws
  {
    let fixture = try PublicationFixture(operation)
    let child = try fixture.pause(
      "publication", at: TransactionCheckpoint.progress(0, .applied).name)
    defer { terminateProcess(child) }
    let original = fixture.root.appendingPathComponent("moved-original")
    if operation == .directoryDelete {
      try Data("external edit".utf8).write(to: fixture.target.appendingPathComponent("file"))
    } else {
      try FileManager.default.moveItem(at: fixture.target, to: original)
      try FileManager.default.createDirectory(
        at: fixture.target, withIntermediateDirectories: false)
      try Data("external replacement".utf8).write(
        to: fixture.target.appendingPathComponent("file"))
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: fixture.target.path)
    }
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.resume(child)
    let trace = try fixture.trace(child)
    #expect(!trace.contains(TransactionCheckpoint.progress(1, .publishing).name))
    #expect(trace.contains("recovery." + TransactionCheckpoint.progress(1, .cancelled).name))
    let result = try fixture.result("publication-result")
    #expect(result.hasPrefix("unchanged\n"))
    #expect(result.contains("preparation is stale; prepare again"))
    #expect(try FileSnapshot.read(at: fixture.target) == external)
    if operation == .directoryReplace {
      #expect(try FileSnapshot.read(at: original) == fixture.beforeTarget)
    }
    #expect(try FileSnapshot.read(at: fixture.auxiliary) == fixture.beforeAuxiliary)
    try fixture.expectClean()
    try fixture.store.withLock {}
  }

  @Test func disposalConflictNamesTheChangedContainer() throws {
    let fixture = try PublicationFixture(.crossParentReplace)
    let child = try fixture.pause("publication", at: TransactionCheckpoint.phase(.committed).name)
    defer { terminateProcess(child) }
    let journal = try #require(try fixture.lastJournal())
    #expect(journal.containers.map(\.entry) == [0, 1])
    let foreign = fixture.container(1, journal: journal).appendingPathComponent("foreign")
    try Data("external".utf8).write(to: foreign)
    terminateProcess(child)
    try fixture.expectUnresolved(containing: "terminal disposal evidence changed")
    let recorded = try #require(try fixture.lastJournal())
    #expect(recorded.entries[0].conflict == nil)
    let entry = recorded.entries[1]
    let root = try #require(entry.path.split(separator: "/").first)
    #expect(entry.conflict?.locations == [entry.path, root + "/" + recorded.containerName(1)])
    #expect(try Data(contentsOf: foreign) == Data("external".utf8))
  }

  @Test(arguments: ["external", "postimage"])
  func concurrentCreatorKeepsItsBytesAndInode(_ bytes: String) throws {
    let fixture = try PublicationFixture(.fileCreate)
    let child = try fixture.pause(
      "publication", at: TransactionCheckpoint.publication(1, .validated).name)
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
    let child = try fixture.pause(
      "publication", at: TransactionCheckpoint.publication(1, .validated).name)
    defer { terminateProcess(child) }
    if !inPlace {
      try FileManager.default.moveItem(
        at: fixture.target, to: fixture.root.appendingPathComponent("original"))
    }
    try Data("external preimage".utf8).write(to: fixture.target)
    let external = try FileSnapshot.read(at: fixture.target)
    try fixture.restop(child, at: TransactionCheckpoint.publication(1, .exchanged).name)
    terminateProcess(child)
    let journal = try #require(try fixture.lastJournal())
    let postimage = try #require(journal.entries[1].staged)
    #expect(try FileSnapshot.read(at: fixture.target) == postimage)
    #expect(
      try FileSnapshot.read(at: fixture.slot(.exchanged, entry: 1, journal: journal)) == external
    )
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == postimage)
    #expect(
      try FileSnapshot.read(at: fixture.slot(.exchanged, entry: 1, journal: journal)) == external
    )
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
    let child = try fixture.pause(
      "publication", at: TransactionCheckpoint.progress(1, .applied).name)
    defer { terminateProcess(child) }
    let journal = try #require(try fixture.lastJournal())
    let slot: TransactionSlot = operation == .directoryDelete ? .deleted : .exchanged
    let original = fixture.slot(slot, entry: 1, journal: journal)
    let saved = fixture.root.appendingPathComponent("saved-preimage")
    let lease = try #require(fixture.beforeTarget).writeLease
    if let lease {
      try FileManager.default.setAttributes(
        [.posixPermissions: lease.grantedMode], ofItemAtPath: original.path)
    }
    try FileManager.default.moveItem(at: original, to: saved)
    if let lease {
      try FileManager.default.setAttributes(
        [.posixPermissions: lease.originalMode], ofItemAtPath: saved.path)
    }
    let published = try FileSnapshot.read(at: fixture.target)
    terminateProcess(child)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == published)
    #expect(try FileSnapshot.read(at: saved) == fixture.beforeTarget)
    #expect(try fixture.lastJournal()?.phase == .applying)
  }

  @Test func missingWithdrawnObjectIsUnresolvedBeforeDisposalIntent() throws {
    let fixture = try PublicationFixture(.fileCreate)
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.publication(1, .created).name))
    let recovery = try fixture.pause(
      "publication-recover", at: TransactionCheckpoint.progress(1, .restored).name)
    defer { terminateProcess(recovery) }
    let journal = try #require(try fixture.lastJournal())
    let withdrawn = fixture.slot(.withdrawn, entry: 1, journal: journal)
    let saved = fixture.root.appendingPathComponent("saved-postimage")
    try FileManager.default.moveItem(at: withdrawn, to: saved)
    terminateProcess(recovery)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: fixture.target) == nil)
    #expect(try FileSnapshot.read(at: saved) == journal.entries[1].staged)
  }

  @Test(arguments: [PublicationOperation.fileCreate, .fileReplace, .directoryDelete])
  func externalRecoveryDestinationPreservesBothVersions(_ operation: PublicationOperation) throws {
    let fixture = try PublicationFixture(operation)
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.progress(1, .applied).name))
    let recovery = try fixture.pause(
      "publication-recover", at: TransactionCheckpoint.restoration(1, .validated).name)
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
    case .fileCreate: location = fixture.slot(.withdrawn, entry: 1, journal: journal)
    case .fileReplace: location = fixture.slot(.exchanged, entry: 1, journal: journal)
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
        try FileSnapshot.read(at: fixture.slot(.deleted, entry: 1, journal: journal))
          == fixture.beforeTarget)
    } else {
      #expect(
        try FileSnapshot.read(at: fixture.root.appendingPathComponent("saved-postimage"))
          == journal.entries[1].staged)
    }
  }

  @Test func committedFailureRetainsUserDataAndRecordsConflict() throws {
    let fixture = try PublicationFixture(.fileReplace)
    let child = try fixture.pause("publication", at: TransactionCheckpoint.phase(.committed).name)
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
      try FileSnapshot.read(at: fixture.slot(.exchanged, entry: 1, journal: journal))
        == fixture.beforeTarget)
  }

  @Test(arguments: [false, true])
  func plannedUnidentifiedContainerOnlyAdmitsEmptyRmdir(_ populate: Bool) throws {
    let fixture = try PublicationFixture(.fileCreate)
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.containerCreated(0).name))
    let journal = try #require(try fixture.lastJournal())
    #expect(journal.containers[0].identity == nil)
    let container = fixture.container(0, journal: journal)
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
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.progress(1, .ready).name))
    let journal = try #require(try fixture.lastJournal())
    let file = fixture.slot(.exchanged, entry: 1, journal: journal)
    try Data("changed after sealing".utf8).write(to: file)
    let changed = try FileSnapshot.read(at: file)
    try fixture.expectUnresolved()
    #expect(try FileSnapshot.read(at: file) == changed)
    #expect(try FileSnapshot.read(at: fixture.target) == fixture.beforeTarget)
  }

  @Test func directoryPermissionChangesOutsideIntentRemainExternal() throws {
    let fixture = try PublicationFixture(.directoryReplace)
    let child = try fixture.pause(
      "publication",
      at: TransactionCheckpoint.permissions(1, .publicationGrant, .target, .synced).name)
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
    try transaction.replace(fixture.target, with: .data(Data("postimage".utf8)))
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
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.progress(1, .ready).name))
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
      try fixture.store.withLock {}
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
    try manifestText("defaultAgents: [.codex]").write(to: fixture.store.declarationURL)
    var old = try StateStore.encode(
      LegacyJournal(
        id: id, scope: directory.identity,
        roots: ["state": directory.identity], phase: "applying",
        entries: [
          .init(path: "state/" + StateStore.declarationFileName, existed: true, replacement: true)
        ]))
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
      try fixture.store.withLock {}
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    let diagnostic = FileTransaction.recoveryDiagnostic(store: fixture.store)
    #expect(diagnostic.requiresOwner)
    #expect(diagnostic.message.contains("version that wrote it"))
  }

  @Test(arguments: ["identity", "disposal"])
  func missingContainerEvidenceCannotAuthorizeTerminalDeletion(_ field: String) throws {
    let fixture = try PublicationFixture(.fileReplace)
    terminateProcess(
      try fixture.pause("publication", at: TransactionCheckpoint.phase(.committed).name))
    var journal = try #require(try fixture.lastJournal())
    if field == "identity" {
      journal.containers[0].identity = nil
    } else {
      journal.containers[0].disposal = nil
    }
    try StateStore.encode(journal).write(
      to: fixture.store.directory.appendingPathComponent("transaction.json"))
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(
      throws: CoreError.invalidState(
        field == "identity"
          ? "sealed operation is missing private container identity"
          : "terminal container is missing user-object disposal evidence")
    ) { try fixture.store.withLock {} }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test func unchangedStateIsNotAnImplicitCachePrecondition() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let cache = SourceCache(store: fixture.store)
    let bytes = Data("artifact".utf8)
    let digest = "sha256:" + FileHash.sha256Hex(data: Data("artifact".utf8))
    let transaction = FileTransaction(store: fixture.store)
    let target = try cache.artifactURL(digest: digest)
    try transaction.replace(target, with: .data(bytes), expectedHash: digest)
    try manifestText("defaultAgents: []").write(to: fixture.store.declarationURL)
    let state = try FileSnapshot.read(at: fixture.store.declarationURL)
    try transaction.commit()
    #expect(try Data(contentsOf: target) == bytes)
    #expect(try FileSnapshot.read(at: fixture.store.declarationURL) == state)
  }
}

enum PublicationOperation: String, CaseIterable, Sendable {
  case fileReplace, directoryReplace, directoryDelete, symlinkCreate, fileCreate
  /// The target is in another parent than the auxiliary file, so two containers are used.
  case crossParentReplace

  var renamePoint: String {
    switch self {
    case .directoryDelete: TransactionCheckpoint.publication(1, .deleted).name
    case .fileReplace, .directoryReplace, .crossParentReplace:
      TransactionCheckpoint.publication(1, .exchanged).name
    case .symlinkCreate, .fileCreate: TransactionCheckpoint.publication(1, .created).name
    }
  }

  /// Undo of the target's publication rename.
  var reverseRenamePoint: String {
    switch self {
    case .directoryDelete: TransactionCheckpoint.restoration(1, .returned).name
    case .fileReplace, .directoryReplace, .crossParentReplace:
      TransactionCheckpoint.restoration(1, .exchanged).name
    case .symlinkCreate, .fileCreate: TransactionCheckpoint.restoration(1, .withdrawn).name
    }
  }

  var leasesDirectories: Bool { self == .directoryReplace || self == .directoryDelete }

  /// Recovery starts from construction, sealed staging, an interrupted rename or directory
  /// grant, an applied entry, the committed marker and terminal disposal.
  var recoverySeeds: [RecoverySeed] {
    var seeds = [
      RecoverySeed(point: TransactionCheckpoint.stage(1, .constructed).name),
      RecoverySeed(point: TransactionCheckpoint.progress(1, .ready).name),
      RecoverySeed(point: renamePoint, renamed: true),
      RecoverySeed(point: TransactionCheckpoint.progress(1, .applied).name, renamed: true),
      RecoverySeed(
        point: TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name,
        committed: true),
      RecoverySeed(point: TransactionCheckpoint.disposalIntent.name, committed: true),
    ]
    if leasesDirectories {
      seeds.append(
        RecoverySeed(
          point: TransactionCheckpoint.permissions(1, .publicationGrant, .target, .changed).name))
    }
    return seeds
  }

  /// Points every recovery from `seed` must reach.
  func requiredRecoveryPoints(from seed: RecoverySeed) -> Set<String> {
    var points = [
      TransactionCheckpoint.journalSynced.name, TransactionCheckpoint.journalRemoved.name,
    ]
    if !seed.committed {
      points.append(TransactionCheckpoint.persisted(.rolledBack, .terminal, .renamed).name)
    }
    if seed.renamed { points.append(reverseRenamePoint) }
    return Set(points)
  }
}

/// A publication interruption that recovery starts from.
struct RecoverySeed: Sendable {
  let point: String
  var committed = false
  /// The target's publication rename has happened, so rollback must reverse it.
  var renamed = false
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

/// Kill-point matrices recorded from real traces. By default publication tests kill each
/// operation at representative points, and kill recovery at durable steps from each seeded
/// interruption; `AGENTS_PUBLICATION_MATRIX=full` kills at every recorded point.
private enum PublicationMatrix {
  static let complete = ProcessInfo.processInfo.environment["AGENTS_PUBLICATION_MATRIX"] == "full"
  static let publications = record(recovery: false)
  static let recoveries = record(recovery: true)

  /// Every recovery seed, durable intent, the synced rename, the mode restoration and the
  /// removal of the first container.
  private static func representativePublication(_ operation: PublicationOperation) -> Set<String> {
    var points =
      operation.recoverySeeds.map(\.point) + [
        TransactionCheckpoint.progress(1, .publishing).name,
        TransactionCheckpoint.publication(1, .synced).name,
        TransactionCheckpoint.containerRemoved(0).name,
      ]
    if operation.leasesDirectories {
      // A deleted directory's mode is restored in its slot; a replacement's at the target.
      let location: TransactionObjectLocation =
        operation == .directoryDelete ? .slot(.deleted) : .target
      points.append(
        TransactionCheckpoint.permissions(1, .publicationRestore, location, .changed).name)
    }
    return Set(points)
  }

  /// The observed-journal barrier, each durable recovery write, each reverse rename, undo
  /// grant and mode restoration, and disposal.
  private static let representativeRecovery: Set<String> = {
    var points: [TransactionCheckpoint] = [.journalSynced, .containerRemoved(0), .journalRemoved]
    for phase in [TransactionJournal.Phase.applying, .committed, .rolledBack] {
      points += [.persisted(phase, .terminal, .renamed), .persisted(phase, .disposing, .renamed)]
      for index in 0...1 {
        for progress in [TransactionJournal.Progress.restoring, .restored, .cancelled] {
          points.append(.persisted(phase, .entry(index, progress), .renamed))
        }
      }
    }
    for index in 0...1 {
      points += [
        .restoration(index, .exchanged), .restoration(index, .returned),
        .restoration(index, .withdrawn), .restoration(index, .synced),
        .permissions(index, .undoGrant, .target, .changed),
        .permissions(index, .undoRestore, .target, .changed),
        .permissions(index, .cancelRestore, .target, .changed),
      ]
    }
    return Set(points.map(\.name))
  }()

  private static func record(recovery: Bool) -> [PublicationFault] {
    var cases: [PublicationFault] = []
    let commitMarker = TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name
    for operation in PublicationOperation.allCases {
      let selected = recovery ? representativeRecovery : representativePublication(operation)
      let seeds: [RecoverySeed?] = recovery ? operation.recoverySeeds.map { $0 } : [nil]
      for seed in seeds {
        do {
          let fixture = try PublicationFixture(operation)
          if let seed { terminateProcess(try fixture.pause("publication", at: seed.point)) }
          let command = recovery ? "publication-recover" : "publication"
          let child = try fixture.launch(command, at: "never")
          defer { terminateProcess(child) }
          try ProcessWait.exit(child, root: fixture.root)
          guard child.terminationStatus == 0 else {
            throw CoreError.invalidState("checkpoint recorder exited \(child.terminationStatus)")
          }
          let trace = try fixture.trace(child)
          guard !trace.isEmpty, Set(trace).count == trace.count else {
            throw CoreError.invalidState("checkpoint names are empty or repeated")
          }
          let required = seed.map(operation.requiredRecoveryPoints(from:)) ?? selected
          if !required.isSubset(of: trace) {
            throw CoreError.invalidState(
              "representative points were not recorded: \(required.subtracting(trace).sorted())")
          }
          var committed = seed?.committed ?? false
          for point in trace {
            if point == commitMarker { committed = true }
            guard complete || selected.contains(point) else { continue }
            cases.append(
              PublicationFault(
                operation: operation, point: point, committed: committed, seed: seed?.point))
          }
        } catch {
          cases.append(
            PublicationFault(
              operation: operation, point: "recording", seed: seed?.point,
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
    target =
      operation == .crossParentReplace
      ? root.appendingPathComponent(".agents/skills/target")
      : root.appendingPathComponent("AGENTS.md")
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
      if operation == .crossParentReplace {
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      }
      if operation == .fileReplace || operation == .crossParentReplace {
        try Data("preimage".utf8).write(to: target)
      }
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
      try ProcessWait.stopped(child, root: root)
      return child
    } catch {
      terminateProcess(child)
      throw error
    }
  }

  /// The child was confirmed stopped by `pause` or `restop`, so SIGCONT cannot be lost.
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
    try ProcessWait.stopped(child, root: root)
  }

  func trace(_ child: Process) throws -> [String] {
    try String(
      contentsOf: root.appendingPathComponent("checkpoint-\(child.processIdentifier).log"),
      encoding: .utf8
    ).split(separator: "\n").map(String.init)
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

  func container(_ index: Int, journal: TransactionJournal) -> URL {
    (journal.containers[index].entry == 0 ? auxiliary : target).deletingLastPathComponent()
      .appendingPathComponent(journal.containerName(index))
  }

  func slot(_ slot: TransactionSlot, entry index: Int, journal: TransactionJournal) -> URL {
    container(journal.entries[index].container, journal: journal)
      .appendingPathComponent(slot.name(index))
  }

  /// After an interrupted recovery, a journal already removed has no outcome left to report.
  func recover(expected: TransactionOutcome.Disposition, afterRecovery: Bool = false) throws {
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
      if expected == .committed, !afterRecovery {
        #expect(try result("stopped-outcome") == "committed")
      }
    }
  }

  func expectUnresolved(
    containing expected: String =
      "missing or changed expected target or recovery slot object"
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
    for parent in Set([auxiliary, target].map { $0.deletingLastPathComponent().path }) {
      #expect(
        try !FileManager.default.contentsOfDirectory(atPath: parent).contains {
          $0.hasPrefix(".agents-")
        })
    }
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
