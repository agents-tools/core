import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Registered native MCP files")
struct RegisteredNativeTargetTests {
  @Test func absentSharedRootPreviewIsPureAndApplyCreatesPrivateObjects() throws {
    let fixture = try NativeRouteFixture()
    var environment = fixture.store.environment
    let missing = fixture.root.appendingPathComponent("fresh/nested")
    environment.environment["CLAUDE_CONFIG_DIR"] = missing.path
    let store = StateStore(scope: .project, environment: environment)
    let before = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(footprint: [.claudeMCPLocal, .codexMCPUser]) {
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      #expect(target.url == missing.appendingPathComponent(".claude.json"))
      #expect(try store.materializationReceipt(for: target) == nil)
      let prepared = try store.preparePrivateMaterialization(target)
      #expect(prepared.receiptGeneration == nil && prepared.beforeAccess == nil)
      #expect(throws: CoreError.self) {
        let transaction = FileTransaction(store: store)
        try transaction.replacePrivate(prepared, provider: NativeRouteBindings()) { _ in Data() }
      }
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    try store.withLock(footprint: [.claudeMCPLocal]) {
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivate(
        store.preparePrivateMaterialization(target), provider: NativeRouteBindings()
      ) { _ in Data("private fixture".utf8) }
      try transaction.commit()
      #expect(try store.materializationReceipt(for: target) != nil)
      _ = try DirectoryHandle(at: missing).requirePrivateAccess(".claude.json")
    }
  }

  @Test func absentRootAppearanceReadmitsWithoutInventingAMetadataIdentity() throws {
    let fixture = try NativeRouteFixture()
    var environment = fixture.store.environment
    let root = fixture.root.appendingPathComponent("fresh")
    environment.environment["CLAUDE_CONFIG_DIR"] = root.path
    let store = StateStore(scope: .project, environment: environment)
    let bytes = try store.withReadLock(footprint: [.claudeMCPLocal]) {
      let target = try store.nativeTarget(for: .claudeMCPLocal)
      if !FileManager.default.fileExists(atPath: root.path) {
        // An external native writer does not participate in Core coordination.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("external generation".utf8).write(to: target.url)
        return Data("stale absence".utf8)
      }
      return try Data(contentsOf: target.url)
    }
    #expect(bytes == Data("external generation".utf8))
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents-native").path))
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
  }

  @Test(arguments: ["alias", "ancestor"])
  func absentRootInspectionRefusesRedirectedAuthority(_ change: String) throws {
    let fixture = try NativeRouteFixture()
    let parent = fixture.root.appendingPathComponent("authority")
    let other = fixture.root.appendingPathComponent("unrelated")
    for path in [parent, other] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    var environment = fixture.store.environment
    let root = parent.appendingPathComponent("fresh")
    environment.environment["CLAUDE_CONFIG_DIR"] = root.path
    let store = StateStore(scope: .project, environment: environment)
    #expect(throws: CoreError.self) {
      try store.withReadLock(footprint: [.claudeMCPLocal]) {
        _ = try store.nativeTarget(for: .claudeMCPLocal)
        if change == "alias" {
          try FileManager.default.createSymbolicLink(at: root, withDestinationURL: other)
        } else {
          try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("old"))
          try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
      }
    }
    #expect(try DirectoryHandle(at: other).names().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
  }

  @Test(arguments: [false, true], [AgentID.codex, .cursor])
  func legacyInstallationSpellingRequiresItsExactCommittedRecipient(
    _ rollback: Bool, _ agent: AgentID
  ) throws {
    let fixture = try NativeRouteFixture()
    let store = fixture.store
    let parent = AgentRegistry.installSkillsDirectory(
      for: agent, scope: .project, environment: store.environment)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let legacy = parent.appendingPathComponent("Example Skill")
    try Data("old".utf8).write(to: legacy)
    let ledger = try fixture.recordSkill(name: "Example Skill", agent: agent)
    let transaction = FileTransaction(store: store) { point in
      if point == "entry.0.applied" {
        let journal = try fixture.journal()
        #expect(journal.entries.first?.path == agent.rawValue + "/Example Skill")
      }
      if rollback && point == "entry.1.applied" { throw CoreError.invalidState("fixture rollback") }
    }
    try transaction.replace(legacy, with: .data(Data("next".utf8)))
    #expect(throws: CoreError.self) {
      try transaction.replace(
        parent.appendingPathComponent("Unrecorded Skill"), with: .data(Data()))
    }
    let other = AgentRegistry.installSkillsDirectory(
      for: .claudeCode, scope: .project, environment: store.environment)
    #expect(throws: CoreError.self) {
      try transaction.replace(other.appendingPathComponent("Example Skill"), with: .data(Data()))
    }
    let outside = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let alias = parent.appendingPathComponent("Traversal Skill")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    #expect(throws: CoreError.self) {
      try transaction.replace(alias.appendingPathComponent("child"), with: .data(Data()))
    }
    #expect(try DirectoryHandle(at: outside).names().isEmpty)
    for path in ["codex/..", "codex/.", "codex/a/b", "codex/a\\b"] {
      #expect(throws: CoreError.self) { try TransactionPaths(store: store).components(path) }
    }
    try transaction.replace(
      store.resolvedURL,
      with: .data(ResolvedLedgerCodec.encode(ResolvedLedger(), limits: .standard)))
    if rollback {
      #expect(throws: CoreError.self) { try transaction.commit() }
      #expect(
        try ResolvedLedgerCodec.decode(Data(contentsOf: store.resolvedURL), limits: .standard)
          == ledger)
    } else {
      try transaction.commit()
    }
    #expect(try Data(contentsOf: legacy) == Data((rollback ? "old" : "next").utf8))
    #expect(
      !FileManager.default.fileExists(atPath: parent.appendingPathComponent("example-skill").path))
  }

  #if os(Linux)
    @Test func distinctUnicodeFilenamesKeepSeparateInstallationAuthority() throws {
      let fixture = try NativeRouteFixture()
      let recorded = "\u{00E9} Skill"
      let alternate = "e\u{0301} Skill"
      try fixture.recordSkill(name: recorded, agent: .codex)
      let parent = AgentRegistry.installSkillsDirectory(
        for: .codex, scope: .project, environment: fixture.store.environment)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let authorized = parent.appendingPathComponent(recorded)
      let unrecorded = parent.appendingPathComponent(alternate)
      let recordedBytes = Data("old".utf8)
      let alternateBytes = Data("unrecorded before".utf8)
      let directory = try DirectoryHandle(at: parent)
      try directory.write(recorded, data: recordedBytes)
      try directory.write(alternate, data: alternateBytes)
      try #require(authorized.lastPathComponent.utf8.elementsEqual(recorded.utf8))
      try #require(unrecorded.lastPathComponent.utf8.elementsEqual(alternate.utf8))
      let first = FileObjectIdentity(try #require(try directory.info(recorded)))
      let second = FileObjectIdentity(try #require(try directory.info(alternate)))
      try #require(first != second)
      let names = try directory.names()
      try #require(names.contains(where: { $0.utf8.elementsEqual(recorded.utf8) }))
      try #require(names.contains(where: { $0.utf8.elementsEqual(alternate.utf8) }))
      let refused = FileTransaction(store: fixture.store)
      #expect(throws: CoreError.self) { try refused.delete(unrecorded) }
      #expect(throws: CoreError.self) {
        try refused.replace(unrecorded, with: .data(Data("unauthorized".utf8)))
      }
      #expect(try directory.info(recorded).map(FileObjectIdentity.init) == first)
      #expect(try directory.info(alternate).map(FileObjectIdentity.init) == second)
      #expect(try Data(contentsOf: authorized) == recordedBytes)
      #expect(try Data(contentsOf: unrecorded) == alternateBytes)
      let allowed = FileTransaction(store: fixture.store)
      try allowed.replace(authorized, with: .data(Data("recorded after".utf8)))
      try allowed.commit()
      #expect(try Data(contentsOf: authorized) == Data("recorded after".utf8))
      #expect(try Data(contentsOf: unrecorded) == alternateBytes)
      #expect(try directory.info(alternate).map(FileObjectIdentity.init) == second)
      #expect(try directory.info(recorded).map(FileObjectIdentity.init) != second)
    }
  #endif

  @Test(arguments: NativeTargetRoute.mcpRoutes)
  func registeredFilesPublishPrivatelyAndRetainTheirReceipt(_ route: NativeTargetRoute) throws {
    let fixture = try NativeRouteFixture()
    let expected: [NativeTargetRoute: String] = [
      .claudeMCPProject: ".mcp.json", .claudeMCPLocal: "configured/.claude.json",
      .claudeMCPUser: "configured/.claude.json", .codexMCPProject: ".codex/config.toml",
      .codexMCPUser: "configured/config.toml", .geminiMCPProject: ".gemini/settings.json",
      .geminiMCPUser: "configured/.gemini/settings.json", .cursorMCPProject: ".cursor/mcp.json",
      .cursorMCPUser: "home/.cursor/mcp.json", .openCodeMCPProjectJSON: "opencode.json",
      .openCodeMCPProjectJSONC: "opencode.jsonc", .openCodeMCPUserJSON: "configured/opencode.json",
      .openCodeMCPUserJSONC: "configured/opencode.jsonc",
    ]
    let store = fixture.store
    var privateBeforeWrite = false
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      #expect(target.url == fixture.root.appendingPathComponent(try #require(expected[route])))
      let transaction = FileTransaction(store: store) { point in
        if point == "stage.0.writeCreated" {
          let journal = try fixture.journal()
          let container = try DirectoryHandle(
            at: target.url.deletingLastPathComponent().appendingPathComponent(
              journal.containers[0].name))
          _ = try container.requirePrivateAccess("entry.0.staged")
          #expect(try container.read("entry.0.staged").isEmpty)
          privateBeforeWrite = true
        }
      }
      try transaction.replacePrivate(
        try store.preparePrivateMaterialization(target), bindings: ["fixture"],
        provider: NativeRouteBindings()
      ) { try $0.value(for: "fixture") }
      try transaction.commit()
      let receipt = try #require(try store.materializationReceipt(for: target))
      let edit = FileTransaction(store: store)
      try edit.replace(target.url, with: .data(Data("owned sibling; next region".utf8)))
      try edit.commit()
      #expect(try store.materializationReceipt(for: target)?.generation != receipt.generation)
      #expect(try Data(contentsOf: target.url) == Data("owned sibling; next region".utf8))
      if !route.shared { #expect(TransactionLockContext.current(store)?.resources.isEmpty == true) }
    }
    #expect(privateBeforeWrite)
  }

  @Test func explicitRootsAndFileVariantsDoNotGuessDiscoveryOrAuthorizeSiblings() throws {
    let fixture = try NativeRouteFixture()
    let environment = RuntimeEnvironment(
      projectDirectory: fixture.root, homeDirectory: fixture.root.appendingPathComponent("home"),
      environment: [
        "CURSOR_CONFIG_DIR": fixture.config.path, "XDG_CONFIG_HOME": fixture.config.path,
      ])
    let store = StateStore(scope: .project, environment: environment)
    #expect(
      try store.nativeTarget(for: .codexMCPUser).url
        == environment.homeDirectory.appendingPathComponent(".codex/config.toml"))
    #expect(
      try store.nativeTarget(for: .geminiMCPUser).url
        == environment.homeDirectory.appendingPathComponent(".gemini/settings.json"))
    #expect(
      try store.nativeTarget(for: .cursorMCPUser).url
        == environment.homeDirectory.appendingPathComponent(".cursor/mcp.json"))
    #expect(
      try store.nativeTarget(for: .openCodeMCPUserJSONC).url
        == fixture.config.appendingPathComponent("opencode/opencode.jsonc"))
    try FileManager.default.createDirectory(
      at: fixture.config.appendingPathComponent("opencode"), withIntermediateDirectories: true)
    let before = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(footprint: [.openCodeMCPUserJSON, .openCodeMCPUserJSONC]) {
      let json = try store.nativeTarget(for: .openCodeMCPUserJSON)
      let jsonc = try store.nativeTarget(for: .openCodeMCPUserJSONC)
      #expect(json.url.lastPathComponent == "opencode.json")
      #expect(jsonc.url.lastPathComponent == "opencode.jsonc")
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    for (key, route) in [
      ("CODEX_HOME", NativeTargetRoute.codexMCPUser),
      ("GEMINI_CLI_HOME", .geminiMCPUser), ("OPENCODE_CONFIG_DIR", .openCodeMCPUserJSON),
      ("XDG_CONFIG_HOME", .openCodeMCPUserJSON),
    ] {
      let invalid = StateStore(
        scope: .project,
        environment: RuntimeEnvironment(
          projectDirectory: fixture.root, homeDirectory: environment.homeDirectory,
          environment: [key: "relative-root"]))
      #expect(throws: CoreError.self) { try invalid.nativeTarget(for: route) }
    }
    let missing = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: fixture.root, homeDirectory: environment.homeDirectory,
        environment: ["CODEX_HOME": fixture.root.appendingPathComponent("missing").path]))
    #expect(throws: CoreError.self) { try missing.withLock(footprint: [.codexMCPUser]) {} }
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("missing").path))
    try fixture.store.withLock(footprint: [.codexMCPUser]) {
      let transaction = FileTransaction(store: fixture.store)
      #expect(throws: CoreError.self) {
        try transaction.replace(
          fixture.config.appendingPathComponent("auth.json"), with: .data(Data()))
      }
      #expect(throws: CoreError.self) {
        try transaction.replace(
          fixture.config.appendingPathComponent("other.toml"), with: .data(Data()))
      }
    }
    let user = StateStore(scope: .user, environment: fixture.store.environment)
    #expect(throws: CoreError.self) { try user.nativeTarget(for: .codexMCPProject) }
  }

  @Test(arguments: ["queued", "staged"])
  func projectRootAliasesCannotRedirectQueuedOrdinaryWrites(_ change: String) throws {
    let fixture = try NativeRouteFixture()
    let first = fixture.root.appendingPathComponent("first")
    let second = fixture.root.appendingPathComponent("second")
    for root in [first, second] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let alias = fixture.root.appendingPathComponent(".codex")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    func redirect() throws {
      try FileManager.default.removeItem(at: alias)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
    }
    #expect(throws: CoreError.self) {
      try fixture.store.withLock(footprint: [.codexMCPProject]) {
        let target = try fixture.store.nativeTarget(for: .codexMCPProject)
        let transaction = FileTransaction(store: fixture.store) { point in
          if change == "staged", point == "stage.0.writeCreated" { try redirect() }
        }
        try transaction.replace(target.url, with: .data(Data("owned region".utf8)))
        if change == "queued" { try redirect() }
        try transaction.commit()
      }
    }
    let journal = fixture.store.directory.appendingPathComponent("transaction.json")
    if change == "staged" {
      #expect(FileManager.default.fileExists(atPath: journal.path))
      try FileManager.default.removeItem(at: alias)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
      #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
        try fixture.store.withLock {}
      }
    }
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(
      !FileManager.default.fileExists(atPath: first.appendingPathComponent("config.toml").path))
    #expect(
      !FileManager.default.fileExists(atPath: second.appendingPathComponent("config.toml").path))
  }

  @Test func projectAndUserFileCoincidenceRequiresTheSharedAdmission() throws {
    let fixture = try NativeRouteFixture()
    let root = fixture.root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: fixture.root, homeDirectory: fixture.root.appendingPathComponent("home"),
        environment: ["CODEX_HOME": root.path]))
    try store.withLock(footprint: [.codexMCPProject]) {
      let target = try store.nativeTarget(for: .codexMCPProject)
      let transaction = FileTransaction(store: store)
      #expect(throws: CoreError.self) {
        try transaction.replace(target.url, with: .data(Data("owned region".utf8)))
      }
    }
    try store.withLock(footprint: [.codexMCPUser]) {
      let target = try store.nativeTarget(for: .codexMCPUser)
      let transaction = FileTransaction(store: store)
      try transaction.replace(target.url, with: .data(Data("shared region".utf8)))
      try transaction.commit()
    }
    #expect(
      try Data(contentsOf: root.appendingPathComponent("config.toml")) == Data("shared region".utf8)
    )
  }

  @Test func distinctFilesHaveIndependentReceiptsAcrossAliasedHomes() throws {
    let fixture = try NativeRouteFixture()
    let store = fixture.store
    let routes = Set(NativeTargetRoute.sharedRoutes)
    var receipts: [NativeTargetRoute: Data] = [:]
    var identities: [NativeTargetRoute: SharedResourceIdentity] = [:]
    try store.withLock(footprint: routes) {
      let transaction = FileTransaction(store: store)
      for route in NativeTargetRoute.sharedRoutes {
        let target = try store.nativeTarget(for: route)
        try transaction.replacePrivate(
          try store.preparePrivateMaterialization(target), provider: NativeRouteBindings()
        ) { _ in Data(route.rawValue.utf8) }
        identities[route] = try TransactionLockContext.current(store).requiredResourceForRoute(
          route
        ).identity
      }
      try transaction.commit()
      for route in NativeTargetRoute.sharedRoutes {
        let target = try store.nativeTarget(for: route)
        let receipt = try store.materializationReceipts(for: target.path)
        #expect(Set(receipt.records.targets.keys) == [target.path])
        receipts[route] = try Data(contentsOf: receipt.url)
      }
    }
    #expect(Set(identities.values.map(\.orderingKey)).count == NativeTargetRoute.sharedRoutes.count)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.config)
    let other = StateStore(
      scope: .user,
      environment: RuntimeEnvironment(
        projectDirectory: fixture.root,
        homeDirectory: fixture.root.appendingPathComponent("other-home"),
        environment: [
          "CLAUDE_CONFIG_DIR": alias.path, "CODEX_HOME": alias.path,
          "GEMINI_CLI_HOME": alias.path, "OPENCODE_CONFIG_DIR": alias.path,
        ]))
    let shared = Set([
      NativeTargetRoute.codexMCPUser, .geminiMCPUser, .openCodeMCPUserJSON, .openCodeMCPUserJSONC,
      .claudeMCPLocal,
    ])
    try other.withLock(footprint: shared) {
      for route in shared {
        #expect(
          try TransactionLockContext.current(other).requiredResourceForRoute(route).identity
            == identities[route])
      }
      let target = try other.nativeTarget(for: .codexMCPUser)
      let transaction = FileTransaction(store: other)
      try transaction.replace(target.url, with: .data(Data("owned sibling; new codex region".utf8)))
      try transaction.commit()
    }
    try store.withLock(footprint: routes) {
      for route in NativeTargetRoute.sharedRoutes {
        let target = try store.nativeTarget(for: route)
        #expect(try store.materializationReceipt(for: target) != nil)
        let receipt = try store.materializationReceipts(for: target.path)
        if route != .codexMCPUser { #expect(try Data(contentsOf: receipt.url) == receipts[route]) }
      }
      let transaction = FileTransaction(store: store)
      try transaction.delete(store.nativeTarget(for: .openCodeMCPUserJSON).url)
      try transaction.commit()
      #expect(
        try store.materializationReceipt(for: store.nativeTarget(for: .openCodeMCPUserJSON)) == nil)
      #expect(
        try store.materializationReceipt(for: store.nativeTarget(for: .openCodeMCPUserJSONC)) != nil
      )
    }
  }

  @Test func aChangedPendingRuntimeCannotCreateAnUnrelatedRequestedDomain() throws {
    let fixture = try NativeRouteFixture()
    let child = try stateTestProcess(
      root: fixture.root,
      arguments: [
        "shared-install", "shared.ready", "--native-routes",
        "codex.mcp.user,opencode.mcp.user.jsonc", "--shared-config", fixture.config.path,
      ])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let before = try FileSnapshot.read(at: fixture.root)
    let changed = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: fixture.root, homeDirectory: fixture.store.environment.homeDirectory,
        environment: [
          "CODEX_HOME": fixture.config.path,
          "OPENCODE_CONFIG_DIR": fixture.root.appendingPathComponent("wrong-root").path,
        ]))
    #expect(throws: CoreError.self) {
      try changed.withLock(footprint: [.cursorMCPUser]) {
        Issue.record("pending recovery must reject the changed runtime before callback")
      }
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test(arguments: [
    "shared.1.reservation.halfWritten", "shared.ready", "entry.0.applied", "journal.finalized",
  ])
  func multiplePendingResourcesRecoverUnderTheirOriginalRuntime(_ point: String) throws {
    let fixture = try NativeRouteFixture()
    let child = try stateTestProcess(
      root: fixture.root,
      arguments: [
        "shared-install", point, "--native-routes", "codex.mcp.user,opencode.mcp.user.jsonc",
        "--shared-config", fixture.config.path,
      ])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let before = try FileSnapshot.read(at: fixture.root)
    try fixture.store.withReadLock(
      onPendingRecovery: {
        let diagnostic = FileTransaction.recoveryDiagnostic(store: fixture.store)
        #expect(!diagnostic.requiresOwner)
        let context = try #require(TransactionLockContext.current(fixture.store))
        #expect(
          Set(context.resources.map { $0.identity.basename }) == ["config.toml", "opencode.jsonc"])
      }, { _ = Issue.record("expected pending native resources") })
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    var entered = false
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.store.withLock(footprint: [.cursorMCPUser]) { entered = true }
    }
    #expect(!entered)
    try fixture.store.withLock(footprint: [.codexMCPUser, .openCodeMCPUserJSONC]) {
      for route in [NativeTargetRoute.codexMCPUser, .openCodeMCPUserJSONC] {
        let target = try fixture.store.nativeTarget(for: route)
        let receipt = try fixture.store.materializationReceipt(for: target)
        if point == "journal.finalized" {
          #expect(receipt != nil)
        } else {
          #expect(!FileManager.default.fileExists(atPath: target.url.path))
          #expect(receipt == nil)
        }
      }
    }
  }
}

private struct NativeRouteBindings: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    Data(binding.utf8)
  }
}

private final class NativeRouteFixture {
  let root: URL
  let config: URL
  let store: StateStore
  init() throws {
    root = try temporaryDirectory()
    config = root.appendingPathComponent("configured")
    do {
      try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("other-home"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("old-data"), withIntermediateDirectories: true)
      try Data("ordinary before".utf8).write(to: root.appendingPathComponent("old-data/AGENTS.md"))
      store = StateStore(
        scope: .project,
        environment: RuntimeEnvironment(
          projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
          environment: [
            "CLAUDE_CONFIG_DIR": config.path, "CODEX_HOME": config.path,
            "GEMINI_CLI_HOME": config.path, "OPENCODE_CONFIG_DIR": config.path,
          ]))
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }
  deinit { removeTemporaryDirectory(root) }
  @discardableResult
  func recordSkill(name: String, agent: AgentID) throws -> ResolvedLedger {
    let store = self.store
    var ledger = ResolvedLedger()
    ledger.sources["fixture"] = LedgerSource(kind: .local, revision: "live")
    ledger.components["skill"] = LedgerComponent(
      declaringSource: "fixture", source: "fixture", root: ".", kind: "skills",
      name: name,
      payload: .init(object: [:]), conditions: [], recipients: [agent], chatGPT: false,
      resources: [])
    ledger.deployments = [
      LedgerDeployment(
        id: "deployment",
        target: .init(kind: .registered, root: "skills-" + agent.rawValue, path: name),
        route: "agents/skill@1", owners: ["skill"], recipients: [agent], ownership: .generated,
        expectedHash: "sha256:" + FileHash.sha256Hex(data: Data("old".utf8)), created: true)
    ]
    ledger.lowerings = [
      LockedLowering(
        id: "lowering", format: "agents/skill@1", inputs: ["skill"], resources: [],
        deployments: ["deployment"], layout: .init(object: [:]), platform: "macos", artifacts: [])
    ]
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try ResolvedLedgerCodec.encode(ledger, limits: .standard).write(to: store.resolvedURL)
    return ledger
  }
  func journal() throws -> TransactionJournal {
    try FileTransaction.readJournal(
      Data(contentsOf: store.directory.appendingPathComponent("transaction.json")))
  }
}

extension Optional where Wrapped == TransactionLockContext {
  fileprivate func requiredResourceForRoute(_ route: NativeTargetRoute) throws -> SharedResource {
    try #require(self).resource(for: route)
  }
}

extension RegisteredNativeTargetTests {
  private static var componentFiles: [NativeTargetRoute] {
    var result: [NativeTargetRoute] = [
      .claudeSettingsProject, .claudeSettingsUser,
      .codexHooksProject, .codexHooksUser, .cursorHooksProject, .cursorHooksUser,
      .geminiIgnoreProject, .cursorIgnoreProject,
    ]
    for member in [
      NativeTargetRoute.Member.claudeCommand, .claudeAgent, .codexAgent,
      .geminiCommand, .geminiAgent, .cursorCommand, .cursorAgent,
    ] {
      for scope in [InstallScope.project, .user] {
        if let route = try? NativeTargetRoute.named(member, scope: scope, name: "example") {
          result.append(route)
        }
      }
    }
    return result
  }

  @Test(arguments: componentFiles)
  func componentFilesRetainPrivateGenerationOnOrdinarySiblingEdit(_ route: NativeTargetRoute) throws
  {
    let fixture = try NativeRouteFixture()
    let store = StateStore(
      scope: route.shared ? .user : .project, environment: fixture.store.environment)
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivate(
        store.preparePrivateMaterialization(target), provider: NativeRouteBindings()
      ) {
        _ in Data("bound region; unmanaged sibling".utf8)
      }
      try transaction.commit()
      let before = try #require(try store.materializationReceipt(for: target))
      let ordinary = FileTransaction(store: store)
      try ordinary.replace(target.url, with: .data(Data("bound region; edited sibling".utf8)))
      try ordinary.commit()
      let after = try #require(try store.materializationReceipt(for: target))
      #expect(before.generation != after.generation)
      _ = try DirectoryHandle(at: target.url.deletingLastPathComponent()).requirePrivateAccess(
        target.url.lastPathComponent)
    }
    try store.withReadLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      let receipt = try store.materializationReceipt(for: target)
      #expect(receipt != nil)
    }
  }

  @Test func componentRouteBoundariesAndPureFreshHomePreview() throws {
    let fixture = try NativeRouteFixture()
    var environment = fixture.store.environment
    environment.homeDirectory = fixture.root.appendingPathComponent("fresh-home")
    environment.environment = [:]
    let store = StateStore(scope: .user, environment: environment)
    let routes = try Set([
      NativeTargetRoute.named(.claudeCommand, scope: .user, name: "team/check"),
      .named(.geminiExtension, scope: .user, name: "example"),
      .named(.cursorLocalPlugin, scope: .user, name: "example"),
    ])
    let before = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(footprint: routes) {
      for route in routes {
        #expect(try store.nativeTargetIdentity(for: route) == nil)
        let target = try store.nativeTarget(for: route)
        #expect(target.url.path.hasPrefix(environment.homeDirectory.path + "/"))
        #expect(try store.materializationReceipt(for: target) == nil)
      }
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    for name in [
      "", ".", "..", "../escape", "/escape", "a//b", "a/../b", "a\\b", ".agents-native",
      "a/.agents-native/b", ".agents-temporary",
    ] {
      #expect(throws: CoreError.self) {
        try NativeTargetRoute.named(.claudeCommand, scope: .user, name: name)
      }
    }
    #expect(throws: CoreError.self) {
      try NativeTargetRoute.named(.cursorCommand, scope: .user, name: "example")
    }
    #expect(throws: CoreError.self) {
      try NativeTargetRoute.named(.geminiExtension, scope: .project, name: "example")
    }
    #expect(throws: CoreError.self) { try fixture.store.nativeTarget(for: .claudeSettingsUser) }
    let beforeRefusal = try FileSnapshot.read(at: fixture.root)
    #expect(throws: CoreError.self) {
      try fixture.store.withLock(footprint: [.claudeSettingsUser]) {
        _ = Issue.record("wrong-scope request must be refused before callback")
      }
    }
    #expect(try FileSnapshot.read(at: fixture.root) == beforeRefusal)
    var collidingEnvironment = fixture.store.environment
    collidingEnvironment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent(".claude").path
    let colliding = StateStore(scope: .project, environment: collidingEnvironment)
    #expect(throws: CoreError.self) {
      try colliding.nativeTarget(for: .named(.claudeAgent, scope: .project, name: "example"))
    }
    #expect(try FileSnapshot.read(at: fixture.root) == beforeRefusal)
    let linkParent = fixture.config.appendingPathComponent("commands")
    try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: fixture.root)
    let user = StateStore(scope: .user, environment: fixture.store.environment)
    #expect(throws: CoreError.self) {
      try user.nativeTarget(for: .named(.claudeCommand, scope: .user, name: "escape"))
    }
    #expect(NativeTargetRoute.claudeSettingsUser.knownReaders == [.claudeCode, .cursor])
    let fileRoute = try NativeTargetRoute.file(
      .claudeCommand, scope: .user, relativePath: "team/check.md")
    let namedRoute = try NativeTargetRoute.named(.claudeCommand, scope: .user, name: "team/check")
    #expect(fileRoute == namedRoute)
    #expect(throws: CoreError.self) {
      try NativeTargetRoute.file(.claudeCommand, scope: .user, relativePath: "team/check.toml")
    }
  }

  @Test func aliasedComponentKindsShareIdentityAndSensitiveReceiptAcrossHomes() throws {
    let fixture = try NativeRouteFixture()
    var environment = fixture.store.environment
    environment.environment["GEMINI_CLI_HOME"] = fixture.root.path
    environment.environment["CLAUDE_CONFIG_DIR"] =
      fixture.root.appendingPathComponent(".gemini").path
    let a = StateStore(scope: .user, environment: environment)
    environment.homeDirectory = fixture.root.appendingPathComponent("other-home")
    let b = StateStore(scope: .project, environment: environment)
    let routes: Set<NativeTargetRoute> = [.claudeSettingsUser, .geminiMCPUser, .cursorHooksUser]
    var identity: NativeTargetIdentity?
    try a.withLock(footprint: routes) {
      let first = try a.nativeTarget(for: .claudeSettingsUser)
      let second = try a.nativeTarget(for: .geminiMCPUser)
      #expect(first.path == second.path)
      identity = try a.nativeTargetIdentity(for: .claudeSettingsUser)
      #expect(identity == (try a.nativeTargetIdentity(for: .geminiMCPUser)))
      #expect(identity != (try a.nativeTargetIdentity(for: .cursorHooksUser)))
      let transaction = FileTransaction(store: a)
      try transaction.replacePrivate(
        a.preparePrivateMaterialization(first), provider: NativeRouteBindings()
      ) { _ in Data("bound; sibling".utf8) }
      try transaction.commit()
    }
    try b.withLock(footprint: [.geminiMCPUser]) {
      let target = try b.nativeTarget(for: .geminiMCPUser)
      #expect(identity == (try b.nativeTargetIdentity(for: .geminiMCPUser)))
      let previous = try #require(try b.materializationReceipt(for: target))
      let transaction = FileTransaction(store: b)
      try transaction.replace(target.url, with: .data(Data("bound; changed sibling".utf8)))
      try transaction.commit()
      #expect(try b.materializationReceipt(for: target)?.generation != previous.generation)
    }
    try a.withReadLock(footprint: [.claudeSettingsUser]) {
      let target = try a.nativeTarget(for: .claudeSettingsUser)
      let receipt = try a.materializationReceipt(for: target)
      #expect(receipt != nil)
    }
  }
}

extension RegisteredNativeTargetTests {
  @Test(arguments: ["shared.1.reservation.halfWritten", "entry.0.applied", "journal.finalized"])
  func namedFilesWithEqualBasenamesRecoverThroughTheirClosedRoots(_ point: String) throws {
    let fixture = try NativeRouteFixture()
    let routes = try [
      NativeTargetRoute.named(.claudeAgent, scope: .user, name: "example"),
      .named(.cursorAgent, scope: .user, name: "example"),
    ]
    let store = StateStore(scope: .user, environment: fixture.store.environment)
    let child = try stateTestProcess(
      root: fixture.root,
      arguments: [
        "shared-install", point, "--native-routes", routes.map(\.rawValue).joined(separator: ","),
        "--shared-config", fixture.config.path, "--scope", "user",
      ])
    defer { terminateProcess(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    terminateProcess(child)
    let before = try FileSnapshot.read(at: fixture.root)
    try store.withReadLock(
      onPendingRecovery: {
        let diagnosis = FileTransaction.recoveryDiagnostic(store: store)
        #expect(!diagnosis.requiresOwner)
      }, { _ = Issue.record("expected pending named targets") })
    #expect(try FileSnapshot.read(at: fixture.root) == before)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    try store.withReadLock(footprint: Set(routes)) {
      for route in routes {
        let target = try store.nativeTarget(for: route)
        let receipt = try store.materializationReceipt(for: target)
        #expect((receipt != nil) == (point == "journal.finalized"))
      }
    }
  }

  @Test(arguments: [
    NativeTargetRoute.Member.claudeSkillPlugin, .cursorLocalPlugin, .geminiExtension,
  ])
  func registeredBundleContainersPublishAndDeleteWithoutInstallerAuthority(
    _ member: NativeTargetRoute.Member
  ) throws {
    let fixture = try NativeRouteFixture()
    let store = StateStore(scope: .user, environment: fixture.store.environment)
    let route = try NativeTargetRoute.named(member, scope: .user, name: "example")
    let payload = fixture.root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    try Data("native manifest fixture".utf8).write(
      to: payload.appendingPathComponent("manifest.json"))
    try store.withLock(footprint: [route]) {
      let target = try store.nativeTarget(for: route)
      #expect(throws: CoreError.self) { try store.preparePrivateMaterialization(target) }
      #expect(throws: CoreError.self) {
        let invalid = FileTransaction(store: store)
        try invalid.replace(target.url, with: .data(Data("wrong kind".utf8)))
      }
      let transaction = FileTransaction(store: store)
      try transaction.replace(target.url, with: .copy(payload))
      try transaction.commit()
      #expect(
        try Data(contentsOf: target.url.appendingPathComponent("manifest.json"))
          == Data("native manifest fixture".utf8))
      #expect(throws: CoreError.self) {
        let outside = fixture.root.appendingPathComponent("outside-native-root")
        try FileTransaction(store: store).replace(outside, with: .copy(payload))
      }
      let removal = FileTransaction(store: store)
      try removal.delete(target.url)
      try removal.commit()
      #expect(!FileManager.default.fileExists(atPath: target.url.path))
    }
  }
}

extension RegisteredNativeTargetTests {
  @Test func projectAliasesPreserveWholeFileSensitivityAcrossComponentKinds() throws {
    let fixture = try NativeRouteFixture()
    let store = fixture.store
    let claude = try NativeTargetRoute.named(.claudeAgent, scope: .project, name: "example")
    let cursor = try NativeTargetRoute.named(.cursorAgent, scope: .project, name: "example")
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent(".cursor"),
      withDestinationURL: fixture.root.appendingPathComponent(".claude"))
    try store.withLock(footprint: [claude, cursor]) {
      let a = try store.nativeTarget(for: claude)
      let b = try store.nativeTarget(for: cursor)
      #expect(a.path == b.path)
      let transaction = FileTransaction(store: store)
      try transaction.replacePrivate(
        store.preparePrivateMaterialization(a), provider: NativeRouteBindings()
      ) { _ in Data("private sibling; first region".utf8) }
      try transaction.commit()
    }
    try store.withLock(footprint: [cursor]) {
      let target = try store.nativeTarget(for: cursor)
      let before = try #require(try store.materializationReceipt(for: target))
      let transaction = FileTransaction(store: store)
      try transaction.replace(target.url, with: .data(Data("private sibling; changed region".utf8)))
      try transaction.commit()
      #expect(try store.materializationReceipt(for: target)?.generation != before.generation)
    }
    try store.withReadLock(footprint: [claude]) {
      let target = try store.nativeTarget(for: claude)
      let receipt = try store.materializationReceipt(for: target)
      #expect(receipt != nil)
    }
  }
}
