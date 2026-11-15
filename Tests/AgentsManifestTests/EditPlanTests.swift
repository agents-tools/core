import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

func planned(_ previous: Declaration, _ next: Declaration, in text: String?) throws -> [UInt8]? {
  try DeclarationEditPlan.bytes(
    replacing: previous, with: next, in: text.map { Array($0.utf8) },
    identity: DocumentIdentity("manifest"), environment: projectionEnvironment)
}

@Suite("Declaration edit planning")
struct EditPlanTests {
  @Test func equivalentSpellingsAndWatchOrderPreserveEveryByte() throws {
    let body = """
      # header
      version: 1
      defaultAgents: [codex, claude-code]
      sources:
        g: {url: https://github.com/team/skills, requirement: {from: "1.2.0", to: "2.0.0"}}
        l: {path: ./rules/, subpath: ./skills} # retained
      components: [{kind: skills, source: g, select: [b, a], exclude: []}]
      watch: [l, g]
      """
    let previous = try projected(body)
    var next = previous
    next.agents = [.claudeCode, .codex]
    next.sources["g"] = SourceDeclaration(
      kind: .git, location: "https://GitHub.com/team/skills.git",
      requirement: .upToNextMajor(from: "1.2.0"))
    next.sources["l"] = SourceDeclaration(
      kind: .local, location: "/work/project/rules", path: "skills")
    try next.updateSkills { $0?["g"] = SkillDeclaration(select: .names(["a", "b"])) }
    next.watch = ["g", "l"]
    #expect(try planned(previous, next, in: body) == nil)
    #expect(try planned(Declaration(), Declaration(), in: nil) == nil)
  }
  @Test func defaultRecipientsCanBeInsertedReplacedAndOmitted() throws {
    var previous = try projected("version: 1\n")
    var bytes = Array("version: 1\n".utf8)
    for recipients: [AgentID]? in [[], [.codex, .claudeCode], nil] {
      var next = previous
      next.agents = recipients
      bytes = try #require(try planned(previous, next, in: String(decoding: bytes, as: UTF8.self)))
      #expect(try projected(String(decoding: bytes, as: UTF8.self)).agents == recipients)
      previous = next
    }
  }
  @Test func missingCollectionsAndLastElementRemovalKeepValidDocuments() throws {
    let doc = try document("# header\r\nversion: 1\r\n")
    let added = try doc.preparing([
      .insertComponent(
        .instructions(InstructionsDeclaration(sections: ["guide"])), into: .root, at: .last)
    ])
    let populated = try DeclarationDocument(
      bytes: added.bytes, identity: DocumentIdentity("manifest"))
    let removed = try populated.preparing([
      .removeComponent(#require(populated.node(at: "/components/0")))
    ])
    #expect(
      try DeclarationDocument(bytes: removed.bytes, identity: DocumentIdentity("manifest"))
        .declaration.components.isEmpty)
    #expect(String(decoding: removed.bytes, as: UTF8.self).hasPrefix("# header\r\n"))
  }
  @Test func preparationRejectsOversizedIntentBeforeRendering() throws {
    let doc = try document("version: 1\n")
    expectManifestFailure("manifest.limit") {
      try doc.preparing([
        .insertComponent(
          .ignore(name: "large", patterns: [String(repeating: "x", count: 20_000_000)]),
          into: .root, at: .first)
      ])
    }
  }
}

extension EditPlanTests {
  @Test func blockAndFlowMovesCarryCommentsAcrossContainers() throws {
    let doc = try document(
      """
      version: 1
      components:
        # owned entry
        - kind: ignore
          name: moving
          patterns: [] # owned tail
      groups:
        target:
          components:
            - {kind: ignore, name: existing, patterns: []}
      """)
    let change = try doc.preparing([
      .moveComponent(
        #require(doc.node(at: "/components/0")), into: .group(#require(doc.node(at: "/groups/0"))),
        at: .last)
    ])
    let result = try DeclarationDocument(
      bytes: change.bytes, identity: DocumentIdentity("manifest"))
    #expect(result.declaration.components.isEmpty)
    #expect(result.declaration.groups[0]["components"]?.elements?.count == 2)
    let text = String(decoding: change.bytes, as: UTF8.self)
    #expect(text.contains("# owned entry\n      - kind: ignore"))
    #expect(text.contains("patterns: [] # owned tail"))
    let flow = try document(
      "version: 1\ncomponents: [{kind: ignore, name: moving, patterns: []}]\ngroups: {target: {}}\n"
    )
    let moved = try flow.preparing([
      .moveComponent(
        #require(flow.node(at: "/components/0")),
        into: .group(#require(flow.node(at: "/groups/0"))), at: .first)
    ])
    #expect(
      try DeclarationDocument(bytes: moved.bytes, identity: DocumentIdentity("manifest"))
        .declaration.groups[0]["components"]?.elements?.count == 1)
  }

  @Test func sourceKindChangeRetainsInternalCommentsAndUnchangedFields() throws {
    let body =
      "version: 1\nsources:\n  s:\n    path: ./s # location\n    # root comment\n    subpath: rules\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
    let previous = try projected(body)
    var next = previous
    next.sourceDeclarations[0].source = SourceDeclaration(
      kind: .git, location: "https://example.invalid/repo.git", path: "rules")
    try next.updateSkills { $0?["s"]?.mode = .copy }
    let bytes = try #require(try planned(previous, next, in: body))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(text.contains("# root comment\n    subpath: rules"))
    #expect(text.contains("# location"))
    #expect(try projected(text).components == next.components)
  }

  @Test func unrelatedHandlesAndLiteralKindsAreRejectedWithoutTrapping() throws {
    let doc = try document("version: 1\ncomponents: [{kind: ignore, name: i, patterns: []}]\n")
    let scalar = try #require(doc.node(at: "/components/0/name"))
    for edit in [
      ManifestEdit.setSkillSelection(scalar, .all), .moveComponent(scalar, into: .root, at: .first),
      .setDictionaryEntry(scalar, key: "k", value: .string("v")),
    ] {
      expectManifestFailure("manifest.edit.readOnly") { try doc.preparing([edit]) }
    }
  }
}

extension EditPlanTests {
  @Test func blockScalarHeaderCommentsAndFollowingFieldsSurviveReplacement() throws {
    let doc = try document(
      "version: 1\ncomponents:\n  - kind: subagent\n    name: a\n    description: d\n    prompt: |- # owned header\n      before\n    model: keep\n# tail\n"
    )
    let change = try doc.preparing([
      .replaceComponent(
        #require(doc.node(at: "/components/0")),
        with: .subagent(name: "a", description: "d", prompt: .literal("after"), model: "keep"))
    ])
    let text = String(decoding: change.bytes, as: UTF8.self)
    #expect(text.contains("# owned header\n    model: keep\n# tail\n"))
    #expect(
      try DeclarationDocument(bytes: change.bytes, identity: DocumentIdentity("manifest"))
        .declaration == change.expectedDeclaration)
  }
}
