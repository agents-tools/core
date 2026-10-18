import AgentsCore
import AgentsInstructions
import AgentsSkills
import Darwin
import Foundation
import Testing

@Suite("Read-only skill inspection")
struct ReadOnlyInspectionTests {
  @Test(arguments: [InstallScope.project, .user])
  func pendingTransactionSurvivesDoctorsListingsAndPreviews(_ scope: InstallScope) throws {
    try inspectPendingTransaction(scope: scope, initialize: false)
  }

  @Test func initializationRecoversPendingProjectTransaction() throws {
    try inspectPendingTransaction(scope: .project, initialize: true)
  }

  private func inspectPendingTransaction(
    scope: InstallScope, initialize: Bool
  ) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
      environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path])
    let store = StateStore(scope: scope, environment: environment)
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let target = AgentRegistry.installSkillsDirectory(
      for: .codex, scope: scope, environment: environment
    ).appendingPathComponent("target")
    let new = root.appendingPathComponent("new")
    for directory in [target, new] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(directory.lastPathComponent.utf8).write(
        to: directory.appendingPathComponent("SKILL.md"))
    }
    let instructions = InstructionLocations.file(
      for: .codex, scope: scope, environment: environment)!
    let created = InstructionLocations.file(
      for: .geminiCLI, scope: scope, environment: environment)!
    try FileManager.default.createDirectory(
      at: instructions.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("Original instructions\n".utf8).write(to: instructions)
    let child = try interruptedTransaction(root: root, scope: scope)
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = root.appendingPathComponent("ready")
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    #expect(!FileManager.default.fileExists(atPath: instructions.path))
    #expect(try Data(contentsOf: created) == Data("New instructions\n".utf8))
    #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == Data("new".utf8))
    try #require(
      FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent("transaction.json").path))
    let before = try snapshot(root)

    let skills = try SkillOperations.doctor(scope: scope, environment: environment)
    #expect(skills.checks.map(\.id) == ["pending-recovery"])
    #expect(skills.checks.first?.status == .warning)
    #expect(skills.ok)
    #expect(skills.checks.first?.path == store.directory.path)
    #expect(skills.checks.first?.message.contains("next command that changes this scope") == true)
    #expect(try snapshot(root) == before)
    let report = try InstructionOperations.doctor(scope: scope, environment: environment)
    #expect(report.diagnostics.map(\.kind) == [.pendingRecovery])
    #expect(report.diagnostics.first?.path == store.directory)
    #expect(
      report.diagnostics.first?.message.contains("next command that changes this scope") == true)
    #expect(try snapshot(root) == before)

    let pending = CoreError.invalidState("transaction recovery is required before inspection")
    #expect(throws: pending) {
      try SkillOperations.listManaged(scope: scope, environment: environment)
    }
    #expect(try snapshot(root) == before)
    #expect(throws: pending) {
      try SkillOperations.listInstalled(scope: scope, environment: environment)
    }
    #expect(try snapshot(root) == before)
    #expect(throws: pending) {
      try SkillOperations.removableSkillNames(scope: scope, environment: environment)
    }
    #expect(throws: pending) {
      try SkillOperations.add(
        AddOptions(source: new.path, scope: scope, listOnly: true, environment: environment))
    }
    #expect(throws: pending) {
      try SkillOperations.updateInstalled(scope: scope, environment: environment)
    }
    #expect(throws: pending) {
      try InstructionOperations.listManaged(scope: scope, environment: environment)
    }
    #expect(throws: pending) {
      try InstructionOperations.updateInstalled(scope: scope, environment: environment)
    }
    #expect(try snapshot(root) == before)
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) {
      if initialize {
        _ = try SkillOperations.initializeSkill(named: "authored", directory: root)
      } else {
        _ = try SkillOperations.updateInstalled(scope: scope, environment: environment, apply: true)
      }
    }
    #expect(try Data(contentsOf: instructions) == Data("Original instructions\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: created.path))
    #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == Data("target".utf8))
  }

  @Test(arguments: [SourceKind.local, .git], [true, false])
  func doctorInspectsAdvancedUpstreamWithoutFetching(_ kind: SourceKind, _ retainMirror: Bool)
    throws
  {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    try fixture.commit()
    let source = SourceDeclaration(
      kind: kind,
      location: kind == .local ? fixture.repo.path : "file://localhost" + fixture.repo.path,
      requirement: .branch("master"))
    try fixture.store().save(
      declaration: Declaration(
        agents: [.codex], sources: ["fixture": source],
        skills: ["fixture": SkillDeclaration(select: .all)]), resolved: ResolvedState())
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    try fixture.skill("demo", body: "Upstream")
    try fixture.commit()
    try fixture.skill("demo", body: "Uncommitted")
    let mirrors = fixture.store().cacheDirectory.appendingPathComponent("mirrors")
    if !retainMirror { try FileManager.default.removeItem(at: mirrors) }
    let before = try snapshot(fixture.root)
    let report = try SkillOperations.doctor(environment: fixture.environment)
    let update = try #require(report.checks.first { $0.id == "source-update" })
    #expect(update.message == "fixture has a newer matching revision")
    #expect(!report.checks.contains { $0.id == "source-unavailable" })
    #expect(report.checks.contains { $0.id == "uncommitted-source" } == (kind == .local))
    #expect(try snapshot(fixture.root) == before)
    #expect(FileManager.default.fileExists(atPath: mirrors.path) == retainMirror)
  }

  @Test(arguments: [InstallScope.project, .user], [true, false])
  func inspectionsDoNotCreateStateFiles(_ scope: InstallScope, _ existingDirectory: Bool) throws {
    let fixture = try SkillFixture()
    let store = fixture.store(scope)
    if existingDirectory {
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      try StateStore.encode(Declaration()).write(to: store.declarationURL)
    }
    let before = try snapshot(fixture.root)
    #expect(
      try SkillOperations.doctor(scope: scope, environment: fixture.environment).checks.isEmpty)
    #expect(try SkillOperations.listManaged(scope: scope, environment: fixture.environment).isEmpty)
    #expect(
      try SkillOperations.listInstalled(scope: scope, environment: fixture.environment).isEmpty)
    #expect(
      try SkillOperations.updateInstalled(scope: scope, environment: fixture.environment).isEmpty)
    #expect(try snapshot(fixture.root) == before)
  }

  @Test(arguments: [true, false])
  func pinnedDoctorsDoNotCreateMissingMirrorLocks(_ removeDirectory: Bool) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    let instructions = fixture.repo.appendingPathComponent("instructions")
    try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: true)
    try Data("# Rules\n\nInstructions\n".utf8).write(
      to: instructions.appendingPathComponent("rules.md"))
    try fixture.commit()
    let source = SourceDeclaration(
      kind: .git, location: "file://localhost" + fixture.repo.path,
      requirement: .revision(try fixture.head()))
    try fixture.store().save(
      declaration: Declaration(
        agents: [.codex], sources: ["fixture": source],
        skills: ["fixture": SkillDeclaration(select: .all)],
        instructions: InstructionsDeclaration(sections: ["fixture:rules"])),
      resolved: ResolvedState())
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    let locks = fixture.store().cacheDirectory.appendingPathComponent("locks")
    let files = try FileManager.default.contentsOfDirectory(
      at: locks, includingPropertiesForKeys: nil)
    try #require(!files.isEmpty)
    for file in removeDirectory ? [locks] : files { try FileManager.default.removeItem(at: file) }
    let before = try snapshot(fixture.root)
    let skills = try SkillOperations.doctor(environment: fixture.environment)
    #expect(!skills.checks.contains { $0.id == "source-unavailable" || $0.id == "source-update" })
    #expect(try snapshot(fixture.root) == before)
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(
      !report.diagnostics.contains {
        $0.kind == .sourceResolutionFailed || $0.kind == .sourceUpdateAvailable
      })
    #expect(try snapshot(fixture.root) == before)
  }

  private func snapshot(_ directory: URL) throws -> [String: SkillFileEntry] {
    let entries = try #require(
      FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: SkillFileEntry] = [:]
    for case let file as URL in entries {
      let path = PathSafety.relativePath(file.path, to: directory.path)
      if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
        result[path] = .symbolicLink(link)
      } else if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[path] = .file(try Data(contentsOf: file))
      } else {
        result[path] = .directory
      }
    }
    return result
  }

  private func interruptedTransaction(root: URL, scope: InstallScope) throws -> Process {
    var directory = Bundle(for: InspectionTestBundle.self).bundleURL.deletingLastPathComponent()
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let process = Process()
    process.executableURL = directory.appendingPathComponent("StateTestProcess")
    process.arguments = [root.path, "inspection-transaction", "replace.4", scope.rawValue]
    try process.run()
    return process
  }
}

private final class InspectionTestBundle: NSObject {}
