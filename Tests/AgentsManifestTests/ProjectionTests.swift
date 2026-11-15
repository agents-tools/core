import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

let projectionEnvironment = RuntimeEnvironment(
  projectDirectory: URL(fileURLWithPath: "/work/project", isDirectory: true),
  homeDirectory: URL(fileURLWithPath: "/work/home", isDirectory: true), environment: [:])
func projected(_ body: String) throws -> Declaration {
  try ManifestProjection.declaration(of: document(body), environment: projectionEnvironment)
}

@Suite("Manifest projection")
struct ProjectionTests {
  @Test func absentValuesStayDistinctFromExplicitEmptyValues() throws {
    #expect(try projected("version: 1\n") == Declaration())
    let explicit = try projected(
      "version: 1\ndefaultAgents: []\ncomponents: [{kind: instructions, agents: []}]\nwatch: []\n")
    #expect(explicit.agents == [])
    #expect((try explicit.instructions) == InstructionsDeclaration(agents: []))
    #expect(explicit.watch == nil)
    let inherited = try projected("version: 1\ncomponents: [{kind: instructions}]\n")
    #expect(inherited.agents == nil)
    #expect((try inherited.instructions) == InstructionsDeclaration())
    #expect((try inherited.instructions)?.agents == nil)
  }
  @Test(arguments: [
    "groups: {g: {}}\nuses: [{group: g}]",
    "components: [{kind: skills, source: s, condition: {agents: [codex]}}]",
    "components: [{kind: skills, source: s, native: {'claude-code/skill@1': {x: 1}}}]",
    "components: [{kind: instructions, condition: {scopes: [user]}}]",
    "components: [{kind: instructions, sections: [{name: g, condition: {}}]}]",
    "components: [{kind: instructions, chatgpt: {p: {sections: [], condition: {platforms: [linux]}}}}]",
    "components: [{kind: instructions, chatgpt: {p: {sections: [{name: g, condition: {}}]}}}]",
    "components: [{kind: ignore, name: i, patterns: []}]",
    "components: [{kind: skills, source: s}, {kind: skills, source: s, select: [a]}]",
    "components: [{kind: instructions}, {kind: instructions, sections: [{name: g}]}]",
    "components: [{kind: skills, source: '.'}]",
  ])
  func completeStructuresRemainSymbolic(_ fields: String) throws {
    let doc = try document("version: 1\nsources: {s: {path: s}}\n" + fields + "\n")
    let declaration = try ManifestProjection.declaration(
      of: doc, environment: projectionEnvironment)
    #expect(YAMLConstruction.root(declaration) == doc.declaration)
  }
  @Test func unusedGroupsAndExportsArePreserved() throws {
    let declaration = try projected(
      "version: 1\nexports: [review]\nsources: {s: {path: s}}\ngroups: {review: {components: [{kind: skills, source: s, condition: {agents: [codex]}}, {kind: ignore, name: i, patterns: [x]}], uses: [{group: nested}]}, nested: {components: [{kind: instructions, sections: [{name: g}]}]}}\n"
    )
    #expect(declaration.exports == ["review"])
    #expect(declaration.groups.map(\.name) == ["review", "nested"])
    #expect(declaration.groups[0].components.count == 2)
    #expect(declaration.groups[0].uses == [GroupUseDeclaration(name: "nested")])
  }
  @Test func environmentDependentValidationFollowsProjection() throws {
    let doc = try document(
      "version: 1\nsources: {a: {path: '~/rules'}, b: {path: /work/home/rules}}\n")
    #expect(throws: CoreError.self) {
      try ManifestProjection.declaration(of: doc, environment: projectionEnvironment)
    }
  }
}
