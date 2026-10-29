import AgentsCore
import Foundation
import ManifestTestSupport
import SwiftSyntax
import Testing

@testable import AgentsManifest

struct AdmissionCase {
  let name: String
  let bytes: [UInt8]
  let expected: String?
  init(_ name: String, _ expression: String, expected: String? = nil, complete: Bool = false) {
    self.name = name
    bytes = Array((complete ? expression : manifestHeader + "let value = " + expression).utf8)
    self.expected = expected
  }
  init(_ name: String, bytes: [UInt8], expected: String?) {
    self.name = name
    self.bytes = bytes
    self.expected = expected
  }
}

func fixedAdmissionCases() -> [AdmissionCase] {
  var cases: [AdmissionCase] = []
  for depth in [7, 8, 9, 20, 200, 20_000] {
    for (name, left, right) in [
      ("squares", "[", "]"), ("mixed", "f([", "])"), ("dictionaries", "[\"k\":", "]"),
      ("calls", ".f(", ")"), ("parentheses", "(", ")"),
    ] {
      cases.append(
        AdmissionCase(
          "\(name)-\(depth)",
          String(repeating: left, count: depth) + "0" + String(repeating: right, count: depth),
          expected: name == "squares" && depth <= 8 || name == "dictionaries" && depth <= 8
            || name == "mixed" && depth <= 8
            || name == "parentheses" && depth <= 20 || name == "calls" && depth <= 20
            ? "accepted" : nil))
      cases.append(
        AdmissionCase(
          "\(name)-unbalanced-\(depth)", String(repeating: left, count: depth) + "0", expected: nil)
      )
    }
  }
  for (name, expression) in [
    (
      "brace-nests",
      String(repeating: "{", count: 20_000) + "0" + String(repeating: "}", count: 20_000)
    ),
    ("generic-small", "let value: A<B> = 0"),
    (
      "generic-large",
      "let value: " + String(repeating: "A<", count: 20_000) + "B"
        + String(repeating: ">", count: 20_000) + " = 0"
    ),
    ("ambiguous-angle", String(repeating: "a<", count: 200_000) + "b"),
    ("members", "a" + String(repeating: ".b", count: 200_000)),
    ("numeric-prefix", String(repeating: "-", count: 200_000) + "1"),
    ("force-unwrap", "a" + String(repeating: "!", count: 200_000)),
    ("postfix-calls", "a" + String(repeating: "()", count: 200_000)),
    ("subscripts", "a" + String(repeating: "[0]", count: 200_000)),
    ("plus-chain", "1" + String(repeating: " + 1", count: 200_000)),
  ] { cases.append(AdmissionCase(name, expression, expected: nil)) }
  for word in ["copy", "await", "consume", "each", "unsafe"] {
    for count in [2, 200_000] {
      cases.append(
        AdmissionCase(
          "prefix-\(word)-\(count)", String(repeating: word + " ", count: count) + "x",
          expected: count == 2 ? "manifest.syntax" : nil))
    }
    cases.append(AdmissionCase("label-\(word)", "f(\(word): 0)", expected: "accepted"))
    cases.append(AdmissionCase("member-\(word)", ".\(word)", expected: "accepted"))
    cases.append(
      AdmissionCase(
        "binding-\(word)", manifestHeader + "let \(word) = 0", expected: "manifest.syntax",
        complete: true))
  }
  for body in [
    "#\"\"\"#\nlet danger: A<A<B>> = 0\n// \"\"\"#", "#\"raw\"#", "##\"\"\"\ntext\n\"\"\"##",
  ] { cases.append(AdmissionCase("raw-\(cases.count)", body, expected: "manifest.syntax")) }
  for bad in [
    "x y", "f(x y)", "`x`", "é", "$x", "1.0", "0x1", "1e2", "- 1", "--1", "+1", "a+b", "a +b",
    "a+ b", "f(0,)", "(0,)", "[key: 0]", "a[0]", "(a).b", "a.b.c", "a()()", "a.b().c()",
    "a /* x */ .b", "\"\\q\"", "\"\\u{D800}\"", "\"\\u{110000}\"", "\"\\u{}\"", "\"\\(x)\"",
    "/*unterminated", "\"unterminated",
  ] { cases.append(AdmissionCase("forbidden-\(cases.count)", bad, expected: "manifest.syntax")) }
  for value in [
    "\"\\0\\t\\n\\r\\\"\\'\\\\\"", "\"\\u{0}\\u{1F600}\"", "\"é😀\"", "-1_000", "1_",
    "\"\\\\(literal)\"", "/* nested /* comment */ */ 0",
    String(repeating: "/*", count: 20) + "x" + String(repeating: "*/", count: 20) + " 0",
  ] { cases.append(AdmissionCase("literal-\(cases.count)", value, expected: "accepted")) }
  cases.append(
    AdmissionCase(
      "comments-21",
      String(repeating: "/*", count: 21) + "x" + String(repeating: "*/", count: 21) + "0",
      expected: "manifest.limit"))
  for newline in ["\n", "\r\n", "\r"] {
    for (content, closing, good) in [
      ("", "  ", true), (" ", "  ", false), ("  ", "  ", true), ("   ", "  ", true),
      ("\t", "  ", false), ("  \ttext", "  ", false), ("  text\ttail", "  ", true),
      ("  text", "  ", true), ("", "\t", false),
    ] {
      cases.append(
        AdmissionCase(
          "indent-\(cases.count)", "\"\"\"" + newline + content + newline + closing + "\"\"\"",
          expected: good ? "accepted" : "manifest.syntax"))
    }
  }
  let gaps = ["", " ", "\t", "\n", "\r\n"]
  for left in gaps {
    for right in gaps {
      cases.append(
        AdmissionCase(
          "assignment-\(cases.count)", manifestHeader + "let value" + left + "=" + right + "-1",
          expected: !left.isEmpty && !right.isEmpty ? "accepted" : "manifest.syntax", complete: true
        ))
      cases.append(
        AdmissionCase(
          "plus-spacing-\(cases.count)", "[]" + left + "+" + right + "[]",
          expected: !left.isEmpty && !right.isEmpty ? "accepted" : "manifest.syntax"))
      cases.append(
        AdmissionCase(
          "range-spacing-\(cases.count)",
          ".source(name: \"s\", path: \"s\", \"1.2.0\"" + left + "..<" + right + "\"2.0.0\")",
          expected: left.isEmpty == right.isEmpty ? "accepted" : "manifest.syntax"))
    }
  }
  for op in ["=", "+", "..<"] {
    for (left, right, good) in [
      (" /*a*/ ", " /*b*/ ", true), ("/*a*/ ", " ", false), (" /*a*/", " ", false),
      (" ", "/*a*/ ", false), (" /*a*//*b*/ ", " ", false), (" /*a*/ /*b*/ ", " ", true),
      (" //a\n", " ", true),
    ] {
      let expression =
        op == "="
        ? manifestHeader + "let value" + left + op + right + "0"
        : op == "+"
          ? "[]" + left + op + right + "[]"
          : ".source(name: \"s\", path: \"s\", \"1.2.0\"" + left + op + right + "\"2.0.0\")"
      cases.append(
        AdmissionCase(
          "operator-comments-\(op)-\(cases.count)", expression,
          expected: good ? "accepted" : "manifest.syntax", complete: op == "="))
    }
  }
  for body in ["-1", "(-1)", "[-1]", "[0,-1]", "[\"k\":-1]", "f(-1)", "f(label:-1)", "/*c*/ -1"] {
    cases.append(AdmissionCase("negative-good-\(cases.count)", body, expected: "accepted"))
  }
  for body in ["a-1", "1-1", ")-1", "]-1", ".-1", "--1", "+-1", "/*c*/-1", "-\n1"] {
    cases.append(AdmissionCase("negative-bad-\(cases.count)", body, expected: "manifest.syntax"))
  }
  for range in [
    "\"1.2.0\"...\"2.0.0\"", "\"1.2.0\"..<\"2.0.0\"..<\"3.0.0\"", "lower..<\"2.0.0\"",
    "\"1.2.0\"..<upper", "(\"1.2.0\")..<\"2.0.0\"", "1..<2", ".upToNextMinor",
    ".upToNextMinor(\"1.2.0\")",
  ] {
    cases.append(
      AdmissionCase(
        "range-rejected-\(cases.count)", ".source(name: \"s\", path: \"s\", " + range + ")",
        expected: "manifest.syntax"))
  }
  for misplaced in [
    "\"1.2.0\"..<\"2.0.0\"", "[\"1.2.0\"..<\"2.0.0\"]", ".upToNextMajor(from: \"1.2.0\")",
  ] {
    cases.append(
      AdmissionCase("misplaced-range-\(cases.count)", misplaced, expected: "manifest.syntax"))
  }
  cases.append(
    AdmissionCase(
      "terms-32", Array(repeating: "[]", count: 32).joined(separator: " + "), expected: "accepted"))
  cases.append(
    AdmissionCase(
      "terms-33", Array(repeating: "[]", count: 33).joined(separator: " + "),
      expected: "manifest.limit"))
  cases.append(
    AdmissionCase(
      "reservation-boundary",
      "[" + Array(repeating: "0", count: 12_495).joined(separator: ",") + "]", expected: "accepted")
  )
  cases.append(
    AdmissionCase(
      "reservation-excess", "[" + Array(repeating: "0", count: 12_496).joined(separator: ",") + "]",
      expected: "manifest.limit"))
  cases.append(
    AdmissionCase(
      "literal-reservation", "\"\"\"\n" + String(repeating: "text\n", count: 25_000) + "\"\"\"",
      expected: "manifest.limit"))
  cases.append(
    AdmissionCase(
      "escape-reservation", "\"" + String(repeating: "\\n", count: 25_000) + "\"",
      expected: "manifest.limit"))
  cases.append(
    AdmissionCase(
      "token-reservation", manifestHeader + String(repeating: "let x = 0\n", count: 25_000),
      expected: "manifest.limit", complete: true))
  cases.append(AdmissionCase("invalid-utf8", bytes: [255], expected: "manifest.syntax"))
  cases.append(
    AdmissionCase(
      "byte-excess-before-decoding", bytes: Array(repeating: 255, count: 2_097_153),
      expected: "manifest.limit"))
  let prefix = Array((manifestHeader + "let value = \"").utf8)
  cases.append(
    AdmissionCase(
      "byte-boundary-string",
      bytes: prefix + Array(repeating: 120, count: 2_097_152 - prefix.count - 1) + [34],
      expected: "accepted"))
  let identifier = Array((manifestHeader + "let ").utf8)
  cases.append(
    AdmissionCase(
      "byte-boundary-identifier",
      bytes: identifier + Array(repeating: 120, count: 2_097_152 - identifier.count - 4)
        + Array(" = 0".utf8), expected: "accepted"))
  let comment = Array((manifestHeader + "let value = 0\n//").utf8)
  cases.append(
    AdmissionCase(
      "byte-boundary-comment",
      bytes: comment + Array(repeating: 91, count: 2_097_152 - comment.count), expected: "accepted")
  )
  for (name, suffix) in [
    ("eof", ""), ("import", "import AgentsDescription\nlet agents = Agents()"),
  ] {
    cases.append(
      AdmissionCase(
        "directive-bare-cr-" + name,
        "// agents-tools-version: 1.0\r" + suffix,
        expected: "manifest.version.invalid", complete: true))
  }
  return cases
}

@Suite("Manifest adversarial admission", .serialized)
struct AdversarialTests {
  @Test func fixedRegressionsUnderWholeChildWatchdog() throws {
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var results: [ProbeResult] = []
    for fixture in fixedAdmissionCases() {
      let result: ProbeResult
      do {
        result = try probe(fixture.name, fixture.bytes, in: directory)
      } catch is ExpectationFailedError {
        continue
      } catch {
        Issue.record(error, "fixed regression: \(fixture.name)")
        continue
      }
      if let expected = fixture.expected {
        #expect(result.report.status == expected, "\(fixture.name): \(result.report.message)")
      } else {
        #expect(
          ["manifest.syntax", "manifest.limit"].contains(result.report.status), "\(fixture.name)")
        #expect(result.report.metrics.parserCalls == 0, "\(fixture.name)")
      }
      if fixture.name.hasPrefix("raw-") {
        #expect(result.report.offset == fixture.bytes.firstIndex(of: 35))
        #expect(result.report.metrics.parserCalls == 0)
      }
      if result.report.stage == .admission {
        var line = 1
        var column = 1
        var index = 0
        while index < result.report.offset {
          let byte = fixture.bytes[index]
          if byte == 13 {
            line += 1
            column = 1
            if index + 1 < result.report.offset && fixture.bytes[index + 1] == 10 { index += 1 }
          } else if byte == 10 {
            line += 1
            column = 1
          } else {
            column += 1
          }
          index += 1
        }
        #expect(result.report.line == line)
        #expect(result.report.column == column)
      }
      results.append(result)
    }
    print(
      "MANIFEST_FIXED configuration=\(probeConfiguration) watchdogSeconds=\(probeWatchdogSeconds) cases=\(fixedAdmissionCases().count) completed=\(results.count) slowest=\(results.max(by: { $0.wallSeconds < $1.wallSeconds })!.name) seconds=\(results.map(\.wallSeconds).max()!) peakMemory=\(results.map { $0.report.peakMemoryBytes }.max()!)"
    )
    try recordProbeResults(results, name: "fixed-run")
  }

  @Test func iterativeSyntheticTreesExerciseIndependentBoundaries() throws {
    let source = SourceText([], identity: DocumentIdentity("synthetic"))
    var deep = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("root")))
    for depth in 1...127 {
      deep = ExprSyntax(
        MemberAccessExprSyntax(
          base: deep, declName: DeclReferenceExprSyntax(baseName: .identifier("m"))))
      if depth == 126 {
        #expect(try SyntaxValidation.guardTree(Syntax(deep), source: source).depth == 128)
      }
    }
    #expect(throws: ManifestFailure.self) {
      try SyntaxValidation.guardTree(Syntax(deep), source: source)
    }
    let atLimit = ArrayExprSyntax(
      elements: ArrayElementListSyntax(
        (0..<24_999).map { _ in
          ArrayElementSyntax(
            expression: IntegerLiteralExprSyntax(literal: .integerLiteral("0")),
            trailingComma: .commaToken())
        }))
    #expect(try SyntaxValidation.guardTree(Syntax(atLimit), source: source).nodes == 100_000)
    let wide = ArrayExprSyntax(
      elements: ArrayElementListSyntax(
        (0..<25_001).map { _ in
          ArrayElementSyntax(
            expression: IntegerLiteralExprSyntax(literal: .integerLiteral("0")),
            trailingComma: .commaToken())
        }))
    #expect(throws: ManifestFailure.self) {
      try SyntaxValidation.guardTree(Syntax(wide), source: source)
    }
  }
}
