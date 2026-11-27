import CPlatform
import Foundation
import StateTestSupport
import Synchronization
import Testing

@testable import AgentsCore

@Suite("Private native array continuity receipts")
struct NativeArrayReceiptTests {
  private let original = Data(#"{"hooks":["private-value"],"sibling":0}"#.utf8)
  private let sibling = Data(#"{"hooks":["private-value"],"sibling":1}"#.utf8)

  private func array(_ key: String = "hooks", token: UUID = UUID(), digest: String = "array")
    -> PrivateNativeArrayRecord
  {
    .init(
      path: [.key(key)], documentFormat: "json", token: token,
      semanticDigest: "sha256:" + FileHash.sha256Hex(data: Data(digest.utf8)))
  }

  private func install(
    _ bytes: Data, arrays: [PrivateNativeArrayRecord], target: MaterializationTarget,
    store: StateStore
  ) throws {
    let transaction = FileTransaction(store: store)
    try transaction.replacePrivate(
      store.preparePrivateMaterialization(target), provider: NoArrayBindings(),
      produce: { _ in
        .init(
          bytes: bytes, nativeArrayTransitions: arrays.map { .init(previous: nil, current: $0) })
      })
    try transaction.commit()
  }

  @Test func overlappingCreatedAncestryUsesOriginalAccessAndStillRefusesRealDrift() throws {
    let fixture = try TransactionFixture()
    let store = StateStore(scope: .user, environment: fixture.store.environment)
    try FileManager.default.createDirectory(
      at: store.environment.homeDirectory, withIntermediateDirectories: true)
    let named = try NativeTargetRoute.named(.codexAgent, scope: .user, name: "review")
    var before = ""
    try store.withReadLock(footprint: [.codexMCPUser, named]) {
      before = try TargetPrecondition(store.nativeTarget(for: named).url).displayEvidence(
        includeContent: false)
    }
    try store.withLock(footprint: [.codexMCPUser, named]) {
      let target = try store.nativeTarget(for: named)
      #expect(try TargetPrecondition(target.url).displayEvidence(includeContent: false) == before)
      let parent = store.environment.homeDirectory
      let mode = try #require(
        try DirectoryHandle(at: parent.deletingLastPathComponent()).accessEvidence(
          parent.lastPathComponent)
      ).mode
      defer { _ = chmod(parent.path, mode) }
      try #require(chmod(parent.path, mode ^ 0o010) == 0)
      #expect(throws: CoreError.self) {
        try TargetPrecondition(target.url).displayEvidence(includeContent: false)
      }
    }
  }

  @Test func actualArrayProducerReceivesBindingsOnlyAfterVerifiedEmptyPrivateStage() throws {
    let fixture = try TransactionFixture()
    let provider = StagedArrayBindings()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: store) { point in
        if point == "stage.0.writeCreated" {
          let journal = try StateStore.decode(
            Data(contentsOf: store.directory.appendingPathComponent(TransactionJournal.fileName)),
            as: TransactionJournal.self)
          let parent = try DirectoryHandle(at: target.url.deletingLastPathComponent())
          let container = try parent.child(journal.containerName(0))
          let slot = TransactionSlot.staging(for: journal.entries[0]).name(0)
          _ = try container.requirePrivateAccess(slot)
          #expect(try container.read(slot).isEmpty)
          provider.ready.withLock { $0 = true }
        }
      }
      try transaction.replacePrivate(
        store.preparePrivateMaterialization(target), bindings: ["value"], provider: provider,
        produce: { values in
          let bytes = try values.value(for: "value")
          return .init(
            bytes: bytes, nativeArrayTransitions: [.init(previous: nil, current: array())])
        })
      try transaction.commit()
      #expect(try store.materializationReceipt(for: target)?.nativeArrays?.count == 1)
    }
  }

  @Test func siblingGenerationPreservesContinuityAndExactNoOpNeedsNoTransition() throws {
    let fixture = try TransactionFixture()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let record = array()
      try install(original, arrays: [record], target: target, store: store)
      let first = try #require(try store.materializationReceipt(for: target))
      let accessFingerprint = try store.preparePrivateMaterialization(target).accessFingerprint()
      let transaction = FileTransaction(store: store)
      try transaction.replace(
        target.url, with: .data(sibling),
        nativeArrayTransitions: [.init(previous: record, current: record)])
      try transaction.commit()
      let next = try #require(try store.materializationReceipt(for: target))
      #expect(next.generation != first.generation)
      #expect(next.nativeArrays == [record])
      #expect(
        try store.preparePrivateMaterialization(target).accessFingerprint() == accessFingerprint)
      #expect(throws: CoreError.self) {
        try store.preparePrivateMaterialization(target, expecting: first.generation)
      }
      let noOp = FileTransaction(store: store)
      try noOp.replace(target.url, with: .data(sibling))
      try noOp.commit()
      #expect(try store.materializationReceipt(for: target)?.nativeArrays == [record])
      let raw = try store.materializationReceipts(for: target.path)
      #expect(raw.records.version == 2)
      #expect(!String(reflecting: next).contains(record.semanticDigest))
      #expect(
        !String(reflecting: PrivateMaterializationResult(bytes: original)).contains("private-value")
      )
      _ = try DirectoryHandle(at: target.url.deletingLastPathComponent()).requirePrivateAccess(
        target.url.lastPathComponent)
    }
  }

  @Test func anotherScopeUsesTheSamePhysicalArrayReceiptThroughAnAlias() throws {
    let fixture = try TransactionFixture()
    let config = fixture.root.appendingPathComponent("config")
    let alias = fixture.root.appendingPathComponent("config-alias")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
    var aEnvironment = fixture.store.environment
    aEnvironment.environment["CLAUDE_CONFIG_DIR"] = config.path
    var bEnvironment = aEnvironment
    bEnvironment.environment["CLAUDE_CONFIG_DIR"] = alias.path
    bEnvironment.homeDirectory = fixture.root.appendingPathComponent("other-home")
    try FileManager.default.createDirectory(
      at: bEnvironment.homeDirectory, withIntermediateDirectories: true)
    let a = StateStore(scope: .project, environment: aEnvironment)
    let b = StateStore(scope: .user, environment: bEnvironment)
    let record = array()
    var generation: UUID?
    var receiptURL: URL!
    try a.withLock(footprint: [.claudeMCPLocal]) {
      let target = try a.nativeTarget(for: .claudeMCPLocal)
      try install(original, arrays: [record], target: target, store: a)
      generation = try a.materializationReceipt(for: target)?.generation
      receiptURL = try a.materializationReceipts(for: target.path).url
    }
    try b.withLock(footprint: [.claudeMCPUser]) {
      let target = try b.nativeTarget(for: .claudeMCPUser)
      #expect(try b.materializationReceipt(for: target)?.nativeArrays == [record])
      #expect(
        try b.materializationReceipts(for: target.path).url.resolvingSymlinksInPath()
          == receiptURL.resolvingSymlinksInPath())
      let transaction = FileTransaction(store: b)
      try transaction.replace(
        target.url, with: .data(sibling),
        nativeArrayTransitions: [.init(previous: record, current: record)])
      try transaction.commit()
    }
    try a.withReadLock(footprint: [.claudeMCPLocal]) {
      let target = try a.nativeTarget(for: .claudeMCPLocal)
      #expect(throws: CoreError.self) {
        try a.preparePrivateMaterialization(target, expecting: generation)
      }
      #expect(try a.materializationReceipt(for: target)?.nativeArrays == [record])
    }
    #expect(!FileManager.default.fileExists(atPath: a.materializationReceiptURL.path))
    #expect(!FileManager.default.fileExists(atPath: b.materializationReceiptURL.path))
  }

  @Test(arguments: [
    "missing", "duplicate", "wrong-path", "same-token-change", "unsupported", "incomplete",
    "over-depth", "private-error", "mixed-format", "newline-digest",
  ])
  func invalidTransitionsPublishNothing(_ kind: String) throws {
    let fixture = try TransactionFixture()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let a = array()
      let b = array("other")
      try install(original, arrays: [a, b], target: target, store: store)
      let state = try store.materializationReceipts(for: target.path)
      let receipt = try Data(contentsOf: state.url)
      var transitions: [PrivateNativeArrayTransition]? = [
        .init(previous: a, current: a), .init(previous: b, current: b),
      ]
      switch kind {
      case "missing": transitions = nil
      case "duplicate": transitions!.append(.init(previous: a, current: a))
      case "wrong-path":
        transitions![0] = .init(previous: array("wrong", token: a.token), current: a)
      case "same-token-change":
        transitions![0] = .init(previous: a, current: array(token: a.token, digest: "changed"))
      case "unsupported":
        transitions![0] = .init(
          previous: a,
          current: .init(
            path: a.path, documentFormat: "yaml", token: UUID(), semanticDigest: a.semanticDigest))
      case "mixed-format":
        transitions![0] = .init(
          previous: a,
          current: .init(
            path: a.path, documentFormat: "toml", token: UUID(), semanticDigest: a.semanticDigest))
      case "over-depth":
        transitions![0] = .init(
          previous: a,
          current: .init(
            path: Array(repeating: .key("nested"), count: LedgerLimits.standard.depth + 1),
            documentFormat: "json", token: UUID(), semanticDigest: a.semanticDigest))
      case "newline-digest":
        transitions![0] = .init(
          previous: a,
          current: .init(
            path: a.path, documentFormat: "json", token: UUID(),
            semanticDigest: a.semanticDigest + "\n"))
      case "private-error":
        transitions![0] = .init(
          previous: a,
          current: .init(
            path: a.path, documentFormat: "json", token: UUID(),
            semanticDigest: "private-error-must-not-escape"))
      default: transitions!.removeLast()
      }
      let transaction = FileTransaction(store: store)
      try transaction.replace(target.url, with: .data(sibling), nativeArrayTransitions: transitions)
      do {
        try transaction.commit()
        Issue.record("expected transition refusal")
      } catch {
        #expect(!String(describing: error).contains("private-error-must-not-escape"))
      }
      #expect(try Data(contentsOf: target.url) == original)
      #expect(try Data(contentsOf: state.url) == receipt)
      #expect(try !TransactionJournal.isPresent(in: DirectoryHandle(at: store.directory)))
    }
  }

  @Test(arguments: [false, true])
  func arrayRotationRollbackAndWholeFileDeletionAreAtomic(_ rollback: Bool) throws {
    let fixture = try TransactionFixture()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let old = array()
      let changed = array(digest: "changed")
      try install(original, arrays: [old], target: target, store: store)
      let state = try store.materializationReceipts(for: target.path)
      let receipt = try Data(contentsOf: state.url)
      let transaction = FileTransaction(store: store) { point in
        if rollback && point == "entry.1.applied" {
          throw CoreError.invalidState("injected receipt publication failure")
        }
      }
      try transaction.replace(
        target.url, with: .data(sibling),
        nativeArrayTransitions: [.init(previous: old, current: changed)])
      if rollback {
        #expect(throws: CoreError.self) { try transaction.commit() }
        #expect(try Data(contentsOf: target.url) == original)
        #expect(try Data(contentsOf: state.url) == receipt)
        #expect(try store.materializationReceipt(for: target)?.nativeArrays == [old])
      } else {
        try transaction.commit()
        #expect(try store.materializationReceipt(for: target)?.nativeArrays == [changed])
        let clear = FileTransaction(store: store)
        try clear.replace(
          target.url, with: .data(sibling),
          nativeArrayTransitions: [.init(previous: changed, current: nil)])
        try clear.commit()
        #expect(try store.materializationReceipts(for: target.path).records.version == 2)
        #expect(try store.materializationReceipt(for: target)?.nativeArrays == nil)
        let deletion = FileTransaction(store: store)
        try deletion.delete(target.url)
        try deletion.commit()
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
      }
    }
  }

  @Test func missingTargetNeedsExplicitFreshArrayEvidence() throws {
    let fixture = try TransactionFixture()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let old = array()
      let fresh = array()
      try install(original, arrays: [old], target: target, store: store)
      try FileManager.default.removeItem(at: target.url)
      #expect(throws: CoreError.self) {
        try FileTransaction(store: store).replace(target.url, with: .data(original))
      }
      let stale = FileTransaction(store: store)
      try stale.replacePrivate(
        store.preparePrivateMaterialization(target), provider: NoArrayBindings(),
        produce: { _ in
          .init(bytes: original, nativeArrayTransitions: [.init(previous: old, current: old)])
        })
      #expect(throws: CoreError.self) { try stale.commit() }
      #expect(!FileManager.default.fileExists(atPath: target.url.path))
      let restore = FileTransaction(store: store)
      try restore.replacePrivate(
        store.preparePrivateMaterialization(target), provider: NoArrayBindings(),
        produce: { _ in
          .init(bytes: original, nativeArrayTransitions: [.init(previous: old, current: fresh)])
        })
      try restore.commit()
      #expect(try store.materializationReceipt(for: target)?.nativeArrays == [fresh])
    }
  }

  @Test(arguments: ["stage.0.constructed", "entry.1.applied", "journal.committed"])
  func restartRecoversSealedArrayReceiptWithoutAProducer(_ point: String) throws {
    let fixture = try TransactionFixture()
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent("configured-claude").path
    let store = StateStore(scope: .project, environment: environment)
    let record = array()
    var targetURL: URL!
    var receiptURL: URL!
    var previousReceipt = Data()
    try store.withLock(footprint: [.claudeMCPLocal]) {
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      targetURL = target.url
      try install(original, arrays: [record], target: target, store: store)
      receiptURL = try store.materializationReceipts(for: target.path).url
      previousReceipt = try Data(contentsOf: receiptURL)
    }
    let child = try stateTestProcess(root: fixture.root, arguments: ["shared-array-edit", point])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let before = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: store).requiresOwner)
      }, { Issue.record("expected pending array transaction") })
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    let committed = point == "journal.committed"
    #expect(try Data(contentsOf: targetURL) == (committed ? sibling : original))
    if !committed { #expect(try Data(contentsOf: receiptURL) == previousReceipt) }
    try store.withReadLock(footprint: [.claudeMCPLocal]) {
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      #expect(try store.materializationReceipt(for: target)?.nativeArrays == [record])
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("provider-called").path))
  }

  @Test func receiptVersionsAndNestedFieldsAreStrictAndUTF8AddressesStayDistinct() throws {
    let fixture = try TransactionFixture()
    try fixture.store.withLock(footprint: [.claudeMCPLocal]) {
      let store = fixture.store
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivate(
        store.preparePrivateMaterialization(target), provider: NoArrayBindings()
      ) { _ in original }
      try transaction.commit()
      let v1 = try store.materializationReceipts(for: target.path)
      #expect(v1.records.version == 1)
      #expect(
        try StateStore.decode(Data(contentsOf: v1.url), as: MaterializationReceipts.self).version
          == 1)
      let records = [array("\u{e9}"), array("e\u{301}")]
      #expect(records[0].path != records[1].path)
      let upgrade = FileTransaction(store: store)
      try upgrade.replace(
        target.url, with: .data(original),
        nativeArrayTransitions: records.map { .init(previous: nil, current: $0) })
      try upgrade.commit()
      let bytes = try Data(contentsOf: v1.url)
      let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      func refuses(_ edit: (inout [String: Any]) -> Void) throws {
        var value = object
        edit(&value)
        let data = try JSONSerialization.data(withJSONObject: value)
        #expect(throws: (any Error).self) {
          let decoded = try StateStore.decode(data, as: MaterializationReceipts.self)
          try decoded.validate(store: store)
        }
      }
      try refuses { $0["version"] = 1 }
      try refuses { $0["unknown"] = NSNull() }
      for kind in ["record", "step", "duplicate", "negative", "digest", "null"] {
        try refuses { value in
          var targets = value["targets"] as! [String: Any]
          let key = targets.keys.first!
          var record = targets[key] as! [String: Any]
          var arrays = record["nativeArrays"] as! [[String: Any]]
          switch kind {
          case "record": arrays[0]["unknown"] = NSNull()
          case "step":
            var path = arrays[0]["path"] as! [[String: Any]]
            path[0]["unknown"] = NSNull()
            arrays[0]["path"] = path
          case "duplicate": arrays.append(arrays[0])
          case "negative": arrays[0]["path"] = [["kind": "position", "index": -1]]
          case "digest": arrays[0]["semanticDigest"] = "invalid"
          default: record["nativeArrays"] = NSNull()
          }
          if kind != "null" { record["nativeArrays"] = arrays }
          targets[key] = record
          value["targets"] = targets
        }
      }
    }
  }
}

private struct NoArrayBindings: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    throw CoreError.invalidState("unexpected binding request")
  }
}

private final class StagedArrayBindings: RuntimeBindingProvider {
  let ready = Mutex(false)
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    guard ready.withLock({ $0 }) else {
      throw CoreError.invalidState("private stage was not verified")
    }
    return Data(#"{"hooks":["private-value"],"sibling":0}"#.utf8)
  }
}
