import AgentsCore
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import StateTestSupport
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
    let lock = try fixture.store().loadLedger()
    try fixture.store().save(declaration: declaration, ledger: lock)
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
    var lock = try fixture.store().loadLedger()
    let unavailable = String(repeating: "a", count: 40)
    for id in lock.sources.keys where lock.sources[id]!.revision != "live" {
      lock.sources[id]!.revision = unavailable
    }
    for id in lock.components.keys where lock.components[id]!.revision != nil {
      lock.components[id]!.revision = unavailable
    }
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), ledger: lock)
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
    var lock = try fixture.store().loadLedger()
    var deployment = try #require(lock.deployments.first { $0.route == "agents/skill@1" })
    var lowering = try #require(lock.lowerings.first { $0.deployments.contains(deployment.id) })
    let id = deployment.id + ":cursor"
    deployment.id = id
    deployment.target.root = "skills-cursor"
    deployment.recipients = [.cursor]
    lowering.id = id
    lowering.deployments = [id]
    lowering.layout.object?["mode"] = .init("copy")
    lowering.layout.object?["name"] = .init(id)
    for index in lowering.artifacts.indices { lowering.artifacts[index].name = id }
    lock.deployments.append(deployment)
    lock.lowerings.append(lowering)
    try fixture.store().save(declaration: fixture.store().loadDeclaration(), ledger: lock)
    let bytes = try fixture.stateAndTargetBytes()
    #expect(throws: (any Error).self) {
      try SkillOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.stateAndTargetBytes() == bytes)
  }

  @Test func removalFingerprintPreservesRemainingIndependentMembers() throws {
    let fixture = try SkillFixture()
    for name in ["demo", "keep-b", "keep-a"] { try fixture.skill(name, body: name) }
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let pin = try fixture.head()
    let request = UpdateRequest(operation: .remove, kinds: [.skills], names: ["demo"])
    let first = try UpdateOperations.preview(request, environment: fixture.environment)
    let second = try UpdateOperations.preview(request, environment: fixture.environment)
    #expect(first.displayedFingerprint == second.displayedFingerprint)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
      try $0.apply(ifUnchangedFrom: first.displayedFingerprint)
    }
    let ledger = try fixture.store().loadLedger()
    #expect(
      Set(ledger.components.values.filter { $0.kind == "skills" }.map(\.name)) == [
        "keep-a", "keep-b",
      ])
    #expect(
      ledger.components.values.filter { $0.kind == "skills" }.allSatisfy { $0.revision == pin })
    #expect(try fixture.body(fixture.target("keep-a")).contains("keep-a"))
    #expect(try fixture.body(fixture.target("keep-b")).contains("keep-b"))
    #expect(!FileManager.default.fileExists(atPath: fixture.target("demo").path))
  }

  @Test func removalDoesNotDiscoverNewAllMembers() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try fixture.skill("new-member", body: "Current")
    try fixture.commit()
    try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    #expect(try fixture.store().loadResolved().skills.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.target("new-member").path))
    #expect(try fixture.store().loadDeclaration().skills?["fixture"]?.select == .all)
    #expect(try fixture.store().loadDeclaration().skills?["fixture"]?.exclude == ["demo"])
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.store().loadResolved().skills.keys.sorted() == ["new-member"])
    #expect(try fixture.body(fixture.target("new-member")).contains("Current"))
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
