import AgentsCore
import AgentsSkills
import Foundation
import Testing

@Suite("Typed source shorthand")
struct SourceShorthandTests {
  @Test func addStoresSelectorsAsDeclarationFields() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.skill("other", body: "B")
    try fixture.commit()
    let outcome = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path + "@branch:master@skill:demo", agents: [.codex],
        environment: fixture.environment))
    #expect(outcome.installed.map(\.skill) == ["demo"])
    let declaration = try fixture.store().loadDeclaration()
    #expect(
      declaration.sources == [
        "source": SourceDeclaration(
          kind: .local, location: fixture.repo.path, requirement: .branch("master"))
      ])
    #expect(declaration.skills?["source"]?.select == .names(["demo"]))
  }

  @Test func sourceListingFiltersToTheSelectedSkill() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.skill("other", body: "B")
    try fixture.commit()
    let outcome = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path + "@skill:demo", listOnly: true,
        environment: fixture.environment))
    #expect(outcome.availableSkills.map(\.name) == ["demo"])
  }

  @Test func conflictingOptionsStopBeforeWriting() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path + "@branch:master", sourceRequirement: .branch("other"),
          environment: fixture.environment))
    }
    #expect(throws: CoreError.self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path + "@skill:demo", all: true, environment: fixture.environment))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().declarationURL.path))
  }

  @Test func watchAddDeclaresTheRequirementAndRejectsSkillSelectors() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    try fixture.store().save(declaration: Declaration(), resolved: ResolvedState())
    let watch = SkillOperations.watchOperations()
    #expect(throws: CoreError.self) {
      try watch.add(fixture.repo.path + "@skill:demo", environment: fixture.environment)
    }
    try watch.add(fixture.repo.path + "@branch:master", environment: fixture.environment)
    let declaration = try fixture.store().loadDeclaration()
    #expect(declaration.sources["source"]?.requirement == .branch("master"))
    #expect(declaration.watch == ["source"])
  }
}
