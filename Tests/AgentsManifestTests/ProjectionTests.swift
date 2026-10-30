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
  @Test func everyDeployableShapeMapsToTheDeclaration() throws {
    let declaration = try projected(
      """
      let agents = Agents(
        defaultAgents: [.openCode, .claudeCode],
        sources: [
          .source(name: "git", url: "github.com/team/skills", branch: "main", subpath: "skills"),
          .source(name: "local", path: "./drafts", "1.2.0"..<"2.0.0"),
          .source(name: "index", index: "https://example.org/.well-known/skills/index.json"),
          .source(name: "pinned", url: "https://example.org/p.git", exact: "1.2.3+build"),
        ],
        components: [
          .skills(source: "git"),
          .skills(
            source: "local", select: ["a", "b"], exclude: ["b"], mode: .copy,
            overrides: [.skill(name: "a", mode: .link, agents: []), .skill(name: "b")],
            agents: [.codex]),
          .skills(source: "index", select: [], exclude: []),
          .instructions(
            sections: ["guide", .section(name: "rule", source: "git"), .section(name: "own", source: "."), "guide"],
            chatGPT: [.prompt(name: "weekly", sections: [], append: "notes/weekly.md")],
            agents: []),
        ],
        watch: ["git"]
      )
      """)
    #expect(
      declaration
        == Declaration(
          agents: [.opencode, .claudeCode],
          sources: [
            "git": SourceDeclaration(
              kind: .git, location: "https://github.com/team/skills", requirement: .branch("main"),
              path: "skills"),
            "local": SourceDeclaration(
              kind: .local, location: "./drafts", requirement: .upToNextMajor(from: "1.2.0")),
            "index": SourceDeclaration(
              kind: .wellKnown, location: "https://example.org/.well-known/skills/index.json"),
            "pinned": SourceDeclaration(
              kind: .git, location: "https://example.org/p.git", requirement: .exact("1.2.3+build")),
          ],
          skills: [
            "git": SkillDeclaration(select: .all),
            "local": SkillDeclaration(
              select: .names(["a", "b"]), exclude: ["b"], agents: [.codex], mode: .copy,
              overrides: [
                "a": SkillOverride(agents: [], mode: .link), "b": SkillOverride(),
              ]),
            "index": SkillDeclaration(select: .names([])),
          ],
          instructions: InstructionsDeclaration(
            agents: [], sections: ["guide", "git:rule", "own", "guide"],
            chatgpt: ["weekly": PromptDeclaration(sections: [], append: "notes/weekly.md")]),
          watch: ["git"]))
  }

  @Test func absentValuesStayDistinctFromExplicitEmptyValues() throws {
    #expect(try projected("let agents = Agents()") == Declaration())
    let explicit = try projected(
      "let agents = Agents(defaultAgents: [], components: [.instructions(agents: [])], watch: [])")
    #expect(explicit.agents == [])
    #expect(explicit.instructions == InstructionsDeclaration(agents: []))
    #expect(explicit.watch == nil)
    let inherited = try projected("let agents = Agents(components: [.instructions()])")
    #expect(inherited.agents == nil)
    #expect(inherited.instructions == InstructionsDeclaration())
    #expect(inherited.instructions?.agents == nil)
  }

  @Test(arguments: [
    ("groups: [.group(name: \"g\")], uses: [\"g\"]", "\"g\""),
    (
      "components: [.skills(source: \"s\", condition: .when(agents: [.codex]))]",
      ".when(agents: [.codex])"
    ),
    (
      "components: [.skills(source: \"s\", native: [\"claude-code/skill@1\": [\"x\": 1]])]",
      "[\"claude-code/skill@1\": [\"x\": 1]]"
    ),
    ("components: [.instructions(condition: .when(scopes: [.user]))]", ".when(scopes: [.user])"),
    (
      "components: [.instructions(sections: [.section(name: \"g\", condition: .when())])]",
      ".when()"
    ),
    (
      "components: [.instructions(chatGPT: [.prompt(name: \"p\", sections: [], condition: .when(platforms: [.linux]))])]",
      ".when(platforms: [.linux])"
    ),
    (
      "components: [.instructions(chatGPT: [.prompt(name: \"p\", sections: [.section(name: \"g\", condition: .when())])])]",
      ".when()"
    ),
    ("components: [.ignore(name: \"i\", patterns: [])]", ".ignore(name: \"i\", patterns: [])"),
    (
      "components: [.skills(source: \"s\"), .skills(source: \"s\", select: [\"a\"])]",
      ".skills(source: \"s\", select: [\"a\"])"
    ),
    (
      "components: [.instructions(), .instructions(sections: [\"g\"])]",
      ".instructions(sections: [\"g\"])"
    ),
    ("components: [.skills(source: \".\")]", "\".\""),
  ])
  func unsupportedStructuresAreReportedAtTheirLocation(_ fields: String, _ located: String) throws {
    let body =
      "let agents = Agents(sources: [.source(name: \"s\", path: \"s\")], " + fields + ")"
    let doc = try document(body)
    do {
      _ = try ManifestProjection.declaration(of: doc, environment: projectionEnvironment)
      Issue.record("projection accepted unsupported structure: \(fields)")
    } catch let failure as ManifestFailure {
      #expect(failure.diagnostics.map(\.code) == ["manifest.unsupported"])
      let span = try #require(failure.diagnostics.first?.span)
      #expect(span.document == DocumentIdentity("manifest"))
      #expect(
        String(decoding: doc.bytes[span.start..<span.end], as: UTF8.self) == located, "\(fields)")
      #expect(span.line == 4 && span.column > 1)
    }
  }

  @Test func inertGroupsAndExportsAreAccepted() throws {
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
    #expect(
      declaration == Declaration(sources: ["s": SourceDeclaration(kind: .local, location: "s")]))
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

  @Test func semanticEqualityIgnoresSpellingButKeepsInheritanceAndSectionOrder() {
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
    left.skills = ["s": SkillDeclaration(select: .names(["a", "b"]), exclude: [], overrides: [:])]
    right.skills = ["s": SkillDeclaration(select: .names(["b", "a"]))]
    #expect(equal(left, right))
    right.skills?["s"]?.agents = []
    #expect(!equal(left, right))
    left.instructions = InstructionsDeclaration(sections: ["a", "b"], chatgpt: [:])
    right = left
    right.instructions?.chatgpt = nil
    #expect(equal(left, right))
    right.instructions?.sections = ["b", "a"]
    #expect(!equal(left, right))
    right.instructions = nil
    #expect(!equal(left, right))
  }
}
