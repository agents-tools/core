import AgentsDescription

enum LiteralConversionError: Error {
  case incompatible, invalidVersion

  var code: String { self == .invalidVersion ? "manifest.domain" : "manifest.type" }
  var message: String {
    self == .invalidVersion ? "invalid semantic version" : "literal needs a compatible context"
  }
}

/// Closed literal conversions shared by static evaluation and domain edits.
/// Already constructed children keep their type; referenced expressions never enter this algebra.
enum LiteralConversion {
  static func kind(of value: ConstructionValue) -> LiteralKind? {
    switch value {
    case .text: .string
    case .integer: .integer
    case .boolean: .boolean
    case .none: .nilLiteral
    case .array: .array
    case .object: .dictionary
    default: nil
    }
  }

  static func elementType(
    for kind: LiteralKind, context: ConstructionType?
  ) throws -> ConstructionType? {
    guard let context = context?.unwrapped else { return nil }
    let payload: ConstructionType
    if case .named(let name) = context {
      guard let type = Vocabulary.literalConstructions[name]?[kind]?.payloadType else {
        throw LiteralConversionError.incompatible
      }
      payload = type
    } else {
      payload = context
    }
    switch (kind, payload) {
    case (.array, .array(let element)), (.dictionary, .dictionary(let element)): return element
    default: throw LiteralConversionError.incompatible
    }
  }

  static func convert(
    _ value: ConstructionValue, to context: ConstructionType,
    charge: () throws -> Void = {}
  ) throws -> ConstructionValue {
    try charge()
    if case .optional(let wrapped) = context {
      return value == .none ? .none : try convert(value, to: wrapped, charge: charge)
    }
    switch (value, context) {
    case (.text, .named("String")), (.integer, .named("Int")), (.boolean, .named("Bool")):
      return value
    case (.node(let type, _, _), .named(let expected)) where type == expected: return value
    case (.array(let values), .array(let element)):
      return .array(try values.map { try convert($0, to: element, charge: charge) })
    case (.object(let fields), .dictionary(let element)):
      return .object(try fields.mapValues { try convert($0, to: element, charge: charge) })
    case (.text(let text), .named("Version")):
      let version = Version(stringLiteral: text)
      guard version.valid else { throw LiteralConversionError.invalidVersion }
      return .version(version)
    default: break
    }
    guard case .named(let name) = context, let kind = kind(of: value),
      let construction = Vocabulary.literalConstructions[name]?[kind]
    else { throw LiteralConversionError.incompatible }
    var fields = construction.defaults
    if let key = construction.payload, let type = construction.payloadType {
      fields[key] = try convert(value, to: type, charge: charge)
    }
    return .node(type: name, member: construction.member, fields: fields)
  }
}
