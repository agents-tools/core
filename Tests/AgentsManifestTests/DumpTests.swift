import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Evaluated manifest dump")
struct DumpTests {
  @Test(arguments: [
    "PrintedEmpty", "PrintedFields", "DumpSymbolic", "ConsumerExample", "LiteralCoverage",
  ])
  func completeGoldenObjectsAndLocationsAreByteExact(_ name: String) throws {
    let bytes = try manifestFixture(name + ".swift.txt")
    let dump = try ManifestDump(bytes: bytes)
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(dump.locations.count == document.sourceMap.entries.count)
    let output = try dump.encodedJSON()
    #expect(try output == manifestFixture(name + ".dump.json"))
    #expect(try output == dump.encodedJSON())
    #expect(output.last == 10)
    #expect(dump.sourceDigest == "sha256:" + FileHash.sha256Hex(data: Data(bytes)))
    let root = try #require(JSONSerialization.jsonObject(with: Data(output)) as? [String: Any])
    #expect(
      root.keys.sorted() == [
        "declaration", "diagnostics", "kind", "languageVersion", "locations", "schemaVersion",
        "sourceDigest",
      ])
    #expect(root["schemaVersion"] as? Int == 1)
    let declaration = try #require(root["declaration"])
    for location in dump.locations {
      #expect(resolve(location.pointer, in: declaration) != nil, "\(name): \(location.pointer)")
      #expect(location.span.document.rawValue == "manifest")
      #expect(location.origins.allSatisfy { $0.document.rawValue == "manifest" })
    }
  }

  @Test func symbolicConditionsGroupsExplicitRecipientsAndNormalizedPointersSurvive() throws {
    let bytes = try manifestFixture("DumpSymbolic.swift.txt")
    let dump = try ManifestDump(bytes: bytes)
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(dump.encodedJSON())) as? [String: Any])
    let declaration = try #require(root["declaration"])
    #expect(resolve("/defaultAgents", in: declaration) as? [String] == [])
    #expect(resolve("/components/0/agents", in: declaration) as? [String] == [])
    #expect(resolve("/components/1/agents", in: declaration) is NSNull)
    #expect(resolve("/sources/0/name", in: declaration) as? String == "a")
    #expect(resolve("/sources/1/url", in: declaration) as? String == "https://intranet/team.git")
    #expect(resolve("/sources/1/requirement/upToNextMinor", in: declaration) as? String == "1.2.0")
    #expect(resolve("/components/1/select", in: declaration) as? [String] == ["a", "z"])
    #expect(resolve("/components/1/overrides/0/name", in: declaration) as? String == "a")
    #expect(resolve("/components/2/exclude/0/kind", in: declaration) as? String == "command")
    #expect(resolve("/components/2/exclude/0/name", in: declaration) as? String == "zzz")
    #expect(resolve("/components/2/exclude/1/kind", in: declaration) as? String == "hook")
    #expect(resolve("/components/2/exclude/1/name", in: declaration) as? String == "aaa")
    #expect(resolve("/components/2/exclude/2/name", in: declaration) as? String == "bbb")
    #expect(resolve("/components/2/exclude/3/kind", in: declaration) as? String == "skill")
    #expect(resolve("/components/0/chatGPT/0/name", in: declaration) as? String == "a")
    #expect(resolve("/uses/0/kind", in: declaration) as? String == "exported")
    #expect(resolve("/uses/0/source", in: declaration) as? String == "z")
    #expect(resolve("/uses/1/kind", in: declaration) as? String == "local")
    #expect(resolve("/uses/1/source", in: declaration) is NSNull)
    #expect(
      resolve("/uses/0/condition/agents", in: declaration) as? [String] == ["codex", "opencode"])
    let location = try #require(dump.locations.first { $0.pointer == "/sources/1/name" })
    #expect(
      String(decoding: bytes[location.span.start..<location.span.end], as: UTF8.self) == "\"z\"")
    let condition = try #require(dump.locations.first { $0.pointer == "/uses/0/condition" })
    #expect(!condition.origins.isEmpty)
    #expect(dump.locations.contains { $0.defaulted && $0.pointer == "/sources/0/requirement" })
    #expect(dump.diagnostics.map(\.code) == ["manifest.domain"])
    #expect(dump.diagnostics[0].severity == .warning)
  }

  @Test func commentsChangeOnlyDigestAndLocations() throws {
    let first = try document("let agents = Agents(defaultAgents: [])")
    let second = try document("// comment\nlet agents = Agents(defaultAgents: [])")
    let a = try ManifestDump(document: first)
    let b = try ManifestDump(document: second)
    #expect(a.declaration == b.declaration)
    #expect(a.sourceDigest != b.sourceDigest)
    #expect(a.locations.first?.span != b.locations.first?.span)
  }

  @Test func taggedValuesRetainTheirPayloadTypesAndFactoryFields() throws {
    let dump = try ManifestDump(bytes: manifestFixture("LiteralCoverage.swift.txt"))
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(dump.encodedJSON())) as? [String: Any])
    let declaration = try #require(root["declaration"])
    let config = "/components/5/initializationOptions/config"
    #expect(resolve(config + "/kind", in: declaration) as? String == "object")
    #expect(resolve(config + "/value/decimal/kind", in: declaration) as? String == "decimal")
    #expect(resolve(config + "/value/decimal/value", in: declaration) as? String == "1.25")
    #expect(resolve(config + "/value/integer/value", in: declaration) as? Int == -1)
    #expect(
      resolve(config + "/value/null", in: declaration) as? [String: String] == ["kind": "null"])
    #expect(resolve(config + "/value/array/value/2/kind", in: declaration) as? String == "boolean")
    #expect(resolve(config + "/value/array/value/2/value", in: declaration) as? Bool == false)
    let token = "/components/0/transport/environment/TOKEN"
    #expect(resolve(token + "/kind", in: declaration) as? String == "secret")
    #expect(resolve(token + "/value", in: declaration) as? String == "token")
    #expect(resolve("/components/2/prompt/kind", in: declaration) as? String == "literal")
    #expect(resolve("/components/5/run/kind", in: declaration) as? String == "executable")
    #expect(
      resolve("/components/6/rules/0/operation", in: declaration) as? [String: String] == [
        "kind": "read"
      ])
    #expect(
      resolve("/components/6/rules/3/operation", in: declaration) as? [String: String] == [
        "kind": "tool", "value": "fetch",
      ])
    #expect(resolve("/components/7/exclude/0/kind", in: declaration) as? String == "command")
  }

  @Test func invalidInputAndOutputExhaustionPublishNoPartialObject() throws {
    var output: [UInt8]?
    do {
      output = try ManifestDump(
        bytes: Array((manifestHeader + "let agents = Agents(watch: [\"unknown\"])").utf8)
      ).encodedJSON()
      Issue.record("invalid dump succeeded")
    } catch let failure as ManifestFailure {
      #expect(failure.diagnostics.map(\.code) == ["manifest.domain"])
    }
    #expect(output == nil)
    let model = ManifestJSONValue.object([
      "escaped": .string("\0\n\"\\😀"), "a": .array([.boolean(true), .integer(-1), .null]),
    ])
    let encoded = try model.encodedJSON()
    #expect(try model.encodedCount(limit: encoded.count) == encoded.count - 1)
    expectManifestFailure("manifest.limit") { try model.encodedJSON(limit: encoded.count - 1) }
    #expect(try model.encodedJSON(limit: encoded.count) == encoded)
  }

  private func resolve(_ pointer: String, in value: Any) -> Any? {
    if pointer.isEmpty { return value }
    var current = value
    for segment in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      let key = pointerUnescape(String(segment))
      if let fields = current as? [String: Any], let child = fields[key] {
        current = child
      } else if let values = current as? [Any], let index = Int(key), values.indices.contains(index)
      {
        current = values[index]
      } else {
        return nil
      }
    }
    return current
  }
}
