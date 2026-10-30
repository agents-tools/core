import AgentsManifest
import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Installed inventory")
struct InstalledInventoryTests {
  @Test(arguments: [InstallScope.project, .user])
  func validatesFilesystemCandidatesAndAgentSpecificRoots(_ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    var environment = fixture.environment
    environment.environment["CODEX_HOME"] =
      fixture.root.appendingPathComponent("configured-codex").path
    environment.environment["XDG_CONFIG_HOME"] =
      fixture.root.appendingPathComponent("configured-xdg").path
    let universal = fixture.target("unused", scope: scope).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: universal, withIntermediateDirectories: true)
    let live = try SkillOperations.initializeSkill(
      named: "linked", directory: fixture.root.appendingPathComponent("live"))
    try FileManager.default.createSymbolicLink(
      at: universal.appendingPathComponent("linked"), withDestinationURL: live)
    try FileManager.default.createSymbolicLink(
      at: universal.appendingPathComponent("dangling"),
      withDestinationURL: fixture.root.appendingPathComponent("missing"))
    let file = fixture.root.appendingPathComponent("file")
    try Data("file".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(
      at: universal.appendingPathComponent("file-link"), withDestinationURL: file)
    for name in ["no-skill", "invalid"] {
      try FileManager.default.createDirectory(
        at: universal.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data("---\nname: invalid\n---".utf8).write(
      to: universal.appendingPathComponent("invalid/SKILL.md"))
    let claude = AgentRegistry.installSkillsDirectory(
      for: .claudeCode, scope: scope, environment: environment)
    _ = try SkillOperations.initializeSkill(named: "claude-only", directory: claude)
    var expectedCodex = Set(["linked"])
    if scope == .user {
      _ = try SkillOperations.initializeSkill(
        named: "codex-native",
        directory: AgentRegistry.userSkillsDirectory(for: .codex, environment: environment))
      _ = try SkillOperations.initializeSkill(
        named: "opencode-native",
        directory: AgentRegistry.userSkillsDirectory(for: .opencode, environment: environment))
      expectedCodex.insert("codex-native")
      #expect(
        Set(
          try SkillOperations.listInstalled(
            scope: scope, agents: [.opencode], environment: environment
          ).map(\.name)) == ["opencode-native", "linked"])
    }
    let codex = try SkillOperations.listInstalled(
      scope: scope, agents: [.codex], environment: environment)
    #expect(Set(codex.map(\.name)) == expectedCodex)
    #expect(
      codex.allSatisfy { $0.status == .installedOnly && $0.isInstalled && $0.sourceIdentity == nil }
    )
    #expect(
      try SkillOperations.listInstalled(
        scope: scope, agents: [.claudeCode], environment: environment
      ).map(\.name) == ["claude-only"])
  }

  @Test(arguments: [InstallScope.project, .user])
  func detectsDriftThroughLinksForEveryRecipient(_ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: [.codex, .claudeCode], scope: scope,
        environment: fixture.environment))
    try Data("drift".utf8).write(
      to: fixture.target("demo", scope: scope).appendingPathComponent("extra"))
    let managed = try SkillOperations.listManaged(
      scope: scope, agents: [.codex, .claudeCode], environment: fixture.environment)
    #expect(managed.count == 2)
    #expect(managed.allSatisfy { $0.status == .copyDrift })
    let installed = try SkillOperations.listInstalled(
      scope: scope, agents: [.codex, .claudeCode], environment: fixture.environment)
    #expect(installed.count == 2)
    #expect(installed.allSatisfy { $0.status == .copyDrift })
    let report = try SkillOperations.doctor(scope: scope, environment: fixture.environment)
    #expect(report.checks.filter { $0.id == "copy-drift" }.count == 2)
  }

  @Test(arguments: [InstallScope.project, .user], [InstallMode.link, .copy, .edit])
  func corruptFirstAddAndInventoryLeaveAllFilesUnchanged(_ scope: InstallScope, _ mode: InstallMode)
    throws
  {
    for corruptDeclaration in [false, true] {
      let fixture = try SkillFixture()
      let store = fixture.store(scope)
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      let file = corruptDeclaration ? store.declarationURL : store.resolvedURL
      let bytes = Data("{corrupt".utf8)
      try bytes.write(to: file)
      // Declaration diagnostics come from the manifest front end; a corrupt lock is a state error.
      func expectFailure(_ body: () throws -> Void) {
        if corruptDeclaration {
          #expect(throws: ManifestFailure.self, performing: body)
        } else {
          #expect(throws: CoreError.self, performing: body)
        }
      }
      expectFailure { _ = try fixture.add(mode: mode, scope: scope) }
      expectFailure {
        _ = try SkillOperations.listManaged(scope: scope, environment: fixture.environment)
      }
      expectFailure {
        _ = try SkillOperations.listInstalled(scope: scope, environment: fixture.environment)
      }
      expectFailure {
        _ = try SkillOperations.removableSkillNames(scope: scope, environment: fixture.environment)
      }
      expectFailure {
        _ = try SkillOperations.doctor(scope: scope, environment: fixture.environment)
      }
      #expect(try Data(contentsOf: file) == bytes)
      // The declaration is parsed under the scope lock, which a first writer creates.
      #expect(
        try Set(FileManager.default.contentsOfDirectory(atPath: store.directory.path))
          == Set([file.lastPathComponent] + (corruptDeclaration ? [".agents.lock"] : [])))
      #expect(!FileManager.default.fileExists(atPath: store.cacheDirectory.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.target("demo", scope: scope).deletingLastPathComponent().path))
      #expect(!FileManager.default.fileExists(atPath: fixture.repo.path))
    }
  }
}
