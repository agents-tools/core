import AgentsCore
import AgentsSkills
import Foundation
import Testing

@Suite("Source aliases on add")
struct SkillSourceAliasTests {
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
    #expect(declaration.skills?["mirror-source"]?.select == .names(["other"]))
  }
}
