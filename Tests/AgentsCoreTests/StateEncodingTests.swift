import Foundation
import Testing

@testable import AgentsCore

@Suite("State JSON encoding")
struct StateEncodingTests {
  @Test(arguments: ["agents.json", "agents.resolved", "transaction.json"])
  func rejectsEncodedDocumentsWithoutChangingFiles(_ name: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let declaration = try Data(contentsOf: store.declarationURL)
    let resolved = try Data(contentsOf: store.resolvedURL)
    let json: String
    switch name {
    case "agents.json":
      json = #"{"sources":{"same":{"local":"/a"},"same":{"local":"/b"}}}"#
    case "agents.resolved": json = String(decoding: resolved, as: UTF8.self)
    default:
      let directory = try #require(try store.openDirectoryIfPresent())
      let object: [String: Any] = [
        "id": UUID().uuidString, "scope": try directory.identity,
        "roots": [:] as [String: String], "phase": "committed", "entries": [] as [String],
      ]
      json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let encodings = [
      Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8),
      json.data(using: .utf16)!, json.data(using: .utf16LittleEndian)!,
      json.data(using: .utf16BigEndian)!, json.data(using: .utf32)!,
      json.data(using: .utf32LittleEndian)!, json.data(using: .utf32BigEndian)!,
      Data(json.utf8) + Data(" {}".utf8), Data([0xFF]),
    ]
    for data in encodings {
      let url = store.directory.appendingPathComponent(name)
      try data.write(to: url)
      #expect(throws: (any Error).self) {
        if name == "agents.json" {
          _ = try store.loadDeclaration()
        } else {
          _ = try store.loadResolved()
        }
      }
      #expect(throws: (any Error).self) {
        try store.save(declaration: Declaration(), resolved: ResolvedState())
      }
      #expect(try Data(contentsOf: url) == data)
      if name != "agents.json" {
        #expect(try Data(contentsOf: store.declarationURL) == declaration)
      }
      if name != "agents.resolved" { #expect(try Data(contentsOf: store.resolvedURL) == resolved) }
    }
  }

  @Test func acceptsCompleteUTF8IncludingEscapedNullAndNonASCIIKeys() throws {
    try JSONKeys.validate(Data(" \n{\"é\":\"\\u0000\",\"日本語\":[{},true,null,12]}\t".utf8))
    for json in ["{} {}", "{} true", "true false", "{}\u{FEFF}"] {
      #expect(throws: (any Error).self) { try JSONKeys.validate(Data(json.utf8)) }
    }
    #expect(throws: (any Error).self) {
      try JSONKeys.validate(Data(#"{"é":1,"\u00e9":2}"#.utf8))
    }
  }
}
