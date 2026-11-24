import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Transaction I/O cost")
struct TransactionCostTests {
  @Test func mixedInstallationBatchKeepsEachTargetUnderItsRegisteredRoot() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let home = root.appendingPathComponent("home")
    let loader = root.appendingPathComponent("claude")
    let physical = root.appendingPathComponent("physical-claude")
    try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: loader, withDestinationURL: physical)
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let bytes = Data("generated skill\n".utf8)
    try bytes.write(to: source.appendingPathComponent("SKILL.md"))
    let store = StateStore(
      scope: .user,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: home,
        environment: ["CLAUDE_CONFIG_DIR": loader.path]))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let agents =
      Array(repeating: AgentID.codex, count: 16)
      + Array(repeating: AgentID.claudeCode, count: 8)
    let targets = try agents.enumerated().map {
      try store.skillInstallationTarget(for: $0.element, named: "generated-\($0.offset)")
    }
    try store.withLock(installations: targets) {
      let transaction = FileTransaction(store: store)
      for target in targets { try transaction.replaceSkill(target, with: .link(source)) }
      try transaction.commit()
    }
    for target in targets {
      let installed = try #require(try FileSnapshot.read(at: target.url))
      #expect(installed.isSymbolicLink)
      #expect(try Data(contentsOf: target.url.appendingPathComponent("SKILL.md")) == bytes)
      let expected =
        target.agent == .claudeCode
        ? physical.appendingPathComponent("skills") : home.appendingPathComponent(".agents/skills")
      #expect(target.url.deletingLastPathComponent().path == expected.path)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent("transaction.json").path))
  }

  @Test func coincidentInstallationParentsRetainBothLoaderChecks() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let original = root.appendingPathComponent(".agents")
    let redirected = root.appendingPathComponent("redirected")
    let alias = root.appendingPathComponent(".claude")
    for parent in [original, redirected] {
      try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("skills"), withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("generated skill\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let codex = try store.skillInstallationTarget(for: .codex, named: "codex-skill")
    let claude = try store.skillInstallationTarget(for: .claudeCode, named: "claude-skill")
    #expect(try #require(codex.parentIdentity) == claude.parentIdentity)
    var moved = false
    #expect(throws: CoreError.self) {
      try store.withLock(installations: [codex, claude]) {
        let transaction = FileTransaction(store: store) { point in
          if point == TransactionCheckpoint.phase(.preparing).name {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: redirected)
            moved = true
          }
        }
        try transaction.replaceSkill(codex, with: .link(source))
        try transaction.replaceSkill(claude, with: .link(source))
        try transaction.commit()
      }
    }
    #expect(moved)
    for parent in [original, redirected] {
      for target in [codex, claude] {
        let url = parent.appendingPathComponent("skills").appendingPathComponent(target.name)
        #expect(try FileSnapshot.read(at: url) == nil)
      }
    }
    let journal = store.directory.appendingPathComponent("transaction.json")
    #expect(FileManager.default.fileExists(atPath: journal.path))
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.withLock {} }
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    for parent in [original, redirected] {
      #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path + "/skills").isEmpty)
    }
  }

  @Test func containersOnOneDeviceShareOneProbe() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    var steps: [String] = []
    try store.withLock {
      let transaction = FileTransaction(store: store) { steps.append($0) }
      try transaction.replace(
        root.appendingPathComponent("AGENTS.md"), with: .data(Data("after".utf8)))
      try transaction.replace(
        store.declarationURL, with: .data(manifestText("defaultAgents: [\"codex\"]\n")))
      try transaction.commit()
    }
    #expect(steps.contains(TransactionCheckpoint.containerCreated(1).name))
    #expect(steps.contains(TransactionCheckpoint.probe(0, .verified).name))
    #expect(!steps.contains(TransactionCheckpoint.probe(1, .firstCreated).name))
  }
}
