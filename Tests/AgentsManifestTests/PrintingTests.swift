import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

private func local(_ location: String, _ requirement: SourceRequirement? = nil) -> SourceDeclaration
{
  SourceDeclaration(kind: .local, location: location, requirement: requirement)
}

private let escapedAlias = "é/别名~\"\\\n\r\t\u{1}\u{7f}\u{85}"

/// Declarations whose canonical documents are the `Printed*` goldens.
let printedDeclarations: [(String, Declaration)] = [
  ("PrintedEmpty", Declaration()),
  (
    "PrintedExplicitEmpty",
    Declaration(agents: [], instructions: InstructionsDeclaration(agents: []))
  ),
  (
    "PrintedEscapes",
    Declaration(
      agents: [],
      sources: [escapedAlias: SourceDeclaration(kind: .git, location: "example.org/escape.git")],
      skills: [escapedAlias: SkillDeclaration(select: .names(["selected"]))],
      instructions: InstructionsDeclaration(chatgpt: [
        "\"\\\n\r\t\u{1}\u{7f}\u{85} e\u{301} 😀": PromptDeclaration(
          sections: ["own"], append: "notes/内容.md")
      ]))
  ),
  (
    "PrintedRanges",
    Declaration(sources: [
      "a": SourceDeclaration(
        kind: .git, location: "https://Example.org/a.git", requirement: .exact("1.2.3+build")),
      "b": local("./b", .upToNextMajor(from: "1.2.0")),
      "c": local("./c", .upToNextMinor(from: "1.2.0-beta+build")),
      "d": local("./d", .range(from: "1.2.0", to: "2.0.0")),
      "e": local("./e", .upToNextMinor(from: "1.2.0+lower")),
      "f": local("./f", .range(from: "1.2.0", to: "1.8.0-beta+bound")),
      "g": local("./g", .upToNextMinor(from: "9223372036854775807.1.0")),
      "h": SourceDeclaration(
        kind: .git, location: "ssh://User@INTRANET:2222/team/h.git",
        requirement: .revision("abc123")),
      "i": local("./i", .upToNextMinor(from: "1.2.0-" + String(repeating: "alpha", count: 20))),
      "j": SourceDeclaration(kind: .git, location: "intranet/team@variant"),
    ])
  ),
  (
    "PrintedWidth",
    Declaration(
      sources: [
        "s": local("./s"), String(repeating: "x", count: 47): local("p"),
        String(repeating: "y", count: 48): local("p2"),
      ],
      skills: [
        "s": SkillDeclaration(
          select: .names([String(repeating: "b", count: 24), String(repeating: "a", count: 33)]),
          exclude: [String(repeating: "d", count: 24), String(repeating: "c", count: 33)],
          mode: .link)
      ])
  ),
  (
    "PrintedFields",
    Declaration(
      agents: [.opencode, .codex, .claudeCode],
      sources: [
        "empty": local("./live"),
        "git": SourceDeclaration(
          kind: .git, location: "intranet/team.git", requirement: .branch("main"), path: "skills"),
        "index": SourceDeclaration(
          kind: .wellKnown, location: "https://example.org/.well-known/skills/index.json",
          path: "bundle"),
        "local": local("./drafts", .revision("abc123")),
      ],
      skills: [
        "empty": SkillDeclaration(select: .all, mode: .edit),
        "git": SkillDeclaration(
          select: .names(["b", "a"]), exclude: ["b"], agents: [], mode: .copy,
          overrides: [
            "a": SkillOverride(agents: [.codex], mode: .link), "b": SkillOverride(agents: []),
          ]),
        "index": SkillDeclaration(select: .names([])),
        "local": SkillDeclaration(select: .all, overrides: ["future": SkillOverride(mode: .copy)]),
      ],
      instructions: InstructionsDeclaration(
        agents: [.geminiCLI, .codex], sections: ["own", "git:rule", "own", "local:nested/rule"],
        chatgpt: [
          "": PromptDeclaration(sections: []),
          "周报": PromptDeclaration(sections: ["git:rule", "own"], append: "notes/周报.md"),
        ]),
      watch: ["local", "git", "index"])
  ),
]

@Suite("Canonical manifest printing")
struct PrintingTests {
  @Test(arguments: printedDeclarations)
  func newDocumentsMatchTheirGoldensDeterministically(_ name: String, _ declaration: Declaration)
    throws
  {
    let golden = try manifestFixture(name + ".swift.txt")
    let printed = try CanonicalPrinter().manifest(
      DeclarationConstruction.root(declaration).constructionValue)
    #expect(printed == golden)
    #expect(
      try CanonicalPrinter().manifest(DeclarationConstruction.root(declaration).constructionValue)
        == printed)
    let created = try planned(Declaration(), declaration, in: nil)
    let empty = ManifestProjection.equivalent(
      declaration, Declaration(), environment: projectionEnvironment)
    #expect(created == (empty ? nil : golden))
    #expect(try planned(Declaration(), declaration, in: nil) == created)
    #expect(golden.last == 10 && !golden.contains(13))
    #expect(!golden.starts(with: [0xEF, 0xBB, 0xBF]))
    let text = String(decoding: golden, as: UTF8.self)
    for line in text.split(separator: "\n") where !line.contains("alphaalpha") {
      #expect(line.utf8.count <= 80, "\(name): \(line)")
    }
    let document = try DeclarationDocument(bytes: golden, identity: DocumentIdentity("manifest"))
    let projection = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(
      ManifestProjection.equivalent(projection, declaration, environment: projectionEnvironment))
  }

  @Test func firstEditsOfAnEmptyManifestUseTheCanonicalLayout() throws {
    let empty = manifestHeader + "let agents = Agents()\n"
    var added = Declaration()
    added.sources["skills"] = SourceDeclaration(kind: .git, location: "github.com/team/skills")
    added.skills = ["skills": SkillDeclaration(select: .all)]
    let bytes = try #require(try planned(Declaration(), added, in: empty))
    #expect(
      String(decoding: bytes, as: UTF8.self) == manifestHeader + """
        let agents = Agents(
          sources: [
            .source(name: "skills", url: "https://github.com/team/skills"),
          ],
          components: [
            .skills(source: "skills"),
          ]
        )

        """)
    #expect(
      bytes
        == (try CanonicalPrinter().manifest(DeclarationConstruction.root(added).constructionValue)))
    for (name, declaration) in printedDeclarations where name != "PrintedEmpty" {
      let edited = try #require(try planned(Declaration(), declaration, in: empty))
      #expect(edited == (try manifestFixture(name + ".swift.txt")), "\(name)")
    }
  }

  @Test func emptyArgumentListsSkipDefaultsAndRejectCommentOnlyInteriors() throws {
    let doc = try document("let agents = Agents()")
    let source = try doc.preparing(operations: [
      .setArgument(doc.node(at: "")!, field: "watch", value: .array([]))
    ])
    #expect(source.bytes == doc.bytes)
    let commented = try document("let agents = Agents(/* empty */)")
    expectManifestFailure("manifest.edit.readOnly") {
      try commented.preparing([.setWatch(["s"])])
    }
  }
}
