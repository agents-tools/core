import AgentsDescription
import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsManifest

@Suite("Manifest semantic versions")
struct SemanticVersionTests {
  @Test func descriptionValidationAndOrderingMatchCore() {
    let versions = [
      "0.0.0", "v1.2.3", " V1.2.3+build ", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
      "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.0+build",
      "\(Int.max).\(Int.max).\(Int.max)", "1.0.0-9999999999999999999999999999999", "", "1.0",
      "01.0.0", "1.01.0", "1.0.01", "1.0.0-01", "1.0.0-", "1.0.0+", "1.0.0+a+b", "1.0.0-😀",
    ]
    for raw in versions {
      let value = Version(stringLiteral: raw)
      let oracle = SemanticVersion(raw)
      #expect(value.valid == (oracle != nil), "\(raw)")
      if let oracle { #expect(value.normalized == oracle.description) }
      for other in versions {
        if let a = oracle, let b = SemanticVersion(other) {
          #expect((value < Version(stringLiteral: other)) == (a < b))
          #expect((value == Version(stringLiteral: other)) == (a == b))
        }
      }
    }
  }

  @Test func rangeIRUsesPrecedenceAndExactIRKeepsMetadata() throws {
    #expect(
      DeclarationValue.requirement(.range(from: "1.2.0+left", to: "1.8.0+right"))
        == .requirement(.range(from: "1.2.0", to: "1.8.0")))
    #expect(
      DeclarationValue.requirement(.upToNextMajor(from: "1.2.0"))
        == .requirement(.range(from: "1.2.0", to: "2.0.0+build")))
    #expect(DeclarationValue.requirement(.exact("1.2.0+build")) != .requirement(.exact("1.2.0")))
    let doc = try document(
      "let agents = Agents(sources: [.source(name: \"s\", path: \"s\", \"1.2.0+lower\"..<\"1.8.0+upper\")])"
    )
    let change = try doc.preparing([.upsertSource(.source(name: "s", path: "s", "1.2.0"..<"1.8.0"))]
    )
    #expect(change.bytes == doc.bytes)
    #expect(change.patches.isEmpty)
  }
  @Test func checkedSuccessorsCanonicalizeRangesAndKeepExactMetadata() throws {
    let doc = try document(
      """
      let agents = Agents(sources: [
        .source(name: "major", path: "major", " v1.2.0+lower "..<"2.0.0+upper"),
        .source(name: "minor", path: "minor", "1.2.0"..<"1.3.0+meta"),
        .source(name: "exact", path: "exact", exact: "V1.2.0+meta")
      ])
      """)
    #expect(
      doc.declaration.sources[0]["requirement"] == .requirement(.upToNextMajor(from: "1.2.0+lower"))
    )
    #expect(
      doc.declaration.sources[1]["requirement"] == .requirement(.upToNextMinor(from: "1.2.0")))
    #expect(doc.declaration.sources[2]["requirement"] == .requirement(.exact("1.2.0+meta")))
    _ = try document(
      "let agents = Agents(sources: [.source(name: \"s\", path: \"s\", \"\(Int.max).0.0\"..<\"\(Int.max).1.0\")])"
    )
    for requirement in [
      "from: \"\(Int.max).0.0\"", ".upToNextMinor(from: \"1.\(Int.max).0\")",
      "\"2.0.0\"..<\"1.0.0\"", "exact: \"1.0\"",
    ] {
      expectManifestFailure("manifest.domain") {
        try document(
          "let agents = Agents(sources: [.source(name: \"s\", path: \"s\", \(requirement))])")
      }
    }
  }

  @Test func rangeValuesAndLiteralGroupReferencesAreEqual() throws {
    let fixtures = compiledFixtures().first { $0.name == "RequirementValues.swift.txt" }!
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + fixtures.name)
    let doc = try DeclarationDocument(
      bytes: Array(Data(contentsOf: url)), identity: DocumentIdentity("manifest"))
    let constants = doc.evaluation.constants
    for pair in [
      ("majorFrom", "majorHelper"), ("majorFrom", "majorRange"), ("minorHelper", "minorRange"),
      ("prereleaseFrom", "prereleaseHelper"), ("prereleaseFrom", "prereleaseRange"),
      ("prereleaseMinor", "prereleaseMinorRange"), ("localLiteral", "localFactory"),
    ] {
      #expect(constants[pair.0]!.value == constants[pair.1]!.value, "\(pair)")
      #expect(
        Lowering.lower(constants[pair.0]!.value) == Lowering.lower(constants[pair.1]!.value),
        "\(pair)")
    }
  }

}
