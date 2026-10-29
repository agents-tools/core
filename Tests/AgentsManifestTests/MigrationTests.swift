import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

private let migrationCases = [
  "MigrationEmpty", "MigrationExplicitEmpty", "MigrationFields", "MigrationAliases",
  "MigrationRanges", "MigrationEscapes", "MigrationWidth", "MigrationAliasGap",
]

func manifestFixture(_ name: String) throws -> [UInt8] {
  Array(try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)))
}

@Suite("Manifest migration")
struct MigrationTests {
  @Test(arguments: migrationCases)
  func canonicalFixturesAreByteExactDeterministicAndStableUnderEqualEdits(_ name: String) throws {
    let input = try manifestFixture(name + ".migration.json")
    let first = try ManifestMigration.generate(json: input)
    let second = try ManifestMigration.generate(json: input)
    #expect(try first.bytes == manifestFixture(name + ".swift.txt"))
    #expect(first.bytes == second.bytes)
    #expect(first.diagnostics == second.diagnostics)
    #expect(first.bytes.last == 10 && !first.bytes.dropLast().suffix(1).contains(10))
    #expect(!first.bytes.starts(with: [0xEF, 0xBB, 0xBF]) && !first.bytes.contains(13))
    let doc = try DeclarationDocument(bytes: first.bytes, identity: DocumentIdentity("manifest"))
    #expect(doc.declaration == first.declaration)
    let edited = try doc.preparing([.setWatch(first.declaration.watch)])
    #expect(edited.bytes == first.bytes && edited.patches.isEmpty)
  }

  @Test func transformationsReportOriginalPointersFullValuesAndPreserveExcludedOverrides() throws {
    let result = try ManifestMigration.generate(
      json: manifestFixture("MigrationAliases.migration.json"))
    #expect(
      result.diagnostics.map(\.code) == ["migration.inertOverride", "migration.sourceAliasRenamed"])
    #expect(result.diagnostics.map(\.pointer) == ["/skills/./overrides/b", "/sources/."])
    #expect(result.diagnostics[0].value == .object([:]))
    #expect(result.diagnostics[1].oldAlias == "." && result.diagnostics[1].newAlias == "source-3")
    #expect(
      result.declaration.sources.map { $0["name"]?.string } == ["source", "source-2", "source-3"])
    #expect(result.declaration.components[0]["overrides"]?.elements?.count == 1)
    let instructions = result.declaration.components[1]
    let sections = try #require(instructions["sections"]?.elements)
    #expect(
      sections.map { $0.record?["source"] } == [.null, .string("source-3"), .string("source-3")])
    let prompts = try #require(instructions["chatGPT"]?.elements)
    #expect(prompts[0].record?["sections"]?.elements?[0].record?["source"] == .string("source-3"))
    #expect(result.declaration.watch == ["source", "source-3"])
    let fields = try ManifestMigration.generate(
      json: manifestFixture("MigrationFields.migration.json"))
    #expect(fields.diagnostics.count == 1)
    #expect(
      fields.diagnostics[0].value
        == .object([
          "agents": .array([.string("opencode"), .string("codex")]), "mode": .string("copy"),
        ]))
    #expect(fields.declaration.components[3]["overrides"]?.elements?.count == 1)
    let escaped = try ManifestMigration.generate(
      json: manifestFixture("MigrationEscapes.migration.json"))
    #expect(
      escaped.diagnostics[0].pointer.contains("~1") && escaped.diagnostics[0].pointer.contains("~0")
    )
  }

  @Test func firstUnusedAliasAndInertRulesDoNotDependOnDiscovery() throws {
    let result = try ManifestMigration.generate(
      json: manifestFixture("MigrationAliasGap.migration.json"))
    #expect(result.diagnostics.count == 1 && result.diagnostics[0].newAlias == "source")
    #expect(result.declaration.components[0]["overrides"]?.elements?.count == 1)
  }

  @Test func compatibilityProjectionRetainsInheritanceAndCanonicalizesCoreRequirements() throws {
    let legacy = Declaration(
      agents: [],
      sources: [
        "a": SourceDeclaration(
          kind: .git, location: "intranet/team.git",
          requirement: .range(from: "v1.2.0", to: "2.0.0+meta"))
      ],
      skills: [
        "a": SkillDeclaration(
          select: .names([]), agents: [], mode: .link,
          overrides: ["future": SkillOverride(agents: [])])
      ],
      instructions: InstructionsDeclaration())
    let projection = try legacy.compatibilityProjection()
    #expect(projection.defaultAgents == [])
    #expect(projection.sources[0]["url"] == .string("https://intranet/team.git"))
    #expect(projection.sources[0]["requirement"] == .requirement(.upToNextMajor(from: "1.2.0")))
    #expect(projection.components[0]["agents"] == .array([]))
    #expect(projection.components[0]["mode"] == .string("link"))
    #expect(projection.components[0]["overrides"]?.elements?.count == 1)
    #expect(projection.components[1]["agents"] == .null)
    #expect(try Declaration().compatibilityProjection() == DeclarationIR())
    let migration = try ManifestMigration.generate(
      json: manifestFixture("MigrationRanges.migration.json"))
    let doc = try DeclarationDocument(
      bytes: migration.bytes, identity: DocumentIdentity("manifest"))
    let change = try doc.preparing([
      .upsertSource(.source(name: "b", path: "./b", "1.2.0"..<"2.0.0"))
    ])
    #expect(change.bytes == doc.bytes && change.patches.isEmpty)
  }

  @Test(arguments: [
    #"{"unknown":null}"#, #"{"sources":{"x":{"git":"intranet/team","unknown":null}}}"#,
    #"{"sources":{},"sources":{}}"#, #"{"agents":["unknown"]}"#,
    #"{"sources":{"x":{"local":"a"}},"skills":{"x":{"select":"all","overrides":{"a":{"unknown":null}}}}}"#,
  ])
  func strictJSONFailuresNeverProduceSource(_ input: String) {
    #expect(throws: (any Error).self) { try ManifestMigration.generate(json: Array(input.utf8)) }
  }

  @Test func invalidUTF8AndSelfCheckFailuresHaveNoPartialResult() throws {
    #expect(throws: (any Error).self) { try ManifestMigration.generate(json: [0xFF]) }
    var result: ManifestMigrationResult?
    do {
      result = try ManifestMigration.generate(
        json: Array("{}".utf8), environment: RuntimeEnvironment(),
        checking: { _ in DeclarationIR(watch: ["wrong"]) })
      Issue.record("self-check did not reject mismatching projection")
    } catch let failure as MigrationFailure {
      #expect(failure.diagnostics.map(\.code) == ["migration.mismatch"])
    }
    #expect(result == nil)
  }

  @Test func byteWidthIncludesLabelsCommasAndUTF8() throws {
    let printer = CanonicalPrinter()
    let atBoundary = Source.source(name: String(repeating: "a", count: 47), path: "p")
      .constructionValue
    let overBoundary = Source.source(name: String(repeating: "a", count: 48), path: "p")
      .constructionValue
    #expect(!printer.render(atBoundary, indentation: "    ").contains("\n"))
    #expect(printer.render(overBoundary, indentation: "    ").contains("\n"))
    let unicode = Source.source(name: String(repeating: "é", count: 24), path: "p")
      .constructionValue
    #expect(printer.render(unicode, indentation: "    ").contains("\n"))
    let doc = try ManifestMigration.generate(json: manifestFixture("MigrationWidth.migration.json"))
    let text = String(decoding: doc.bytes, as: UTF8.self)
    #expect(text.contains("select: ["))
    #expect(text.split(separator: "\n").allSatisfy { $0.utf8.count <= 80 })
  }

  @Test func migrationLimitsAreNamedAndNeverReturnTruncatedResults() throws {
    func limit(_ budget: String, _ operation: () throws -> Void) {
      do {
        try operation()
        Issue.record("expected migration.limit: \(budget)")
      } catch let failure as MigrationFailure {
        #expect(failure.diagnostics.map(\.code) == ["migration.limit"])
        #expect(failure.diagnostics[0].budget?.contains(budget) == true)
      } catch { Issue.record(error) }
    }
    limit("collection entries") {
      try ManifestMigration.preflight(.array(Array(repeating: .none, count: 10_001)))
    }
    var deep: ConstructionValue = .none
    for _ in 0..<64 { deep = .array([deep]) }
    limit("expanded depth") { try ManifestMigration.preflight(deep) }
    let nodes = ConstructionValue.array(
      Array(repeating: .array(Array(repeating: .none, count: 100)), count: 1_000))
    limit("expanded nodes") { try ManifestMigration.preflight(nodes) }
    limit("decoded string bytes") {
      try ManifestMigration.preflight(
        .text(String(repeating: "x", count: ManifestLimits.Values.stringBytes + 1)))
    }
    limit("encoded output bytes") {
      try ManifestMigration.preflight(.text(String(repeating: "\0", count: 6_000_000)))
    }
    let oversized = Declaration(sources: [
      "s": SourceDeclaration(
        kind: .local, location: String(repeating: "x", count: ManifestLimits.Input.bytes))
    ])
    limit("source bytes") {
      _ = try ManifestMigration.generate(json: Array(JSONEncoder().encode(oversized)))
    }
    let many = Declaration(
      sources: ["s": SourceDeclaration(kind: .local, location: "s")],
      instructions: InstructionsDeclaration(sections: Array(repeating: "s:guide", count: 3_600)))
    limit("reservation") {
      _ = try ManifestMigration.generate(json: Array(JSONEncoder().encode(many)))
    }
  }
}
