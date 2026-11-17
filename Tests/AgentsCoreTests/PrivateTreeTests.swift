import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Private complete native trees")
struct PrivateTreeTests {
  @Test func completeTreeIsPrivateBeforeProviderAndOrdinarySiblingUpdatesRetainItsReceipt() throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(
      .claudeSkillPlugin, scope: .user, name: "private-fixture")
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent("configured-claude").path
    let store = StateStore(scope: .user, environment: environment)
    var first: UUID?
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let prepared = try store.preparePrivateMaterialization(target)
      let provider = TreeBindings {
        let journal = try treeJournal(store)
        let parent = try DirectoryHandle(at: target.url.deletingLastPathComponent())
        let container = try parent.child(journal.containerName(0))
        let name = TransactionSlot.staging(for: journal.entries[0]).name(0)
        let snapshot = try #require(try FileSnapshot.read(name, from: container))
        _ = try container.requirePrivateAccess(name)
        let members = try #require(
          try TreeMemberAccess.capture(
            name, in: container, snapshot: snapshot, requirePrivate: true))
        #expect(members.map(\.path) == ["bin", "bin/run", "config", "sibling"])
        #expect(try container.child(name).read("config").isEmpty)
        #expect(try container.child(name).child("bin").read("run").isEmpty)
        #expect(members.first { $0.path == "bin/run" }?.access.mode == 0o700)
        return Data("fixture-private".utf8)
      }
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivateTree(prepared, entries: treeEntries(), provider: provider)
      try transaction.commit()
      let receipt = try #require(try store.materializationReceipt(for: target))
      first = receipt.generation
      #expect(receipt.treeAccess?.count == 4)
      #expect(
        try Data(contentsOf: target.url.appendingPathComponent("config"))
          == Data("fixture-private".utf8))
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: target.url.appendingPathComponent("alias").path) == "bin/run")
    }
    // A cold scope has no source/provider need for an ordinary sibling update.
    var other = environment
    other.homeDirectory = fixture.root.appendingPathComponent("other-home")
    try FileManager.default.createDirectory(
      at: other.homeDirectory, withIntermediateDirectories: true)
    let second = StateStore(scope: .user, environment: other)
    try second.withLock(footprint: [route]) {
      let target = try second.nativeTarget(for: route)
      let privateBytes = try Data(contentsOf: target.url.appendingPathComponent("config"))
      let transaction = FileTransaction(store: second)
      #expect(throws: CoreError.self) {
        try transaction.replace(target.url, with: .copy(fixture.root.appendingPathComponent("new")))
      }
      let update = FileTransaction(store: second)
      try update.replacePrivateTree(
        second.preparePrivateMaterialization(target),
        entries: [
          .init("config", content: .file(privateBytes)),
          .init("sibling", content: .file(Data("changed ordinary sibling".utf8))),
        ],
        provider: TreeBindings {
          throw CoreError.invalidState("ordinary edit must not resolve bindings")
        })
      try update.commit()
      let receipt = try #require(try second.materializationReceipt(for: target))
      #expect(receipt.generation != first)
      #expect(receipt.treeAccess?.map(\.path) == ["config", "sibling"])
      let remove = FileTransaction(store: second)
      try remove.delete(target.url)
      try remove.commit()
      #expect(try second.materializationReceipt(for: target) == nil)
    }
  }

  @Test(arguments: ["provider", "entry.0.applied", "entry.1.applied", "journal.committed"])
  func failuresPreserveCompleteGenerationAndReceipt(_ failure: String) throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(
      .cursorLocalPlugin, scope: .user, name: "rollback-fixture")
    let store = StateStore(scope: .user, environment: fixture.store.environment)
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let original = FileTransaction(store: store)
      try original.replacePrivateTree(
        store.preparePrivateMaterialization(target),
        entries: [
          .init("old", content: .file(Data("old-private".utf8)))
        ], provider: TreeBindings { Data() })
      try original.commit()
      let before = try FileSnapshot.read(at: target.url)
      let generation = try store.materializationReceipt(for: target)?.generation
      let outcome = TransactionOutcome()
      let transaction = FileTransaction(store: store, outcome: outcome) { point in
        if point == failure { throw CoreError.invalidState("bounded tree interruption") }
      }
      try transaction.replacePrivateTree(
        store.preparePrivateMaterialization(target), entries: treeEntries(),
        provider: TreeBindings {
          if failure == "provider" { throw CoreError.invalidState("private fixture failure") }
          return Data("new-private".utf8)
        })
      #expect(throws: CoreError.self) { try transaction.commit() }
      if failure == "journal.committed" {
        #expect(outcome.terminal == .committed)
        #expect(try store.materializationReceipt(for: target)?.generation != generation)
        #expect(
          try Data(contentsOf: target.url.appendingPathComponent("config"))
            == Data("new-private".utf8))
      } else {
        #expect(try FileSnapshot.read(at: target.url) == before)
        #expect(try store.materializationReceipt(for: target)?.generation == generation)
      }
      #expect(!outcome.recoveryPending)
      #expect(
        !FileManager.default.fileExists(
          atPath: store.directory.appendingPathComponent("transaction.json").path))
    }
  }

  @Test func accessChangesArePreparedAndInvalidTreesNeverResolveBindings() throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(
      .claudeSkillPlugin, scope: .project, name: "private-plugin")
    try fixture.store.withLock(footprint: [route]) {
      let target = try fixture.store.nativeTarget(for: route)
      try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
      try Data("ordinary".utf8).write(to: target.url.appendingPathComponent("ordinary"))
      try #require(chmod(target.url.path, 0o755) == 0)
      try #require(chmod(target.url.appendingPathComponent("ordinary").path, 0o644) == 0)
      #expect(throws: CoreError.self) { try fixture.store.preparePrivateMaterialization(target) }
      let prepared = try fixture.store.preparePrivateMaterialization(target, changingAccess: true)
      #expect(prepared.accessChange?.mode == 0o700)
      #expect(prepared.memberAccessChanges.map(\.path) == ["ordinary"])
      let before = try FileSnapshot.read(at: target.url)
      let bad: [[PrivateTreeEntry]] = [
        [.init("../escape", content: .file(Data()))],
        [.init("link", content: .symlink(".."))],
        [.init("link", content: .symlink("other")), .init("other", content: .symlink("link"))],
        [.init("link", content: .symlink("missing")), .init("link/file", content: .file(Data()))],
        [.init("duplicate", content: .directory), .init("duplicate", content: .file(Data()))],
      ]
      for entries in bad {
        let transaction = FileTransaction(store: fixture.store)
        #expect(throws: CoreError.self) {
          try transaction.replacePrivateTree(
            prepared, entries: entries,
            provider: TreeBindings { throw CoreError.invalidState("must not resolve") })
        }
      }
      #expect(try FileSnapshot.read(at: target.url) == before)
      let update = FileTransaction(store: fixture.store)
      try update.replacePrivateTree(
        prepared, entries: [.init("safe-dangling", content: .symlink("missing/file"))],
        provider: TreeBindings { Data() })
      try update.commit()
      #expect(try fixture.store.materializationReceipt(for: target)?.treeAccess == [])
    }
  }

  @Test func readOnlyOrdinaryPreimageIsRestoredWithItsAccess() throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .project, name: "read-only")
    try fixture.store.withLock(footprint: [route]) {
      let target = try fixture.store.nativeTarget(for: route)
      try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
      try Data("original".utf8).write(to: target.url.appendingPathComponent("old"))
      try #require(chmod(target.url.path, 0o555) == 0)
      defer { _ = chmod(target.url.path, 0o755) }
      let original = try FileSnapshot.read(at: target.url)
      let transaction = FileTransaction(store: fixture.store) { point in
        if point == "entry.0.applied" { throw CoreError.invalidState("bounded interruption") }
      }
      try transaction.replacePrivateTree(
        fixture.store.preparePrivateMaterialization(target, changingAccess: true),
        entries: [.init("new", content: .file(Data()))], provider: TreeBindings { Data() })
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(try FileSnapshot.read(at: target.url) == original)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
    }
  }

  @Test func changedSealedMemberRetainsRecoveryEvidenceUntilAccessIsRestored() throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .project, name: "freshness")
    var changed: URL?
    var cleanupPending = false
    do {
      try fixture.store.withLock(footprint: [route]) {
        let target = try fixture.store.nativeTarget(for: route)
        let outcome = TransactionOutcome()
        let transaction = FileTransaction(store: fixture.store, outcome: outcome) { point in
          if point == "entry.0.ready" {
            let journal = try treeJournal(fixture.store)
            let file = target.url.deletingLastPathComponent()
              .appendingPathComponent(journal.containerName(0))
              .appendingPathComponent(TransactionSlot.staging(for: journal.entries[0]).name(0))
              .appendingPathComponent("member")
            try #require(chmod(file.path, 0o644) == 0)
            changed = file
          }
        }
        try transaction.replacePrivateTree(
          fixture.store.preparePrivateMaterialization(target),
          entries: [.init("member", content: .file(Data("fixture".utf8)))],
          provider: TreeBindings { Data() })
        #expect(throws: CoreError.self) { try transaction.commit() }
        #expect(outcome.recoveryPending)
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        let sealed = try #require(changed)
        #expect(FileManager.default.fileExists(atPath: sealed.path))
        try #require(chmod(sealed.path, 0o600) == 0)
      }
    } catch CoreError.invalidState {
      cleanupPending = true
    }
    #expect(cleanupPending)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.withLock(footprint: [route]) {}
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
  }

  @Test(arguments: ["missing", "duplicate", "kind"])
  func malformedTreeReceiptNeverBecomesOrdinary(_ field: String) throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .project, name: "receipt")
    try fixture.store.withLock(footprint: [route]) {
      let target = try fixture.store.nativeTarget(for: route)
      let transaction = FileTransaction(store: fixture.store)
      try transaction.replacePrivateTree(
        fixture.store.preparePrivateMaterialization(target),
        entries: [.init("member", content: .file(Data()))], provider: TreeBindings { Data() })
      try transaction.commit()
      let url = fixture.store.materializationReceiptURL
      var json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      var targets = try #require(json["targets"] as? [String: [String: Any]])
      var record = try #require(targets[target.path])
      if field == "missing" {
        record.removeValue(forKey: "treeAccess")
      } else if field == "duplicate" {
        var members = try #require(record["treeAccess"] as? [[String: Any]])
        members.append(try #require(members.first))
        record["treeAccess"] = members
      } else {
        var access = try #require(record["access"] as? [String: Any])
        var identity = try #require(access["identity"] as? [String: Any])
        identity["kind"] = Int(S_IFREG)
        access["identity"] = identity
        record["access"] = access
      }
      targets[target.path] = record
      json["targets"] = targets
      try JSONSerialization.data(withJSONObject: json).write(to: url)
      let before = try FileSnapshot.read(at: fixture.root)
      #expect(throws: CoreError.self) { try fixture.store.materializationReceipt(for: target) }
      #expect(try FileSnapshot.read(at: fixture.root) == before)
    }
  }

  @Test func missingNativeRootHasStablePreviewEvidenceDuringAdmission() throws {
    let fixture = try TransactionFixture()
    let store = StateStore(scope: .project, environment: fixture.store.environment)
    var before = ""
    var privateBefore = ""
    try store.withReadLock(footprint: [.cursorMCPUser]) {
      let target = try store.nativeTarget(for: .cursorMCPUser)
      before = try TargetPrecondition(target.url).displayEvidence(includeContent: false)
      privateBefore = try store.preparePrivateMaterialization(target).accessFingerprint()
      #expect(!FileManager.default.fileExists(atPath: target.url.deletingLastPathComponent().path))
    }
    try store.withLock(footprint: [.cursorMCPUser]) {
      let target = try store.nativeTarget(for: .cursorMCPUser)
      #expect(try TargetPrecondition(target.url).displayEvidence(includeContent: false) == before)
      #expect(try store.preparePrivateMaterialization(target).accessFingerprint() == privateBefore)
    }
    try store.withReadLock(footprint: [.cursorMCPUser]) {
      let target = try store.nativeTarget(for: .cursorMCPUser)
      let parent = target.url.deletingLastPathComponent()
      try #require(chmod(parent.path, 0o750) == 0)
      #expect(try TargetPrecondition(target.url).displayEvidence(includeContent: false) != before)
    }
  }

  #if os(Linux)
    @Test func unicodeDistinctMembersSurviveSnapshotCodecDigestAndDisposal() throws {
      let fixture = try TransactionFixture()
      let parent = try DirectoryHandle(at: fixture.root.appendingPathComponent("new"))
      let nfc = "\u{e9}"
      let nfd = "e\u{301}"
      try parent.write(nfc, data: Data("nfc".utf8))
      try parent.link(nfd, destination: "SKILL.md")
      let before = try #require(try FileSnapshot.read(at: parent.url))
      #expect(before.children?.count == 3)
      #expect(before.child(named: nfc)?.isRegular == true)
      #expect(before.child(named: nfd)?.isSymbolicLink == true)
      let decoded = try StateStore.decode(StateStore.encode(before), as: FileSnapshot.self)
      #expect(decoded == before)
      try parent.remove(nfc, expecting: before.child(named: nfc))
      let remaining = try #require(try FileSnapshot.read(at: parent.url))
      #expect(before.containsRemaining(remaining))
      try DirectoryHandle(at: fixture.root).remove(
        "new", expecting: before, identity: before.identity)
      #expect(!FileManager.default.fileExists(atPath: parent.url.path))
    }
  #endif
}

private struct TreeBindings: RuntimeBindingProvider {
  let resolve: @Sendable () throws -> Data
  init(_ resolve: @escaping @Sendable () throws -> Data) { self.resolve = resolve }
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data { try resolve() }
}

private func treeEntries() -> [PrivateTreeEntry] {
  [
    .init("bin", content: .directory),
    .init(
      "bin/run",
      content: .boundFile(bindings: ["fixture"], executable: true) { try $0.value(for: "fixture") }),
    .init("config", content: .boundFile(bindings: ["fixture"]) { try $0.value(for: "fixture") }),
    .init("sibling", content: .file(Data("ordinary sibling".utf8))),
    .init("alias", content: .symlink("bin/run")),
  ]
}

private func treeJournal(_ store: StateStore) throws -> TransactionJournal {
  try StateStore.decode(
    Data(contentsOf: store.directory.appendingPathComponent("transaction.json")),
    as: TransactionJournal.self)
}

extension PrivateTreeTests {
  @Test(arguments: [
    "stage.0.constructed", "entry.0.ready", "entry.0.applied", "entry.1.applied",
    "journal.committed", "disposal.0.unlinked.entry.0.exchanged/old", "journal.finalized",
  ])
  func restartRecoveryKeepsCompleteTreeAndSealedDisposalSubset(_ point: String) throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(
      .claudeSkillPlugin, scope: .user, name: "private-fixture")
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent("configured-claude").path
    let store = StateStore(scope: .user, environment: environment)
    var generation: UUID?
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivateTree(
        store.preparePrivateMaterialization(target),
        entries: [
          .init("old", content: .file(Data("old tree".utf8))),
          .init("other", content: .file(Data("old sibling".utf8))),
        ], provider: TreeBindings { Data() })
      try transaction.commit()
      generation = try store.materializationReceipt(for: target)?.generation
    }
    let child = try stateTestProcess(
      root: fixture.root, arguments: ["private-tree-install", point, "--scope", "user"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let beforeRead = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: store).requiresOwner)
      }, { Issue.record("a sealed tree journal must remain pending on a read") })
    #expect(try FileSnapshot.read(at: fixture.root) == beforeRead)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    let committed =
      point == "journal.committed" || point.hasPrefix("disposal.") || point == "journal.finalized"
    try store.withReadLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let receipt = try #require(try store.materializationReceipt(for: target))
      #expect((receipt.generation != generation) == committed)
      let directory = try DirectoryHandle(at: target.url)
      _ = try FileAccessEvidence.requirePrivate(descriptor: directory.descriptor)
      if committed {
        #expect(try directory.read("config") == Data("tree-private-after".utf8))
        #expect(try directory.child("nested").read("run") == Data("tree-private-after".utf8))
        #expect(try directory.readLink("alias") == "nested/run")
      } else {
        #expect(try directory.read("old") == Data("old tree".utf8))
        #expect(try directory.read("other") == Data("old sibling".utf8))
      }
    }
  }

  @Test func differentHomesShareTreeLockBeforeCallbackAndProvider() throws {
    let fixture = try TransactionFixture()
    let config = fixture.root.appendingPathComponent("tree-shared-root")
    let other = fixture.root.appendingPathComponent("other-project")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let holder = try stateTestProcess(
      root: fixture.root,
      arguments: [
        "private-tree-lock", "tree.locked", "--scope", "user", "--shared-config", config.path,
      ])
    defer { terminateProcess(holder) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: holder, root: fixture.root)
    let waiter = try stateTestProcess(
      root: other,
      arguments: [
        "private-tree-install", "shared.0.lock.contended", "--scope", "user", "--shared-config",
        config.path,
      ])
    defer { terminateProcess(waiter) }
    try ProcessWait.marker(other.appendingPathComponent("ready"), child: waiter, root: other)
    #expect(
      !FileManager.default.fileExists(
        atPath: other.appendingPathComponent("tree-provider-resolved").path))
    try #require(kill(holder.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(holder, root: fixture.root)
    #expect(holder.terminationStatus == 0)
    try #require(kill(waiter.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(waiter, root: other)
    #expect(waiter.terminationStatus == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: other.appendingPathComponent("tree-provider-resolved").path))
    #expect(
      try Data(contentsOf: config.appendingPathComponent("skills/private-fixture/config"))
        == Data("tree-private-after".utf8))
  }

  @Test(arguments: ["stagedTreeAccess", "duplicateMember", "coordination", "version"])
  func malformedTreeJournalIsReadOnlyRejected(_ field: String) throws {
    let fixture = try TransactionFixture()
    let child = try stateTestProcess(
      root: fixture.root,
      arguments: ["private-tree-install", "entry.0.ready", "--scope", "user"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent("configured-claude").path
    let store = StateStore(scope: .user, environment: environment)
    let journalURL = store.directory.appendingPathComponent("transaction.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    var entries = try #require(json["entries"] as? [[String: Any]])
    switch field {
    case "version": json["version"] = 3
    case "coordination": entries[0]["coordination"] = 999
    case "duplicateMember":
      var staged = try #require(entries[0]["staged"] as? [String: Any])
      var children = try #require(staged["children"] as? [[String: Any]])
      children.append(try #require(children.first))
      staged["children"] = children
      entries[0]["staged"] = staged
    default:
      var security = try #require(entries[0]["security"] as? [String: Any])
      security.removeValue(forKey: field)
      entries[0]["security"] = security
    }
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(to: journalURL)
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(throws: (any Error).self) { try store.withLock {} }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test func recordedNamedRootsResolveOnColdReadWithoutPathAuthority() throws {
    let fixture = try TransactionFixture()
    let route = try NativeTargetRoute.named(.claudeCommand, scope: .project, name: "team/review")
    var ledger = ResolvedLedger()
    ledger.sources["fixture"] = LedgerSource(kind: .local, revision: "live")
    ledger.components["command"] = LedgerComponent(
      declaringSource: "fixture", source: "fixture", root: ".", kind: "command",
      name: "review", payload: .init(object: [:]), conditions: [], recipients: [.claudeCode],
      chatGPT: false, resources: [])
    ledger.deployments = [
      .init(
        id: "deployment", target: .init(kind: .registered, root: route.root, path: route.basename),
        route: "fixture/command@1",
        owners: ["command"], recipients: [.claudeCode], ownership: .generated,
        expectedHash: "sha256:" + String(repeating: "a", count: 64), created: true)
    ]
    ledger.lowerings = [
      .init(
        id: "lowering", format: "fixture/command@1", inputs: ["command"], resources: [],
        deployments: ["deployment"], layout: .init(object: [:]), platform: "macos", artifacts: [])
    ]
    try ResolvedLedgerCodec.encode(ledger, limits: .standard).write(to: fixture.store.resolvedURL)
    let cold = StateStore(scope: .project, environment: fixture.store.environment)
    let target = try ledger.deployments[0].target.resolve(roots: cold.ledgerRoots)
    #expect(target == fixture.root.appendingPathComponent(".claude/commands/team/review.md"))
    #expect(throws: CoreError.self) {
      try FileTransaction(store: cold).replace(target, with: .data(Data()))
    }
    try cold.withLock(footprint: [route]) {
      let admitted = try cold.nativeTarget(for: route)
      let transaction = FileTransaction(store: cold)
      try transaction.replace(admitted.url, with: .data(Data("command".utf8)))
      try transaction.commit()
    }
    ledger.deployments[0].target.path = "unrecorded.md"
    try ResolvedLedgerCodec.encode(ledger, limits: .standard).write(to: fixture.store.resolvedURL)
    #expect(cold.ledgerRoots[route.root] == nil)
    ledger.deployments[0].target.root = "native-member-2e2e2f657363617065"
    try ResolvedLedgerCodec.encode(ledger, limits: .standard).write(to: fixture.store.resolvedURL)
    #expect(cold.ledgerRoots[ledger.deployments[0].target.root!] == nil)
    #expect(RuntimeBindingValues([:]).description == "<runtime bindings>")
  }
}

extension PrivateTreeTests {
  @Test func independentNestedCoordinationIsRefusedBeforeCreatingMetadata() throws {
    let fixture = try TransactionFixture()
    var environment = fixture.store.environment
    let configured = fixture.root.appendingPathComponent("configured")
    try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
    environment.environment["CLAUDE_CONFIG_DIR"] = configured.path
    environment.environment["CODEX_HOME"] = configured.appendingPathComponent("skills/plugin").path
    let store = StateStore(scope: .user, environment: environment)
    let before = try FileSnapshot.read(at: fixture.root)
    #expect(throws: CoreError.self) { try store.withReadLock(footprint: [.codexMCPUser]) {} }
    #expect(throws: CoreError.self) { try store.withLock(footprint: [.codexMCPUser]) {} }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    environment.environment["CODEX_HOME"] =
      fixture.root.appendingPathComponent("independent-codex").path
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("independent-codex"),
      withIntermediateDirectories: true)
    let allowed = StateStore(scope: .user, environment: environment)
    let plugin = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .user, name: "plugin")
    try allowed.withLock(footprint: [plugin, .codexMCPUser]) {
      let target = try allowed.nativeTarget(for: plugin)
      let transaction = FileTransaction(store: allowed)
      try transaction.replacePrivateTree(
        allowed.preparePrivateMaterialization(target), entries: [],
        provider: TreeBindings { Data() })
      let codex = try allowed.nativeTarget(for: .codexMCPUser)
      try transaction.replacePrivate(
        allowed.preparePrivateMaterialization(codex), provider: TreeBindings { Data() }
      ) { _ in Data("ordinary fixture".utf8) }
      try transaction.commit()
      #expect(try allowed.materializationReceipt(for: target)?.treeAccess == [])
      #expect(try allowed.materializationReceipt(for: codex)?.treeAccess == nil)
      #expect(try allowed.materializationReceipt(for: codex) != nil)
    }
  }
}
