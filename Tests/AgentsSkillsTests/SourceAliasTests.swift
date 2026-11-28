import AgentsCore
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

@Suite("Source aliases on add")
struct SkillSourceAliasTests {
  @Test(arguments: [false, true])
  func addSelectsTheRequestedRootOfASharedRepository(located: Bool) throws {
    let fixture = try SkillFixture()
    try fixture.skill("first", body: "First root")
    let second = fixture.repo.appendingPathComponent("second/skills/second")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "---\nname: second\ndescription: Test skill\n---\n\nSecond root\n".write(
      to: second.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try fixture.commit()
    try fixture.store().save(
      declaration: Declaration(sources: [
        "a": SourceDeclaration(kind: .local, location: fixture.repo.path, path: "."),
        "b": SourceDeclaration(kind: .local, location: fixture.repo.path, path: "second"),
      ]), ledger: ResolvedLedger())
    let sources = try fixture.store().loadDeclaration().sources
    _ = try SkillOperations.add(
      AddOptions(
        source: "a", agents: [.codex], skillNames: ["first"],
        environment: fixture.environment))
    let first = try fixture.body(fixture.target("first"))
    let result = try SkillOperations.add(
      AddOptions(
        source: located ? fixture.repo.path + "@path:second" : "b",
        agents: [.codex], skillNames: ["second"], environment: fixture.environment))
    #expect(result.installed.map(\.skill) == ["second"])
    let declaration = try fixture.store().loadDeclaration()
    #expect(declaration.sources == sources)
    let skills = try declaration.skills
    #expect(skills?["a"]?.select == .names(["first"]))
    #expect(skills?["b"]?.select == .names(["second"]))
    #expect(try fixture.body(fixture.target("first")) == first)
    #expect(try fixture.body(fixture.target("second")).contains("Second root"))
  }

  @Test func sourcesSharingALastComponentReceiveDistinctAliases() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let mirror = fixture.root.appendingPathComponent("mirror/source")
    let skill = mirror.appendingPathComponent("skills/other")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "---\nname: other\ndescription: Test skill\n---\n\nB\n".write(
      to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try initGitRepo(mirror)
    for repo in [fixture.repo, mirror] {
      _ = try SkillOperations.add(
        AddOptions(source: repo.path, agents: [.codex], environment: fixture.environment))
    }
    let declaration = try fixture.store().loadDeclaration()
    #expect(declaration.sources["source"]?.location == fixture.repo.path)
    #expect(declaration.sources["mirror-source"]?.location == mirror.path)
    #expect((try declaration.skills)?["mirror-source"]?.select == .names(["other"]))
  }
}
