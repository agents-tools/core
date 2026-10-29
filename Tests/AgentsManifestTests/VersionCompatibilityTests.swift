import AgentsDescription
import Testing

@testable import AgentsCore
@testable import AgentsManifest

@Suite("Manifest version compatibility")
struct VersionCompatibilityTests {
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
}
