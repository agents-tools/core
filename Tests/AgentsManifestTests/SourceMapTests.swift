import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Manifest source maps")
struct SourceMapTests {
  @Test func normalizedRequirementParentsKeepTheCompleteReferenceOriginChain() throws {
    let doc = try document(
      """
      let minimum: Version = "1.2.0"
      let alias: Version = minimum
      let agents = Agents(sources: [.source(name: "s", path: "s", from: alias)])
      """)
    for pointer in ["/sources/0/requirement", "/sources/0/requirement/from"] {
      let location = try #require(doc.sourceMap.locations(at: pointer).first)
      #expect(
        String(decoding: doc.bytes[location.span.start..<location.span.end], as: UTF8.self)
          == "alias")
      #expect(
        location.origins.map {
          String(decoding: doc.bytes[$0.start..<$0.end], as: UTF8.self)
        } == ["minimum", "\"1.2.0\""])
    }
  }
  @Test func configurationPayloadMappingDoesNotInspectUserKeys() throws {
    for expression in ["[\"value\": 1, \"other\": 2]", ".object([\"value\": 1, \"other\": 2])"] {
      let doc = try document(
        "let agents = Agents(components: [.lspServer(name: \"s\", run: .executable(\"tool\"), languages: [\".swift\": \"swift\"], initializationOptions: [\"options\": "
          + expression + "])])")
      for (suffix, spelling) in [
        ("", "[\"value\": 1, \"other\": 2]"), ("/value", "1"), ("/other", "2"),
      ] {
        let pointer = "/components/0/initializationOptions/options/value" + suffix
        let location = try #require(doc.sourceMap.locations(at: pointer).first)
        #expect(
          String(decoding: doc.bytes[location.span.start..<location.span.end], as: UTF8.self)
            == spelling)
        #expect(doc.node(at: pointer) != nil)
      }
    }
  }

}
