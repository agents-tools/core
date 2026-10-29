import AgentsDescription

package struct ValueCost: Sendable {
  package var nodes = 1
  package var strings = 0
  package var encoded = 16
  package var depth = 1
  package var origins = 1

  package static func scalar(_ text: String = "") -> Self {
    var encoded = 2
    for byte in text.utf8 {
      encoded += byte < 32 ? 6 : (byte == 34 || byte == 92 ? 2 : 1)
    }
    return Self(strings: text.utf8.count, encoded: encoded)
  }

  package static func container(_ children: [ValueCost], keys: [String] = []) -> Self {
    var result = Self()
    for child in children {
      result.nodes = add(result.nodes, child.nodes)
      result.strings = add(result.strings, child.strings)
      result.encoded = add(result.encoded, add(child.encoded, 4 + child.nodes * 2))
      result.origins = add(result.origins, child.origins)
      result.depth = max(result.depth, child.depth + 1)
    }
    for key in keys {
      let cost = scalar(key)
      result.strings = add(result.strings, cost.strings)
      result.encoded = add(result.encoded, cost.encoded + 4)
    }
    return result
  }

  package var fits: Bool {
    nodes <= 100_000 && strings <= 16_777_216 && encoded <= 33_554_432
      && depth <= 64 && origins <= 1_000_000
  }

  package static func add(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? 33_554_433 : min(result, 33_554_433)
  }
}

package final class EvaluatedValue: Sendable {
  package let type: ConstructionType
  package let value: ConstructionValue
  package let cost: ValueCost
  package let syntax: Int
  package let fields: [String: EvaluatedValue]
  package let elements: [EvaluatedValue]
  package let referent: EvaluatedValue?
  package let defaulted: Bool
  package let referenceDepth: Int

  package init(
    type: ConstructionType, value: ConstructionValue, cost: ValueCost, syntax: Int,
    fields: [String: EvaluatedValue] = [:], elements: [EvaluatedValue] = [],
    referent: EvaluatedValue? = nil, defaulted: Bool = false
  ) {
    self.type = type
    self.value = value
    self.cost = cost
    self.syntax = syntax
    self.fields = fields
    self.elements = elements
    self.referent = referent
    self.defaulted = defaulted
    referenceDepth = (referent?.referenceDepth ?? 0) + (referent == nil ? 0 : 1)
  }
}

package func constructionCost(_ value: ConstructionValue) -> ValueCost {
  switch value {
  case .text(let text): return .scalar(text)
  case .version(let version): return .scalar(version.normalized)
  case .range(let range):
    return .container([.scalar(range.lowerBound.normalized), .scalar(range.upperBound.normalized)])
  case .array(let values): return .container(values.map(constructionCost))
  case .object(let fields):
    return .container(fields.values.map(constructionCost), keys: Array(fields.keys))
  case .node(let type, let member, let fields):
    return .container(
      fields.values.map(constructionCost), keys: [type, member] + Array(fields.keys))
  case .none, .integer, .boolean: return ValueCost()
  }
}
