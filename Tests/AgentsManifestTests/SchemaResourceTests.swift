import AgentsManifest
import Foundation
import Testing

@Suite("Manifest schema resource")
struct SchemaResourceTests {
  @Test func exportedBytesMatchTheCanonicalResource() throws {
    let resource = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/AgentsManifest/Resources/agents.schema.json")
    let expected = try Data(contentsOf: resource)
    let exported = try ManifestSchemaResource.encodedJSON()
    #expect(exported == Array(expected))
    _ = try JSONSerialization.jsonObject(with: Data(exported))
  }
}
