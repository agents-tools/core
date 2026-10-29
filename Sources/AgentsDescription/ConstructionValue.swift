package indirect enum ConstructionType: Sendable, Hashable {
  /// No contextual type: nil literals and synthesized provenance fields.
  case untyped
  case named(String)
  case array(ConstructionType)
  case dictionary(ConstructionType)
  case optional(ConstructionType)

  package var unwrapped: ConstructionType {
    if case .optional(let type) = self { return type }
    return self
  }
}

package struct ConstructionParameter: Sendable {
  package let label: String
  package let name: String
  package let type: ConstructionType
  package let defaultValue: ConstructionValue?
  package let defaultExpression: String?
}

package struct ConstructionSignature: Sendable {
  package let type: String
  package let member: String
  package let parameters: [ConstructionParameter]
  package let callable: Bool
}

package enum LiteralKind: String, Sendable, Hashable {
  case string, integer, boolean, array, dictionary
  case nilLiteral = "nil"
}

package struct LiteralConstruction: Sendable {
  package let member: String
  package let payload: String?
  package let payloadType: ConstructionType?
  package let defaults: [String: ConstructionValue]
}

package indirect enum ConstructionValue: Sendable, Equatable {
  case text(String)
  case integer(Int)
  case boolean(Bool)
  case none
  case array([ConstructionValue])
  case object([String: ConstructionValue])
  case node(type: String, member: String, fields: [String: ConstructionValue])
  case version(Version)
  case range(Range<Version>)

  package static func construct(
    type: String, member: String, fields: [String: ConstructionValue]
  ) -> Self {
    if type == "GroupReference" {
      var result = fields
      if result["source"] == nil { result["source"] = ConstructionValue.none }
      return .node(type: type, member: member, fields: result)
    }
    if type == "Source" {
      var result = fields
      if case .version(let lower) = result.removeValue(forKey: "from") {
        result["requirement"] = .range(.upToNextMajor(from: lower))
      } else if let range = result.removeValue(forKey: "range") {
        result["requirement"] = range
      } else if let exact = result.removeValue(forKey: "exact") {
        let value: ConstructionValue
        if case .version(let version) = exact {
          value = .text(version.normalized)
        } else {
          value = exact
        }
        result["requirement"] = .node(
          type: "Requirement", member: "exact", fields: ["value": value])
      } else if let branch = result.removeValue(forKey: "branch") {
        result["requirement"] = .node(
          type: "Requirement", member: "branch", fields: ["value": branch])
      } else if let revision = result.removeValue(forKey: "revision") {
        result["requirement"] = .node(
          type: "Requirement", member: "revision", fields: ["value": revision])
      } else {
        result["requirement"] = ConstructionValue.none
      }
      return .node(type: type, member: member, fields: result)
    }
    if type == "VersionRange", case .version(let lower) = fields["from"] {
      return .range(
        member == "upToNextMajor" ? .upToNextMajor(from: lower) : .upToNextMinor(from: lower))
    }
    return .node(type: type, member: member, fields: fields)
  }
}

package protocol ConstructionRepresentable {
  var constructionValue: ConstructionValue { get }
}
extension String: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .text(self) }
}
extension Int: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .integer(self) }
}
extension Bool: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .boolean(self) }
}
extension Optional: ConstructionRepresentable where Wrapped: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { self?.constructionValue ?? .none }
}
extension Array: ConstructionRepresentable where Element: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .array(map(\.constructionValue)) }
}
extension Dictionary: ConstructionRepresentable
where Key == String, Value: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .object(mapValues(\.constructionValue)) }
}
extension Range: ConstructionRepresentable where Bound == Version {
  package var constructionValue: ConstructionValue { .range(self) }
}
