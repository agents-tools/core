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
  @Test func compilerBackedFixturesProjectAndConstructWithoutLoss() throws {
    for fixture in compiledFixtures() {
      let doc = try DeclarationDocument(
        bytes: manifestFixture(fixture.name), identity: DocumentIdentity(fixture.name))
      let declaration = try ManifestProjection.declaration(
        of: doc, environment: projectionEnvironment)
      let construction = try DeclarationConstruction.root(declaration).constructionValue
      #expect(Lowering.declaration(construction) == doc.declaration, "\(fixture.name)")
      #expect(
        Lowering.declaration(fixture.agents.constructionValue) == doc.declaration, "\(fixture.name)"
      )
      let printed = try CanonicalPrinter().manifest(construction)
      let roundtrip = try DeclarationDocument(
        bytes: printed, identity: DocumentIdentity(fixture.name))
      #expect(roundtrip.declaration == doc.declaration, "\(fixture.name)")
    }
  }

  @Test func absentValuesStayDistinctFromExplicitEmptyValues() throws {
    #expect(try projected("let agents = Agents()") == Declaration())
    let explicit = try projected(
      "let agents = Agents(defaultAgents: [], components: [.instructions(agents: [])], watch: [])")
    #expect(explicit.agents == [])
    #expect((try explicit.instructions) == InstructionsDeclaration(agents: []))
    #expect(explicit.watch == nil)
    let inherited = try projected("let agents = Agents(components: [.instructions()])")
    #expect(inherited.agents == nil)
    #expect((try inherited.instructions) == InstructionsDeclaration())
    #expect((try inherited.instructions)?.agents == nil)
  }

  @Test(arguments: [
    "groups: [.group(name: \"g\")], uses: [\"g\"]",
    "components: [.skills(source: \"s\", condition: .when(agents: [.codex]))]",
    "components: [.skills(source: \"s\", native: [\"claude-code/skill@1\": [\"x\": 1]])]",
    "components: [.instructions(condition: .when(scopes: [.user]))]",
    "components: [.instructions(sections: [.section(name: \"g\", condition: .when())])]",
    "components: [.instructions(chatGPT: [.prompt(name: \"p\", sections: [], condition: .when(platforms: [.linux]))])]",
    "components: [.instructions(chatGPT: [.prompt(name: \"p\", sections: [.section(name: \"g\", condition: .when())])])]",
    "components: [.ignore(name: \"i\", patterns: [])]",
    "components: [.skills(source: \"s\"), .skills(source: \"s\", select: [\"a\"])]",
    "components: [.instructions(), .instructions(sections: [\"g\"])]",
    "components: [.skills(source: \".\")]",
  ])
  func completeStructuresRemainSymbolic(_ fields: String) throws {
    let body = #"let agents = Agents(sources: [.source(name: "s", path: "s")], "# + fields + ")"
    let doc = try document(body)
    let declaration = try ManifestProjection.declaration(
      of: doc, environment: projectionEnvironment)
    #expect(
      Lowering.declaration(try DeclarationConstruction.root(declaration).constructionValue)
        == doc.declaration)
  }

  @Test func unusedGroupsAndExportsArePreserved() throws {
    let declaration = try projected(
      """
      let agents = Agents(
        exports: ["review"],
        sources: [.source(name: "s", path: "s")],
        groups: [
          .group(
            name: "review",
            components: [
              .skills(source: "s", condition: .when(agents: [.codex])),
              .ignore(name: "i", patterns: ["x"]),
            ],
            uses: ["nested"]
          ),
          .group(name: "nested", components: [.instructions(sections: ["g"])]),
        ]
      )
      """)
    #expect(declaration.exports == ["review"])
    #expect(declaration.groups.map(\.name) == ["review", "nested"])
    #expect(declaration.groups[0].components.count == 2)
    #expect(declaration.groups[0].uses == [GroupUseDeclaration(name: "nested")])
  }

  @Test func environmentDependentValidationFollowsProjection() throws {
    let doc = try document(
      "let agents = Agents(sources: [.source(name: \"a\", path: \"~/rules\"), .source(name: \"b\", path: \"/work/home/rules\")])"
    )
    #expect(throws: CoreError.self) {
      try ManifestProjection.declaration(of: doc, environment: projectionEnvironment)
    }
    let other = RuntimeEnvironment(
      projectDirectory: URL(fileURLWithPath: "/work/project", isDirectory: true),
      homeDirectory: URL(fileURLWithPath: "/elsewhere", isDirectory: true), environment: [:])
    #expect(try ManifestProjection.declaration(of: doc, environment: other).sources.count == 2)
  }

  @Test func semanticEqualityIgnoresSpellingButKeepsInheritanceAndSectionOrder() throws {
    func equal(_ lhs: Declaration, _ rhs: Declaration) -> Bool {
      ManifestProjection.equivalent(lhs, rhs, environment: projectionEnvironment)
    }
    func sources(_ source: SourceDeclaration) -> Declaration { Declaration(sources: ["s": source]) }
    #expect(
      equal(
        sources(SourceDeclaration(kind: .git, location: "github.com/a/b")),
        sources(SourceDeclaration(kind: .git, location: "https://GitHub.com/a/b.git/"))))
    #expect(
      equal(
        sources(SourceDeclaration(kind: .local, location: "./rules", path: "./skills/")),
        sources(SourceDeclaration(kind: .local, location: "/work/project/rules", path: "skills"))))
    #expect(
      equal(
        sources(
          SourceDeclaration(
            kind: .git, location: "https://e.org/r", requirement: .range(from: "1.2.0", to: "2.0.0")
          )),
        sources(
          SourceDeclaration(
            kind: .git, location: "https://e.org/r", requirement: .upToNextMajor(from: "v1.2.0")))))
    #expect(
      !equal(
        sources(
          SourceDeclaration(kind: .git, location: "https://e.org/r", requirement: .exact("1.0.0"))),
        sources(
          SourceDeclaration(kind: .git, location: "https://e.org/r", requirement: .exact("1.0.0+b"))
        )))
    #expect(
      !equal(
        sources(SourceDeclaration(kind: .local, location: "a")),
        sources(SourceDeclaration(kind: .local, location: "a", path: "x"))))
    #expect(equal(Declaration(agents: [.codex, .cursor]), Declaration(agents: [.cursor, .codex])))
    #expect(!equal(Declaration(agents: []), Declaration()))
    #expect(equal(Declaration(skills: [:], watch: []), Declaration()))
    let base = Declaration(sources: ["s": SourceDeclaration(kind: .local, location: "s")])
    var left = base
    var right = base
    try left.setSkills([
      "s": SkillDeclaration(select: .names(["a", "b"]), exclude: [], overrides: [:])
    ])
    try right.setSkills(["s": SkillDeclaration(select: .names(["b", "a"]))])
    #expect(equal(left, right))
    try right.updateSkills { $0?["s"]?.agents = [] }
    #expect(!equal(left, right))
    try left.setInstructions(InstructionsDeclaration(sections: ["a", "b"], chatgpt: [:]))
    right = left
    try right.updateInstructions { $0?.chatgpt = nil }
    #expect(equal(left, right))
    try right.updateInstructions { $0?.sections = ["b", "a"] }
    #expect(!equal(left, right))
    try right.setInstructions(nil)
    #expect(!equal(left, right))
  }
}
