import Foundation

/// Private document coordinates, not edit instructions or filesystem authority.
package enum PrivateNativeAddressStep: Codable, Equatable, Sendable {
  case key(String)
  case stableID(key: String, value: String)
  case position(index: Int)

  private enum CodingKeys: String, CodingKey { case kind, key, value, index }
  package init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    switch try fields.decode(String.self, forKey: .kind) {
    case "key":
      try ReceiptFields.require(decoder, ["kind", "key"])
      self = .key(try fields.decode(String.self, forKey: .key))
    case "stableID":
      try ReceiptFields.require(decoder, ["kind", "key", "value"])
      self = .stableID(
        key: try fields.decode(String.self, forKey: .key),
        value: try fields.decode(String.self, forKey: .value))
    case "position":
      try ReceiptFields.require(decoder, ["kind", "index"])
      self = .position(index: try fields.decode(Int.self, forKey: .index))
    default: throw CoreError.invalidState("unsupported private array address")
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .key(let key):
      try fields.encode("key", forKey: .kind)
      try fields.encode(key, forKey: .key)
    case .stableID(let key, let value):
      try fields.encode("stableID", forKey: .kind)
      try fields.encode(key, forKey: .key)
      try fields.encode(value, forKey: .value)
    case .position(let index):
      try fields.encode("position", forKey: .kind)
      try fields.encode(index, forKey: .index)
    }
  }
  package static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.key(let a), .key(let b)): return Data(a.utf8) == Data(b.utf8)
    case (.stableID(let ak, let av), .stableID(let bk, let bv)):
      return Data(ak.utf8) == Data(bk.utf8) && Data(av.utf8) == Data(bv.utf8)
    case (.position(let a), .position(let b)): return a == b
    default: return false
    }
  }
}

/// Only the private receipt encodes this evidence. Diagnostic reflection is redacted.
package struct PrivateNativeArrayRecord: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  package let path: [PrivateNativeAddressStep]
  package let documentFormat: String
  package let token: UUID
  package let semanticFormat: String
  package let semanticDigest: String
  package var description: String { "<private native array>" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }

  package init(
    path: [PrivateNativeAddressStep], documentFormat: String, token: UUID,
    semanticFormat: String = "native-array@1", semanticDigest: String
  ) {
    self.path = path
    self.documentFormat = documentFormat
    self.token = token
    self.semanticFormat = semanticFormat
    self.semanticDigest = semanticDigest
  }
  private enum CodingKeys: String, CodingKey {
    case path, documentFormat, token, semanticFormat, semanticDigest
  }
  package init(from decoder: any Decoder) throws {
    try ReceiptFields.require(
      decoder, ["path", "documentFormat", "token", "semanticFormat", "semanticDigest"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    path = try c.decode([PrivateNativeAddressStep].self, forKey: .path)
    documentFormat = try c.decode(String.self, forKey: .documentFormat)
    token = try c.decode(UUID.self, forKey: .token)
    semanticFormat = try c.decode(String.self, forKey: .semanticFormat)
    semanticDigest = try c.decode(String.self, forKey: .semanticDigest)
  }
}

/// E/F supplies same-edit structural proof; Core validates coverage and the sealed preimage.
package struct PrivateNativeArrayTransition {
  package let previous: PrivateNativeArrayRecord?
  package let current: PrivateNativeArrayRecord?
  package init(previous: PrivateNativeArrayRecord?, current: PrivateNativeArrayRecord?) {
    self.previous = previous
    self.current = current
  }
}

/// Ephemeral actual render output. It has no encoding or payload diagnostic representation.
package struct PrivateMaterializationResult: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let bytes: Data
  let nativeArrayTransitions: [PrivateNativeArrayTransition]?
  package init(bytes: Data, nativeArrayTransitions: [PrivateNativeArrayTransition]? = nil) {
    self.bytes = bytes
    self.nativeArrayTransitions = nativeArrayTransitions
  }
  package var description: String { "<private materialization result>" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

/// Unknown fields, including null, are rejected before decoding receipt records.
enum ReceiptFields {
  private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  static func require(_ decoder: any Decoder, _ allowed: Set<String>) throws {
    let fields = try decoder.container(keyedBy: Key.self)
    guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw CoreError.invalidState("invalid private receipt fields")
    }
  }
}

extension PrivateNativeArrayRecord {
  static func validate(_ records: [Self]) throws {
    guard records.count <= LedgerLimits.standard.entries else {
      throw CoreError.invalidState("private array records exceed limits")
    }
    let bytes = try StateStore.encode(records)
    try LedgerAdmission.check(bytes, limits: .standard)
    var paths = Set<Data>()
    var tokens = Set<UUID>()
    for record in records {
      guard ["json", "jsonc", "jsonc-trailing-commas", "toml"].contains(record.documentFormat),
        record.documentFormat == records.first?.documentFormat,
        record.semanticFormat == "native-array@1",
        record.path.count <= LedgerLimits.standard.depth,
        tokens.insert(record.token).inserted,
        paths.insert(try StateStore.encode(record.path)).inserted
      else { throw CoreError.invalidState("invalid private array record") }
      for step in record.path {
        if case .position(let index) = step, index < 0 {
          throw CoreError.invalidState("invalid private array address")
        }
      }
      guard record.semanticDigest.utf8.count == 71,
        record.semanticDigest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression)
          != nil
      else {
        throw CoreError.invalidState("invalid private array digest")
      }
    }
  }

  static func applying(
    _ result: PrivateMaterializationResult, previous: MaterializationReceipts.Record?,
    admitted: Bool, hasPreimage: Bool = true
  ) throws -> [Self]? {
    let old = previous?.nativeArrays ?? []
    guard let transitions = result.nativeArrayTransitions else {
      guard
        old.isEmpty || (hasPreimage && previous?.digest == FileHash.sha256Hex(data: result.bytes))
      else {
        throw CoreError.invalidState("changed tracked file requires complete array transitions")
      }
      return previous?.nativeArrays
    }
    guard admitted else {
      throw CoreError.invalidState("array transitions require a registered native file")
    }
    guard transitions.count <= LedgerLimits.standard.entries else {
      throw CoreError.invalidState("private array transitions exceed limits")
    }
    var oldByToken: [UUID: Self] = [:]
    for record in old {
      guard oldByToken.updateValue(record, forKey: record.token) == nil else {
        throw CoreError.invalidState("duplicate private array records")
      }
    }
    var covered = Set<UUID>()
    var next: [Self] = []
    for transition in transitions {
      guard transition.previous != nil || transition.current != nil else {
        throw CoreError.invalidState("empty private array transition")
      }
      if let before = transition.previous {
        guard oldByToken[before.token] == before, covered.insert(before.token).inserted else {
          throw CoreError.invalidState(
            "private array transition does not match the current receipt")
        }
      }
      if let after = transition.current {
        if let existing = oldByToken[after.token] {
          guard hasPreimage, transition.previous == existing, after == existing else {
            throw CoreError.invalidState("changed private array requires a new continuity token")
          }
        }
        next.append(after)
      }
    }
    guard covered == Set(old.map(\.token)) else {
      throw CoreError.invalidState("incomplete private array transitions")
    }
    try validate(next)
    return next.isEmpty ? nil : next
  }
}
