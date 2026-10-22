import AgentsCore
import AgentsInstructions
import AgentsSkills
import Darwin
import Foundation
import Testing

@Suite("Read-only skill inspection")
struct ReadOnlyInspectionTests {
  @Test(arguments: [false, true], [false, true])
  func firstSkillAddRetriesAnUnlockedRead(_ cached: Bool, _ bodyThrows: Bool) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Committed content")
    try fixture.commit()
    let store = fixture.store()
    if cached {
      _ = try SourceCache(store: store).resolve(
        SourceDeclaration(kind: .local, location: fixture.repo.path))
    }
    let lock = store.directory.appendingPathComponent(".agents.lock")
    try #require(!FileManager.default.fileExists(atPath: lock.path))
    var reads = 0

    let skills = try store.withReadLock {
      reads += 1
      let skills = try store.readResolved().skills
      if reads == 1 {
        try #require(skills.isEmpty)
        _ = try fixture.add(mode: .copy)
        if bodyThrows { throw CoreError.invalidState("inconsistent inspection") }
      } else {
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let acquired = flock(descriptor, LOCK_EX | LOCK_NB)
        let lockError = errno
        #expect(acquired == -1)
        #expect(lockError == EWOULDBLOCK)
      }
      return skills
    }
    #expect(reads == 2)
    #expect(skills.keys.sorted() == ["demo"])
    #expect(skills["demo"]?.revision == (try fixture.head()))
    #expect(try fixture.body(fixture.target("demo")).contains("Committed content"))
  }

  @Test(arguments: [InstallScope.project, .user])
  func pendingRefCleanupSurvivesDoctorsListingsAndPreviews(_ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    try fixture.commit()
    _ = try fixture.add(mode: .copy, scope: scope)
    try SkillOperations.watchOperations().add(
      "fixture", scope: scope, environment: fixture.environment)
    try Data().write(
      to: fixture.store(scope).directory.appendingPathComponent("watch-refs.pending"))

    try inspectPendingRecovery(
      root: fixture.root, scope: scope, environment: fixture.environment, source: fixture.repo.path)
  }

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
    try inspectPendingRecovery(
      root: root, scope: scope, environment: environment, source: new.path)
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

  @Test(arguments: [InstallScope.project, .user], [true, false])
  func addSelectionLeavesStateAndSourcesUnchanged(
    _ scope: InstallScope, _ existingDirectory: Bool
  ) throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "B")
    let instructions = fixture.repo.appendingPathComponent("instructions")
    try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: true)
    for name in ["one", "two"] {
      try Data("# \(name)\n\nInstructions\n".utf8).write(
        to: instructions.appendingPathComponent(name + ".md"))
    }
    try fixture.commit()
    for directory in [fixture.environment.projectDirectory, fixture.environment.homeDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let store = fixture.store(scope)
    if existingDirectory {
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      try StateStore.encode(
        Declaration(sources: [
          "relative": SourceDeclaration(kind: .local, location: "../source"),
          "remote": SourceDeclaration(kind: .git, location: "file://localhost" + fixture.repo.path),
        ])
      ).write(to: store.declarationURL)
    }
    let before = try snapshot(fixture.root)
    let sources =
      ["../source", "~/../source"] + (existingDirectory ? ["relative", "remote"] : [])
    for source in sources {
      for listOnly in [false, true] {
        let skills = try SkillOperations.add(
          AddOptions(
            source: source, scope: scope, listOnly: listOnly,
            sourceRequirement: .branch("master"), environment: fixture.environment))
        #expect(skills.availableSkills.map(\.name) == ["one", "two"])
        #expect(skills.installed.isEmpty)
        #expect(try snapshot(fixture.root) == before)
        let report = try InstructionOperations.add(
          InstructionAddOptions(
            source: source, listOnly: listOnly, scope: scope,
            sourceRequirement: .branch("master"), environment: fixture.environment))
        #expect(report.available.map(\.record.name) == ["one", "two"])
        #expect(report.result == nil)
        #expect(try snapshot(fixture.root) == before)
      }
    }
  }

  @Test func emptyAddSelectionDoesNotCreateState() throws {
    let fixture = try SkillFixture()
    try FileManager.default.createDirectory(at: fixture.repo, withIntermediateDirectories: true)
    try Data("Empty source\n".utf8).write(to: fixture.repo.appendingPathComponent("README.md"))
    try fixture.commit()
    let before = try snapshot(fixture.root)
    #expect(throws: CoreError.notFound("no skills found in \(fixture.repo.path)")) {
      try SkillOperations.add(
        AddOptions(source: fixture.repo.path, environment: fixture.environment))
    }
    #expect(try snapshot(fixture.root) == before)
    #expect(throws: CoreError.notFound("source provides no instructions")) {
      try InstructionOperations.add(
        InstructionAddOptions(source: fixture.repo.path, environment: fixture.environment))
    }
    #expect(try snapshot(fixture.root) == before)
  }

  @Test func addSelectionCanReadACachedHistoricalCommitWithoutChangingTheMirror() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "B")
    let instructions = fixture.repo.appendingPathComponent("instructions")
    try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: true)
    for name in ["one", "two"] {
      try Data("# \(name)\n\nInstructions\n".utf8).write(
        to: instructions.appendingPathComponent(name + ".md"))
    }
    try fixture.commit()
    let revision = try fixture.head()
    let source = "fixture"
    try fixture.store().save(
      declaration: Declaration(sources: [
        source: SourceDeclaration(kind: .git, location: "file://localhost" + fixture.repo.path)
      ]), resolved: ResolvedState())
    _ = try SkillOperations.add(
      AddOptions(source: source, agents: [.codex], all: true, environment: fixture.environment))
    // A cached immutable pin remains inspectable when upstream no longer provides it.
    try FileManager.default.removeItem(at: fixture.repo)
    let before = try snapshot(fixture.root)
    let skills = try SkillOperations.add(
      AddOptions(
        source: source, sourceRequirement: .revision(revision), environment: fixture.environment))
    #expect(skills.availableSkills.map(\.name) == ["one", "two"])
    #expect(skills.installed.isEmpty)
    let report = try InstructionOperations.add(
      InstructionAddOptions(
        source: source, sourceRequirement: .revision(revision), environment: fixture.environment))
    #expect(report.available.map(\.record.name) == ["one", "two"])
    #expect(report.available.allSatisfy { $0.record.revision == revision })
    #expect(report.result == nil)
    #expect(try snapshot(fixture.root) == before)
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

  private func inspectPendingRecovery(
    root: URL, scope: InstallScope, environment: RuntimeEnvironment, source: String
  ) throws {
    let store = StateStore(scope: scope, environment: environment)
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
    for listOnly in [false, true] {
      #expect(throws: pending) {
        try SkillOperations.add(
          AddOptions(source: source, scope: scope, listOnly: listOnly, environment: environment))
      }
      #expect(try snapshot(root) == before)
      #expect(throws: pending) {
        try InstructionOperations.add(
          InstructionAddOptions(
            source: source, listOnly: listOnly, scope: scope, environment: environment))
      }
      #expect(try snapshot(root) == before)
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
    #expect(throws: pending) {
      try InstructionOperations.list(
        source: SourceDeclaration(kind: .local, location: source),
        scope: scope, environment: environment)
    }
    #expect(try snapshot(root) == before)
    let watch = SkillOperations.watchOperations()
    #expect(throws: pending) { try watch.status(scope: scope, environment: environment) }
    #expect(try snapshot(root) == before)
    #expect(throws: pending) { try watch.diff(source, scope: scope, environment: environment) }
    #expect(try snapshot(root) == before)
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
        let mode =
          try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
          as? NSNumber
        result[path] = .file(
          try Data(contentsOf: file), executable: (mode?.uint16Value ?? 0) & 0o111 != 0)
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
