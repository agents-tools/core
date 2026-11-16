import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Private materialization transactions")
struct PrivateMaterializationTests {
  @Test func preparationIsSymbolicAndAccessChangesAreExplicit() throws {
    let fixture = try TransactionFixture()
    let target = try fixture.store.materializationTarget(
      at: fixture.root.appendingPathComponent("AGENTS.md"))
    let provider = TestBindings("secret-sentinel")
    try #require(chmod(target.url.path, 0o644) == 0)
    let before = try FileSnapshot.read(at: target.url)
    #expect(throws: CoreError.self) { try fixture.store.preparePrivateMaterialization(target) }
    let prepared = try fixture.store.preparePrivateMaterialization(target, changingAccess: true)
    #expect(prepared.accessChange?.before.mode == 0o644)
    #expect(prepared.accessChange?.mode == 0o600)
    #expect(provider.calls == 0)
    #expect(try FileSnapshot.read(at: target.url) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.materializationReceiptURL.path))
    #expect(throws: CoreError.self) {
      try fixture.store.materializationTarget(
        at: fixture.root.appendingPathComponent("outside.json"))
    }
    #expect(throws: CoreError.self) {
      try fixture.store.materializationTarget(at: fixture.store.resolvedURL)
    }
  }

  @Test(arguments: [false, true])
  func ownerExecuteChangesAreExplicitAndRollbackRestoresTheirMode(_ rollback: Bool) throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent("AGENTS.md")
    try #require(chmod(target.path, 0o700) == 0)
    try fixture.store.withLock {
      let registered = try fixture.store.materializationTarget(at: target)
      #expect(throws: CoreError.self) {
        try fixture.store.preparePrivateMaterialization(registered)
      }
      let prepared = try fixture.store.preparePrivateMaterialization(
        registered, changingAccess: true)
      #expect(prepared.accessChange?.before.mode == 0o700)
      #expect(prepared.accessChange?.mode == 0o600)
      let transaction = FileTransaction(store: fixture.store) { point in
        if rollback && point == "entry.0.applied" {
          throw CoreError.invalidState("interrupt owner mode change")
        }
      }
      try transaction.replacePrivate(prepared, provider: TestBindings("unused")) { _ in
        Data("private-after".utf8)
      }
      if rollback {
        #expect(throws: CoreError.self) { try transaction.commit() }
      } else {
        try transaction.commit()
      }
    }
    #expect(
      try DirectoryHandle(at: fixture.root).accessEvidence("AGENTS.md")?.mode
        == (rollback ? 0o700 : 0o600))
    #expect(
      try Data(contentsOf: target) == Data((rollback ? "old instructions" : "private-after").utf8))
  }

  @Test func privateStagingPrecedesProviderAndReceiptCommitsWithTheTarget() throws {
    let fixture = try TransactionFixture()
    let provider = TestBindings("secret-sentinel")
    var observed = false
    try fixture.store.withLock {
      let target = try fixture.store.materializationTarget(
        at: fixture.root.appendingPathComponent("AGENTS.md"))
      let prepared = try fixture.store.preparePrivateMaterialization(target, changingAccess: true)
      let transaction = FileTransaction(store: fixture.store) { point in
        if point == "stage.0.writeCreated" {
          let journal = try readMaterializationJournal(fixture)
          let container = try DirectoryHandle(at: fixture.root).child(journal.containerName(0))
          let name = TransactionSlot.exchanged.name(0)
          let info = try #require(try container.info(name))
          #expect(info.st_size == 0)
          _ = try container.requirePrivateAccess(name)
          #expect(provider.calls == 0)
          observed = true
        }
      }
      try transaction.replacePrivate(prepared, bindings: ["value"], provider: provider) {
        #expect(!String(reflecting: $0).contains("secret-sentinel"))
        return try $0.value(for: "value")
      }
      #expect(provider.calls == 0)
      try transaction.commit()
    }
    #expect(observed && provider.calls == 1)
    let record = try #require(
      try fixture.store.materializationReceipts().records.targets["instructions-project/AGENTS.md"])
    #expect(
      try Data(contentsOf: fixture.root.appendingPathComponent("AGENTS.md"))
        == Data("secret-sentinel".utf8))
    let parent = try DirectoryHandle(at: fixture.root)
    _ = try parent.requirePrivateAccess("AGENTS.md", matching: record.access)
    _ = try DirectoryHandle(at: fixture.store.directory).requirePrivateAccess(
      MaterializationReceipts.fileName)
    let receipt = try Data(contentsOf: fixture.store.materializationReceiptURL)
    #expect(!String(decoding: receipt, as: UTF8.self).contains("secret-sentinel"))
    #expect(try !TransactionJournal.isPresent(in: DirectoryHandle(at: fixture.store.directory)))
  }

  @Test(arguments: ["target-mode", "target-acl", "ancestor", "provider", "renderer"])
  func staleAccessAndValueFailuresPublishNothingAndNeverExposeValues(_ kind: String) throws {
    let fixture = try TransactionFixture()
    let provider = TestBindings("secret-error-sentinel")
    let targetURL = fixture.root.appendingPathComponent("AGENTS.md")
    try #require(chmod(targetURL.path, 0o644) == 0)
    var errorText = ""
    try fixture.store.withLock {
      let target = try fixture.store.materializationTarget(at: targetURL)
      let prepared = try fixture.store.preparePrivateMaterialization(target, changingAccess: true)
      let transaction = FileTransaction(store: fixture.store)
      try transaction.replacePrivate(prepared, bindings: ["value"], provider: provider) { values in
        if kind == "renderer" { throw CoreError.invalidState("secret-error-sentinel") }
        return try values.value(for: "value")
      }
      switch kind {
      case "target-mode": try #require(chmod(targetURL.path, 0o640) == 0)
      case "target-acl": try setFixtureMetadata(targetURL, mode: 0o644, value: Data())
      case "ancestor": try #require(chmod(fixture.root.path, 0o775) == 0)
      case "provider": provider.fails = true
      default: break
      }
      do {
        try transaction.commit()
        Issue.record("expected private materialization refusal")
      } catch { errorText = String(describing: error) }
      #expect(!errorText.contains("secret-error-sentinel"))
    }
    #expect(!errorText.isEmpty)
    #expect(try Data(contentsOf: targetURL) == Data("old instructions".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.materializationReceiptURL.path))
    #expect(provider.calls == (["provider", "renderer"].contains(kind) ? 1 : 0))
  }

  @Test(arguments: [false, true])
  func ordinaryRegionEditsKeepSensitiveSiblingsAndPrivateReceipt(_ digestMatches: Bool) throws {
    let fixture = try TransactionFixture()
    try installPrivate("secret sibling; region before", in: fixture)
    let target = try fixture.store.materializationTarget(
      at: fixture.root.appendingPathComponent("AGENTS.md"))
    let before = try fixture.store.preparePrivateMaterialization(target)
    let targetBefore = try FileSnapshot.read(at: target.url)
    let receiptBefore = try Data(contentsOf: fixture.store.materializationReceiptURL)
    let replacement = Data("secret sibling; region after".utf8)
    let expectedHash =
      "sha256:" + FileHash.sha256Hex(data: digestMatches ? replacement : Data("different".utf8))
    var inspected = false
    try fixture.store.withLock {
      let transaction = FileTransaction(store: fixture.store) { point in
        if point == "stage.0.writeCreated" {
          let journal = try readMaterializationJournal(fixture)
          let container = target.url.deletingLastPathComponent().appendingPathComponent(
            journal.containers[0].name)
          let handle = try DirectoryHandle(at: container)
          let access = try handle.requirePrivateAccess("entry.0.exchanged")
          #expect(access.mode == 0o600)
          #expect(try handle.read("entry.0.exchanged").isEmpty)
          inspected = true
        }
      }
      try transaction.replace(target.url, with: .data(replacement), expectedHash: expectedHash)
      if digestMatches {
        try transaction.commit()
      } else {
        #expect(throws: CoreError.invalidState("staged content digest mismatch")) {
          try transaction.commit()
        }
      }
    }
    #expect(inspected)
    if !digestMatches {
      #expect(try FileSnapshot.read(at: target.url) == targetBefore)
      #expect(try Data(contentsOf: fixture.store.materializationReceiptURL) == receiptBefore)
      #expect(
        try fixture.store.preparePrivateMaterialization(
          target, requiringReceiptForExistingTarget: true
        ).receiptGeneration == before.receiptGeneration)
      return
    }
    #expect(try Data(contentsOf: target.url) == Data("secret sibling; region after".utf8))
    let after = try fixture.store.preparePrivateMaterialization(
      target, requiringReceiptForExistingTarget: true)
    #expect(after.receiptGeneration != before.receiptGeneration)
    #expect(throws: CoreError.self) { try before.evidence.validate() }
  }

  @Test func wholeFileDeletionRemovesSensitiveReceipt() throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let target = fixture.root.appendingPathComponent("AGENTS.md")
    try fixture.store.withLock {
      let transaction = FileTransaction(store: fixture.store)
      try transaction.delete(target)
      try transaction.commit()
    }
    #expect(try fixture.store.materializationReceipts().records.targets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }

  @Test(arguments: [
    "containers.identified", "stage.0.writeCreated", "stage.0.constructed", "entry.0.ready",
    "publish.0.exchanged", "entry.0.applied", "entry.1.applied", "journal.committed",
    "disposal.intent", "disposal.0.removed",
  ])
  func killedMaterializationRecoversWithoutCallingProvider(_ point: String) throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let beforeReceipt = try Data(contentsOf: fixture.store.materializationReceiptURL)
    let child = try stateTestProcess(root: fixture.root, arguments: ["private-install", point])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let called = fixture.root.appendingPathComponent("provider-called")
    if FileManager.default.fileExists(atPath: called.path) {
      try FileManager.default.removeItem(at: called)
    } else {
      #expect(["containers.identified", "stage.0.writeCreated"].contains(point))
    }
    let recovery = try stateTestProcess(
      root: fixture.root, arguments: ["private-recover", "never"])
    defer { terminateProcess(recovery) }
    try ProcessWait.exit(recovery, root: fixture.root)
    #expect(recovery.terminationStatus == 0)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("provider-called").path))
    let committed = point == "journal.committed" || point.hasPrefix("disposal.")
    #expect(
      try Data(contentsOf: fixture.root.appendingPathComponent("AGENTS.md"))
        == Data((committed ? "private-after" : "private-before").utf8))
    if !committed {
      #expect(try Data(contentsOf: fixture.store.materializationReceiptURL) == beforeReceipt)
    }
    _ = try fixture.store.materializationReceipts()
    #expect(try !TransactionJournal.isPresent(in: DirectoryHandle(at: fixture.store.directory)))
  }

  @Test func aNewPrivateTargetRollsBackWithoutLeavingAReceipt() throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent("GEMINI.md")
    try fixture.store.withLock {
      let prepared = try fixture.store.preparePrivateMaterialization(
        fixture.store.materializationTarget(at: target))
      #expect(prepared.accessChange == nil)
      let transaction = FileTransaction(store: fixture.store) { point in
        if point == "entry.0.applied" {
          throw CoreError.invalidState("interrupt new private target")
        }
      }
      try transaction.replacePrivate(prepared, provider: TestBindings("unused")) { _ in
        Data("private-new".utf8)
      }
      #expect(throws: CoreError.self) { try transaction.commit() }
    }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.materializationReceiptURL.path))
    #expect(try !TransactionJournal.isPresent(in: DirectoryHandle(at: fixture.store.directory)))
  }

  @Test func changedStagingAccessStopsBeforeResolvingBindings() throws {
    let fixture = try TransactionFixture()
    let provider = TestBindings("must-not-be-read")
    #expect(throws: CoreError.self) {
      try fixture.store.withLock {
        let prepared = try fixture.store.preparePrivateMaterialization(
          fixture.store.materializationTarget(at: fixture.root.appendingPathComponent("AGENTS.md")),
          changingAccess: true)
        let transaction = FileTransaction(store: fixture.store) { point in
          if point == "stage.0.writeCreated" {
            let journal = try readMaterializationJournal(fixture)
            let file = fixture.root.appendingPathComponent(journal.containerName(0))
              .appendingPathComponent("entry.0.exchanged")
            try #require(chmod(file.path, 0o644) == 0)
          }
        }
        try transaction.replacePrivate(prepared, bindings: ["value"], provider: provider) {
          try $0.value(for: "value")
        }
        try transaction.commit()
      }
    }
    #expect(provider.calls == 0)
    #expect(
      try Data(contentsOf: fixture.root.appendingPathComponent("AGENTS.md"))
        == Data("old instructions".utf8))
  }

  @Test(arguments: [
    "restore.1.exchanged", "restore.0.exchanged", "journal.rolledBack", "disposal.0.removed",
  ])
  func recoveryCanBeKilledAndRepeatedWithoutResolvingBindings(_ point: String) throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let originalReceipt = try Data(contentsOf: fixture.store.materializationReceiptURL)
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["private-install", "entry.1.applied"])
    defer { terminateProcess(child) }
    let marker = fixture.root.appendingPathComponent("ready")
    try ProcessWait.marker(marker, child: child, root: fixture.root)
    terminateProcess(child)
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("provider-called"))
    let first = try stateTestProcess(root: fixture.root, arguments: ["private-recover", point])
    defer { terminateProcess(first) }
    try ProcessWait.marker(marker, child: first, root: fixture.root)
    terminateProcess(first)
    let second = try stateTestProcess(root: fixture.root, arguments: ["private-recover", "never"])
    defer { terminateProcess(second) }
    try ProcessWait.exit(second, root: fixture.root)
    #expect(second.terminationStatus == 0)
    #expect(
      try Data(contentsOf: fixture.root.appendingPathComponent("AGENTS.md"))
        == Data("private-before".utf8))
    #expect(try Data(contentsOf: fixture.store.materializationReceiptURL) == originalReceipt)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("provider-called").path))
    #expect(try !TransactionJournal.isPresent(in: DirectoryHandle(at: fixture.store.directory)))
  }

  @Test(arguments: ["target", "backup", "ancestor", "restore-race"])
  func unsafeSensitiveRecoveryRetainsJournalAndPrivateEvidence(_ change: String) throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["private-install", "entry.0.applied"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let journal = try readMaterializationJournal(fixture)
    let backup = fixture.root.appendingPathComponent(journal.containerName(0))
      .appendingPathComponent("entry.0.exchanged")
    if change == "target" {
      try #require(chmod(fixture.root.appendingPathComponent("AGENTS.md").path, 0o644) == 0)
    }
    if change == "backup" { try #require(chmod(backup.path, 0o644) == 0) }
    if change == "ancestor" { try #require(chmod(fixture.root.path, 0o775) == 0) }
    #expect(throws: (any Error).self) {
      try fixture.store.withLock(
        checkpoint: { point in
          if change == "restore-race" && point == "restore.0.validated" {
            try #require(chmod(backup.path, 0o644) == 0)
          }
        }, {})
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent(TransactionJournal.fileName).path))
    #expect(try Data(contentsOf: backup) == Data("private-before".utf8))
    #expect(
      try Data(contentsOf: fixture.root.appendingPathComponent("AGENTS.md"))
        == Data("private-after".utf8))
  }

  @Test func receiptInspectionAndExpectedGenerationsDoNotExposeValues() throws {
    let fixture = try TransactionFixture()
    try installPrivate("receipt-secret-sentinel", in: fixture)
    let target = try fixture.store.materializationTarget(
      at: fixture.root.appendingPathComponent("AGENTS.md"))
    let first = try #require(try fixture.store.materializationReceipt(for: target))
    let prepared = try fixture.store.preparePrivateMaterialization(
      target, expecting: first.generation)
    let same = try fixture.store.preparePrivateMaterialization(target, expecting: first.generation)
    #expect(try prepared.accessFingerprint() == same.accessFingerprint())
    #expect(!String(reflecting: first).contains("receipt-secret-sentinel"))
    try installPrivate("rotated-private-value", in: fixture)
    #expect(throws: CoreError.self) {
      try fixture.store.preparePrivateMaterialization(target, expecting: first.generation)
    }
    let second = try #require(try fixture.store.materializationReceipt(for: target))
    #expect(second.generation != first.generation)
    try FileManager.default.removeItem(at: fixture.store.materializationReceiptURL)
    #expect(throws: CoreError.self) {
      try fixture.store.preparePrivateMaterialization(
        target, requiringReceiptForExistingTarget: true)
    }
  }

  @Test func receiptWritesAreReservedAcrossLogicalAndPhysicalRootAliases() throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let before = try Data(contentsOf: fixture.store.materializationReceiptURL)
    let alias = fixture.root.appendingPathComponent("project-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let aliased = StateStore(
      scope: .project, environment: RuntimeEnvironment(projectDirectory: alias))
    let transaction = FileTransaction(store: aliased)
    #expect(throws: CoreError.self) {
      try transaction.replace(
        fixture.store.materializationReceiptURL.resolvingSymlinksInPath(), with: .data(Data()))
    }
    #expect(try Data(contentsOf: fixture.store.materializationReceiptURL) == before)
  }

  @Test func anAbsentRecordedTargetCanBeRestoredAndItsReceiptCanBeRemoved() throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let target = fixture.root.appendingPathComponent("AGENTS.md")
    try FileManager.default.removeItem(at: target)
    try fixture.store.withLock {
      let prepared = try fixture.store.preparePrivateMaterialization(
        fixture.store.materializationTarget(at: target), requiringReceiptForExistingTarget: true)
      let transaction = FileTransaction(store: fixture.store)
      try transaction.replacePrivate(
        prepared, bindings: ["value"], provider: TestBindings("restored-private")
      ) { try $0.value(for: "value") }
      try transaction.commit()
    }
    #expect(try Data(contentsOf: target) == Data("restored-private".utf8))
    try FileManager.default.removeItem(at: target)
    try fixture.store.withLock {
      let transaction = FileTransaction(store: fixture.store)
      try transaction.delete(target)
      try transaction.commit()
    }
    #expect(try fixture.store.materializationReceipts().records.targets.isEmpty)
  }

  @Test func lastPublicationCheckCannotCopyChangedTargetAccessOntoSecretBytes() throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent("AGENTS.md")
    try #require(chmod(target.path, 0o644) == 0)
    #expect(throws: CoreError.self) {
      try fixture.store.withLock {
        let prepared = try fixture.store.preparePrivateMaterialization(
          fixture.store.materializationTarget(at: target), changingAccess: true)
        let transaction = FileTransaction(store: fixture.store) { point in
          if point == "publish.0.validated" { try #require(chmod(target.path, 0o640) == 0) }
        }
        try transaction.replacePrivate(
          prepared, bindings: ["value"], provider: TestBindings("unpublished-secret")
        ) { try $0.value(for: "value") }
        try transaction.commit()
      }
    }
    #expect(try Data(contentsOf: target) == Data("old instructions".utf8))
    let journal = try readMaterializationJournal(fixture)
    let container = try DirectoryHandle(at: fixture.root).child(journal.containerName(0))
    _ = try container.requirePrivateAccess("entry.0.exchanged")
    #expect(try container.read("entry.0.exchanged") == Data("unpublished-secret".utf8))
  }

  @Test(arguments: ["security", "preimageAccess", "ancestry", "version"])
  func missingSecurityEvidenceCannotRecoverOrMutateObjects(_ field: String) throws {
    let fixture = try TransactionFixture()
    try installPrivate("private-before", in: fixture)
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["private-install", "entry.0.applied"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let path = fixture.store.directory.appendingPathComponent(TransactionJournal.fileName)
    var value = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    if field == "version" {
      value["version"] = 1
    } else {
      var entries = try #require(value["entries"] as? [[String: Any]])
      if field == "security" {
        entries[0].removeValue(forKey: field)
      } else {
        var security = try #require(entries[0]["security"] as? [String: Any])
        security.removeValue(forKey: field)
        entries[0]["security"] = security
      }
      value["entries"] = entries
    }
    try JSONSerialization.data(withJSONObject: value).write(to: path)
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(throws: (any Error).self) { try fixture.store.withLock {} }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }
}

private final class TestBindings: RuntimeBindingProvider {
  let value: String
  var calls = 0
  var fails = false
  init(_ value: String) { self.value = value }
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    calls += 1
    if fails { throw CoreError.invalidState(value) }
    return Data(value.utf8)
  }
}

private func installPrivate(_ value: String, in fixture: TransactionFixture) throws {
  try fixture.store.withLock {
    let target = try fixture.store.materializationTarget(
      at: fixture.root.appendingPathComponent("AGENTS.md"))
    let prepared = try fixture.store.preparePrivateMaterialization(target, changingAccess: true)
    let transaction = FileTransaction(store: fixture.store)
    try transaction.replacePrivate(prepared, bindings: ["value"], provider: TestBindings(value)) {
      try $0.value(for: "value")
    }
    try transaction.commit()
  }
}

private func readMaterializationJournal(_ fixture: TransactionFixture) throws -> TransactionJournal
{
  try StateStore.decode(
    Data(contentsOf: fixture.store.directory.appendingPathComponent(TransactionJournal.fileName)),
    as: TransactionJournal.self)
}
