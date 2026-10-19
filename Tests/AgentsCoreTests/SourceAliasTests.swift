import Foundation
import Testing

@testable import AgentsCore

@Suite("Source aliases")
struct SourceAliasTests {
  @Test func derivesTheLastComponentWhileItIsFree() {
    let declaration = Declaration()
    #expect(declaration.derivedAlias(for: "https://github.com/anthropics/skills") == "skills")
    #expect(declaration.derivedAlias(for: "git@github.com:owner/rules.git") == "rules")
    #expect(declaration.derivedAlias(for: "/work/Team Rules") == "team-rules")
  }

  @Test func prefixesParentsThenNumbersWhileTaken() {
    var declaration = Declaration(sources: [
      "skills": SourceDeclaration(kind: .git, location: "https://github.com/sketch-hq/skills")
    ])
    #expect(
      declaration.derivedAlias(for: "https://github.com/anthropics/skills") == "anthropics-skills")
    #expect(declaration.derivedAlias(for: "git@github.com:owner/skills.git") == "owner-skills")
    #expect(declaration.derivedAlias(for: "/work/team/skills") == "team-skills")
    declaration.sources["anthropics-skills"] = SourceDeclaration(
      kind: .git, location: "https://gitlab.com/anthropics/skills")
    #expect(
      declaration.derivedAlias(for: "https://github.com/anthropics/skills")
        == "github.com-anthropics-skills")
    #expect(declaration.derivedAlias(for: "/skills") == "skills-2")
  }
}
