import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Shared native physical targets")
struct SharedTargetTests {
  @Test func localAndUserWritersKeepOnePrivateGenerationAcrossScopesAndAliases() throws {
    let fixture = try SharedFixture()
    let provider = SharedBindings()
    var stale: PreparedPrivateMaterialization?
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let prepared = try fixture.a.preparePrivateMaterialization(target)
      let transaction = FileTransaction(store: fixture.a)
      try transaction.replacePrivate(prepared, bindings: ["secret"], provider: provider) {
        try $0.value(for: "secret")
      }
      try transaction.commit()
      stale = try fixture.a.preparePrivateMaterialization(target)
    }
    let first = try #require(stale)
    let key = try fixture.identity(fixture.a)
    var generations = [first.receiptGeneration]
    for (store, route, bytes) in [
      (fixture.b, NativeTargetRoute.claudeMCPLocal, "secret sibling; B region"),
      (fixture.user, NativeTargetRoute.claudeMCPUser, "secret sibling; B region; user region"),
      (fixture.a, NativeTargetRoute.claudeMCPLocal, "secret sibling; user region"),
    ] {
      var privateBeforeWrite = false
      try store.withLock(footprint: [route]) {
        let target = try store.nativeTarget(for: route)
        let before = try store.preparePrivateMaterialization(
          target, requiringReceiptForExistingTarget: true)
        #expect(before.receiptGeneration == generations.last!)
        let transaction = FileTransaction(store: store) { point in
          if point == "stage.0.writeCreated" {
            let journal = try fixture.journal(store)
            let container = target.url.deletingLastPathComponent().appendingPathComponent(
              journal.containers[0].name)
            let directory = try DirectoryHandle(at: container)
            _ = try directory.requirePrivateAccess("entry.0.exchanged")
            #expect(try directory.read("entry.0.exchanged").isEmpty)
            privateBeforeWrite = true
          }
        }
        try transaction.replace(target.url, with: .data(Data(bytes.utf8)))
        try transaction.commit()
        let after = try store.preparePrivateMaterialization(
          target, requiringReceiptForExistingTarget: true)
        #expect(after.receiptGeneration != before.receiptGeneration)
        generations.append(after.receiptGeneration)
        #expect(try Data(contentsOf: target.url) == Data(bytes.utf8))
        #expect(try TransactionLockContext.current(store).requiredResource().identity == key)
      }
      #expect(privateBeforeWrite)
      #expect(try store.materializationReceipts().records.targets.isEmpty)
    }
    #expect(provider.calls == 1)
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      #expect(throws: CoreError.self) { try first.evidence.validate() }
      #expect(throws: CoreError.self) {
        try fixture.a.preparePrivateMaterialization(
          first.target, expecting: first.receiptGeneration)
      }
    }
  }

  @Test func registeredProjectRouteIsLocalAndSharedRequestsRequireAdmission() throws {
    let fixture = try SharedFixture()
    let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
    try fixture.a.withLock {
      let transaction = FileTransaction(store: fixture.a)
      #expect(throws: CoreError.self) { try transaction.replace(target.url, with: .data(Data())) }
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.config.appendingPathComponent(SharedResource.metadataName).path))
    try fixture.a.withLock(footprint: [.claudeMCPProject]) {
      #expect(TransactionLockContext.current(fixture.a)?.resources.isEmpty == true)
      let project = try fixture.a.nativeTarget(for: .claudeMCPProject)
      let transaction = FileTransaction(store: fixture.a)
      try transaction.replace(project.url, with: .data(Data("project only".utf8)))
      #expect(throws: CoreError.self) {
        try transaction.replace(
          fixture.config.appendingPathComponent("other.json"), with: .data(Data()))
      }
      try transaction.commit()
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.config.appendingPathComponent(SharedResource.metadataName).path))
  }

  @Test func externalSiblingOrAccessChangesCannotRefreshSharedReceipts() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try Data(contentsOf: fixture.receiptURL())
    try Data("external trust change".utf8).write(to: fixture.target)
    #expect(throws: CoreError.self) {
      try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
        let transaction = FileTransaction(store: fixture.b)
        try transaction.replace(fixture.target, with: .data(Data("replacement".utf8)))
      }
    }
    #expect(try Data(contentsOf: fixture.receiptURL()) == before)
    #expect(try Data(contentsOf: fixture.target) == Data("external trust change".utf8))
  }

  @Test(arguments: ["target", "ancestor"])
  func sharedPreparedWriteRejectsChangedAccess(_ changed: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let targetBytes = try Data(contentsOf: fixture.target)
    let receiptURL = try fixture.receiptURL()
    let receipt = try Data(contentsOf: receiptURL)
    let changedURL = changed == "target" ? fixture.target : fixture.config
    var original = stat()
    try #require(stat(changedURL.path, &original) == 0)
    defer { _ = chmod(changedURL.path, original.st_mode & 0o7777) }
    try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.b.nativeTarget(for: .claudeMCPLocal)
      let prepared = try fixture.b.preparePrivateMaterialization(
        target, requiringReceiptForExistingTarget: true)
      let transaction = FileTransaction(store: fixture.b)
      try transaction.replace(
        target.url, with: .data(Data("secret sibling; changed region".utf8)),
        expecting: prepared.evidence)
      let externalMode: mode_t = changed == "target" ? 0o644 : 0o777
      try #require(chmod(changedURL.path, externalMode) == 0)
      #expect(throws: CoreError.self) { try transaction.commit() }
      var actual = stat()
      try #require(stat(changedURL.path, &actual) == 0)
      #expect(actual.st_mode & 0o7777 == externalMode)
      #expect(try Data(contentsOf: fixture.target) == targetBytes)
      #expect(try Data(contentsOf: receiptURL) == receipt)
    }
  }

  @Test(arguments: [
    "journal.preparing.created.written", "journal.preparing.created.renamed",
    "shared.0.reservation.created",
    "shared.0.reservation.halfWritten", "shared.0.reservation.written",
    "shared.0.reservation.published", "shared.0.reservation.synced", "shared.ready",
    "stage.0.writeCreated", "publish.0.exchanged", "entry.0.applied", "entry.2.applied",
    "journal.committed", "disposal.0.removed", "journal.finalized",
    "shared.0.reservation.removed", "journal.unlinked",
  ])
  func sharedCrashWindowsRecoverOneGeneration(_ point: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let old = try Data(contentsOf: fixture.target)
    let oldReceipt = try Data(contentsOf: fixture.receiptURL())
    let child = try stateTestProcess(root: fixture.root, arguments: ["shared-edit", point])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let observed =
      point == "journal.preparing.created.written"
      ? fixture.a.directory.appendingPathComponent("transaction.new")
      : fixture.root.appendingPathComponent("last-journal")
    let journal = try StateStore.decode(
      Data(contentsOf: observed),
      as: TransactionJournal.self)
    let committed = journal.phase == .committed
    if point != "shared.0.reservation.removed" && point != "journal.unlinked"
      && point != "journal.preparing.created.renamed"
      && point != "journal.preparing.created.written"
    {
      #expect(throws: CoreError.self) {
        try fixture.b.withLock(footprint: [.claudeMCPLocal]) {}
      }
    }
    do { try fixture.a.withLock {} } catch CoreError.transactionRecovered {}
    #expect(
      try Data(contentsOf: fixture.target)
        == (committed ? Data("secret sibling; edited region".utf8) : old))
    if !committed { #expect(try Data(contentsOf: fixture.receiptURL()) == oldReceipt) }
    try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.b.nativeTarget(for: .claudeMCPLocal)
      #expect(try fixture.b.materializationReceipt(for: target) != nil)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.a.directory.appendingPathComponent("transaction.json").path))
    #expect(
      try DirectoryHandle(at: fixture.receiptURL().deletingLastPathComponent()).names().sorted()
        == ["lock", "receipt"])
  }

  @Test(arguments: [false, true])
  func finalizedCleanupAndDiagnosisNeverReconstructOldData(_ rolledBack: Bool) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let command = rolledBack ? "entry.0.applied" : "shared.0.reservation.removed"
    let child = try stateTestProcess(root: fixture.root, arguments: ["shared-edit", command])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    if rolledBack {
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ready"))
      let recovery = try stateTestProcess(
        root: fixture.root, arguments: ["shared-recover", "shared.0.reservation.removed"])
      defer { terminateProcess(recovery) }
      try ProcessWait.marker(
        fixture.root.appendingPathComponent("ready"), child: recovery, root: fixture.root)
      terminateProcess(recovery)
    }
    let journal = try fixture.journal(fixture.a)
    #expect(journal.finalized)
    #expect(journal.phase == (rolledBack ? .rolledBack : .committed))
    try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
      let transaction = FileTransaction(store: fixture.b)
      try transaction.replace(
        fixture.target, with: .data(Data("secret sibling; later B generation".utf8)))
      try transaction.commit()
    }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("old-data"))
    let target = try FileSnapshot.read(at: fixture.target)
    let receipt = try Data(contentsOf: fixture.receiptURL())
    let journalBytes = try Data(
      contentsOf: fixture.a.directory.appendingPathComponent("transaction.json"))
    try fixture.a.withReadLock(
      onPendingRecovery: {
        let diagnostic = FileTransaction.recoveryDiagnostic(store: fixture.a)
        #expect(!diagnostic.requiresOwner)
        #expect(diagnostic.message.contains(rolledBack ? "rolledBack" : "committed"))
      }, { _ = Issue.record("finalized journal must remain pending for inspection") })
    #expect(
      try Data(contentsOf: fixture.a.directory.appendingPathComponent("transaction.json"))
        == journalBytes)
    let outcome = TransactionOutcome()
    outcome.journalID = journal.id
    do { try fixture.a.withLock(outcome: outcome) {} } catch CoreError.transactionRecovered {}
    #expect(outcome.disposition == (rolledBack ? .unchanged : .committed))
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(try Data(contentsOf: fixture.receiptURL()) == receipt)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("old-data").path))
  }
  @Test func aliasedCallersWaitOnTheSamePhysicalLockBeforeScopeEntry() throws {
    let fixture = try SharedFixture()
    let holder = try stateTestProcess(
      root: fixture.root, arguments: ["shared-lock", "shared.locked"])
    defer { terminateProcess(holder) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: holder, root: fixture.root)
    let other = fixture.b.environment.projectDirectory
    let waiter = try stateTestProcess(
      root: other,
      arguments: [
        "shared-lock", "shared.0.lock.contended", "--shared-config",
        fixture.root.appendingPathComponent("config-alias").path,
      ])
    defer { terminateProcess(waiter) }
    try ProcessWait.marker(other.appendingPathComponent("ready"), child: waiter, root: other)
    #expect(!FileManager.default.fileExists(atPath: fixture.b.directory.path))
    terminateProcess(waiter)
    terminateProcess(holder)
    try fixture.b.withLock(footprint: [.claudeMCPLocal, .claudeMCPUser]) {
      let local = try fixture.b.nativeTarget(for: .claudeMCPLocal)
      let user = try fixture.b.nativeTarget(for: .claudeMCPUser)
      #expect(local.path == user.path)
      #expect(local.url == user.url)
    }
  }

  @Test(arguments: [false, true])
  func aliasedWritersSerializeAcrossReplacementAndBothMakeProgress(_ reverse: Bool) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let other = fixture.b.environment.projectDirectory
    try FileManager.default.createDirectory(
      at: other.appendingPathComponent("old-data"), withIntermediateDirectories: true)
    try Data("ordinary before".utf8).write(to: other.appendingPathComponent("old-data/AGENTS.md"))
    let firstRoot = reverse ? other : fixture.root
    let secondRoot = reverse ? fixture.root : other
    let firstConfig = reverse ? fixture.root.appendingPathComponent("config-alias") : fixture.config
    let secondConfig =
      reverse ? fixture.config : fixture.root.appendingPathComponent("config-alias")
    let holder = try stateTestProcess(
      root: firstRoot,
      arguments: ["shared-edit", "publish.0.exchanged", "--shared-config", firstConfig.path])
    defer { terminateProcess(holder) }
    try ProcessWait.marker(
      firstRoot.appendingPathComponent("ready"), child: holder, root: firstRoot)
    try ProcessWait.stopped(holder, root: firstRoot)
    let published = try Data(contentsOf: fixture.target)
    #expect(published == Data("secret sibling; edited region".utf8))
    let waiter = try stateTestProcess(
      root: secondRoot,
      arguments: ["shared-edit", "shared.0.lock.contended", "--shared-config", secondConfig.path])
    defer { terminateProcess(waiter) }
    try ProcessWait.marker(
      secondRoot.appendingPathComponent("ready"), child: waiter, root: secondRoot)
    try ProcessWait.stopped(waiter, root: secondRoot)
    #expect(try Data(contentsOf: fixture.target) == published)
    try #require(kill(holder.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(holder, root: firstRoot)
    #expect(holder.terminationStatus == 0)
    let firstGeneration = try fixture.a.withReadLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let receipt = try fixture.a.materializationReceipt(for: target)
      return try #require(receipt).generation
    }
    try #require(kill(waiter.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(waiter, root: secondRoot)
    #expect(waiter.terminationStatus == 0)
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let after = try fixture.a.preparePrivateMaterialization(
        target, requiringReceiptForExistingTarget: true)
      #expect(after.receiptGeneration != firstGeneration)
      #expect(try Data(contentsOf: target.url) == published)
    }
  }

  @Test(arguments: ["shared-skill-recover", "shared-watch-recover", "shared-instruction-recover"])
  func ordinaryMutationEntrypointsRecoverPendingSharedFootprints(_ command: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let old = try Data(contentsOf: fixture.target)
    let oldReceipt = try Data(contentsOf: fixture.receiptURL())
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "entry.0.applied"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let before = try FileSnapshot.read(at: fixture.config)
    #expect(throws: CoreError.self) { try fixture.a.loadResolved() }
    #expect(try FileSnapshot.read(at: fixture.config) == before)
    let recovery = try stateTestProcess(root: fixture.root, arguments: [command, "never"])
    defer { terminateProcess(recovery) }
    try ProcessWait.exit(recovery, root: fixture.root)
    #expect(recovery.terminationStatus == 0)
    #expect(try Data(contentsOf: fixture.target) == old)
    #expect(try Data(contentsOf: fixture.receiptURL()) == oldReceipt)
  }

  @Test(arguments: [false, true])
  func wholeFileDeletionAndReceiptDeletionRecoverTogether(_ committed: Bool) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let old = try Data(contentsOf: fixture.target)
    let receiptURL = try fixture.receiptURL()
    let oldReceipt = try Data(contentsOf: receiptURL)
    let child = try stateTestProcess(
      root: fixture.root,
      arguments: ["shared-delete", committed ? "journal.committed" : "entry.0.applied"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    do { try fixture.a.withLock {} } catch CoreError.transactionRecovered {}
    if committed {
      #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
      #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
    } else {
      #expect(try Data(contentsOf: fixture.target) == old)
      #expect(try Data(contentsOf: receiptURL) == oldReceipt)
    }
  }

  @Test func finalizedOwnerCannotDeleteAnotherJournalsReservation() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.0.reservation.removed"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let other = fixture.b.environment.projectDirectory
    let b = try stateTestProcess(
      root: other,
      arguments: ["shared-edit", "shared.ready", "--shared-config", fixture.config.path])
    defer { terminateProcess(b) }
    try ProcessWait.marker(other.appendingPathComponent("ready"), child: b, root: other)
    terminateProcess(b)
    let reservationURL = try fixture.receiptURL().deletingLastPathComponent()
      .appendingPathComponent("reservation")
    let reservation = try Data(contentsOf: reservationURL)
    let target = try FileSnapshot.read(at: fixture.target)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("old-data"))
    try fixture.a.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: fixture.a).requiresOwner)
      }, { _ = Issue.record("expected metadata cleanup diagnostic") })
    do { try fixture.a.withLock {} } catch CoreError.transactionRecovered {}
    #expect(try Data(contentsOf: reservationURL) == reservation)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    do { try fixture.b.withLock {} } catch CoreError.transactionRecovered {}
  }

  @Test func synchronousFailureRecoversWithinTheOriginalFootprint() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try Data(contentsOf: fixture.target)
    let receipt = try Data(contentsOf: fixture.receiptURL())
    var callbacks = 0
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      callbacks += 1
      let transaction = FileTransaction(store: fixture.a) { point in
        if point == "publish.0.exchanged" { throw CoreError.invalidState("injected failure") }
      }
      try transaction.replace(fixture.target, with: .data(Data("secret sibling; change".utf8)))
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(try TransactionLockContext.current(fixture.a).requiredResource().reservation() == nil)
      let unsupported = FileTransaction(store: fixture.a)
      var producers = 0
      #expect(throws: CoreError.self) {
        try unsupported.replace(
          fixture.target,
          with: .prepared { url in
            producers += 1
            return url
          })
      }
      #expect(producers == 0)
      #expect(throws: CoreError.self) {
        try fixture.b.withLock(footprint: [.claudeMCPUser]) { callbacks += 1 }
      }
    }
    #expect(callbacks == 1)
    #expect(try Data(contentsOf: fixture.target) == before)
    #expect(try Data(contentsOf: fixture.receiptURL()) == receipt)
  }

  @Test(arguments: [
    "collision", "symlink", "unknown-slot", "malformed-reservation", "missing-ready-reservation",
    "unsafe-partial",
  ])
  func unsafeCoordinationMetadataIsRetainedAndRefused(_ shape: String) throws {
    let fixture = try SharedFixture()
    if shape == "collision" || shape == "symlink" {
      let url = fixture.config.appendingPathComponent(SharedResource.metadataName)
      if shape == "collision" {
        try Data().write(to: url)
      } else {
        try FileManager.default.createSymbolicLink(
          at: url, withDestinationURL: fixture.b.environment.projectDirectory)
      }
    } else {
      try fixture.install()
      let metadata = try DirectoryHandle(at: fixture.receiptURL().deletingLastPathComponent())
      if shape == "missing-ready-reservation" || shape == "unsafe-partial" {
        let child = try stateTestProcess(
          root: fixture.root,
          arguments: [
            "shared-edit",
            shape == "unsafe-partial" ? "shared.0.reservation.halfWritten" : "shared.ready",
          ])
        defer { terminateProcess(child) }
        try ProcessWait.marker(
          fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
        terminateProcess(child)
        if shape == "unsafe-partial" {
          let journal = try fixture.journal(fixture.a)
          let slot = metadata.url.appendingPathComponent(SharedResource.temporaryName(journal.id))
          try #require(chmod(slot.path, 0o644) == 0)
        } else {
          try metadata.remove("reservation")
        }
      } else {
        let name = shape == "unknown-slot" ? "reservation-unknown.new" : "reservation"
        let file = try metadata.createPrivateFile(name)
        try file.write(Data("incomplete".utf8))
      }
    }
    let before = try FileSnapshot.read(at: fixture.config)
    var callbacks = 0
    #expect(throws: CoreError.self) {
      try fixture.a.withLock(footprint: [.claudeMCPLocal]) { callbacks += 1 }
    }
    #expect(callbacks == 0)
    #expect(try FileSnapshot.read(at: fixture.config) == before)
  }

  @Test func intentBeforeReservationCannotUndoALaterWritersGeneration() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "journal.preparing.created.renamed"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
      let transaction = FileTransaction(store: fixture.b)
      try transaction.replace(
        fixture.target, with: .data(Data("secret sibling; later region".utf8)))
      try transaction.commit()
    }
    let before = try FileSnapshot.read(at: fixture.target)
    let receipt = try Data(contentsOf: fixture.receiptURL())
    do { try fixture.a.withLock {} } catch CoreError.transactionRecovered {}
    #expect(try FileSnapshot.read(at: fixture.target) == before)
    #expect(try Data(contentsOf: fixture.receiptURL()) == receipt)
  }

  @Test(arguments: [
    "journal.rolledBack.finalized.written", "journal.rolledBack.finalized.renamed",
    "journal.finalized",
  ])
  func interruptedRecoveryOfALoneReservationIntentIsRepeatable(_ point: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try Data(contentsOf: fixture.target)
    let receipt = try Data(contentsOf: fixture.receiptURL())
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "journal.preparing.created.written"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ready"))
    let recovery = try stateTestProcess(root: fixture.root, arguments: ["shared-recover", point])
    defer { terminateProcess(recovery) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: recovery, root: fixture.root)
    terminateProcess(recovery)
    try fixture.a.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: fixture.a).requiresOwner)
      }, { _ = Issue.record("expected pending cleanup") })
    do { try fixture.a.withLock {} } catch CoreError.transactionRecovered {}
    #expect(try Data(contentsOf: fixture.target) == before)
    #expect(try Data(contentsOf: fixture.receiptURL()) == receipt)
  }

  @Test func authorizationAliasChangesInvalidateTheHeldPhysicalTarget() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try FileSnapshot.read(at: fixture.target)
    let receipt = try Data(contentsOf: fixture.receiptURL())
    let other = fixture.root.appendingPathComponent("other-config")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try fixture.b.withLock(footprint: [.claudeMCPLocal]) {
      let alias = fixture.root.appendingPathComponent("config-alias")
      try FileManager.default.removeItem(at: alias)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
      #expect(throws: CoreError.self) { try fixture.b.nativeTarget(for: .claudeMCPLocal) }
      let transaction = FileTransaction(store: fixture.b)
      #expect(throws: CoreError.self) {
        try transaction.replace(other.appendingPathComponent(".claude.json"), with: .data(Data()))
      }
    }
    #expect(try FileSnapshot.read(at: fixture.target) == before)
    #expect(try Data(contentsOf: fixture.receiptURL()) == receipt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
  }

  @Test(arguments: ["footprint", "reservationsReady", "finalized", "metadata-target"])
  func missingCoordinationEvidenceAndForgedMetadataTargetsCannotReplay(_ field: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.ready"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let url = fixture.a.directory.appendingPathComponent("transaction.json")
    var value = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    if field == "metadata-target" {
      var entries = try #require(value["entries"] as? [[String: Any]])
      let index = try #require(
        entries.firstIndex {
          ($0["path"] as? String)?.hasPrefix(NativeTargetRoute.metadataRoot) == true
        })
      entries[index]["path"] = NativeTargetRoute.metadataRoot + "/lock"
      value["entries"] = entries
    } else {
      value.removeValue(forKey: field)
    }
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try bytes.write(to: url)
    let target = try FileSnapshot.read(at: fixture.target)
    let metadata = try FileSnapshot.read(at: fixture.receiptURL().deletingLastPathComponent())
    try fixture.a.withReadLock(
      onPendingRecovery: {
        #expect(FileTransaction.recoveryDiagnostic(store: fixture.a).requiresOwner)
      }, { _ = Issue.record("invalid evidence must block inspection") })
    #expect(throws: CoreError.self) { try fixture.a.withLock {} }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(try FileSnapshot.read(at: fixture.receiptURL().deletingLastPathComponent()) == metadata)
  }

  @Test func aForeignReservationReportsItsOwnerWithoutOpeningTheOwnerScope() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.ready"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let journal = try fixture.journal(fixture.a)
    var message = ""
    do { try fixture.b.withLock(footprint: [.claudeMCPLocal]) {} } catch CoreError.recoveryPending(
      let value)
    { message = value }
    #expect(message.contains(fixture.a.directory.path))
    #expect(message.contains(journal.id.uuidString))
    #expect(!message.contains("secret sibling"))
    #expect(try fixture.journal(fixture.a).id == journal.id)
  }

  @Test func orphanedForeignReservationRemainsPending() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.ready"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let journal = try fixture.journal(fixture.a)
    let journalURL = fixture.a.directory.appendingPathComponent("transaction.json")
    let reservationURL = try fixture.receiptURL().deletingLastPathComponent()
      .appendingPathComponent("reservation")
    let reservation = try Data(contentsOf: reservationURL)
    let target = try FileSnapshot.read(at: fixture.target)
    try FileManager.default.removeItem(at: journalURL)
    var calls = 0
    var message = ""
    do {
      try fixture.b.withLock(footprint: [.claudeMCPLocal]) { calls += 1 }
    } catch CoreError.recoveryPending(let value) {
      message = value
    }
    #expect(message.contains(fixture.a.directory.path))
    #expect(message.contains(journal.id.uuidString))
    #expect(calls == 0)
    #expect(try Data(contentsOf: reservationURL) == reservation)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
    #expect(!FileManager.default.fileExists(atPath: journalURL.path))
  }

  @Test(arguments: [false, true], [false, true])
  func readOnlyAdmissionRechecksSuccessfulAndFailedUnlockedSharedReads(
    _ metadataExists: Bool, _ throwFirst: Bool
  ) throws {
    let fixture = try SharedFixture()
    if metadataExists { _ = try SharedResource(store: fixture.a, create: true) }
    let writer = fixture.a
    var attempts = 0
    let result = try fixture.b.withReadLock(footprint: [.claudeMCPLocal]) {
      attempts += 1
      let target = try fixture.b.nativeTarget(for: .claudeMCPLocal)
      let receipt = try fixture.b.materializationReceipt(for: target)
      if attempts == 1 {
        #expect(receipt == nil)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
          defer { finished.signal() }
          do {
            try writer.withLock(footprint: [.claudeMCPLocal]) {
              let target = try writer.nativeTarget(for: .claudeMCPLocal)
              let transaction = FileTransaction(store: writer)
              try transaction.replacePrivate(
                try writer.preparePrivateMaterialization(target), provider: SharedBindings()
              ) { _ in
                Data("secret sibling; concurrently installed".utf8)
              }
              try transaction.commit()
            }
          } catch { Issue.record(error) }
        }
        try #require(finished.wait(timeout: .now() + 10) == .success)
        if throwFirst { throw CoreError.invalidState("discarded unlocked inspection") }
      }
      return receipt != nil
    }
    #expect(attempts == 2)
    #expect(result)
  }

  @Test func aSharedTransactionCannotEscapeItsHeldContext() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try FileSnapshot.read(at: fixture.target)
    let provider = SharedBindings()
    var escaped: FileTransaction?
    let missingRoot = AgentRegistry.installSkillsDirectory(
      for: .claudeCode, scope: .project, environment: fixture.a.environment)
    #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: fixture.a)
      try transaction.replace(missingRoot.appendingPathComponent("escaped"), with: .data(Data()))
      try transaction.replacePrivate(
        try fixture.a.preparePrivateMaterialization(target), bindings: ["secret"],
        provider: provider
      ) { try $0.value(for: "secret") }
      escaped = transaction
    }
    #expect(throws: CoreError.self) { try escaped?.commit() }
    #expect(provider.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    #expect(try FileSnapshot.read(at: fixture.target) == before)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.a.directory.appendingPathComponent("transaction.json").path))
  }

  @Test func recoveryCannotCreateANewCoordinationDomainFromAChangedRuntime() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.ready"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let wrong = fixture.root.appendingPathComponent("missing-config")
    var environment = fixture.a.environment
    environment.environment["CLAUDE_CONFIG_DIR"] = wrong.path
    let relocated = StateStore(scope: .project, environment: environment)
    let journal = try Data(
      contentsOf: fixture.a.directory.appendingPathComponent("transaction.json"))
    let target = try FileSnapshot.read(at: fixture.target)
    #expect { try relocated.withLock {} } throws: { error in
      guard case CoreError.invalidState(let message) = error else { return false }
      return message.contains("original registered runtime context")
    }
    #expect(!FileManager.default.fileExists(atPath: wrong.path))
    #expect(
      try Data(contentsOf: fixture.a.directory.appendingPathComponent("transaction.json"))
        == journal)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
  }

  @Test func finalizedCleanupRequiresAConsistentTerminalOutcome() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["shared-edit", "shared.0.reservation.removed"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    var journal = try fixture.journal(fixture.a)
    journal.entries[0].progress = .publishing
    let bytes = try StateStore.encode(journal)
    let url = fixture.a.directory.appendingPathComponent("transaction.json")
    try bytes.write(to: url)
    let target = try FileSnapshot.read(at: fixture.target)
    try fixture.a.withReadLock(
      onPendingRecovery: {
        #expect(FileTransaction.recoveryDiagnostic(store: fixture.a).requiresOwner)
      }, { _ = Issue.record("inconsistent terminal outcome must block inspection") })
    #expect(throws: CoreError.self) { try fixture.a.withLock {} }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try FileSnapshot.read(at: fixture.target) == target)
  }

  @Test(arguments: ["scope", "lock", "coordination-lock"])
  func replacementOfTheHeldScopeOrLockStopsBeforeBindings(_ shape: String) throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try FileSnapshot.read(at: fixture.target)
    let provider = SharedBindings()
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: fixture.a)
      try transaction.replacePrivate(
        try fixture.a.preparePrivateMaterialization(target), bindings: ["secret"],
        provider: provider
      ) {
        try $0.value(for: "secret")
      }
      let original: URL
      if shape == "scope" {
        original = fixture.a.directory
      } else if shape == "lock" {
        original = fixture.a.directory.appendingPathComponent(".agents.lock")
      } else {
        original = try TransactionLockContext.current(fixture.a).requiredResource().metadata!.url
          .appendingPathComponent("lock")
      }
      let retained = fixture.root.appendingPathComponent("retained-scope-lock")
      try FileManager.default.moveItem(at: original, to: retained)
      defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.moveItem(at: retained, to: original)
      }
      if shape == "scope" {
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
      } else {
        try Data().write(to: original)
        try #require(chmod(original.path, 0o600) == 0)
      }
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(provider.calls == 0)
    }
    #expect(try FileSnapshot.read(at: fixture.target) == before)
  }

  @Test func aSharedLockReplacedDuringStagingStopsBeforeTheProvider() throws {
    let fixture = try SharedFixture()
    try fixture.install()
    let before = try FileSnapshot.read(at: fixture.target)
    let provider = SharedBindings()
    try fixture.a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.a.nativeTarget(for: .claudeMCPLocal)
      let metadata = try #require(
        TransactionLockContext.current(fixture.a).requiredResource().metadata)
      let lock = metadata.url.appendingPathComponent("lock")
      let retained = fixture.root.appendingPathComponent("retained-coordination-lock")
      var replaced = false
      let transaction = FileTransaction(store: fixture.a) { point in
        if point == "stage.0.writeCreated" {
          try FileManager.default.moveItem(at: lock, to: retained)
          try Data().write(to: lock)
          try #require(chmod(lock.path, 0o600) == 0)
          replaced = true
        }
      }
      try transaction.replacePrivate(
        try fixture.a.preparePrivateMaterialization(target), bindings: ["secret"],
        provider: provider
      ) {
        try $0.value(for: "secret")
      }
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(replaced && provider.calls == 0)
      try FileManager.default.removeItem(at: lock)
      try FileManager.default.moveItem(at: retained, to: lock)
      #expect(try FileTransaction.recover(store: fixture.a))
    }
    #expect(try FileSnapshot.read(at: fixture.target) == before)
  }

  @Test func readOnlyFootprintsCreateNoMetadataOrScopeLock() throws {
    let fixture = try SharedFixture()
    let before = try FileSnapshot.read(at: fixture.config)
    try fixture.b.withReadLock(footprint: [.claudeMCPLocal]) {
      let target = try fixture.b.nativeTarget(for: .claudeMCPLocal)
      #expect(try fixture.b.materializationReceipt(for: target) == nil)
    }
    #expect(try FileSnapshot.read(at: fixture.config) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.b.directory.path))
  }

}

private final class SharedBindings: RuntimeBindingProvider {
  var calls = 0
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    calls += 1
    return Data("secret sibling; initial region".utf8)
  }
}

private final class SharedFixture {
  let base: TransactionFixture
  var root: URL { base.root }
  let a: StateStore
  let b: StateStore
  let user: StateStore
  let config: URL
  var target: URL { config.appendingPathComponent(".claude.json") }

  init() throws {
    base = try TransactionFixture()
    config = base.root.appendingPathComponent("configured-claude")
    let other = base.root.appendingPathComponent("B")
    let home = base.root.appendingPathComponent("other-home")
    for url in [config, other, home, base.root.appendingPathComponent("old-data")] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try Data("ordinary before".utf8).write(
      to: base.root.appendingPathComponent("old-data/AGENTS.md"))
    let alias = base.root.appendingPathComponent("config-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
    a = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: base.root,
        homeDirectory: base.root.appendingPathComponent("home"),
        environment: ["CLAUDE_CONFIG_DIR": config.path]))
    b = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: other,
        homeDirectory: home, environment: ["CLAUDE_CONFIG_DIR": alias.path]))
    user = StateStore(
      scope: .user,
      environment: RuntimeEnvironment(
        projectDirectory: other,
        homeDirectory: config, environment: [:]))
  }

  func install() throws {
    try a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try a.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: a)
      try transaction.replacePrivate(
        try a.preparePrivateMaterialization(target), provider: SharedBindings()
      ) { _ in
        Data("secret sibling; initial region".utf8)
      }
      try transaction.commit()
    }
  }

  func identity(_ store: StateStore) throws -> SharedResourceIdentity {
    try store.withReadLock(footprint: [.claudeMCPUser]) {
      try TransactionLockContext.current(store).requiredResource().identity
    }
  }

  func receiptURL() throws -> URL {
    let identity = try SharedResource(store: a, create: false).identity
    return config.appendingPathComponent(SharedResource.metadataName).appendingPathComponent(
      identity.directoryName
    ).appendingPathComponent("receipt")
  }

  func journal(_ store: StateStore) throws -> TransactionJournal {
    try StateStore.decode(
      Data(contentsOf: store.directory.appendingPathComponent("transaction.json")),
      as: TransactionJournal.self)
  }
}
