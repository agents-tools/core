/// Syntax-independent declaration data. Collections retain authored order; recipients are IDs,
/// conditions remain data, and group references are symbolic until linking.
public indirect enum DeclarationValue: Sendable, Equatable {
  case string(String)
  case integer(Int)
  case boolean(Bool)
  case null
  case array([DeclarationValue])
  case dictionary([String: DeclarationValue])
  case record(DeclarationRecord)
  case requirement(SourceRequirement)

  public static func == (lhs: DeclarationValue, rhs: DeclarationValue) -> Bool {
    switch (lhs, rhs) {
    case (.string(let a), .string(let b)): return a == b
    case (.integer(let a), .integer(let b)): return a == b
    case (.boolean(let a), .boolean(let b)): return a == b
    case (.null, .null): return true
    case (.array(let a), .array(let b)): return a == b
    case (.dictionary(let a), .dictionary(let b)): return a == b
    case (.record(let a), .record(let b)): return a == b
    case (.requirement(let a), .requirement(let b)): return a.declarationEquivalent(to: b)
    default: return false
    }
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var elements: [DeclarationValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var record: DeclarationRecord? {
    if case .record(let value) = self { return value }
    return nil
  }
}

/// A tagged domain value. No field contains a deployment path or a syntax node.
public struct DeclarationRecord: Sendable, Equatable {
  public let kind: String
  public let fields: [String: DeclarationValue]

  public init(kind: String, fields: [String: DeclarationValue]) {
    self.kind = kind
    self.fields = fields
  }

  public subscript(_ field: String) -> DeclarationValue? { fields[field] }
}

public struct DeclarationIR: Sendable, Equatable {
  public let defaultAgents: [String]?
  public let exports: [String]
  public let sources: [DeclarationRecord]
  public let components: [DeclarationRecord]
  public let groups: [DeclarationRecord]
  public let uses: [DeclarationRecord]
  public let watch: [String]

  public init(
    defaultAgents: [String]? = nil, exports: [String] = [], sources: [DeclarationRecord] = [],
    components: [DeclarationRecord] = [], groups: [DeclarationRecord] = [],
    uses: [DeclarationRecord] = [], watch: [String] = []
  ) {
    self.defaultAgents = defaultAgents
    self.exports = exports
    self.sources = sources
    self.components = components
    self.groups = groups
    self.uses = uses
    self.watch = watch
  }
}
