import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

@Suite("YAML parser resources")
struct ResourceTests {
  @Test func parserStageWorkCancelsBeforeTheCSTGate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "yaml-budget-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
    let bytes = Array(
      ("[" + Array(repeating: "x", count: 200_000).joined(separator: ",") + "]").utf8)
    let result = try probe("wide-flow", bytes, semantics: true, in: directory)
    #expect(result.report.status == "manifest.limit")
    #expect(result.report.stage == .parser)
    #expect(result.report.metrics.parserCallbacks == YAMLParser.callbackLimit + 1)
    #expect(result.report.metrics.syntaxNodes == 0)
  }
  @Test func validScalarAtTheInputLimitIsAdmitted() throws {
    let prefix = "version: 1\ncomponents: [{kind: subagent, name: a, description: d, prompt: '"
    let suffix = "'}]\n"
    let bytes = Array(
      (prefix
        + String(
          repeating: "x", count: ManifestLimits.Input.bytes - prefix.utf8.count - suffix.utf8.count)
        + suffix).utf8)
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(document.bytes.count == ManifestLimits.Input.bytes)
    #expect(document.declaration.components.count == 1)
  }
  @Test func wideAndDeepShapesFailWithAnEnforcedBudget() {
    for text in [
      "[" + Array(repeating: "x", count: 200_000).joined(separator: ",") + "]",
      String(repeating: "[", count: 256) + "x" + String(repeating: "]", count: 256),
    ] {
      expectManifestFailure("manifest.limit") { try document(text) }
    }
  }
  @Test func inputAndContainerLimitsRemainIndependent() {
    expectManifestFailure("manifest.limit") {
      try document(String(repeating: "x", count: ManifestLimits.Input.bytes + 1))
    }
    expectManifestFailure("manifest.limit") {
      try document(
        "version: 1\nwatch: [" + Array(repeating: "x", count: 10_001).joined(separator: ",") + "]\n"
      )
    }
  }
}
