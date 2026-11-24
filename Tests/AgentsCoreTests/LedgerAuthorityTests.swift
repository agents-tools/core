import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger native authority")
struct LedgerAuthorityTests {
  private let hash = "sha256:" + String(repeating: "a", count: 64)
  private var semantic: LedgerNativeArrayEvidence {
    .semantic(format: "native-array@1", digest: hash)
  }

  private func fixture() -> ResolvedLedger {
    var ledger = ResolvedLedger()
    ledger.sources["root"] = .init(kind: .local, revision: "live")
    ledger.components["hook"] = .init(
      declaringSource: "root", source: "root", root: ".", kind: "hook", name: "hook",
      payload: .init(), conditions: [], recipients: [.claudeCode], chatGPT: false, resources: [])
    let target = LedgerLocation(kind: .registered, root: "native-claude-project", path: ".mcp.json")
    ledger.deployments = [
      .init(
        id: "deployment", target: target, route: "test/native@1", owners: ["hook"],
        recipients: [.claudeCode], ownership: .ownedValues, expectedHash: hash, created: false)
    ]
    ledger.lowerings = [
      .init(
        id: "lowering", format: "test/native@1", inputs: ["hook"], resources: [],
        deployments: ["deployment"], layout: .init(), platform: "macos", artifacts: [])
    ]
    ledger.nativeAuthorities = [
      .init(
        target: target, targetRoute: "claude.mcp.project", documentFormat: "json",
        regions: [
          .init(
            deployments: ["deployment"],
            path: [.key("hooks"), .position(index: 1, evidence: semantic)])
        ],
        createdContainers: [
          .init(deployments: ["deployment"], path: [.key("hooks")], kind: "array")
        ])
    ]
    return ledger
  }

  private func encoded(_ ledger: ResolvedLedger) throws -> Data {
    try ResolvedLedgerCodec.encode(ledger, limits: .standard)
  }

  @Test func publicAndPrivateEvidenceRoundTripWithoutRewriting() throws {
    for evidence in [semantic, .privateArray(token: UUID())] {
      var ledger = fixture()
      ledger.nativeAuthorities![0].regions[0].path[1] = .position(index: 1, evidence: evidence)
      let bytes = try encoded(ledger)
      let pretty = try JSONSerialization.data(
        withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.prettyPrinted])
      #expect(try ResolvedLedgerCodec.decode(pretty, limits: .standard) == ledger)
      #expect(
        try ResolvedLedgerCodec.replacement(ledger, existing: pretty, limits: .standard) == nil)
      #expect(ledger.deployments[0].created == false)
    }
    var old = fixture()
    old.nativeAuthorities = nil
    let oldBytes = try encoded(old)
    var wire = try #require(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
    #expect(wire["nativeAuthorities"] == nil)
    wire["nativeAuthorities"] = NSNull()
    let nullable = try JSONSerialization.data(withJSONObject: wire)
    #expect(try ResolvedLedgerCodec.decode(nullable, limits: .standard) == old)
    #expect(try ResolvedLedgerCodec.replacement(old, existing: nullable, limits: .standard) == nil)
  }

  @Test func equivalentRequirementsDoNotMaskPrivateContinuityChanges() throws {
    var ledger = fixture()
    ledger.sourceUses = [
      .init(source: "root", root: ".", requirement: .range(from: "v1.2.0", to: "2.0.0+meta"))
    ]
    ledger.nativeAuthorities![0].regions[0].path[1] = .position(
      index: 1, evidence: .privateArray(token: UUID()))
    let bytes = try encoded(ledger)
    var next = ledger
    next.sourceUses[0].requirement = .upToNextMajor(from: "1.2.0")
    #expect(try ResolvedLedgerCodec.replacement(next, existing: bytes, limits: .standard) == nil)
    next.nativeAuthorities![0].regions[0].path[1] = .position(
      index: 1, evidence: .privateArray(token: UUID()))
    #expect(try ResolvedLedgerCodec.replacement(next, existing: bytes, limits: .standard) != nil)
  }

  @Test func strictTaggedWireRejectsUnknownAndWrongFields() throws {
    let bytes = try encoded(fixture())
    let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let authority = try #require((root["nativeAuthorities"] as? [[String: Any]])?.first)
    let region = try #require((authority["regions"] as? [[String: Any]])?.first)
    let path = try #require(region["path"] as? [[String: Any]])
    let evidence = try #require(path[1]["evidence"] as? [String: Any])
    for level in 0..<6 {
      var changed = root
      var a = authority
      var r = region
      var p = path
      var e = evidence
      switch level {
      case 0: a["unknown"] = NSNull()
      case 1: r["unknown"] = NSNull()
      case 2: p[0]["index"] = NSNull()
      case 3: p[1]["unknown"] = NSNull()
      case 4: e["token"] = NSNull()
      default:
        var containers = try #require(a["createdContainers"] as? [[String: Any]])
        containers[0]["unknown"] = NSNull()
        a["createdContainers"] = containers
      }
      p[1]["evidence"] = e
      r["path"] = p
      a["regions"] = [r]
      changed["nativeAuthorities"] = [a]
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.decode(
          JSONSerialization.data(withJSONObject: changed), limits: .standard)
      }
    }
    for invalid in [
      ["kind": "unknown"], ["kind": "key", "value": "x"],
      [
        "kind": "position", "index": 0,
        "evidence": ["kind": "privateArray", "token": "not-a-uuid"],
      ],
      ["kind": "position", "index": 0, "evidence": ["kind": "unknown"]],
    ] as [[String: Any]] {
      var changed = root
      var a = authority
      var r = region
      r["path"] = [invalid]
      a["regions"] = [r]
      changed["nativeAuthorities"] = [a]
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.decode(
          JSONSerialization.data(withJSONObject: changed), limits: .standard)
      }
    }
  }

  @Test func ownershipAndCreationRequireSurvivingDescendants() throws {
    let original = fixture()
    var valid = original
    valid.deployments.append(original.deployments[0])
    valid.deployments[1].id = "second"
    valid.lowerings[0].deployments.append("second")
    valid.nativeAuthorities![0].regions[0].deployments.append("second")
    valid.nativeAuthorities![0].createdContainers[0].deployments.append("second")
    _ = try encoded(valid)
    for failure in 0..<12 {
      var ledger = original
      switch failure {
      case 0: ledger.nativeAuthorities![0].regions[0].deployments = []
      case 1: ledger.nativeAuthorities![0].regions[0].deployments = ["missing"]
      case 2: ledger.nativeAuthorities![0].regions[0].deployments.append("deployment")
      case 3: ledger.deployments[0].target.path = "other.json"
      case 4: ledger.deployments[0].ownership = .generated
      case 5: ledger.nativeAuthorities![0].createdContainers[0].path = []
      case 6: ledger.nativeAuthorities![0].createdContainers[0].path = [.key("other")]
      case 7: ledger.nativeAuthorities![0].createdContainers[0].kind = "object"
      case 8: ledger.nativeAuthorities![0].regions = []
      case 9: ledger.nativeAuthorities![0].createdContainers[0].deployments = []
      case 10:
        ledger = valid
        ledger.nativeAuthorities![0].regions[0].deployments = ["deployment"]
      default:
        ledger.nativeAuthorities![0].createdContainers[0].path =
          ledger.nativeAuthorities![0].regions[0].path
      }
      #expect(throws: (any Error).self) { _ = try encoded(ledger) }
    }
  }

  @Test func closedVersionsFormatsAndOrdinalEvidence() throws {
    for failure in 0..<7 {
      var ledger = fixture()
      switch failure {
      case 0: ledger.nativeAuthorities![0].version = 2
      case 1: ledger.nativeAuthorities![0].targetRoute = "arbitrary.route"
      case 2: ledger.nativeAuthorities![0].documentFormat = "yaml"
      case 3:
        ledger.nativeAuthorities![0].regions[0].path[1] = .position(index: -1, evidence: semantic)
      case 4:
        ledger.nativeAuthorities![0].regions[0].path[1] = .position(
          index: 0, evidence: .semantic(format: "native-array@2", digest: hash))
      case 5:
        ledger.nativeAuthorities![0].regions[0].path[1] = .position(
          index: 0, evidence: .semantic(format: "native-array@1", digest: "bad"))
      default:
        ledger.nativeAuthorities![0].target = .init(
          kind: .authoringRelative, root: "project", path: "x")
      }
      #expect(throws: (any Error).self) { _ = try encoded(ledger) }
    }
    for format in ["json", "jsonc", "jsonc-trailing-commas", "toml"] {
      var ledger = fixture()
      ledger.nativeAuthorities![0].documentFormat = format
      _ = try encoded(ledger)
    }
  }

  @Test func duplicateLocationsAndContradictoryArrayPreimagesFail() throws {
    for failure in 0..<5 {
      var ledger = fixture()
      switch failure {
      case 0: ledger.nativeAuthorities!.append(ledger.nativeAuthorities![0])
      case 1: ledger.nativeAuthorities![0].regions.append(ledger.nativeAuthorities![0].regions[0])
      case 2:
        ledger.nativeAuthorities![0].createdContainers.append(
          ledger.nativeAuthorities![0].createdContainers[0])
      case 3:
        ledger.nativeAuthorities![0].regions.append(
          .init(
            deployments: ["deployment"],
            path: [.key("hooks"), .position(index: 0, evidence: .privateArray(token: UUID()))]))
      default:
        ledger.nativeAuthorities![0].regions.append(
          .init(
            deployments: ["deployment"], path: [.key("hooks"), .key("not-an-array")]))
      }
      #expect(throws: (any Error).self) { _ = try encoded(ledger) }
    }
    var distinct = fixture()
    distinct.nativeAuthorities![0].regions.append(
      .init(
        deployments: ["deployment"], path: [.key("hooks"), .position(index: 0, evidence: semantic)])
    )
    _ = try encoded(distinct)
  }

  @Test func nativeStringsAreByteExactAcrossKeysAndStableIDs() throws {
    let composed = "é"
    let decomposed = "e\u{301}"
    #expect(composed == decomposed)
    var ledger = fixture()
    ledger.nativeAuthorities![0].createdContainers = []
    ledger.nativeAuthorities![0].regions = [composed, decomposed].flatMap { value in
      [
        .init(deployments: ["deployment"], path: [.key(value)]),
        .init(
          deployments: ["deployment"], path: [.key("items"), .stableID(key: "id", value: value)]),
      ] as [LedgerNativeOwnedRegion]
    }
    let encoded = try encoded(ledger)
    #expect(try ResolvedLedgerCodec.decode(encoded, limits: .standard) == ledger)
    var changed = ledger
    changed.nativeAuthorities![0].regions[0].path = [.key(decomposed)]
    #expect(changed != ledger)
    #expect(
      LedgerNativePathStep.stableID(key: composed, value: "x")
        != .stableID(key: decomposed, value: "x"))
    var mismatch = fixture()
    mismatch.deployments[0].id = composed
    mismatch.lowerings[0].deployments = [composed]
    mismatch.nativeAuthorities![0].regions[0].deployments = [composed]
    mismatch.nativeAuthorities![0].createdContainers[0].deployments = [composed]
    _ = try self.encoded(mismatch)
    mismatch.nativeAuthorities![0].regions[0].deployments = [decomposed]
    #expect(throws: (any Error).self) { _ = try self.encoded(mismatch) }
    var target = fixture()
    target.deployments[0].target.path = composed
    target.nativeAuthorities![0].target.path = composed
    _ = try self.encoded(target)
    target.nativeAuthorities![0].target.path = decomposed
    #expect(throws: (any Error).self) { _ = try self.encoded(target) }
  }

  @Test func authoritySharesAggregateModelAndWireBudgets() throws {
    var ledger = fixture()
    ledger.nativeAuthorities![0].createdContainers = []
    // Exercise the codec boundary with a budget measured from the actual encoded object graph.
    func nodes(_ value: Any) -> Int {
      if let object = value as? [String: Any] {
        return 1 + object.values.reduce(0) { $0 + nodes($1) }
      }
      if let array = value as? [Any] { return 1 + array.reduce(0) { $0 + nodes($1) } }
      return 1
    }
    let bytes = try encoded(ledger)
    let count = nodes(try JSONSerialization.jsonObject(with: bytes))
    var limits = LedgerLimits.standard
    limits.nodes = count
    limits.encodedBytes = bytes.count
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: limits) == ledger)
    limits.nodes -= 1
    #expect(throws: (any Error).self) { _ = try ResolvedLedgerCodec.encode(ledger, limits: limits) }
    limits = .standard
    limits.nodes = 16
    ledger.nativeAuthorities![0].regions = (0..<20).map {
      .init(deployments: ["deployment"], path: [.key("key-\($0)")])
    }
    #expect(throws: (any Error).self) { try ResolvedLedgerCodec.checkModel(ledger, limits: limits) }
    limits = .standard
    limits.depth = 8
    ledger.nativeAuthorities![0].regions = [
      .init(deployments: ["deployment"], path: (0..<8).map { .key("\($0)") })
    ]
    #expect(throws: (any Error).self) { try ResolvedLedgerCodec.checkModel(ledger, limits: limits) }
  }
}
