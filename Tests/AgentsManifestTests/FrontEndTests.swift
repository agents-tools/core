import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

let manifestHeader = ""
func document(_ body: String) throws -> DeclarationDocument {
  try DeclarationDocument(bytes: Array(body.utf8), identity: DocumentIdentity("manifest"))
}

@Suite("YAML frontend")
struct FrontEndTests {
  @Test(arguments: ["yes", "on", "2026-11-15"])
  func coreStringsRemainStrings(_ text: String) throws {
    let doc = try document(
      "version: 1\ncomponents: [{kind: subagent, name: a, description: d, prompt: \(text)}]\n")
    #expect(doc.declaration.components[0]["prompt"]?.record?["value"] == .string(text))
  }
  @Test(arguments: ["&a []", "*a", "!!str x", "!!float 1", "{x: 1}"])
  func unsupportedOrdinaryValuesAreRejected(_ text: String) {
    #expect(throws: ManifestFailure.self) { try document("version: 1\nwatch: \(text)\n") }
  }
  @Test(arguments: ["\u{85}", "\u{2028}", "\u{2029}"])
  func rawSeparatorsAreRejectedBeforeParsing(_ separator: String) {
    expectManifestFailure("manifest.character") { try document("# \(separator)\nversion: 1\n") }
    let prefix = "\u{FEFF}# 🙂 "
    do {
      _ = try document(prefix + separator + "\r\nversion: 1\r\n")
      Issue.record("expected a raw separator failure")
    } catch let failure as ManifestFailure {
      #expect(failure.diagnostics[0].code == "manifest.character")
      #expect(failure.diagnostics[0].span.start == prefix.utf8.count)
      #expect(failure.diagnostics[0].span.column == prefix.utf8.count + 1)
    } catch {
      Issue.record(error)
    }
  }
  @Test func escapedSeparatorsAndDecimalPayloadsRoundTrip() throws {
    let body = #"""
      version: 1
      components:
        - kind: lspServer
          name: test
          run: {executable: unused}
          languages: {'.swift': swift}
          initializationOptions:
            text: "\u0085\u2028\u2029"
            decimal: !!float "1E+003"
            integerLike: !!float "1"
            negativeZero: !!float "-0"
            '<<': {ordinary: true}
      """#
    let doc = try document(body)
    let typed = try ManifestProjection.declaration(of: doc, environment: projectionEnvironment)
    let bytes = try #require(try planned(Declaration(), typed, in: nil))
    #expect(try projected(String(decoding: bytes, as: UTF8.self)).components == typed.components)
    let dumped = try ManifestDump(document: doc)
    #expect(dumped.schemaVersion == 2 && dumped.format == "yaml" && dumped.manifestVersion == 1)
    #expect(String(decoding: try dumped.encodedJSON(), as: UTF8.self).contains("1E+003"))
  }
  @Test func sourceMapUsesOrderedSemanticPointers() throws {
    let body =
      "version: 1\nsources: {b: {path: b}, a: {path: a}}\ngroups: {unused: {components: [{kind: ignore, name: i, patterns: []}]}}\n"
    let doc = try document(body)
    let name = try #require(doc.sourceMap.locations(at: "/sources/0/name").first)
    #expect(String(decoding: doc.bytes[name.span.start..<name.span.end], as: UTF8.self) == "b")
    #expect(doc.node(at: "/groups/0/components/0/patterns") != nil)
  }
  @Test func duplicateKeysUnknownFieldsAndMultipleDocumentsFail() {
    for body in [
      "version: 1\nversion: 1\n", "version: 1\nunknown: []\n", "version: 1\n---\nversion: 1\n",
      "version: 1.0\n",
    ] {
      #expect(throws: ManifestFailure.self) { try document(body) }
    }
  }

  @Test func decodedDuplicateKeysRetainOriginalByteCoordinates() throws {
    let mappingPrefix = "sources: {'🙂e\u{301}': {path: .}, "
    let firstLinePrefix = "\u{FEFF}{version: 1, " + mappingPrefix
    for (prefix, line, column, suffix) in [
      ("version: 1\n# comment\n" + mappingPrefix, 3, mappingPrefix.utf8.count + 1, "}\n"),
      (
        "\u{FEFF}version: 1\r\n# comment\r\n" + mappingPrefix, 3, mappingPrefix.utf8.count + 1,
        "}\r\n"
      ),
      (firstLinePrefix, 1, firstLinePrefix.utf8.count + 1, "}}\r\n"),
    ] {
      let body = prefix + #"same: {path: .}, "\u0073ame": {path: .}"# + suffix
      do {
        _ = try document(body)
        Issue.record("expected a decoded duplicate key failure")
      } catch let failure as ManifestFailure {
        let diagnostic = try #require(failure.diagnostics.first)
        #expect(failure.stage == .decoding)
        #expect(diagnostic.code == "manifest.key.duplicate")
        #expect(diagnostic.message.contains("same"))
        #expect(diagnostic.span.start == prefix.utf8.count)
        #expect(diagnostic.span.line == line)
        #expect(diagnostic.span.column == column)
        #expect(diagnostic.related.isEmpty)
      }
    }
  }

  @Test func schemaBoundsAreIndependentOfParserSafetyLimits() throws {
    for (rule, accepted, rejected) in [
      (YAMLRule.array(.string, maximum: 1), "[a]", "[a, b]"),
      (.dictionary(.string, maximum: 1), "{a: x}", "{a: x, b: y}"),
      (.object(["a": .string], required: [], maximum: 0), "{}", "{a: x}"),
      (.integerConstant(2), "2", "1"),
    ] {
      try validate(accepted, against: rule)
      expectManifestFailure("manifest.schema") { try validate(rejected, against: rule) }
    }
    for text in ["2.0", "'2'", "9223372036854775808"] {
      expectManifestFailure("manifest.schema") { try validate(text, against: .integerConstant(2)) }
    }
  }

  @Test func oneOfRejectsOverlappingDiscriminatorsAndUnconstrainedBranches() throws {
    let record = YAMLRule.object(["kind": .constant("a")], required: ["kind"], maximum: nil)
    let optional = YAMLRule.object(["kind": .constant("a")], required: [], maximum: nil)
    for choices in [[record, record], [record, optional]] {
      expectManifestFailure("manifest.schema") {
        try validate("{kind: a}", against: .oneOf(choices))
      }
    }
    try validate("{kind: a}", against: .oneOf([record, .string]))
  }

  private func validate(_ text: String, against rule: YAMLRule) throws {
    let source = SourceText(Array(text.utf8), identity: DocumentIdentity("schema-test"))
    let node = try YAMLParser.parse(source).root
    try YAMLValidation(source: source).check(node, rule)
  }
}
