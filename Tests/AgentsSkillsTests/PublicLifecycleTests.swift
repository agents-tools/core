import AgentsCore
import AgentsSkills
import Foundation
import Testing

@Suite("Public lifecycle API")
struct PublicLifecycleTests {
  @Test func defaultsRecipientsAndRestoresTheirLockedModes() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let added = try SkillOperations.add(
      AddOptions(source: fixture.repo.path, mode: .copy, environment: fixture.environment))
    #expect(Set(added.installed.map(\.agent)) == [.codex, .claudeCode])
    var declaration = try fixture.store().loadDeclaration()
    declaration.agents = [.cursor]
    let lock = try fixture.store().loadResolved()
    try fixture.store().save(declaration: declaration, resolved: lock)
    for install in added.installed { try FileManager.default.removeItem(atPath: install.path) }
    let restored = try SkillOperations.installResolvedReport(environment: fixture.environment)
    #expect(Set(restored.installed.map(\.agent)) == [.codex, .claudeCode])
    #expect(restored.installed.allSatisfy { $0.mode == .copy })
  }

  @Test func namedUpdateAddsOnlyRequestedNewAllMember() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    let previous = try fixture.store().loadResolved().skills["one"]
    try fixture.skill("two", body: "B")
    try fixture.skill("three", body: "B")
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(
      environment: fixture.environment, skillNames: ["two"], apply: true)
    let lock = try fixture.store().loadResolved()
    #expect(lock.skills["one"] == previous)
    #expect(lock.skills["two"] != nil && lock.skills["three"] == nil)
  }

  @Test func namedEditOverrideUsesLiveUntrackedSkill() throws {
    let fixture = try SkillFixture()
    try fixture.skill("pinned", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try fixture.skill("live", body: "untracked")
    _ = try SkillOperations.add(
      AddOptions(
        source: "fixture", agents: [.codex], skillNames: ["live"], mode: .edit,
        environment: fixture.environment))
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let lock = try fixture.store().loadResolved()
    #expect(lock.skills["pinned"]?.revision != nil)
    #expect(lock.skills["live"]?.revision == nil)
    #expect(try fixture.body(fixture.target("live")).contains("untracked"))
  }

  @Test func sharedAgentDirectorySurvivesPartialRemoval() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: [.codex, .cursor], environment: fixture.environment))
    try SkillOperations.remove(
      skillNames: ["demo"], agents: [.codex], environment: fixture.environment)
    #expect(FileManager.default.fileExists(atPath: fixture.target("demo").path))
    #expect(try fixture.store().loadResolved().skills["demo"]?.installs == ["cursor": .link])
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.store().loadResolved().skills["demo"]?.installs == ["cursor": .link])
    try SkillOperations.remove(
      skillNames: ["demo"], agents: [.cursor], environment: fixture.environment)
    #expect(!FileManager.default.fileExists(atPath: fixture.target("demo").path))
  }

  @Test func missingPinStopsRestoreBeforeReplacingAnyInstall() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    var lock = try fixture.store().loadResolved()
    lock.skills["two"]?.revision = String(repeating: "a", count: 40)
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), resolved: lock)
    try Data("custom".utf8).write(to: fixture.target("one").appendingPathComponent("SKILL.md"))
    let bytes = try Data(contentsOf: fixture.store().resolvedURL)
    #expect(throws: (any Error).self) {
      try SkillOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.body(fixture.target("one")) == "custom")
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == bytes)
  }

  @Test func addPreservesStateWhenRecipientsHaveConflictingPhysicalModes() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    var lock = try fixture.store().loadResolved()
    lock.skills["demo"]?.installs["cursor"] = .copy
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), resolved: lock)
    let bytes = try fixture.stateAndTargetBytes()
    #expect(throws: (any Error).self) {
      try SkillOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.stateAndTargetBytes() == bytes)
  }

  @Test func emptyNamedSelectionDoesNotRequireSourceAccess() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(source: fixture.repo.path, environment: fixture.environment))
    try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    try FileManager.default.removeItem(at: fixture.repo)
    #expect(try SkillOperations.updateInstalled(environment: fixture.environment).isEmpty)
  }
}
