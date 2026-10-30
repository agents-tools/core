import AgentsDescription

final class EvaluatedValue: Sendable {
  enum Representation: Sendable {
    case scalarLiteral, collectionLiteral, construction, reference, synthetic
  }
  let representation: Representation
  let type: ConstructionType
  let value: ConstructionValue
  let cost: ValueCost
  let syntax: Int
  let fields: [String: EvaluatedValue]
  let elements: [EvaluatedValue]
  let referent: EvaluatedValue?
  let defaulted: Bool
  let referenceDepth: Int

  init(
    type: ConstructionType, value: ConstructionValue, cost: ValueCost, syntax: Int,
    fields: [String: EvaluatedValue] = [:], elements: [EvaluatedValue] = [],
    referent: EvaluatedValue? = nil, defaulted: Bool = false,
    representation: Representation = .construction
  ) {
    self.representation = representation
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

extension EvaluatedValue {
  var elementsForUse: [EvaluatedValue] {
    var value = self
    while let next = value.referent { value = next }
    return value.elements
  }
  func field(_ name: String) -> EvaluatedValue? { referent?.field(name) ?? fields[name] }
}
