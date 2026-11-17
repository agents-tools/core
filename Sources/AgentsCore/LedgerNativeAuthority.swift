import Foundation

/// Evidence for one admitted native document. Physical admission and continuity belong to D/E/F.
package struct LedgerNativeAuthority: Codable, Equatable, Sendable {
  package var version: Int = 1
  package var target: LedgerLocation
  package var targetRoute: String
  /// Closed dialects: json, jsonc, jsonc-trailing-commas, toml. JSONC alone forbids trailing commas.
  package var documentFormat: String
  package var regions: [LedgerNativeOwnedRegion]
  package var createdContainers: [LedgerNativeCreatedContainer]

  package init(
    target: LedgerLocation, targetRoute: String, documentFormat: String,
    regions: [LedgerNativeOwnedRegion], createdContainers: [LedgerNativeCreatedContainer] = []
  ) {
    self.target = target
    self.targetRoute = targetRoute
    self.documentFormat = documentFormat
    self.regions = regions
    self.createdContainers = createdContainers
  }

  package static func == (a: Self, b: Self) -> Bool {
    a.version == b.version && a.target.kind == b.target.kind
      && a.target.root.map { Data($0.utf8) } == b.target.root.map { Data($0.utf8) }
      && Data(a.target.path.utf8) == Data(b.target.path.utf8)
      && Data(a.targetRoute.utf8) == Data(b.targetRoute.utf8)
      && Data(a.documentFormat.utf8) == Data(b.documentFormat.utf8)
      && a.regions == b.regions && a.createdContainers == b.createdContainers
  }
}

package struct LedgerNativeOwnedRegion: Codable, Equatable, Sendable {
  package var deployments: [String]
  package var path: [LedgerNativePathStep]
  package init(deployments: [String], path: [LedgerNativePathStep]) {
    self.deployments = deployments
    self.path = path
  }
  package static func == (a: Self, b: Self) -> Bool {
    a.deployments.map { Data($0.utf8) } == b.deployments.map { Data($0.utf8) }
      && a.path == b.path
  }
}

package struct LedgerNativeCreatedContainer: Codable, Equatable, Sendable {
  package var deployments: [String]
  package var path: [LedgerNativePathStep]
  package var kind: String
  package init(deployments: [String], path: [LedgerNativePathStep], kind: String) {
    self.deployments = deployments
    self.path = path
    self.kind = kind
  }
  package static func == (a: Self, b: Self) -> Bool {
    a.deployments.map { Data($0.utf8) } == b.deployments.map { Data($0.utf8) }
      && a.path == b.path && Data(a.kind.utf8) == Data(b.kind.utf8)
  }
}

/// Decoded native strings retain UTF-8 identity; these are not filesystem paths.
package enum LedgerNativePathStep: Codable, Equatable, Sendable {
  case key(String)
  case stableID(key: String, value: String)
  case position(index: Int, evidence: LedgerNativeArrayEvidence)

  private enum CodingKeys: String, CodingKey { case kind, key, value, index, evidence }
  private enum Kind: String, Codable { case key, stableID, position }

  package init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try fields.decode(Kind.self, forKey: .kind)
    let allowed: Set<CodingKeys>
    switch kind {
    case .key:
      allowed = [.kind, .key]
      self = .key(try fields.decode(String.self, forKey: .key))
    case .stableID:
      allowed = [.kind, .key, .value]
      self = .stableID(
        key: try fields.decode(String.self, forKey: .key),
        value: try fields.decode(String.self, forKey: .value))
    case .position:
      allowed = [.kind, .index, .evidence]
      self = .position(
        index: try fields.decode(Int.self, forKey: .index),
        evidence: try fields.decode(LedgerNativeArrayEvidence.self, forKey: .evidence))
    }
    guard Set(fields.allKeys).isSubset(of: allowed) else {
      throw CoreError.invalidState("invalid native path fields")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .key(let key):
      try fields.encode(Kind.key, forKey: .kind)
      try fields.encode(key, forKey: .key)
    case .stableID(let key, let value):
      try fields.encode(Kind.stableID, forKey: .kind)
      try fields.encode(key, forKey: .key)
      try fields.encode(value, forKey: .value)
    case .position(let index, let evidence):
      try fields.encode(Kind.position, forKey: .kind)
      try fields.encode(index, forKey: .index)
      try fields.encode(evidence, forKey: .evidence)
    }
  }

  package static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.key(let x), .key(let y)): x.utf8.elementsEqual(y.utf8)
    case (.stableID(let x, let y), .stableID(let u, let v)):
      x.utf8.elementsEqual(u.utf8) && y.utf8.elementsEqual(v.utf8)
    case (.position(let x, let y), .position(let u, let v)): x == u && y == v
    default: false
    }
  }
}

/// Semantic digests are non-secret. Private tokens contain no array values or secret digests.
package enum LedgerNativeArrayEvidence: Codable, Equatable, Sendable {
  case semantic(format: String, digest: String)
  case privateArray(token: UUID)

  private enum CodingKeys: String, CodingKey { case kind, format, digest, token }
  private enum Kind: String, Codable { case semantic, privateArray }

  package init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try fields.decode(Kind.self, forKey: .kind)
    let allowed: Set<CodingKeys>
    switch kind {
    case .semantic:
      allowed = [.kind, .format, .digest]
      self = .semantic(
        format: try fields.decode(String.self, forKey: .format),
        digest: try fields.decode(String.self, forKey: .digest))
    case .privateArray:
      allowed = [.kind, .token]
      self = .privateArray(token: try fields.decode(UUID.self, forKey: .token))
    }
    guard Set(fields.allKeys).isSubset(of: allowed) else {
      throw CoreError.invalidState("invalid native array evidence fields")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .semantic(let format, let digest):
      try fields.encode(Kind.semantic, forKey: .kind)
      try fields.encode(format, forKey: .format)
      try fields.encode(digest, forKey: .digest)
    case .privateArray(let token):
      try fields.encode(Kind.privateArray, forKey: .kind)
      try fields.encode(token, forKey: .token)
    }
  }

  package static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.semantic(let x, let y), .semantic(let u, let v)):
      x.utf8.elementsEqual(u.utf8) && y.utf8.elementsEqual(v.utf8)
    case (.privateArray(let x), .privateArray(let y)): x == y
    default: false
    }
  }
}
