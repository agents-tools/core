import AgentsDescription

package struct Evaluation: Sendable {
  package let root: EvaluatedValue
  package let constants: [String: EvaluatedValue]
  package let expressions: [Int: EvaluatedValue]
  package let references: [String: [Int]]
  package let steps: Int
  package let total: ValueCost
}

package final class Evaluator {
  private let source: SourceText
  private let admission: Admission
  private let replacements: [String: StaticValue]
  private var constants: [String: EvaluatedValue] = [:]
  private var expressions: [Int: EvaluatedValue] = [:]
  private var references: [String: [Int]] = [:]
  private var steps = 0
  private var frames = 0
  private var total = ValueCost(nodes: 0, strings: 0, encoded: 0, depth: 0, origins: 0)

  package init(source: SourceText, admission: Admission, replacements: [String: StaticValue] = [:])
  {
    self.source = source
    self.admission = admission
    self.replacements = replacements
  }

  private func fail(_ code: String, _ message: String, _ id: Int) -> ManifestFailure {
    source.failure(
      code, message, admission.nodes[id].range.lowerBound, end: admission.nodes[id].range.upperBound
    )
  }
  private func charge(_ amount: Int = 1, at id: Int) throws {
    guard amount <= 100_000 - steps else {
      throw fail("manifest.limit", "evaluation work steps", id)
    }
    steps += amount
  }
  private func check(_ cost: ValueCost, at id: Int) throws {
    guard cost.fits else {
      throw fail("manifest.limit", "expanded value budget (nodes, bytes, depth or origins)", id)
    }
  }

  package func evaluate() throws -> Evaluation {
    for declaration in admission.declarations {
      if constants[declaration.name] != nil || Vocabulary.typeNames.contains(declaration.name) {
        throw source.failure(
          "manifest.reference", "duplicate or shadowing constant", declaration.nameRange.lowerBound,
          end: declaration.nameRange.upperBound)
      }
      let value: EvaluatedValue
      if let replacement = replacements[declaration.name] {
        let cost = constructionCost(replacement.value)
        try check(cost, at: declaration.expression)
        value = EvaluatedValue(
          type: replacement.type, value: replacement.value, cost: cost,
          syntax: declaration.expression)
      } else {
        value = try evaluate(declaration.expression, context: declaration.type)
      }
      try check(value.cost, at: declaration.expression)
      let next = ValueCost(
        nodes: ValueCost.add(total.nodes, value.cost.nodes),
        strings: ValueCost.add(total.strings, value.cost.strings),
        encoded: ValueCost.add(total.encoded, value.cost.encoded),
        depth: max(total.depth, value.cost.depth),
        origins: ValueCost.add(total.origins, value.cost.origins))
      try check(next, at: declaration.expression)
      total = next
      constants[declaration.name] = value
    }
    guard let root = constants["agents"], root.type == .named("Agents"),
      let declaration = admission.declarations.first(where: { $0.name == "agents" }),
      admission.nodes[declaration.expression].kind == "call",
      admission.nodes[declaration.expression].text == "Agents"
    else {
      throw source.failure(
        "manifest.type", "one let agents = Agents(...) is required", source.bytes.count)
    }
    return Evaluation(
      root: root, constants: constants, expressions: expressions, references: references,
      steps: steps, total: total)
  }

  private func evaluate(_ id: Int, context: ConstructionType?) throws -> EvaluatedValue {
    try charge(at: id)
    frames += 1
    defer { frames -= 1 }
    guard frames <= 64 else { throw fail("manifest.limit", "evaluation frames", id) }
    let node = admission.nodes[id]
    let expected = context?.unwrapped
    let result: EvaluatedValue
    if node.kind == "nil", case .optional = context {
      result = EvaluatedValue(type: context!, value: .none, cost: ValueCost(), syntax: id)
    } else {
      switch node.kind {
      case "group":
        let child = try evaluate(node.children[0], context: context)
        result = EvaluatedValue(
          type: child.type, value: child.value, cost: child.cost, syntax: id, referent: child)
      case "string":
        result = try literal(
          .text(node.text), kind: "string", inferred: "String", context: expected, id: id)
      case "integer", "negative":
        let raw = (node.kind == "negative" ? "-" : "") + node.text.filter { $0 != "_" }
        guard let integer = Int(raw) else {
          throw fail("manifest.type", "integer literal must fit signed 64-bit Int", id)
        }
        result = try literal(
          .integer(integer), kind: "integer", inferred: "Int", context: expected, id: id)
      case "boolean":
        result = try literal(
          .boolean(node.text == "true"), kind: "boolean", inferred: "Bool", context: expected,
          id: id)
      case "nil":
        result = try literal(.none, kind: "nil", inferred: "", context: expected, id: id)
      case "array", "dictionary": result = try collection(id, context: expected)
      case "sequence":
        var arrayType = expected
        if let expected, case .array = expected {
        } else if expected != nil {
          throw fail("manifest.operator", "+ requires exact Swift array operands", id)
        }
        var operands: [EvaluatedValue] = []
        var count = 0
        var costs: [ValueCost] = []
        for child in node.children {
          let value = try evaluate(child, context: arrayType)
          guard case .array = value.type, case .array = value.value else {
            throw fail("manifest.operator", "+ requires exact Swift arrays", child)
          }
          arrayType = value.type
          count += value.elementsForUse.count
          if count > 10_000 { throw fail("manifest.limit", "concatenation entries", id) }
          // Cost is combined before copying any concatenated elements.
          operands.append(value)
          costs.append(contentsOf: value.elementsForUse.map(\.cost))
        }
        let cost = ValueCost.container(costs)
        try check(cost, at: id)
        try charge(count, at: id)
        let elements = operands.flatMap(\.elementsForUse)
        result = EvaluatedValue(
          type: arrayType!, value: .array(elements.map(\.value)), cost: cost, syntax: id,
          elements: elements)
      case "range":
        let lower = try evaluate(node.children[0], context: .named("Version"))
        let upper = try evaluate(node.children[1], context: .named("Version"))
        guard case .version(let l) = lower.value, case .version(let u) = upper.value, l < u else {
          throw fail("manifest.domain", "version range must be increasing", id)
        }
        let cost = ValueCost.container([lower.cost, upper.cost])
        try check(cost, at: id)
        result = EvaluatedValue(
          type: .named("VersionRange"), value: .range(l..<u), cost: cost, syntax: id,
          elements: [lower, upper])
      case "name", "call":
        if node.kind == "name", !node.text.contains(".") {
          try charge(at: id)
          guard let bound = constants[node.text] else {
            throw fail("manifest.reference", "unknown, forward or self reference: \(node.text)", id)
          }
          if bound.referenceDepth >= 63 {
            throw fail("manifest.limit", "active reference frames", id)
          }
          references[node.text, default: []].append(id)
          var cost = bound.cost
          cost.origins = ValueCost.add(cost.origins, cost.nodes)
          try check(cost, at: id)
          result = EvaluatedValue(
            type: bound.type, value: bound.value, cost: cost, syntax: id, referent: bound)
        } else {
          result = try call(id, context: expected)
        }
      default: throw fail("manifest.syntax", "unhandled admitted production", id)
      }
    }
    try check(result.cost, at: id)
    if let context {
      if result.type != context && result.type != context.unwrapped {
        throw fail("manifest.type", "value does not match contextual type", id)
      }
    }
    try charge(at: id)
    expressions[id] = result
    return result
  }

  private func literal(
    _ value: ConstructionValue, kind: String, inferred: String, context: ConstructionType?, id: Int
  ) throws -> EvaluatedValue {
    let type = context ?? .named(inferred)
    let converted: ConstructionValue
    if type == .named(inferred), !inferred.isEmpty {
      converted = value
    } else if case .named(let name) = type, Vocabulary.literalTypes[name]?.contains(kind) == true {
      switch name {
      case "Version":
        guard case .text(let text) = value else {
          throw fail("manifest.type", "version requires a string literal", id)
        }
        let version = Version(stringLiteral: text)
        guard version.valid else { throw fail("manifest.domain", "invalid semantic version", id) }
        converted = .version(version)
      case "SectionReference", "GroupReference":
        converted = .node(
          type: name, member: name == "SectionReference" ? "section" : "group",
          fields: ["name": value, "source": .none, "condition": .none])
      case "PromptContent", "RuntimeValue":
        converted = .node(type: name, member: "literal", fields: ["value": value])
      case "ConfigurationValue":
        converted = .node(
          type: name, member: kind == "nil" ? "null" : kind,
          fields: kind == "nil" ? [:] : ["value": value])
      default: throw fail("manifest.type", "unsupported literal conversion", id)
      }
    } else {
      throw fail("manifest.type", "literal needs a compatible context", id)
    }
    return EvaluatedValue(
      type: type, value: converted, cost: constructionCost(converted), syntax: id)
  }

  private func collection(_ id: Int, context: ConstructionType?) throws -> EvaluatedValue {
    let node = admission.nodes[id]
    let dictionary = node.kind == "dictionary"
    if node.children.count > 10_000 { throw fail("manifest.limit", "collection entries", id) }
    let wrapper: String?
    var elementType: ConstructionType?
    switch context {
    case .array(let type) where !dictionary:
      elementType = type
      wrapper = nil
    case .dictionary(let type) where dictionary:
      elementType = type
      wrapper = nil
    case .named("NativeConfiguration") where dictionary:
      elementType = .dictionary(.named("ConfigurationValue"))
      wrapper = nil
    case .named("ConfigurationValue"):
      elementType = .named("ConfigurationValue")
      wrapper = "ConfigurationValue"
    case .named("SkillSelection") where !dictionary:
      elementType = .named("String")
      wrapper = "SkillSelection"
    case nil: wrapper = nil
    default: throw fail("manifest.type", "collection is incompatible with contextual type", id)
    }
    var values: [EvaluatedValue] = []
    var fields: [String: EvaluatedValue] = [:]
    var keySpans: [String: Range<Int>] = [:]
    for (offset, child) in node.children.enumerated() {
      if dictionary {
        let key = node.keys[offset].decoded!
        if let original = keySpans[key] {
          throw ManifestFailure(
            ManifestDiagnostic(
              code: "manifest.dictionary.duplicateKey", message: "duplicate decoded dictionary key",
              span: source.span(node.keys[offset].range), related: [source.span(original)]))
        }
        keySpans[key] = node.keys[offset].range
      }
      let value = try evaluate(child, context: elementType)
      if elementType == nil { elementType = value.type }
      values.append(value)
      if dictionary { fields[node.keys[offset].decoded!] = value }
    }
    guard let elementType else {
      throw fail("manifest.type", "empty collection needs a contextual type", id)
    }
    var cost = ValueCost.container(
      values.map(\.cost), keys: dictionary ? node.keys.map { $0.decoded! } : [])
    if wrapper != nil {
      cost.nodes += 1
      cost.depth += 1
      cost.encoded += 32
    }
    try check(cost, at: id)
    let payload: ConstructionValue =
      dictionary ? .object(fields.mapValues(\.value)) : .array(values.map(\.value))
    let value: ConstructionValue
    let type: ConstructionType
    if let wrapper {
      type = .named(wrapper)
      value = .node(
        type: wrapper,
        member: wrapper == "SkillSelection" ? "names" : (dictionary ? "object" : "array"),
        fields: [wrapper == "SkillSelection" ? "names" : "value": payload])
    } else {
      type = dictionary ? .dictionary(elementType) : .array(elementType)
      value = payload
    }
    return EvaluatedValue(
      type: type, value: value, cost: cost, syntax: id, fields: fields,
      elements: dictionary ? [] : values)
  }

  private func call(_ id: Int, context: ConstructionType?) throws -> EvaluatedValue {
    let node = admission.nodes[id]
    let parts = node.text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let name: String
    let member: String
    if node.text == "Agents", node.kind == "call" {
      name = "Agents"
      member = "Agents"
    } else if parts.count == 2, parts[0].isEmpty {
      guard case .named(let expected) = context else {
        throw fail("manifest.type", "shorthand factory or member needs a named context", id)
      }
      name = expected
      member = parts[1]
    } else if parts.count == 2, Vocabulary.typeNames.contains(parts[0]) {
      name = parts[0]
      member = parts[1]
    } else {
      throw fail("manifest.call", "unlisted call or member", id)
    }
    let candidates = Vocabulary.signatures.filter {
      $0.type == name && $0.member == member && $0.callable == (node.kind == "call")
    }
    var match: ConstructionSignature?
    for signature in candidates {
      var argument = 0
      var valid = true
      for parameter in signature.parameters {
        if argument < node.arguments.count && node.arguments[argument].label == parameter.label {
          argument += 1
        } else if parameter.defaultValue == nil {
          valid = false
          break
        }
      }
      if valid && argument == node.arguments.count {
        match = signature
        break
      }
    }
    guard let signature = match else {
      throw fail("manifest.call", "unlisted factory/case or incorrect labels/order", id)
    }
    var fields: [String: EvaluatedValue] = [:]
    var argument = 0
    for parameter in signature.parameters {
      if argument < node.arguments.count && node.arguments[argument].label == parameter.label {
        fields[parameter.name] = try evaluate(
          node.arguments[argument].value, context: parameter.type)
        argument += 1
      } else {
        let value = parameter.defaultValue!
        fields[parameter.name] = EvaluatedValue(
          type: parameter.type, value: value, cost: constructionCost(value), syntax: id,
          defaulted: true)
      }
    }
    var cost = ValueCost.container(
      fields.values.map(\.cost), keys: [name, member] + Array(fields.keys))
    if name == "VersionRange" {
      guard case .version(let lower) = fields["from"]?.value,
        lower.successor(major: member == "upToNextMajor").valid
      else { throw fail("manifest.domain", "version successor overflow", id) }
    }
    if name == "Source", case .version(let lower) = fields["from"]?.value,
      !lower.successor(major: true).valid
    {
      throw fail("manifest.domain", "version successor overflow", id)
    }
    try check(cost, at: id)
    try charge(fields.count + 1, at: id)
    let value = ConstructionValue.construct(
      type: name, member: member, fields: fields.mapValues(\.value))
    // Canonical source requirements charge both range endpoints before lowering.
    if name == "Source" { cost = constructionCost(value) }
    try check(cost, at: id)
    return EvaluatedValue(type: .named(name), value: value, cost: cost, syntax: id, fields: fields)
  }
}

extension EvaluatedValue {
  package var elementsForUse: [EvaluatedValue] {
    var value = self
    while let next = value.referent { value = next }
    return value.elements
  }
}
