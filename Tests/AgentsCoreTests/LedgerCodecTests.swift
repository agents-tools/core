import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger codec")
struct LedgerCodecTests {
  @Test func emptyAndUnchangedBytes() throws {
    let value = ResolvedLedger()
    let bytes = try ResolvedLedgerCodec.encode(value, limits: .standard)
    let spaced = Data(" \n".utf8) + bytes
    #expect(try ResolvedLedgerCodec.decode(spaced, limits: .standard) == value)
    #expect(try ResolvedLedgerCodec.replacement(value, existing: spaced, limits: .standard) == nil)
    #expect(throws: (any Error).self) { _ = try StateStore.decode(bytes, as: ResolvedState.self) }
  }

  @Test func strictAdmissionAndReferences() throws {
    try LedgerAdmission.check(
      Data(("{\"" + String(repeating: "k", count: 20_000) + "\":null}").utf8), limits: .standard)
    let bytes = try ResolvedLedgerCodec.encode(ResolvedLedger(), limits: .standard)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["unknown"] = NSNull()
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(unknown, limits: .standard)
    }
    for malformed in [
      "{\"version\":2,\"version\":2}", "{\"a\":1,\"\\u0061\":2}", "[1,]", "[01]", "[true false]",
      "\"\\uZZZZ\"",
    ] {
      #expect(throws: (any Error).self) {
        try LedgerAdmission.check(Data(malformed.utf8), limits: .standard)
      }
    }
    var limits = LedgerLimits.standard
    limits.encodedBytes = bytes.count - 1
    #expect(throws: (any Error).self) { _ = try ResolvedLedgerCodec.decode(bytes, limits: limits) }
    limits = .standard
    limits.objectBytes = 2
    #expect(throws: (any Error).self) {
      try LedgerAdmission.check(Data("{\"contentObjects\":{\"a\":\"YWJj\"}}".utf8), limits: limits)
    }
    limits = .standard
    limits.depth = 2
    #expect(throws: (any Error).self) {
      try LedgerAdmission.check(Data("[[[[]]]]".utf8), limits: limits)
    }
    var ledger = ResolvedLedger()
    ledger.contentObjects["sha256:" + String(repeating: "0", count: 64)] = Data("bad".utf8)
    #expect(throws: (any Error).self) { try ledger.validate() }
  }

  @Test func locationsKeepAuthoredMeaning() throws {
    let roots = ["home": URL(fileURLWithPath: "/new-home")]
    #expect(
      try LedgerLocation(kind: .registered, root: "home", path: "skills").resolve(roots: roots).path
        == "/new-home/skills")
    #expect(
      try LedgerLocation(kind: .absolute, path: "/old-home/skills").resolve(roots: roots).path
        == "/old-home/skills")
    #expect(
      try LedgerLocation(kind: .authoringRelative, root: "home", path: "../skills").resolve(
        roots: roots
      ).path == "/skills")
    for path in ["../escape", "/absolute", "a/../b", "a//b", "~/x"] {
      #expect(throws: (any Error).self) {
        try LedgerLocation(kind: .registered, root: "home", path: path).validate()
      }
    }
  }

  @Test func codecMeasurement() throws {
    guard ProcessInfo.processInfo.environment["AGENTS_LEDGER_MEASURE"] == "1" else { return }
    let count =
      Int(ProcessInfo.processInfo.environment["AGENTS_LEDGER_MEASURE_BYTES"] ?? "") ?? 50 * 1024
      * 1024
    let entries =
      Int(ProcessInfo.processInfo.environment["AGENTS_LEDGER_MEASURE_ENTRIES"] ?? "") ?? 1_000
    var ledger = ResolvedLedger()
    let bytes = Data(repeating: 0x61, count: count)
    let digest = "sha256:" + FileHash.sha256Hex(data: bytes)
    ledger.contentObjects[digest] = bytes
    let emptyDigest = "sha256:" + FileHash.sha256Hex(data: Data())
    ledger.contentObjects[emptyDigest] = Data()
    ledger.sources["root"] = LedgerSource(
      kind: .local, location: .init(kind: .registered, root: "project", path: "."), revision: "live"
    )
    ledger.resources["resource"] = LedgerResource(
      kind: .embedded, source: "root", path: ".", hash: digest,
      entries: [LedgerEntry(path: ".", kind: .directory, executable: false)]
        + (1..<entries).map {
          LedgerEntry(
            path: "entry-\($0)", kind: .file, object: $0 == 1 ? digest : emptyDigest,
            executable: false, byteCount: $0 == 1 ? count : 0)
        })
    let start = Date()
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(encoded, limits: .standard) == ledger)
    func shape(_ value: Any, depth: Int = 0) -> (nodes: Int, depth: Int) {
      let children: [Any]
      if let object = value as? [String: Any] {
        children = Array(object.values)
      } else if let array = value as? [Any] {
        children = array
      } else {
        children = []
      }
      return children.reduce((1, depth)) { result, child in
        let nested = shape(child, depth: depth + 1)
        return (result.0 + nested.nodes, max(result.1, nested.depth))
      }
    }
    let structure = shape(try JSONSerialization.jsonObject(with: encoded))
    var usage = rusage()
    #if os(Linux)
      _ = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
    #else
      _ = getrusage(RUSAGE_SELF, &usage)
    #endif
    #if os(Linux)
      let rss = usage.ru_maxrss * 1024
    #else
      let rss = usage.ru_maxrss
    #endif
    print(
      "LEDGER_MEASUREMENT nodes=\(structure.nodes) depth=\(structure.depth) entries=\(entries) peakRSSBytes=\(rss) decodedBytes=\(count) encodedBytes=\(encoded.count) seconds=\(Date().timeIntervalSince(start))"
    )
  }
}
