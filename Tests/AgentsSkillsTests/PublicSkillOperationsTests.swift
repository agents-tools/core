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
    #expect(Set(listed.availableSkills.map(\.name)) == ["shallow", "deep"])
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
}
