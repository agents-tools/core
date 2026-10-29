import Foundation
import Testing

@testable import AgentsManifest

struct ManifestRandom {
  static let seed: UInt64 = 0xa631_2026_1029
  var state = seed
  mutating func next(_ upper: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 24) % UInt64(upper))
  }
  mutating func choose(_ values: [String]) -> String { values[next(values.count)] }
  mutating func expression(depth: Int = 0) -> String {
    let leaves = [
      "0", "-1", "1_000", "true", "false", "nil", "value", "\"text\"", "\"é😀\"", "\"\\u{1F600}\"",
      "\"\"\"\n  line\n  \\\"quote\n  \"\"\"", ".copy", "Type.member", "[]", "[:]",
    ]
    if depth == 3 || next(4) == 0 { return choose(leaves) }
    switch next(7) {
    case 0:
      return "[" + (0..<next(4)).map { _ in expression(depth: depth + 1) }.joined(separator: ", ")
        + "]"
    case 1: return "[\"key\": " + expression(depth: depth + 1) + "]"
    case 2:
      return choose(["Factory", ".factory", "Type.factory"]) + "("
        + choose(["name", "copy", "await", "consume", "each", "unsafe"]) + ": "
        + expression(depth: depth + 1) + ")"
    case 3: return "(" + expression(depth: depth + 1) + ")"
    case 4: return expression(depth: depth + 1) + " + " + expression(depth: depth + 1)
    case 5: return "/* outer /* inner */ */ " + expression(depth: depth + 1)
    default: return "[" + expression(depth: depth + 1) + ",]"
    }
  }
}

func fuzzAdmissionCases() -> [AdmissionCase] {
  var rng = ManifestRandom()
  var cases: [AdmissionCase] = []
  var generated: [String] = []
  for index in 0..<256 {
    var expression = rng.expression()
    if index == 255 {
      expression = "[" + Array(repeating: "0", count: 12_450).joined(separator: ",") + "]"
    }
    generated.append(expression)
    let type = rng.choose([
      "", ": String", ": [Int]", ": [String: ConfigurationValue]", ": Component",
      ": [[String: [Bool]]]",
    ])
    let text =
      manifestHeader + "let base: [String] = []\nlet value" + type + " = " + expression + "\n"
    cases.append(AdmissionCase("grammar-\(index)", text, expected: "accepted", complete: true))
  }
  let tokens = [
    "let", "import", "copy", "await", "consume", "each", "unsafe", "x", "0", "\"s\"", "(", ")", "[",
    "]", ",", ":", ".", "=", "+", "-1",
  ]
  for index in 0..<128 {
    let sequence = (0..<(1 + rng.next(48))).map { _ in rng.choose(tokens) }.joined(separator: " ")
    cases.append(AdmissionCase("tokens-\(index)", sequence))
  }
  for index in 0..<128 {
    cases.append(
      AdmissionCase(
        "injected-\(index)",
        rng.expression() + " "
          + rng.choose(["<", ">", "{", "}", "#", "?", "!", "&", "*", "/", "`x`", "$x"]),
        expected: "manifest.syntax"))
  }
  for (index, source) in generated.enumerated() {
    let bytes = Array(source.utf8)
    let point = rng.next(bytes.count + 1)
    let skip = min(rng.next(2), bytes.count - point)
    let mutation = Array(
      rng.choose(["", "copy ", "#\"\"\"#", "/*", "\"", "[", ")", " + ", " "]).utf8)
    cases.append(
      AdmissionCase(
        "mutation-\(index)",
        bytes: Array((manifestHeader + "let value = ").utf8) + bytes[..<point] + mutation
          + bytes[(point + skip)...], expected: nil))
  }
  for index in 0..<128 {
    let lower = "\"\(rng.next(10)).\(rng.next(10)).0\""
    let upper = "\"\(10 + rng.next(10)).0.0\""
    let left = rng.choose(["", " ", "\n", " /* c */ ", "/*c*/"])
    let right = rng.choose(["", " ", "\n", " /* c */ ", "/*c*/"])
    let op = rng.choose(["..<", "..<", "...", "<", "..<<"])
    let expression =
      ".source(name: \"r\", url: \"https://example.org/r.git\", "
      + (index % 4 == 0 ? "bound" : lower) + left + op + right + upper + ")"
    cases.append(AdmissionCase("range-fuzz-\(index)", expression))
  }
  return cases
}

@Suite("Manifest differential fuzzing", .serialized)
struct DifferentialFuzzTests {
  @Test func independentlyBuiltGrammarAndParserProjectionsAgree() throws {
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var results: [ProbeResult] = []
    print(
      "MANIFEST_FUZZ_START configuration=\(probeConfiguration) watchdogSeconds=\(probeWatchdogSeconds) seed=\(ManifestRandom.seed) cases=896"
    )
    for fixture in fuzzAdmissionCases() {
      let result = try probe(fixture.name, fixture.bytes, in: directory)
      if result.report.stage == "parser" {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent().deletingLastPathComponent()
        let retained = root.appendingPathComponent(".build/manifest-counterexamples")
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try Data(fixture.bytes).write(to: retained.appendingPathComponent(fixture.name + ".swift"))
        var minimized = fixture.bytes
        var chunk = max(1, minimized.count / 2)
        var attempts = 0
        while chunk > 0 && attempts < 64 {
          var offset = manifestHeader.utf8.count
          var found = false
          while offset + chunk <= minimized.count && attempts < 64 {
            var candidate = minimized
            candidate.removeSubrange(offset..<(offset + chunk))
            attempts += 1
            let check = try probe("minimize", candidate, in: directory)
            if check.report.stage == "parser" {
              minimized = candidate
              found = true
              break
            }
            offset += chunk
          }
          if !found { chunk /= 2 }
        }
        try Data(minimized).write(
          to: retained.appendingPathComponent(fixture.name + ".minimal.swift"))
        Issue.record(
          "differential counterexample retained: \(fixture.name), seed=\(ManifestRandom.seed)")
      }
      if let expected = fixture.expected {
        #expect(result.report.status == expected, "\(fixture.name): \(result.report.message)")
      }
      results.append(result)
    }
    let slowest = results.max { $0.wallSeconds < $1.wallSeconds }!
    let accepted = results.filter { $0.report.status == "accepted" }.count
    print(
      "MANIFEST_FUZZ configuration=\(probeConfiguration) watchdogSeconds=\(probeWatchdogSeconds) seed=\(ManifestRandom.seed) grammar=256 tokens=128 injected=128 mutations=256 ranges=128 cases=\(results.count) accepted=\(accepted) slowest=\(slowest.name) seconds=\(slowest.wallSeconds) peakMemory=\(results.map { $0.report.peakMemoryBytes }.max()!)"
    )
    try recordProbeResults(results, name: "differential-run")
  }
}
