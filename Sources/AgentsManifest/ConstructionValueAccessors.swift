import AgentsDescription

extension ConstructionValue {
  var text: String? {
    if case .text(let value) = self { return value }
    return nil
  }
  var array: [ConstructionValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
  var strings: [String]? { array?.compactMap(\.text) }
  var fields: [String: ConstructionValue] {
    if case .node(_, _, let fields) = self { return fields }
    return [:]
  }
  var member: String {
    if case .node(_, let member, _) = self { return member }
    return ""
  }
}
