import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger wire spelling")
struct LedgerWireSpellingTests {
  @Test func pendingMarketplaceWireBindsBothClosuresAndSharesContentObjects() throws {
    let shared = Data("shared".utf8)
    let addition = Data("added".utf8)
    let sharedID = "sha256:" + FileHash.sha256Hex(data: shared)
    let additionID = "sha256:" + FileHash.sha256Hex(data: addition)
    var deployed = ResolvedLedger()
    deployed.contentObjects[sharedID] = shared
    let original = try ResolvedLedgerCodec.encode(deployed, limits: .standard)
    let oldWire = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    #expect(oldWire["pendingMarketplaceDeployment"] == nil)
    #expect(try ResolvedLedgerCodec.decode(original, limits: .standard) == deployed)

    var desired = deployed
    desired.contentObjects[additionID] = addition
    deployed.pendingDeployment = try MarketplacePendingDeploymentRecord(
      ledger: desired, deployed: deployed, declarationDigest: sharedID)
    var limits = LedgerLimits.standard
    limits.objectBytes = shared.count + addition.count
    let bytes = try ResolvedLedgerCodec.encode(deployed, limits: limits)
    let decoded = try ResolvedLedgerCodec.decode(bytes, limits: limits)
    #expect(decoded == deployed)
    #expect(try decoded.pendingDeployment?.desired(in: decoded) == desired)
    limits.objectBytes -= 1
    #expect(throws: CoreError.self) { try LedgerAdmission.check(bytes, limits: limits) }

    var invalid = decoded
    invalid.sources["changed"] = .init(kind: .local, revision: "live")
    #expect(throws: CoreError.self) { try ResolvedLedgerCodec.encode(invalid, limits: .standard) }
    var root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var pending = try #require(root["pendingMarketplaceDeployment"] as? [String: Any])
    pending["digest"] = sharedID
    root["pendingMarketplaceDeployment"] = pending
    #expect(throws: CoreError.self) {
      try ResolvedLedgerCodec.decode(
        JSONSerialization.data(withJSONObject: root), limits: .standard)
    }
  }

  @Test func nullableMembersFollowTheirOwningRecords() throws {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = LedgerSource(kind: .local, revision: "live")
    ledger.sourceUses = [
      LedgerSourceUse(source: "source", root: "."),
      LedgerSourceUse(source: "source", root: ".", requirement: .upToNextMajor(from: "1.0.0")),
    ]
    ledger.lowerings = [
      LockedLowering(
        id: "value", format: "test/value@1", inputs: [], resources: [], deployments: [],
        layout: .init(), platform: "macos", artifacts: [])
    ]
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var sources = try #require(root["sources"] as? [String: Any])
    var source = try #require(sources["source"] as? [String: Any])
    for key in ["transport", "location", "version", "container", "namespace"] {
      source[key] = NSNull()
    }
    sources["source"] = source
    root["sources"] = sources
    root["sourceUses"] = [
      ["source": "source", "root": ".", "requirement": NSNull()],
      ["source": "source", "root": ".", "requirement": ["from": "1.0.0", "to": NSNull()]],
    ]
    var lowerings = try #require(root["lowerings"] as? [[String: Any]])
    var layout: [String: Any] = ["kind": "null"]
    for key in ["text", "integer", "boolean", "array", "object"] { layout[key] = NSNull() }
    lowerings[0]["layout"] = layout
    root["lowerings"] = lowerings
    let bytes = try JSONSerialization.data(withJSONObject: root)
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: .standard) == ledger)
    #expect(try ResolvedLedgerCodec.replacement(ledger, existing: bytes, limits: .standard) == nil)

    // A member nullable in a source is still unknown at the ledger root or in a tagged value.
    root["transport"] = NSNull()
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(
        JSONSerialization.data(withJSONObject: root), limits: .standard)
    }
    root.removeValue(forKey: "transport")
    layout["namespace"] = NSNull()
    lowerings[0]["layout"] = layout
    root["lowerings"] = lowerings
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(
        JSONSerialization.data(withJSONObject: root), limits: .standard)
    }
    layout.removeValue(forKey: "namespace")
    layout["kind"] = "array"
    lowerings[0]["layout"] = layout
    root["lowerings"] = lowerings
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(
        JSONSerialization.data(withJSONObject: root), limits: .standard)
    }
    layout["array"] = [] as [Any]
    lowerings[0]["layout"] = layout
    root["lowerings"] = lowerings
    let emptyArray = try ResolvedLedgerCodec.decode(
      JSONSerialization.data(withJSONObject: root), limits: .standard)
    #expect(emptyArray.lowerings[0].layout.array == [])
  }

  @Test func escapedBase64UsesDecodedAggregateSize() throws {
    var limits = LedgerLimits.standard
    limits.objectBytes = 3
    for spelling in [#"YQ=="#, #"\u0059Q=="#, #"YQ\u003d\u003D"#] {
      let bytes = Data((#"{"contentObjects":{"first":""# + spelling + #"","second":"YmM="}}"#).utf8)
      limits.encodedBytes = bytes.count
      try LedgerAdmission.check(bytes, limits: limits)
      limits.objectBytes = 2
      #expect(throws: (any Error).self) { try LedgerAdmission.check(bytes, limits: limits) }
      limits.objectBytes = 3
    }
    limits = .standard
    limits.objectBytes = 1
    for spelling in [#"/w=="#, #"\/w=="#, #"\u002fw\u003d="#] {
      try LedgerAdmission.check(
        Data((#"{"contentObjects":{"first":""# + spelling + #""}}"#).utf8), limits: limits)
    }
  }

  @Test func literalAndEscapedKeysShareDuplicateDetection() throws {
    try LedgerAdmission.check(Data(#"{"é":1,"":2}"#.utf8), limits: .standard)
    for object in [
      #"{ "key": 1, "\u006bey": 2 }"#,
      #"{ "é": 1, "\u00e9": 2 }"#,
      "{\"é\":1,\"e\u{301}\":2}",
    ] {
      #expect(throws: CoreError.invalidState("duplicate ledger key")) {
        try LedgerAdmission.check(Data(object.utf8), limits: .standard)
      }
    }
  }

  @Test func keySpellingPreservesWireSizeAndDecodedBudgetSelection() throws {
    var limits = LedgerLimits.standard
    limits.keyBytes = 4
    try LedgerAdmission.check(Data(#"{"é":0}"#.utf8), limits: limits)
    #expect(throws: CoreError.invalidState("ledger key budget")) {
      try LedgerAdmission.check(Data(#"{"\u00e9":0}"#.utf8), limits: limits)
    }
    limits = .standard
    limits.entries = 1
    #expect(throws: CoreError.invalidState("ledger entry budget")) {
      try LedgerAdmission.check(Data(#"{"\u0065ntries":[1,2]}"#.utf8), limits: limits)
    }
    limits.objectBytes = 2
    #expect(throws: CoreError.invalidState("ledger content byte budget")) {
      try LedgerAdmission.check(
        Data(#"{"\u0063ontentObjects":{"data":"YWJj"}}"#.utf8), limits: limits)
    }
  }

  @Test func invalidEscapedContentCannotBypassAdmission() throws {
    for spelling in [#"Y\nQ=="#, #"YQ\u003dA"#, #"\uD800Q=="#, #"YQ===\u003d"#] {
      let bytes = Data((#"{"contentObjects":{"first":""# + spelling + #""}}"#).utf8)
      #expect(throws: (any Error).self) {
        try LedgerAdmission.check(bytes, limits: .standard)
      }
    }
  }
}
