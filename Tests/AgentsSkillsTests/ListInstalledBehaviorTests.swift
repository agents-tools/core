import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Installed Skill Listing")
struct InstalledSkillListingTests {
  @Test func listsInstalledSkillsFromFilesystemShapes() throws {
    let project = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])

    #expect(
      try SkillOperations.listInstalled(scope: .project, agents: [.codex], environment: environment)
        .isEmpty)

    try writeInstalledSkill(project: project, name: "skill-1")
    try writeInstalledSkill(project: project, name: "skill-2")
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent(".agents/skills/no-skill-md"),
      withIntermediateDirectories: true)
    try writeInstalledSkillFile(
      project.appendingPathComponent(".agents/skills/invalid-skill/SKILL.md"),
      contents: "# Invalid\nNo frontmatter")

    let names = try SkillOperations.listInstalled(
      scope: .project, agents: [.codex], environment: environment
    ).map(\.name).sorted()
    #expect(names == ["skill-1", "skill-2"])
  }

  @Test func ignoresDanglingAndFileSymlinksWhenListingInstalledSkills() throws {
    let project = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let skills = project.appendingPathComponent(".agents/skills")
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)

    try FileManager.default.createSymbolicLink(
      at: skills.appendingPathComponent("broken"),
      withDestinationURL: project.appendingPathComponent("missing"))
    try "# not a skill".write(
      to: project.appendingPathComponent("not-a-skill.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: skills.appendingPathComponent("file-link"),
      withDestinationURL: project.appendingPathComponent("not-a-skill.md"))

    #expect(
      try SkillOperations.listInstalled(scope: .project, agents: [.codex], environment: environment)
        .isEmpty)
  }

  @Test func listsDirectorySymlinksAndAgentSpecificDirectories() throws {
    let project = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])

    let shared = project.appendingPathComponent("shared/linked-skill")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try writeInstalledSkillFile(
      shared.appendingPathComponent("SKILL.md"),
      contents: """
        ---
        name: linked-skill
        description: Skill reached through a directory symlink
        ---
        """)
    let universal = project.appendingPathComponent(".agents/skills")
    try FileManager.default.createDirectory(at: universal, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: universal.appendingPathComponent("linked-skill"), withDestinationURL: shared)

    try writeInstalledSkill(
      project: project, name: "claude-only", base: project.appendingPathComponent(".claude/skills"))

    let codex = try SkillOperations.listInstalled(
      scope: .project, agents: [.codex], environment: environment)
    #expect(codex.map(\.name) == ["linked-skill"])

    let claude = try SkillOperations.listInstalled(
      scope: .project, agents: [.claudeCode], environment: environment)
    #expect(claude.map(\.name) == ["claude-only"])
  }

  @Test func listsManagedSkillsFromResolvedStateAndChecksFilesystemPresence() throws {
    let project = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let sourceRoot = project.appendingPathComponent("source")
    let skillDir = sourceRoot.appendingPathComponent("skills/managed")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try writeInstalledSkillFile(
      skillDir.appendingPathComponent("SKILL.md"),
      contents: """
        ---
        name: managed
        description: Managed skill
        ---
        """)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])

    _ = try SkillOperations.add(
      AddOptions(
        source: sourceRoot.path,
        agents: [.codex],
        skillNames: ["managed"],
        environment: environment
      ))

    var managed = try SkillOperations.listManaged(
      scope: .project, agents: [.codex], environment: environment)
    #expect(managed.map(\.name) == ["managed"])
    #expect(managed.first?.sourceIdentity == "source")
    #expect(managed.first?.isInstalled == true)

    try FileManager.default.removeItem(at: project.appendingPathComponent(".agents/skills/managed"))
    managed = try SkillOperations.listManaged(
      scope: .project, agents: [.codex], environment: environment)
    #expect(managed.map(\.name) == ["managed"])
    #expect(managed.first?.isInstalled == false)

    let installed = try SkillOperations.listInstalled(
      scope: .project, agents: [.codex], environment: environment)
    #expect(installed.isEmpty)
  }

  @Test func reportsEditSourceMissingCopyDriftAndInstalledOnlyStatuses() throws {
    let project = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let sourceRoot = project.appendingPathComponent("source")
    let skillDir = sourceRoot.appendingPathComponent("skills/editable")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try writeInstalledSkillFile(
      skillDir.appendingPathComponent("SKILL.md"),
      contents: """
        ---
        name: editable
        description: Editable skill
        ---
        """)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])

    _ = try SkillOperations.add(
      AddOptions(
        source: sourceRoot.path,
        agents: [.codex],
        skillNames: ["editable"],
        mode: .edit,
        environment: environment))
    var managed = try SkillOperations.listManaged(
      scope: .project, agents: [.codex], environment: environment)
    #expect(managed.first?.status == .editLinked)

    try FileManager.default.removeItem(at: sourceRoot)
    managed = try SkillOperations.listManaged(
      scope: .project, agents: [.codex], environment: environment)
    #expect(managed.first?.status == .sourceMissing)

    let copySource = project.appendingPathComponent("copy-source")
    let copySkill = copySource.appendingPathComponent("skills/copied")
    try FileManager.default.createDirectory(at: copySkill, withIntermediateDirectories: true)
    try writeInstalledSkillFile(
      copySkill.appendingPathComponent("SKILL.md"),
      contents: """
        ---
        name: copied
        description: Copied skill
        ---
        """)
    _ = try SkillOperations.add(
      AddOptions(
        source: copySource.path,
        agents: [.codex],
        skillNames: ["copied"],
        mode: .copy,
        environment: environment))
    try "changed".write(
      to: copySkill.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    managed = try SkillOperations.listManaged(
      scope: .project, agents: [.codex], environment: environment)
    #expect(managed.first { $0.name == "copied" }?.status == .copyDrift)

    try writeInstalledSkill(project: project, name: "manual-only")
    let all = try SkillOperations.listInstalled(
      scope: .project, agents: [.codex], environment: environment)
    #expect(all.first { $0.name == "manual-only" }?.status == .installedOnly)

    let report = try SkillOperations.doctor(
      scope: .project, agents: [.codex], environment: environment)
    #expect(report.ok == false)
    #expect(report.checks.contains { $0.message.contains("source-missing") })
    #expect(report.checks.contains { $0.message.contains("copy-drift") })
    #expect(report.checks.contains { $0.message.contains("installed-only") })
  }

  @Test(arguments: [InstallScope.project, .user])
  func treatsSharedDirectorySkillsAsManagedForEveryAgentReadingIt(_ scope: InstallScope) throws {
    let project = try listInstalledTemporaryDirectory()
    let home = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let sourceRoot = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: sourceRoot) }
    defer {
      try? FileManager.default.removeItem(at: project)
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: sourceRoot)
    }
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    try writeInstalledSkillFile(
      sourceRoot.appendingPathComponent("skills/shared/SKILL.md"),
      contents: """
        ---
        name: shared
        description: Shared skill
        ---
        """)
    _ = try SkillOperations.add(
      AddOptions(
        source: sourceRoot.path,
        agents: [.codex],
        skillNames: ["shared"],
        scope: scope,
        mode: .copy,
        environment: environment))

    let cursor = try SkillOperations.listInstalled(
      scope: scope, agents: [.cursor], environment: environment)
    #expect(cursor.map(\.status) == [.installed])
    #expect(cursor.map(\.agent) == [.cursor])
    let report = try SkillOperations.doctor(
      scope: scope, agents: [.cursor], environment: environment)
    #expect(report.checks.contains { $0.id == "skill.cursor.shared" && $0.status == .ok })
    #expect(!report.checks.contains { $0.id == "managed-installs" })
    #expect(!report.checks.contains { $0.message.contains("installed-only") })

    let canonical = AgentRegistry.canonicalSkillsDirectory(scope: scope, environment: environment)
    try "changed".write(
      to: canonical.appendingPathComponent("shared/notes.md"), atomically: true, encoding: .utf8)
    let drifted = try SkillOperations.doctor(
      scope: scope, agents: [.cursor], environment: environment)
    #expect(
      drifted.checks.contains {
        $0.message == "shared for cursor: copy-drift" && $0.status == .warning
      })
  }

  @Test func diagnosesUnmanagedDirectoryWithTheSameNameAsAManagedSkill() throws {
    let root = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let source = root.appendingPathComponent("source")
    try writeInstalledSkill(project: source, name: "shared", base: source)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: home, environment: [:])
    _ = try SkillOperations.add(
      AddOptions(
        source: source.path, agents: [.cursor], scope: .user, mode: .copy,
        environment: environment))
    let native = home.appendingPathComponent(".cursor/skills")
    try writeInstalledSkill(project: root, name: "shared", base: native)

    let report = try SkillOperations.doctor(
      scope: .user, agents: [.cursor], environment: environment)
    #expect(report.checks.contains { $0.id == "skill.cursor.shared" && $0.status == .ok })
    let warning = try #require(report.checks.first { $0.id == "installed-only.cursor.shared" })
    let warningPath = try #require(warning.path)
    #expect(
      URL(fileURLWithPath: warningPath).resolvingSymlinksInPath().path
        == native.appendingPathComponent("shared").resolvingSymlinksInPath().path)
  }

  @Test(arguments: [InstallScope.project, .user])
  func diagnosesLinkedInstallationsByTheirContent(_ scope: InstallScope) throws {
    let root = try listInstalledTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try writeInstalledSkill(project: source, name: "linked", base: source)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let agents: [AgentID] = [.codex, .claudeCode]
    _ = try SkillOperations.add(
      AddOptions(
        source: source.path, agents: agents, scope: scope, mode: .link,
        environment: environment))

    let managed = try SkillOperations.listManaged(
      scope: scope, agents: agents, environment: environment)
    #expect(managed.count == 2)
    #expect(managed.allSatisfy { $0.status == .installed })
    #expect(try SkillOperations.doctor(scope: scope, agents: agents, environment: environment).ok)

    let canonical = AgentRegistry.canonicalSkillsDirectory(scope: scope, environment: environment)
    try "changed".write(
      to: canonical.appendingPathComponent("linked/notes.md"), atomically: true, encoding: .utf8)
    let drifted = try SkillOperations.listManaged(
      scope: scope, agents: agents, environment: environment)
    #expect(drifted.allSatisfy { $0.status == .copyDrift })
    let report = try SkillOperations.doctor(scope: scope, agents: agents, environment: environment)
    #expect(report.checks.filter { $0.message.contains("copy-drift") }.count == 2)
  }

}

private func writeInstalledSkill(
  project: URL, name: String, base: URL? = nil
) throws {
  let root = base ?? project.appendingPathComponent(".agents/skills")
  let skill = root.appendingPathComponent(name)
  try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
  try writeInstalledSkillFile(
    skill.appendingPathComponent("SKILL.md"),
    contents: """
      ---
      name: \(name)
      description: \(name) description
      ---
      """)
}

private func writeInstalledSkillFile(_ file: URL, contents: String) throws {
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: file, atomically: true, encoding: .utf8)
}

private func listInstalledTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("skill-cli-list-installed-tests")
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
