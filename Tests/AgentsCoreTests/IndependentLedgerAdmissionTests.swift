import AgentsManifest
import Foundation
import Testing

@testable import AgentsCore

@Suite("Independent ledger admission")
struct IndependentLedgerAdmissionTests {
  private var limits: LedgerLimits {
    LedgerLimits(
      encodedBytes: 32_768, depth: 32, nodes: 1_000,
      objectBytes: 64, entries: 16, keyBytes: 256)
  }

  private func fixture() -> ResolvedLedger {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = LedgerSource(
      kind: .local, revision: "revision", version: "braces { } and \"quoted\"")
    let first = Data("a".utf8)
    let second = Data("bc".utf8)
    let firstID = "sha256:" + FileHash.sha256Hex(data: first)
    let secondID = "sha256:" + FileHash.sha256Hex(data: second)
    ledger.contentObjects = [firstID: first, secondID: second]
    ledger.resources["first"] = LedgerResource(
      kind: .embedded, source: "source", path: "first", hash: firstID,
      entries: [
        LedgerEntry(
          path: ".", kind: .file, object: firstID, executable: false, byteCount: first.count)
      ])
    ledger.resources["second"] = LedgerResource(
      kind: .embedded, source: "source", path: "second", hash: secondID,
      entries: [
        LedgerEntry(
          path: ".", kind: .file, object: secondID, executable: true, byteCount: second.count)
      ])
    return ledger
  }

  private func wire(_ ledger: ResolvedLedger) throws -> Data {
    try ResolvedLedgerCodec.encode(ledger, limits: limits)
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  @Test func validControlsAndUnchangedReplacement() throws {
    let ledger = fixture()
    let canonical = try wire(ledger)
    #expect(try ResolvedLedgerCodec.decode(canonical, limits: limits) == ledger)

    let pretty = try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: canonical),
      options: [.prettyPrinted, .sortedKeys])
    #expect(pretty != canonical)
    #expect(try ResolvedLedgerCodec.decode(pretty, limits: limits) == ledger)
    #expect(try ResolvedLedgerCodec.replacement(ledger, existing: pretty, limits: limits) == nil)
    var changed = ledger
    changed.sources["source"]?.version = "another version"
    let replacement = try #require(
      try ResolvedLedgerCodec.replacement(changed, existing: pretty, limits: limits))
    #expect(try ResolvedLedgerCodec.decode(replacement, limits: limits) == changed)
  }

  @Test func duplicateAndUnknownKeysAreRejected() throws {
    let canonical = try wire(fixture())
    let text = try #require(String(data: canonical, encoding: .utf8))
    for prefix in [#""version":2,"#, #""ver\u0073ion":2,"#] {
      let duplicate = Data(("{" + prefix + text.dropFirst()).utf8)
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.decode(duplicate, limits: limits)
      }
    }

    var root = try object(canonical)
    root["unexpected"] = NSNull()
    let unknownRoot = try data(root)
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(unknownRoot, limits: limits)
    }
    root = try object(canonical)
    var sources = try #require(root["sources"] as? [String: Any])
    var source = try #require(sources["source"] as? [String: Any])
    source["unexpected"] = NSNull()
    sources["source"] = source
    root["sources"] = sources
    let unknownNested = try data(root)
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(unknownNested, limits: limits)
    }
  }

  @Test func knownOptionalNullIsAccepted() throws {
    let ledger = fixture()
    var root = try object(wire(ledger))
    var sources = try #require(root["sources"] as? [String: Any])
    var source = try #require(sources["source"] as? [String: Any])
    source["transport"] = NSNull()
    sources["source"] = source
    root["sources"] = sources
    let bytes = try data(root)
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: limits) == ledger)
    #expect(try ResolvedLedgerCodec.replacement(ledger, existing: bytes, limits: limits) == nil)
  }

  @Test func versionsAndTagsAreStrict() throws {
    let canonical = try wire(fixture())
    for version in [1, 3] {
      var root = try object(canonical)
      root["version"] = version
      let bytes = try data(root)
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.decode(bytes, limits: limits)
      }
    }
    var root = try object(canonical)
    var resources = try #require(root["resources"] as? [String: Any])
    var resource = try #require(resources["first"] as? [String: Any])
    resource["kind"] = "unknown"
    resources["first"] = resource
    root["resources"] = resources
    let bytes = try data(root)
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(bytes, limits: limits)
    }
  }

  @Test func encodedAndAggregateObjectBudgets() throws {
    let ledger = fixture()
    let bytes = try wire(ledger)
    var bound = limits
    bound.encodedBytes = bytes.count
    bound.objectBytes = 3
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: bound) == ledger)
    bound.encodedBytes = bytes.count - 1
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(bytes, limits: bound)
    }
    bound.encodedBytes = bytes.count
    bound.objectBytes = 2
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(bytes, limits: bound)
    }

    // JSON escapes do not change the decoded Base64 value or its byte budget.
    let text = try #require(String(data: bytes, encoding: .utf8))
    let escaped = text.replacingOccurrences(of: #""YQ==""#, with: #""\u0059Q==""#)
    #expect(escaped != text)
    let escapedBytes = Data(escaped.utf8)
    bound.encodedBytes = escapedBytes.count
    bound.objectBytes = 3
    #expect(try ResolvedLedgerCodec.decode(escapedBytes, limits: bound) == ledger)
  }

  @Test func structureAndEntryBudgets() throws {
    let bytes = try wire(fixture())
    var bound = limits
    bound.entries = 2
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: bound) == fixture())
    bound.entries = 1
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(bytes, limits: bound)
    }

    let shallow = Data(#"{"a":[1,2]}"#.utf8)
    bound = limits
    bound.depth = 2
    bound.nodes = 4
    try LedgerAdmission.check(shallow, limits: bound)
    bound.depth = 1
    #expect(throws: (any Error).self) { try LedgerAdmission.check(shallow, limits: bound) }
    bound.depth = 2
    bound.nodes = 3
    #expect(throws: (any Error).self) { try LedgerAdmission.check(shallow, limits: bound) }
  }

  @Test func corruptReferencesAndPathsFailAtCodecBoundary() throws {
    let valid = fixture()
    #expect(try ResolvedLedgerCodec.decode(wire(valid), limits: limits) == valid)
    var broken = valid
    let objectID = try #require(broken.resources["first"]?.entries.first?.object)
    broken.contentObjects[objectID] = Data("different".utf8)
    #expect(throws: (any Error).self) { _ = try wire(broken) }

    broken = valid
    broken.contentObjects.removeValue(forKey: objectID)
    #expect(throws: (any Error).self) { _ = try wire(broken) }
    broken = valid
    broken.resources["first"]?.source = "missing"
    #expect(throws: (any Error).self) { _ = try wire(broken) }
    for path in ["../escape", "/absolute", "a/../b"] {
      broken = valid
      broken.resources["first"]?.entries[0].path = path
      #expect(throws: (any Error).self) { _ = try wire(broken) }
    }
  }

  @Test func publicV1OperationsPreserveV2Files() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let store = StateStore(scope: .project, environment: environment)
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let declaration = try Data(contentsOf: store.declarationURL)
    let bytes = try wire(fixture())
    try bytes.write(to: store.resolvedURL)
    #expect(throws: (any Error).self) { _ = try store.loadResolved() }
    #expect(throws: (any Error).self) {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    }
    #expect(try Data(contentsOf: store.resolvedURL) == bytes)
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
  }
}
