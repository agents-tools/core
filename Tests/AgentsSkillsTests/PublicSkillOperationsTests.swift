import AgentsCore
import AgentsSkills
import Foundation
import Testing

@Suite("Public Skill Operations")
struct PublicSkillOperationsTests {
  @Test(arguments: [false, true])
  func watchOnlyRejectsMalformedStateBeforeWriting(_ sourceIsProject: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = sourceIsProject ? root : root.appendingPathComponent("source")
    _ = try SkillOperations.initializeSkill(
      named: "demo", directory: source.appendingPathComponent("skills"))
    let installed = try SkillOperations.initializeSkill(
      named: "installed", directory: root.appendingPathComponent(".agents/skills"))
    let installedFile = installed.appendingPathComponent("SKILL.md")
    let originalInstalled = try Data(contentsOf: installedFile)
    let url = root.appendingPathComponent(".agent/skills.resolved")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let malformed = Data("{broken".utf8)
    try malformed.write(to: url)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])

    #expect(throws: CoreError.invalidState("resolved file \(url.path) could not be decoded")) {
      try SkillOperations.add(
        AddOptions(
          source: sourceIsProject ? "." : source.path, all: true, watchOnly: true,
          environment: environment))
    }
    #expect(try Data(contentsOf: url) == malformed)
    #expect(try Data(contentsOf: installedFile) == originalInstalled)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".agents/skills/demo").path))
    #expect(try SkillOperations.watches.store.load(environment: environment).watches.isEmpty)
  }

  @Test(arguments: [false, true])
  func sourceOperationsIgnoreMalformedSourceHint(_ listOnly: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let source = root.appendingPathComponent("source")
    let skill = try SkillOperations.initializeSkill(
      named: "demo", directory: source.appendingPathComponent("skills"))
    let sourceResolved = source.appendingPathComponent(".agent/skills.resolved")
    let projectResolved = project.appendingPathComponent(".agent/skills.resolved")
    for url in [sourceResolved, projectResolved] {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let malformed = Data("{\n<<<<<<< HEAD\n}".utf8)
    let valid = Data(#"{"version":1,"pins":[]}"#.utf8)
    try malformed.write(to: sourceResolved)
    try valid.write(to: projectResolved)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: root.appendingPathComponent("home"),
      environment: [:])
    let outcome = try SkillOperations.add(
      AddOptions(
        source: source.path, skillNames: ["demo"], mode: .copy, listOnly: listOnly,
        environment: environment))
    #expect(outcome.availableSkills.map(\.name) == ["demo"])
    #expect(try Data(contentsOf: sourceResolved) == malformed)
    if listOnly {
      #expect(outcome.installed.isEmpty)
      #expect(try Data(contentsOf: projectResolved) == valid)
      #expect(
        !FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents").path))
    } else {
      #expect(
        try Data(contentsOf: project.appendingPathComponent(".agents/skills/demo/SKILL.md"))
          == Data(contentsOf: skill.appendingPathComponent("SKILL.md")))
    }
  }

  @Test func listsSourceDespiteMalformedProjectState() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    _ = try SkillOperations.initializeSkill(
      named: "demo", directory: source.appendingPathComponent("skills"))
    let url = root.appendingPathComponent(".agent/skills.resolved")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let malformed = Data("{broken".utf8)
    try malformed.write(to: url)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let outcome = try SkillOperations.add(
      AddOptions(source: source.path, listOnly: true, environment: environment))
    #expect(outcome.availableSkills.map(\.name) == ["demo"])
    #expect(try Data(contentsOf: url) == malformed)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents").path))
  }

  @Test(arguments: [false, true])
  func installedListsRejectMalformedState(_ all: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent(".agent/skills.resolved")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":1}"#.utf8).write(to: url)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    #expect(throws: CoreError.invalidState("resolved file \(url.path) could not be decoded")) {
      if all {
        _ = try SkillOperations.listInstalled(
          scope: .project, agents: [.codex], environment: environment)
      } else {
        _ = try SkillOperations.listManaged(
          scope: .project, agents: [.codex], environment: environment)
      }
    }
  }

  @Test func appliesDiscoveryOptionsThroughPublicAPI() throws {
    let root = try temporaryDirectory()
    let source = root.appendingPathComponent("source")
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    #expect(throws: CoreError.self) {
      try SkillOperations.add(AddOptions(source: source.path, all: true, environment: environment))
    }
    let skill = try SkillOperations.initializeSkill(
      named: "internal-skill", directory: source.appendingPathComponent("skills"))
    try """
    ---
    name: internal-skill
    description: Internal skill
    metadata:
      internal: true
    ---
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    for value in ["", "false", "true", "1"] {
      var configured = environment
      configured.environment["INSTALL_INTERNAL_SKILLS"] = value
      let options = AddOptions(source: source.path, listOnly: true, environment: configured)
      if value == "true" || value == "1" {
        #expect(try SkillOperations.add(options).availableSkills.map(\.name) == ["internal-skill"])
      } else {
        #expect(throws: CoreError.self) { try SkillOperations.add(options) }
      }
    }
    let publicSkill = try SkillOperations.initializeSkill(
      named: "public-skill", directory: source.appendingPathComponent("skills"))
    try """
    ---
    name: public-skill
    description: Public skill
    metadata:
      internal: false
    ---
    """.write(to: publicSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    var internalDisabled = environment
    internalDisabled.environment["INSTALL_INTERNAL_SKILLS"] = "false"
    let publicOnly = try SkillOperations.add(
      AddOptions(source: source.path, listOnly: true, environment: internalDisabled))
    #expect(publicOnly.availableSkills.map(\.name) == ["public-skill"])
    _ = try SkillOperations.initializeSkill(
      named: "shallow", directory: source.appendingPathComponent("skills"))
    _ = try SkillOperations.initializeSkill(
      named: "deep", directory: source.appendingPathComponent("skills/level-1/level-2"))
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(source: source.path, skillNames: ["deep"], environment: environment))
    }
    let installed = try SkillOperations.add(
      AddOptions(
        source: source.path, skillNames: ["deep"], fullDepth: true, environment: environment))
    #expect(installed.installed.map(\.skill) == ["deep"])
    let listed = try SkillOperations.add(
      AddOptions(source: source.path, listOnly: true, fullDepth: true, environment: environment))
    #expect(Set(listed.availableSkills.map(\.name)) == ["public-skill", "shallow", "deep"])
    #expect(throws: CoreError.self) { try AgentID.parse("invalid-agent") }
  }

  @Test func initializesUpdatesRestoresAndRemovesSkillsThroughPublicAPI() throws {
    let root = try temporaryDirectory()
    let source = root.appendingPathComponent("source")
    let skill = try SkillOperations.initializeSkill(named: "updatable", directory: source)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let added = try SkillOperations.add(
      AddOptions(source: source.path, mode: .copy, environment: environment))
    let installation = URL(fileURLWithPath: try #require(added.installed.first?.path))
    try "new".write(to: skill.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    let preview = try SkillOperations.updateInstalled(
      scope: .project, environment: environment, apply: false)
    #expect(preview.first?.changed == true)
    #expect(
      !FileManager.default.fileExists(atPath: installation.appendingPathComponent("notes.md").path))
    let updated = try SkillOperations.updateInstalled(
      scope: .project, environment: environment, apply: true)
    #expect(updated.first?.installed.first?.skill == "updatable")
    try FileManager.default.removeItem(at: installation)
    let restored = try SkillOperations.installResolvedReport(environment: environment)
    #expect(restored.installed.map(\.skill) == ["updatable"])
    #expect(restored.skipped.isEmpty)
    #expect(
      try SkillOperations.doctor(scope: .project, agents: [.codex], environment: environment).ok)
    #expect(
      try SkillOperations.removableSkillNames(
        scope: .project, agents: [.codex], environment: environment) == ["updatable"])
    _ = try SkillOperations.remove(
      skillNames: ["UPDATABLE"], scope: .project, agents: [.codex], environment: environment)
    #expect(!FileManager.default.fileExists(atPath: installation.path))
    #expect(
      try SkillOperations.listManaged(scope: .project, agents: [.codex], environment: environment)
        .isEmpty)
  }

  @Test func removesUnmanagedSkillsByNameAgentAndScope() throws {
    let root = try temporaryDirectory()
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let base = root.appendingPathComponent(".agents/skills")
    for name in ["skill-one", "skill-two", "skill_with_underscores"] {
      _ = try SkillOperations.initializeSkill(named: name, directory: base)
    }
    _ = try SkillOperations.remove(
      skillNames: ["SKILL-ONE"], scope: .project, agents: [.codex], environment: environment)
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("skill-one").path))
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("skill-two").path))
    #expect(throws: CoreError.self) {
      try SkillOperations.remove(
        skillNames: ["skill-two"], scope: .global, agents: [.codex], environment: environment)
    }
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("skill-two").path))
    _ = try SkillOperations.remove(
      skillNames: ["skill-two", "skill_with_underscores"], scope: .project,
      agents: [.codex], environment: environment)
    #expect(
      try SkillOperations.listInstalled(scope: .project, agents: [.codex], environment: environment)
        .isEmpty)
    let invalid = base.appendingPathComponent("invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    _ = try SkillOperations.initializeSkill(named: "valid", directory: base)
    _ = try SkillOperations.remove(
      skillNames: ["valid"], scope: .project, agents: [.codex], environment: environment)
    #expect(FileManager.default.fileExists(atPath: invalid.path))
    let native = root.appendingPathComponent(".gemini/skills")
    _ = try SkillOperations.initializeSkill(named: "gemini-only", directory: native)
    #expect(
      try SkillOperations.listInstalled(
        scope: .project, agents: [.geminiCLI], environment: environment
      ).map(\.name) == ["gemini-only"])
    _ = try SkillOperations.remove(
      skillNames: ["gemini-only"], scope: .project, agents: [.geminiCLI], environment: environment)
    #expect(
      !FileManager.default.fileExists(atPath: native.appendingPathComponent("gemini-only").path))
  }

  @Test func updatesFromWatchPreservingInferredInstallationTargets() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    let skill = try SkillOperations.initializeSkill(
      named: "demo", directory: repo.appendingPathComponent("skills"))
    let skillFile = skill.appendingPathComponent("SKILL.md")
    let originalContent = try String(contentsOf: skillFile, encoding: .utf8)
    try initGitRepo(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let projectInstall = try SkillOperations.add(
      AddOptions(
        source: repo.path, agents: [.claudeCode], scope: .project, mode: .symlink, watch: true,
        environment: environment))
    let watchID = try #require(projectInstall.watched.first?.watchID)
    let globalInstall = try SkillOperations.add(
      AddOptions(
        source: watchID, agents: [.codex], scope: .global, mode: .copy,
        environment: environment))
    let originalTargets = projectInstall.installed + globalInstall.installed
    #expect(originalTargets.count == 2)

    let reviewedContent = originalContent + "\nReviewed update\n"
    try reviewedContent.write(to: skillFile, atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "update skill"])
    let reviewedCommit = try gitHead(repo)
    _ = try SkillOperations.watches.refreshWatchedHead(
      watchID: watchID, environment: environment, apply: true)
    _ = try SkillOperations.watches.check(
      watchID: watchID, path: "skills/demo", environment: environment, apply: true)
    _ = try SkillOperations.watches.done(
      watchID: watchID, path: "skills/demo", environment: environment, apply: true)
    for target in originalTargets {
      let installedFile = URL(fileURLWithPath: target.path).appendingPathComponent("SKILL.md")
      #expect(try String(contentsOf: installedFile, encoding: .utf8) == originalContent)
    }

    let updated = try SkillOperations.updateFromWatch(
      watchID, path: "skills/demo", environment: environment, apply: true)

    #expect(updated.count == originalTargets.count)
    for target in originalTargets {
      let result = try #require(
        updated.first { $0.agent == target.agent && $0.scope == target.scope })
      #expect(result.skill == "demo")
      #expect(result.mode == target.mode)
      #expect(result.path == target.path)
      #expect(result.materialization == target.materialization)
      let installedFile = URL(fileURLWithPath: result.path).appendingPathComponent("SKILL.md")
      #expect(try String(contentsOf: installedFile, encoding: .utf8) == reviewedContent)
      let managed = try SkillOperations.listManaged(
        scope: target.scope, agents: AgentID.allCases, environment: environment)
      #expect(managed.count == 1)
      let record = try #require(managed.first)
      #expect(record.name == "demo")
      #expect(record.agent == target.agent)
      #expect(record.scope == target.scope)
      #expect(record.mode == target.mode)
      #expect(record.path == target.path)
      #expect(record.reviewedCommit == reviewedCommit)
    }
  }

  @Test(arguments: [InstallScope.project, .global])
  func removesAllSkillsOnlyForSelectedAgentAndScope(_ scope: InstallScope) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    for name in ["shared", "orphan", "missing"] {
      _ = try SkillOperations.initializeSkill(named: name, directory: source)
    }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    for installScope in [InstallScope.project, .global] {
      _ = try SkillOperations.add(
        AddOptions(
          source: source.path, agents: [.claudeCode, .codex], skillNames: ["shared"],
          scope: installScope, mode: .symlink, environment: environment))
      _ = try SkillOperations.add(
        AddOptions(
          source: source.path, agents: [.claudeCode], skillNames: ["orphan", "missing"],
          scope: installScope, mode: .symlink, environment: environment))
      let base = installScope == .project ? root : environment.homeDirectory
      for name in ["unmanaged-one", "unmanaged-two"] {
        _ = try SkillOperations.initializeSkill(
          named: name, directory: base.appendingPathComponent(".claude/skills"))
      }
    }
    let base = scope == .project ? root : environment.homeDirectory
    for name in ["orphan", "missing"] {
      try FileManager.default.removeItem(at: base.appendingPathComponent(".claude/skills/\(name)"))
    }
    try FileManager.default.removeItem(at: base.appendingPathComponent(".agents/skills/missing"))
    let otherScope: InstallScope = scope == .project ? .global : .project
    let otherLockURL =
      otherScope == .project
      ? root.appendingPathComponent(".agent/skills.resolved")
      : environment.homeDirectory.appendingPathComponent(".agents/skills.resolved")
    let otherLock = try Data(contentsOf: otherLockURL)
    let otherInstallations = try SkillOperations.listInstalled(
      scope: otherScope, agents: AgentID.allCases, environment: environment)
    let otherContents = try otherInstallations.map {
      try Data(contentsOf: URL(fileURLWithPath: $0.path).appendingPathComponent("SKILL.md"))
    }
    let sharedFile = base.appendingPathComponent(".agents/skills/shared/SKILL.md")
    let sharedContent = try Data(contentsOf: sharedFile)

    let removed = try SkillOperations.remove(
      skillNames: [], scope: scope, agents: [.claudeCode], environment: environment)

    let expectedRemoved = [
      ".claude/skills/shared", ".claude/skills/unmanaged-one", ".claude/skills/unmanaged-two",
      ".agents/skills/orphan",
    ].map { base.appendingPathComponent($0).path }
    func normalizedRemovalPath(_ path: String) -> String {
      let url = URL(fileURLWithPath: path)
      return url.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent).path
    }
    #expect(
      Set(removed.map(normalizedRemovalPath)) == Set(expectedRemoved.map(normalizedRemovalPath)))
    for path in expectedRemoved {
      #expect(!FileManager.default.fileExists(atPath: path))
    }
    #expect(
      try SkillOperations.listInstalled(
        scope: scope, agents: [.claudeCode], environment: environment
      )
      .isEmpty)
    let remaining = try SkillOperations.listManaged(
      scope: scope, agents: AgentID.allCases, environment: environment)
    #expect(remaining.map(\.name) == ["shared"])
    #expect(remaining.map(\.agent) == [.codex])
    #expect(try Data(contentsOf: sharedFile) == sharedContent)
    #expect(try Data(contentsOf: otherLockURL) == otherLock)

    _ = try SkillOperations.remove(
      skillNames: [], scope: scope, agents: [.codex], environment: environment)
    #expect(!FileManager.default.fileExists(atPath: sharedFile.deletingLastPathComponent().path))
    let lockURL =
      scope == .project
      ? root.appendingPathComponent(".agent/skills.resolved")
      : environment.homeDirectory.appendingPathComponent(".agents/skills.resolved")
    let lock = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any])
    #expect(try #require(lock["pins"] as? [Any]).isEmpty)
    #expect(try Data(contentsOf: otherLockURL) == otherLock)
    #expect(
      try SkillOperations.listInstalled(
        scope: otherScope, agents: AgentID.allCases, environment: environment) == otherInstallations
    )
    for (installation, content) in zip(otherInstallations, otherContents) {
      let file = URL(fileURLWithPath: installation.path).appendingPathComponent("SKILL.md")
      #expect(try Data(contentsOf: file) == content)
    }
    for name in ["shared", "orphan", "missing"] {
      #expect(
        FileManager.default.fileExists(
          atPath: source.appendingPathComponent("\(name)/SKILL.md").path))
    }
  }
}
