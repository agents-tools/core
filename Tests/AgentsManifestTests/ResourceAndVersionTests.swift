import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Manifest resources and language versions")
struct ResourceAndVersionTests {
  @Test func directiveDiagnosticsAreLexicalAndDistinct() throws {
    for (text, code) in [
      ("import AgentsDescription\nlet agents = Agents()", "manifest.version.missing"),
      (
        "// agents-tools-version: 01.0\nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.invalid"
      ),
      (
        "// agents-tools-version: 1.0 \nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.invalid"
      ),
      (
        "// agents-tools-version: 2.0\nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.unsupported"
      ),
      (
        manifestHeader + "// agents-tools-version: 1.0\nlet agents = Agents()",
        "manifest.version.duplicate"
      ),
    ] {
      do {
        _ = try DeclarationDocument(bytes: Array(text.utf8), identity: DocumentIdentity("manifest"))
        Issue.record("directive accepted")
      } catch let failure as ManifestFailure {
        #expect(failure.diagnostics[0].code == code)
        #expect(failure.metrics.parserCalls == 0)
      }
    }
    _ = try document("let text = \"// agents-tools-version: 1.0\"\nlet agents = Agents()")
  }

  @Test func everyConstantChargesItsFullExpandedCostBeforeUseOrMapping() throws {
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var body = "let v0: ConfigurationValue = 1\n"
    for index in 1...24 {
      body += "let v\(index): ConfigurationValue = .array([v\(index - 1), v\(index - 1)])\n"
    }
    let report = try probe(
      "unused-exponential-reuse", Array((manifestHeader + body + "let agents = Agents()").utf8),
      semantics: true, in: directory)
    #expect(report.report.stage == "evaluation")
    #expect(report.report.status == "manifest.limit")
    var aliases = "let seed: ConfigurationValue = 0\n"
    var tail = "seed"
    for level in 0..<50 {
      let container = "c\(level)"
      aliases += "let \(container): ConfigurationValue = .array([\(tail)])\n"
      tail = container
      for index in 0..<40 {
        let name = "a\(level)_\(index)"
        aliases += "let \(name) = \(tail)\n"
        tail = name
      }
    }
    let aliasReport = try probe(
      "aliases-across-container-depth",
      Array((manifestHeader + aliases + "let agents = Agents()").utf8),
      semantics: true, in: directory)
    #expect(aliasReport.report.status == "manifest.limit")
    var flatAliases = ""
    for chain in 0..<100 {
      var previous = "c\(chain)"
      flatAliases += "let \(previous) = 0\n"
      for index in 0..<60 {
        let name = "a\(chain)_\(index)"
        flatAliases += "let \(name) = \(previous)\n"
        previous = name
      }
    }
    let domainReport = try probe(
      "domain-reference-work",
      Array((manifestHeader + flatAliases + "let agents = Agents()").utf8),
      semantics: true, in: directory)
    #expect(domainReport.report.stage == "domain")
    #expect(domainReport.report.status == "manifest.limit")
    var deep = "let v0: ConfigurationValue = 0\n"
    for index in 1...65 { deep += "let v\(index): ConfigurationValue = .array([v\(index - 1)])\n" }
    #expect(throws: ManifestFailure.self) { try document(deep + "let agents = Agents()") }
    #expect(throws: ManifestFailure.self) {
      try document(
        "let values: [Int] = [" + Array(repeating: "0", count: 10_001).joined(separator: ",")
          + "]\nlet agents = Agents()")
    }
  }

  @Test func mapOriginsAndComparisonHaveIndependentBudgets() throws {
    let base =
      "let sections: [SectionReference] = ["
      + Array(repeating: "\"guide\"", count: 100).joined(separator: ",") + "]\n"
    let components = Array(repeating: ".instructions(sections: sections)", count: 40).joined(
      separator: ",")
    let doc = try document(base + "let agents = Agents(components: [" + components + "])")
    #expect(doc.sourceMap.entries.count > 10_000)
    #expect(doc.sourceMap.entries.count <= 100_000)
    #expect(doc.sourceMap.entries.reduce(0) { $0 + $1.origins.count } <= 1_000_000)
    let unchanged = try doc.preparing([.setWatch([])])
    #expect(unchanged.patches.isEmpty)
    #expect(throws: ManifestFailure.self) {
      try doc.preparing(Array(repeating: .setWatch([]), count: 101))
    }
    let tiny = try document("let agents = Agents()")
    #expect(throws: ManifestFailure.self) {
      try tiny.preparing([.setWatch(Array(repeating: "x", count: 10_001))])
    }
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
      #expect(throws: ManifestFailure.self) {
        try document(
          "let agents = Agents(sources: [.source(name: \"s\", path: \"s\", \(requirement))])")
      }
    }
  }

  @Test func valueLiteralExamplesMatchTheRealCompiler() throws {
    let values: [(String, ConfigurationValue)] = [
      ("nil", nil), ("true", true), ("-9_223_372_036_854_775_808", .integer(Int.min)),
      ("[1, true, nil, \"x\"]", [1, true, nil, "x"]),
      ("[\"x\": [\"y\": .decimal(\"1.25\")]]", ["x": ["y": .decimal("1.25")]]),
      ("\"\\0\\t\\n\\r\\\"\\'\\\\\\u{1F600}\"", "\0\t\n\r\"'\\😀"),
      ("\"\"\"\n  first\n\n  last\n  \"\"\"", "first\n\nlast"),
    ]
    for (expression, compiled) in values {
      let doc = try document(
        "let value: ConfigurationValue = " + expression + "\nlet agents = Agents()")
      #expect(doc.evaluation.constants["value"]!.value == compiled.constructionValue)
    }
  }
}
