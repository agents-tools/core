import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Registered native MCP files")
struct RegisteredNativeTargetTests {
  @Test(arguments: NativeTargetRoute.allCases)
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
