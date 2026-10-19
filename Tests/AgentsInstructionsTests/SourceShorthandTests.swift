import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction source shorthand")
struct InstructionSourceShorthandTests {
  @Test func addStoresTheRequirementAndRejectsSkillSelectors() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    #expect(throws: CoreError.self) {
      try InstructionOperations.add(
        InstructionAddOptions(
          source: fixture.repo.path + "@skill:rules", environment: fixture.environment))
    }
    try InstructionOperations.add(
      InstructionAddOptions(
        source: fixture.repo.path + "@branch:main", names: ["rules"], agents: [.codex],
        environment: fixture.environment))
    let declaration = try fixture.store().loadDeclaration()
    #expect(declaration.sources["rules"]?.requirement == .branch("main"))
  }
}
