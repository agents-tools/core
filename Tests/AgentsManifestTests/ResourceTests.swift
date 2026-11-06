import AgentsCore
import AgentsDescription
import Foundation
import ManifestTestSupport
import Testing

@testable import AgentsManifest

@Suite("Manifest resources")
struct ResourceTests {
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
    #expect(report.report.stage == .evaluation)
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
    #expect(domainReport.report.stage == .domain)
    #expect(domainReport.report.status == "manifest.limit")
    var deep = "let v0: ConfigurationValue = 0\n"
    for index in 1...65 { deep += "let v\(index): ConfigurationValue = .array([v\(index - 1)])\n" }
    expectManifestFailure("manifest.limit") { try document(deep + "let agents = Agents()") }
    expectManifestFailure("manifest.limit") {
      try document(
        "let values: [Int] = [" + Array(repeating: "0", count: 10_001).joined(separator: ",")
          + "]\nlet agents = Agents()")
    }
  }

  @Test func nestedCollectionsReuseTypedReferencedDescendants() throws {
    let base = Array(repeating: "[0]", count: 5_000).joined(separator: ",")
    var body = "let base: [[Int]] = [" + base + "]\n"
    for index in 0..<4 {
      body += "let nested\(index) = [[[[[[base]]]]]]\n"
    }
    let doc = try document(body + "let agents = Agents()")
    let original = try #require(doc.evaluation.constants["base"])
    guard case .array(let originalElements) = original.value else {
      Issue.record("base is not an array")
      return
    }
    #expect(doc.evaluation.steps < ManifestLimits.Evaluation.steps)
    for index in 0..<4 {
      var descendant = try #require(doc.evaluation.constants["nested\(index)"]).value
      for _ in 0..<6 {
        guard case .array(let layer) = descendant, layer.count == 1 else {
          Issue.record("missing collection layer")
          return
        }
        descendant = layer[0]
      }
      guard case .array(let elements) = descendant else {
        Issue.record("missing referenced array")
        return
      }
      // Reusing the array storage keeps all 5,000 typed descendants out of conversion work.
      originalElements.withUnsafeBufferPointer { original in
        elements.withUnsafeBufferPointer { reused in
          #expect(reused.baseAddress == original.baseAddress)
        }
      }
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
    expectManifestFailure("manifest.limit") {
      try doc.preparing(Array(repeating: .setWatch([]), count: 101))
    }
    let tiny = try document("let agents = Agents()")
    expectManifestFailure("manifest.limit") {
      try tiny.preparing([.setWatch(Array(repeating: "x", count: 10_001))])
    }
  }

  @Test func memoryReportsDeriveGrowthFromStoredHighWaterMarks() throws {
    let report = ProbeReport(
      status: "manifest.limit", operation: .editing, metrics: FrontEndMetrics(),
      peakMemoryBytes: 2_048, preparationBaselinePeakBytes: 1_024)
    let data = try JSONEncoder().encode(report)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["preparationPeakGrowthBytes"] == nil)
    let decoded = try JSONDecoder().decode(ProbeReport.self, from: data)
    #expect(decoded.preparationBaselinePeakBytes == 1_024)
    #expect(decoded.preparationPeakGrowthBytes == 1_024)
  }

  @Test func oversizedExplicitInsertionIsRejectedBeforeRendering() throws {
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try probe(
      "oversized-direct-insert",
      Array((manifestHeader + "let agents = Agents(components: [])").utf8),
      extraArguments: ["--edit-oversized"], in: directory)
    #expect(result.report.status == "manifest.limit")
    #expect(result.report.operation == .editing)
    #expect(result.report.preparationBaselinePeakBytes != nil)
    // Compare RSS high-water marks after constructing the component, including earlier peaks.
    // Allow 8 MiB of growth for allocator/runtime variation, below one 20 MB render buffer.
    #expect(try #require(result.report.preparationPeakGrowthBytes) < 8 * 1_024 * 1_024)
    try recordProbeResults([result], name: "oversized-insert-run")
  }

}
