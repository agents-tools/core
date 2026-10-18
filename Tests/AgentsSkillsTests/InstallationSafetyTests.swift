import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Installation safety")
struct InstallationSafetyTests {
  @Test func liveEditSourceRetainsSharedMaterializationAndFailureCleanup() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "B")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "pinned", agents: [.codex], skillNames: ["one"],
        environment: fixture.environment))
    let cache = SourceCache(store: fixture.store())
    let one = try #require(fixture.store().loadResolved().skills["one"])
    let tree = cache.materializedURL(sourceID: one.source, revision: try #require(one.revision))
    _ = try SkillOperations.add(
      AddOptions(
        source: tree.appendingPathComponent("skills/two").path, alias: "live", agents: [.codex],
        mode: .edit, environment: fixture.environment))
    _ = try SkillOperations.remove(skillNames: ["one"], environment: fixture.environment)
    #expect(try fixture.body(fixture.target("two")).contains("B"))
    // A rejected copy must also preserve the existing live cache reference.
    try FileManager.default.createSymbolicLink(
      atPath: fixture.repo.appendingPathComponent("skills/one/ref").path,
      withDestinationPath: "../../shared.txt")
    try Data("shared".utf8).write(to: fixture.repo.appendingPathComponent("shared.txt"))
    try fixture.commit()
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(
          source: "pinned", agents: [.codex], skillNames: ["one"], mode: .copy,
          environment: fixture.environment))
    }
    #expect(try fixture.body(fixture.target("two")).contains("B"))
  }

  @Test func copyRejectsLinksEscapingTheInstalledSubtree() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try Data("committed shared".utf8).write(to: fixture.repo.appendingPathComponent("shared.txt"))
    try FileManager.default.createSymbolicLink(
      atPath: fixture.repo.appendingPathComponent("skills/demo/ref").path,
      withDestinationPath: "../../shared.txt")
    try fixture.commit()
    _ = try fixture.add(mode: .link)
    let before = try fixture.stateAndTargetBytes()
    #expect(throws: CoreError.self) { try fixture.add(mode: .copy) }
    #expect(try fixture.stateAndTargetBytes() == before)
    #expect(
      try String(contentsOf: fixture.target("demo").appendingPathComponent("ref"), encoding: .utf8)
        == "committed shared")
  }

  @Test func movingProjectKeepsCachedLinksAndExternalEditLinksUsable() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "pinned", agents: [.codex, .claudeCode],
        environment: fixture.environment))
    let live = fixture.root.appendingPathComponent("live")
    _ = try SkillOperations.initializeSkill(named: nil, directory: live)
    _ = try SkillOperations.add(
      AddOptions(
        source: live.path, alias: "live", agents: [.codex], mode: .edit,
        environment: fixture.environment))
    for agent in [AgentID.codex, .claudeCode] {
      let target = SkillLifecycle.target(name: "demo", agent: agent, store: fixture.store())
      #expect(
        !(try FileManager.default.destinationOfSymbolicLink(atPath: target.path)).hasPrefix("/"))
    }
    #expect(
      (try FileManager.default.destinationOfSymbolicLink(atPath: fixture.target("live").path))
        .hasPrefix("/"))
    let moved = fixture.root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: fixture.environment.projectDirectory, to: moved)
    let environment = RuntimeEnvironment(
      projectDirectory: moved, homeDirectory: fixture.environment.homeDirectory, environment: [:])
    #expect(try SkillOperations.listManaged(environment: environment).allSatisfy(\.isInstalled))
    #expect(
      try String(
        contentsOf: moved.appendingPathComponent(".agents/skills/demo/SKILL.md"), encoding: .utf8
      ).contains("A"))
  }
}
