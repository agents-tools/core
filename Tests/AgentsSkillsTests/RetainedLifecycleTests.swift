import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Retained lifecycle behavior")
struct RetainedLifecycleTests {
  @Test(arguments: [
    (SourceRequirement.exact("1.0.0-beta.1"), "1.0.0-beta.1"),
    (.exact("1.0.0+build.1"), "1.0.0+build.1"),
    (.range(from: "1.0.0-beta.1", to: "1.0.0-beta.3"), "1.0.0-beta.2"),
  ])
  func publicRequirementsInstallTheSelectedTreeAndPath(
    _ requirement: SourceRequirement, _ version: String
  ) throws {
    let fixture = try SkillFixture()
    for tag in ["1.0.0-beta.1", "1.0.0-beta.2", "1.0.0-beta.3", "1.0.0+build.1", "1.0.0+build.2"] {
      try fixture.skill("demo", body: tag)
      try fixture.skill("other", body: tag)
      try fixture.commit()
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["git", "-C", fixture.repo.path, "tag", "v" + tag])
    }
    let result = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: [.codex], mode: .copy, path: "skills/demo",
        sourceRequirement: requirement, environment: fixture.environment))
    #expect(result.installed.map(\.skill) == ["demo"])
    #expect(try fixture.body(fixture.target("demo")).contains(version))
    #expect(try fixture.store().loadResolved().skills["demo"]?.version == version)
    #expect(try fixture.store().loadResolved().skills["demo"]?.path == "skills/demo")
    #expect(try fixture.store().loadDeclaration().sources.values.first?.path == "skills/demo")
  }

  @Test func copyInstallRejectsADanglingLinkThatResolvesAboveTheSkill() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "demo")
    let skill = fixture.repo.appendingPathComponent("skills/demo")
    try FileManager.default.createSymbolicLink(
      atPath: skill.appendingPathComponent("here").path, withDestinationPath: ".")
    try FileManager.default.createSymbolicLink(
      atPath: skill.appendingPathComponent("leak").path,
      withDestinationPath: "here/here/../../settings.json")
    try fixture.commit()
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path, agents: [.codex], mode: .copy,
          environment: fixture.environment))
    }
  }

  @Test func publicDiscoveryForwardsDepthAndInternalEnvironmentValues() throws {
    let fixture = try SkillFixture()
    try fixture.skill("public", body: "public")
    let internalDirectory = try SkillOperations.initializeSkill(
      named: "internal", directory: fixture.repo.appendingPathComponent("skills"))
    try Data("---\nname: internal\ndescription: Internal\nmetadata:\n  internal: true\n---".utf8)
      .write(to: internalDirectory.appendingPathComponent("SKILL.md"))
    _ = try SkillOperations.initializeSkill(
      named: "deep", directory: fixture.repo.appendingPathComponent("skills/level/level"))
    for value in ["", "false", "TRUE", "yes", "true", "1"] {
      var environment = fixture.environment
      environment.environment["INSTALL_INTERNAL_SKILLS"] = value
      let result = try SkillOperations.add(
        AddOptions(source: fixture.repo.path, listOnly: true, environment: environment))
      #expect(
        Set(result.availableSkills.map(\.name))
          == (["true", "1"].contains(value) ? ["public", "internal"] : ["public"]))
    }
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path, skillNames: ["deep"], mode: .edit,
          environment: fixture.environment))
    }
    let result = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: [.codex], skillNames: ["deep"], mode: .edit,
        fullDepth: true, environment: fixture.environment))
    #expect(result.installed.map(\.skill) == ["deep"])
    let listed = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, listOnly: true, fullDepth: true, environment: fixture.environment
      ))
    #expect(Set(listed.availableSkills.map(\.name)) == ["public", "deep"])
  }

  @Test func copyReplacementPreservesDotfilesAndRemovesStaleFiles() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    let source = fixture.repo.appendingPathComponent("skills/demo")
    try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
    try Data("stale".utf8).write(to: source.appendingPathComponent("old"))
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try Data("drift".utf8).write(to: fixture.target("demo").appendingPathComponent("extra"))
    try FileManager.default.removeItem(at: source.appendingPathComponent("old"))
    try fixture.skill("demo", body: "B")
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try String(
        contentsOf: fixture.target("demo").appendingPathComponent(".hidden"), encoding: .utf8)
        == "hidden")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.target("demo").appendingPathComponent("extra").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.target("demo").appendingPathComponent("old").path))
  }

  @Test(arguments: [InstallMode.link, .copy], [InstallScope.project, .user])
  func repairsSelfLoopsThroughSymlinkedAgentContainers(_ mode: InstallMode, _ scope: InstallScope)
    throws
  {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let container = fixture.target("demo", scope: scope).deletingLastPathComponent()
    let physical = fixture.root.appendingPathComponent("physical-skills")
    try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: container.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: container, withDestinationURL: physical)
    try FileManager.default.createSymbolicLink(
      atPath: physical.appendingPathComponent("demo").path, withDestinationPath: "demo")
    _ = try fixture.add(mode: mode, scope: scope)
    #expect(try fixture.body(fixture.target("demo", scope: scope)).contains("A"))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: container.path) == physical.path)
    #expect(
      try SkillOperations.listInstalled(
        scope: scope, agents: [.codex], environment: fixture.environment
      ).count == 1)
  }

  @Test(arguments: [false, true])
  func userPlacementRestorationAndPartialRemovalSharePhysicalTargets(_ configureClaude: Bool) throws
  {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    var environment = fixture.environment
    let claudeRoot = environment.homeDirectory.appendingPathComponent(
      configureClaude ? "custom-claude" : ".claude")
    if configureClaude { environment.environment["CLAUDE_CONFIG_DIR"] = claudeRoot.path }
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: AgentID.allCases, scope: .user, environment: environment)
    )
    let shared = fixture.target("demo", scope: .user)
    let claude = claudeRoot.appendingPathComponent("skills/demo")
    #expect(try fixture.body(shared).contains("A"))
    #expect(try fixture.body(claude).contains("A"))
    #expect(
      !(try FileManager.default.destinationOfSymbolicLink(atPath: shared.path)).hasPrefix("/"))
    let bytes = try Data(contentsOf: fixture.store(.user).resolvedURL)
    for target in [shared, claude] { try FileManager.default.removeItem(at: target) }
    _ = try SkillOperations.installResolvedReport(scope: .user, environment: environment)
    #expect(try Data(contentsOf: fixture.store(.user).resolvedURL) == bytes)
    #expect(try fixture.body(shared).contains("A"))
    #expect(try fixture.body(claude).contains("A"))
    _ = try SkillOperations.remove(
      skillNames: ["demo"], scope: .user, agents: [.codex], environment: environment)
    #expect(FileManager.default.fileExists(atPath: shared.path))
    #expect(try fixture.store(.user).loadResolved().skills["demo"]?.installs.count == 4)
    _ = try SkillOperations.remove(
      skillNames: ["demo"], scope: .user, agents: [.claudeCode], environment: environment)
    #expect(!FileManager.default.fileExists(atPath: claude.path))
    #expect(FileManager.default.fileExists(atPath: shared.path))
    _ = try SkillOperations.remove(skillNames: ["demo"], scope: .user, environment: environment)
    #expect(!FileManager.default.fileExists(atPath: shared.path))
    #expect(try fixture.store(.user).loadResolved().skills.isEmpty)
    let materialized = fixture.store(.user).cacheDirectory.appendingPathComponent("materialized")
    #expect(try FileManager.default.contentsOfDirectory(atPath: materialized.path).isEmpty)
  }

  @Test func rejectsRemoteEditAndRestoresDeletedLiveInstallation() throws {
    let fixture = try SkillFixture()
    for source in ["https://example.test/repo.git", "https://example.test"] {
      #expect(throws: CoreError.self) {
        try SkillOperations.add(
          AddOptions(source: source, mode: .edit, environment: fixture.environment))
      }
    }
    try fixture.skill("demo", body: "A")
    _ = try fixture.add(mode: .edit)
    try FileManager.default.removeItem(at: fixture.target("demo"))
    try fixture.skill("demo", body: "live")
    _ = try SkillOperations.installResolvedReport(environment: fixture.environment)
    #expect(try fixture.body(fixture.target("demo")).contains("live"))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.target("demo").path)
        == fixture.repo.appendingPathComponent("skills/demo").path)
    #expect(try fixture.store().loadResolved().skills["demo"]?.revision == nil)
  }

  @Test(arguments: [InstallScope.project, .user])
  func removesMissingSourcesAndInstallsWithRecipientAndScopeIsolation(_ scope: InstallScope) throws
  {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    for selected in [InstallScope.project, .user] {
      _ = try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path, agents: [.codex, .claudeCode], scope: selected,
          environment: fixture.environment))
    }
    let other: InstallScope = scope == .project ? .user : .project
    let otherBytes = try Data(contentsOf: fixture.store(other).resolvedURL)
    try FileManager.default.removeItem(at: fixture.repo)
    try FileManager.default.removeItem(at: fixture.target("demo", scope: scope))
    _ = try SkillOperations.remove(
      skillNames: ["demo"], scope: scope, agents: [.codex], environment: fixture.environment)
    #expect(
      try fixture.store(scope).loadResolved().skills["demo"]?.installs == ["claude-code": .link])
    _ = try SkillOperations.remove(
      skillNames: ["demo"], scope: scope, environment: fixture.environment)
    #expect(try fixture.store(scope).loadResolved().skills.isEmpty)
    #expect(try Data(contentsOf: fixture.store(other).resolvedURL) == otherBytes)
    #expect(try fixture.body(fixture.target("demo", scope: other)).contains("A"))
  }

  @Test func unnamedInitializationCreatesValidSkillInSuppliedCurrentDirectory() throws {
    let fixture = try SkillFixture()
    let current = fixture.root.appendingPathComponent("My Current Skill")
    let initialized = try SkillOperations.initializeSkill(named: nil, directory: current)
    #expect(initialized == current)
    let skill = try #require(
      try Discovery.parseSkill(at: current.appendingPathComponent("SKILL.md")))
    #expect(skill.name == "my-current-skill")
    #expect(!skill.description.isEmpty)
    let bytes = try Data(contentsOf: current.appendingPathComponent("SKILL.md"))
    #expect(throws: CoreError.self) {
      try SkillOperations.initializeSkill(named: nil, directory: current)
    }
    #expect(try Data(contentsOf: current.appendingPathComponent("SKILL.md")) == bytes)
  }
}
