import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite struct CoordinationAdmissionTests {
  @Test func standaloneSelectionAndCanonicalChildUseObservedParent() throws {
    let fixture = try TransactionFixture()
    let store = fixture.store
    let root = try store.captureExistingProjectRoot()
    let before = try FileSnapshot.read(at: fixture.root)
    let target = try store.skillInitializationTarget(
      inChildDirectory: "Selected Skill", named: "demo")
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    #expect(target.file == fixture.root.appendingPathComponent("Selected Skill/demo/SKILL.md"))
    try store.withLock(existingRoot: root) {
      let transaction = FileTransaction(store: store)
      try transaction.initializeSkill(target, bytes: Data("exact template".utf8))
      try transaction.commit()
    }
    #expect(try Data(contentsOf: target.file) == Data("exact template".utf8))
    #expect(throws: CoreError.self) {
      try store.skillInitializationTarget(inChildDirectory: "../escape", named: "demo")
    }
  }

  @Test func legacySymlinkAndPluginKeepDistinctIntentWithOnePhysicalDomain() throws {
    let fixture = try TransactionFixture()
    let store = StateStore(scope: .user, environment: fixture.store.environment)
    let skill = try store.skillInstallationTarget(for: .claudeCode, named: "shared")
    let route = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .user, name: "shared")
    #expect(skill.footprint == [route])
    #expect(throws: CoreError.self) {
      try store.withLock {
        let transaction = FileTransaction(store: store)
        try transaction.replaceSkill(skill, with: .link(fixture.root.appendingPathComponent("new")))
      }
    }
    try store.withLock(footprint: skill.footprint) {
      let transaction = FileTransaction(store: store)
      try transaction.replaceSkill(skill, with: .link(fixture.root.appendingPathComponent("new")))
      try transaction.commit()
      #expect(try FileSnapshot.read(at: skill.url)?.isSymbolicLink == true)
      let native = try store.nativeTarget(for: route)
      #expect(throws: CoreError.self) { try store.preparePrivateMaterialization(native) }
      let copy = FileTransaction(store: store)
      try copy.replaceSkill(skill, with: .copy(fixture.root.appendingPathComponent("new")))
      try copy.commit()
      let privateTree = FileTransaction(store: store)
      try privateTree.replacePrivateTree(
        store.preparePrivateMaterialization(native, changingAccess: true),
        entries: [.init("secret", content: .file(Data("retained".utf8)))],
        provider: AdmissionBindings())
      try privateTree.commit()
      let generation = try store.materializationReceipt(for: native)?.generation
      let refuses = FileTransaction(store: store)
      #expect(throws: CoreError.self) {
        try refuses.replaceSkill(skill, with: .copy(fixture.root.appendingPathComponent("new")))
      }
      let rollback = FileTransaction(store: store) { point in
        if point == "entry.0.applied" { throw CoreError.invalidState("bounded rollback") }
      }
      try rollback.deleteSkill(skill)
      #expect(throws: CoreError.self) { try rollback.commit() }
      #expect(try store.materializationReceipt(for: native)?.generation == generation)
      #expect(
        try Data(contentsOf: native.url.appendingPathComponent("secret")) == Data("retained".utf8))
      #expect(!FileManager.default.fileExists(atPath: store.materializationReceiptURL.path))
    }
  }

  @Test func compatibleProjectUserAliasesRetainOnePrivateReceiptAndLogicalAuthority() throws {
    let fixture = try TransactionFixture()
    var environment = fixture.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent(".claude").path
    let project = StateStore(scope: .project, environment: environment)
    let user = StateStore(scope: .user, environment: environment)
    let local = try NativeTargetRoute.named(.claudeCommand, scope: .project, name: "team/review")
    let global = try NativeTargetRoute.named(.claudeCommand, scope: .user, name: "team/review")
    var generation: UUID?
    try project.withLock(footprint: [local]) {
      let target = try project.nativeTarget(for: local)
      #expect(target.path == local.root + "/" + local.basename)
      let transaction = FileTransaction(store: project)
      try transaction.replacePrivate(
        project.preparePrivateMaterialization(target), provider: AdmissionBindings()
      ) { _ in Data("secret sibling".utf8) }
      try transaction.commit()
      generation = try project.materializationReceipt(for: target)?.generation
      #expect(!FileManager.default.fileExists(atPath: project.materializationReceiptURL.path))
    }
    try user.withLock(footprint: [global]) {
      let target = try user.nativeTarget(for: global)
      #expect(try user.materializationReceipt(for: target)?.generation == generation)
      let transaction = FileTransaction(store: user)
      try transaction.replace(target.url, with: .data(Data("secret sibling; ordinary edit".utf8)))
      try transaction.commit()
      #expect(try user.materializationReceipt(for: target)?.generation != generation)
    }
    try project.withReadLock(footprint: [local]) {
      let target = try project.nativeTarget(for: local)
      #expect(try project.materializationReceipt(for: target) != nil)
      #expect(try Data(contentsOf: target.url) == Data("secret sibling; ordinary edit".utf8))
    }
  }
}

extension CoordinationAdmissionTests {
  @Test func nativeAndLegacyWritersContendBeforeLegacyCallback() throws {
    let f = try TransactionFixture()
    let config = f.root.appendingPathComponent("home/.claude")
    let holder = try stateTestProcess(
      root: f.root,
      arguments: [
        "private-tree-lock", "tree.locked", "--scope", "user", "--shared-config", config.path,
      ])
    defer { terminateProcess(holder) }
    try ProcessWait.marker(f.root.appendingPathComponent("ready"), child: holder, root: f.root)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("ready"))
    let waiter = try stateTestProcess(
      root: f.root,
      arguments: [
        "private-legacy-install", "shared.0.lock.contended", "--scope", "user", "--shared-config",
        config.path,
      ])
    defer { terminateProcess(waiter) }
    try ProcessWait.marker(f.root.appendingPathComponent("ready"), child: waiter, root: f.root)
    #expect(
      !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("legacy-callback").path)
    )
    try #require(kill(holder.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(holder, root: f.root)
    #expect(holder.terminationStatus == 0)
    try #require(kill(waiter.processIdentifier, SIGCONT) == 0)
    try ProcessWait.exit(waiter, root: f.root)
    #expect(waiter.terminationStatus == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: config.appendingPathComponent("skills/private-fixture/SKILL.md").path))
  }

  @Test(arguments: ["entry.0.applied", "journal.finalized"])
  func legacyJournalReconstructsOnlyItsClosedCoordinator(_ point: String) throws {
    let f = try TransactionFixture()
    let config = f.root.appendingPathComponent("home/.claude")
    let child = try stateTestProcess(
      root: f.root,
      arguments: [
        "private-legacy-install", point, "--scope", "user", "--shared-config", config.path,
      ])
    defer { terminateProcess(child) }
    try ProcessWait.marker(f.root.appendingPathComponent("ready"), child: child, root: f.root)
    terminateProcess(child)
    var environment = f.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] = config.path
    let store = StateStore(scope: .user, environment: environment)
    let before = try FileSnapshot.read(at: f.root)
    try store.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: store).requiresOwner)
      }, { Issue.record("expected recovery diagnostic") })
    #expect(try FileSnapshot.read(at: f.root) == before)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    let target = try store.skillInstallationTarget(for: .claudeCode, named: "private-fixture")
    #expect(
      FileManager.default.fileExists(atPath: target.url.path) == (point == "journal.finalized"))
  }
}

extension CoordinationAdmissionTests {
  @Test func projectLegacyAliasDoesNotGrantUserNativeScopeAuthority() throws {
    let f = try TransactionFixture()
    let destination = f.root.appendingPathComponent("home/.claude")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent(".claude"), withDestinationURL: destination)
    let target = try f.store.skillInstallationTarget(for: .claudeCode, named: "legacy")
    let userRoute = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .user, name: "legacy")
    #expect(throws: CoreError.self) { try f.store.withLock(footprint: [userRoute]) {} }
    try f.store.withLock(installations: [target]) { () -> Void in
      #expect(throws: CoreError.self) { try f.store.nativeTarget(for: userRoute) }
      let transaction = FileTransaction(store: f.store)
      try transaction.replaceSkill(target, with: .link(f.root.appendingPathComponent("new")))
      try transaction.commit()
    }
    #expect(try FileSnapshot.read(at: target.url)?.isSymbolicLink == true)
  }

  @Test func incompatibleReadersAndSymlinkDescendantsCannotAcquireAliasAuthority() throws {
    let f = try TransactionFixture()
    let claude = f.root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent(".gemini"), withDestinationURL: claude)
    var environment = f.store.environment
    environment.environment["GEMINI_CLI_HOME"] = f.root.path
    let store = StateStore(scope: .project, environment: environment)
    let before = try FileSnapshot.read(at: f.root)
    #expect(throws: CoreError.self) { try store.withLock(footprint: [.claudeSettingsProject]) {} }
    #expect(try FileSnapshot.read(at: f.root) == before)
    let external = f.root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: claude.appendingPathComponent("commands"), withDestinationURL: external)
    let route = try NativeTargetRoute.named(.claudeCommand, scope: .project, name: "example")
    #expect(throws: CoreError.self) { try store.withReadLock(footprint: [route]) {} }
    #expect(
      !FileManager.default.fileExists(
        atPath: external.appendingPathComponent(".agents-native").path))
  }
}

extension CoordinationAdmissionTests {
  @Test func finalizedLegacyCleanupPreservesLaterGenerationAfterLogicalAliasReplacement() throws {
    let f = try TransactionFixture()
    let config = f.root.appendingPathComponent("home/.claude")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let alias = f.root.appendingPathComponent(".claude")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
    let child = try stateTestProcess(
      root: f.root,
      arguments: [
        "private-legacy-install", "shared.0.reservation.removed", "--shared-config", config.path,
      ])
    defer { terminateProcess(child) }
    try ProcessWait.marker(f.root.appendingPathComponent("ready"), child: child, root: f.root)
    terminateProcess(child)
    var environment = f.store.environment
    environment.environment["CLAUDE_CONFIG_DIR"] = config.path
    let later = StateStore(scope: .user, environment: environment)
    let target = try later.skillInstallationTarget(for: .claudeCode, named: "private-fixture")
    let source = f.root.appendingPathComponent("later")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("later generation".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    try later.withLock(installations: [target]) {
      let transaction = FileTransaction(store: later)
      try transaction.replaceSkill(target, with: .copy(source))
      try transaction.commit()
    }
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
    let owner = StateStore(scope: .project, environment: environment)
    let before = try FileSnapshot.read(at: f.root)
    try owner.withReadLock(
      onPendingRecovery: {
        #expect(!FileTransaction.recoveryDiagnostic(store: owner).requiresOwner)
      }, { Issue.record("expected finalized cleanup diagnostic") })
    #expect(try FileSnapshot.read(at: f.root) == before)
    #expect(throws: CoreError.transactionRecovered(owner.directory.path)) { try owner.withLock {} }
    #expect(
      try Data(contentsOf: target.url.appendingPathComponent("SKILL.md"))
        == Data("later generation".utf8))
    #expect(!FileManager.default.fileExists(atPath: alias.appendingPathComponent("skills").path))
  }
}

extension CoordinationAdmissionTests {
  @Test func legacyLoaderReplacementAndArbitraryPayloadCannotExpandAuthority() throws {
    let f = try TransactionFixture()
    let first = f.root.appendingPathComponent("home/.claude")
    let other = f.root.appendingPathComponent("other-loader")
    for parent in [first, other] {
      try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("skills"), withIntermediateDirectories: true)
    }
    let alias = f.root.appendingPathComponent(".claude")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    let target = try f.store.skillInstallationTarget(for: .claudeCode, named: "example")
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
    let before = try FileSnapshot.read(at: f.root)
    #expect(throws: CoreError.self) {
      try f.store.withLock(installations: [target]) {
        Issue.record("stale authority must not deliver a callback")
      }
    }
    #expect(try FileSnapshot.read(at: f.root) == before)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    try f.store.withLock(installations: [target]) {
      #expect(throws: CoreError.self) {
        try FileTransaction(store: f.store).replaceSkill(target, with: .data(Data()))
      }
    }
    #expect(throws: CoreError.self) {
      try f.store.skillInstallationTarget(for: .claudeCode, named: "../escape")
    }
  }
}

private struct AdmissionBindings: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    throw CoreError.invalidState("no binding was requested")
  }
}
