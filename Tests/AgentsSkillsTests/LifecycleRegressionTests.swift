import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Lifecycle regressions")
struct LifecycleRegressionTests {
  @Test(arguments: [false, true])
  func updatesPersistedFilesystemIdentity(_ named: Bool) throws {
    let fixture = try SkillFixture()
    try fixture.skill("example", body: "A")
    let file = fixture.repo.appendingPathComponent("skills/example/SKILL.md")
    try Data("---\nname: Example Skill\ndescription: Example\n---\nA".utf8).write(to: file)
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try Data("---\nname: Example Skill\ndescription: Example\n---\nB".utf8).write(to: file)
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(
      environment: fixture.environment, skillNames: named ? ["example-skill"] : [], apply: true)
    #expect(try fixture.body(fixture.target("example-skill")).hasSuffix("B"))
  }

  @Test func normalizedIdentityPreservesAmbiguityErrors() throws {
    let fixture = try SkillFixture()
    try fixture.skill("example-skill", body: "A")
    try fixture.skill("example", body: "B")
    try Data("---\nname: Example Skill\ndescription: Example\n---".utf8).write(
      to: fixture.repo.appendingPathComponent("skills/example/SKILL.md"))
    try fixture.commit()
    #expect(throws: CoreError.self) { try fixture.add() }
  }

  @Test func previewUsesPhysicalRemovalsAndEntryTypes() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    let source = fixture.repo.appendingPathComponent("skills/demo")
    for name in ["a", "b"] { try Data("same".utf8).write(to: source.appendingPathComponent(name)) }
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("ref").path, withDestinationPath: "a")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "fixture", agents: [.codex, .claudeCode], mode: .copy,
        environment: fixture.environment))
    var declaration = try fixture.store().loadDeclaration()
    declaration.skills?["fixture"]?.agents = [.codex]
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    let target = fixture.target("demo")
    try FileManager.default.createDirectory(
      at: target.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: target.appendingPathComponent("ref"))
    try FileManager.default.createSymbolicLink(
      atPath: target.appendingPathComponent("ref").path, withDestinationPath: "b")
    let changes = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first
    ).changes
    let claude = SkillLifecycle.target(name: "demo", agent: .claudeCode, store: fixture.store())
      .path
    #expect(changes.contains { $0.path == claude && $0.before == .directory && $0.after == nil })
    #expect(
      changes.contains {
        $0.path == target.appendingPathComponent("empty").path && $0.before == .directory
          && $0.after == nil
      })
    #expect(
      changes.contains {
        $0.path == target.appendingPathComponent("ref").path && $0.before == .symbolicLink("b")
          && $0.after == .symbolicLink("a")
      })
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(!FileManager.default.fileExists(atPath: claude))
    #expect(
      try SkillOperations.updateInstalled(environment: fixture.environment).first?.changed == false)
  }

  @Test func previewDetectsRootLinkIdentityWithIdenticalContent() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    let target = fixture.target("demo")
    let alternate = fixture.root.appendingPathComponent("alternate")
    try FileManager.default.copyItem(at: target.resolvingSymlinksInPath(), to: alternate)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: alternate)
    let preview = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(preview.changed)
    #expect(
      preview.changes.contains {
        $0.path == target.path && $0.before == .symbolicLink(alternate.path)
          && $0.before != $0.after
      })
  }

  @Test func allReconciliationDropsMissingLiveOverrideButNamedUpdateFails() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.skill("other", body: "B")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    var declaration = try fixture.store().loadDeclaration()
    declaration.skills?["fixture"]?.overrides = ["demo": SkillOverride(mode: .edit)]
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("skills/demo"))
    #expect(throws: CoreError.self) {
      try SkillOperations.updateInstalled(
        environment: fixture.environment, skillNames: ["demo"], apply: true)
    }
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.store().loadResolved().skills.keys.sorted() == ["other"])
    #expect(!FileManager.default.fileExists(atPath: fixture.target("demo").path))
  }

  @Test func omittedRecipientsListAndRemoveAllInstalls() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    try fixture.store().save(declaration: Declaration(agents: [.codex]), resolved: ResolvedState())
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, agents: [.codex, .claudeCode], environment: fixture.environment))
    #expect(
      Set(try SkillOperations.listManaged(environment: fixture.environment).map(\.agent)) == [
        .codex, .claudeCode,
      ])
    #expect(
      Set(
        try SkillOperations.listInstalled(environment: fixture.environment).filter {
          $0.sourceIdentity != nil
        }.map(\.agent)) == [.codex, .claudeCode])
    _ = try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    #expect(try fixture.store().loadResolved().skills.isEmpty)
    #expect(try SkillOperations.listInstalled(environment: fixture.environment).isEmpty)
  }
}

extension LifecycleRegressionTests {
  @Test func installedInventoryExcludesMissingAndInvalidCandidates() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let initial = try SkillOperations.listInstalled(
      agents: [.codex], environment: fixture.environment)
    #expect(initial.map(\.name) == ["demo"], "\(initial)")
    try FileManager.default.removeItem(at: fixture.target("demo"))
    let invalid = fixture.target("invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data("# Not a skill".utf8).write(to: invalid.appendingPathComponent("SKILL.md"))
    _ = try SkillOperations.initializeSkill(
      named: "valid", directory: fixture.target("valid").deletingLastPathComponent())
    let installed = try SkillOperations.listInstalled(
      agents: [.codex], environment: fixture.environment)
    #expect(installed.map(\.name) == ["valid"])
    #expect(installed.first?.status == .installedOnly)
    #expect(installed.first?.sourceIdentity == nil)
    #expect(
      try SkillOperations.listManaged(agents: [.codex], environment: fixture.environment).first?
        .status == .missing)
  }
}
