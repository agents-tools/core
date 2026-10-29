import AgentsDescription

struct Evaluation: Sendable {
  let root: EvaluatedValue
  let constants: [String: EvaluatedValue]
  let expressions: [Int: EvaluatedValue]
  let references: [String: [Int]]
  let steps: Int
  let total: ValueCost
}

final class Evaluator {
  private let source: SourceText
  private let admission: Admission
  private let replacements: [String: StaticValue]
  private var constants: [String: EvaluatedValue] = [:]
  private var expressions: [Int: EvaluatedValue] = [:]
  private var references: [String: [Int]] = [:]
  private var steps = 0
  private var frames = 0
  private var total = ValueCost(nodes: 0, strings: 0, encoded: 0, depth: 0, origins: 0)

  init(source: SourceText, admission: Admission, replacements: [String: StaticValue] = [:]) {
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
    guard amount <= ManifestLimits.Evaluation.steps - steps else {
      throw fail("manifest.limit", "evaluation work steps", id)
    }
    steps += amount
  }
  private func check(_ cost: ValueCost, at id: Int) throws {
    guard cost.fits else {
      throw fail("manifest.limit", "expanded value budget (nodes, bytes, depth or origins)", id)
    }
  }

  func evaluate() throws -> Evaluation {
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
      admission.nodes[declaration.expression].kind == .call,
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
    guard frames <= ManifestLimits.Evaluation.frames else {
      throw fail("manifest.limit", "evaluation frames", id)
    }
    let node = admission.nodes[id]
    let expected = context?.unwrapped
    let result: EvaluatedValue
    if node.kind == .nilLiteral, case .optional = context {
      result = EvaluatedValue(type: context!, value: .none, cost: ValueCost(), syntax: id)
    } else {
      switch node.kind {
      case .group:
        let child = try evaluate(node.children[0], context: context)
        result = EvaluatedValue(
          type: child.type, value: child.value, cost: child.cost, syntax: id, referent: child,
          representation: .reference)
      case .string:
        result = try literal(
          .text(node.text), inferred: .named("String"), context: expected, id: id)
      case .integer, .negative:
        let raw = (node.kind == .negative ? "-" : "") + node.text.filter { $0 != "_" }
        guard let integer = Int(raw) else {
          throw fail("manifest.type", "integer literal must fit signed 64-bit Int", id)
        }
        result = try literal(
          .integer(integer), inferred: .named("Int"), context: expected, id: id)
      case .boolean:
        result = try literal(
          .boolean(node.text == "true"), inferred: .named("Bool"), context: expected,
          id: id)
      case .nilLiteral:
        result = try literal(.none, inferred: .untyped, context: expected, id: id)
      case .array, .dictionary: result = try collection(id, context: expected)
      case .sequence:
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
          if count > ManifestLimits.Values.entries {
            throw fail("manifest.limit", "concatenation entries", id)
          }
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
      case .range:
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
      case .name, .call:
        if node.kind == .name, !node.text.contains(".") {
          try charge(at: id)
          guard let bound = constants[node.text] else {
            throw fail("manifest.reference", "unknown, forward or self reference: \(node.text)", id)
          }
          if bound.referenceDepth >= ManifestLimits.Evaluation.frames - 1 {
            throw fail("manifest.limit", "active reference frames", id)
          }
          references[node.text, default: []].append(id)
          var cost = bound.cost
          cost.origins = ValueCost.add(cost.origins, cost.nodes)
          try check(cost, at: id)
          result = EvaluatedValue(
            type: bound.type, value: bound.value, cost: cost, syntax: id, referent: bound,
            representation: .reference)
        } else {
          result = try call(id, context: expected)
        }
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
    _ value: ConstructionValue, inferred: ConstructionType, context: ConstructionType?, id: Int
  ) throws -> EvaluatedValue {
    let type = context ?? inferred
    let converted: ConstructionValue
    do {
      converted = try LiteralConversion.convert(value, to: type)
    } catch let error as LiteralConversionError {
      throw fail(error.code, error.message, id)
    }
    return EvaluatedValue(
      type: type, value: converted, cost: constructionCost(converted), syntax: id,
      representation: .scalarLiteral)
  }

  private func collection(_ id: Int, context: ConstructionType?) throws -> EvaluatedValue {
    let node = admission.nodes[id]
    let dictionary = node.kind == .dictionary
    if node.children.count > ManifestLimits.Values.entries {
      throw fail("manifest.limit", "collection entries", id)
    }
    var elementType: ConstructionType?
    do {
      elementType = try LiteralConversion.elementType(
        for: dictionary ? .dictionary : .array, context: context)
    } catch let error as LiteralConversionError {
      throw fail(error.code, error.message, id)
    }
    let wrapped = context.map { if case .named = $0 { true } else { false } } ?? false
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
    if wrapped {
      cost.nodes += 1
      cost.depth += 1
      cost.encoded += 32
    }
    try check(cost, at: id)
    let payload: ConstructionValue =
      dictionary ? .object(fields.mapValues(\.value)) : .array(values.map(\.value))
    let inferred: ConstructionType = dictionary ? .dictionary(elementType) : .array(elementType)
    let type = context ?? inferred
    let value: ConstructionValue
    do {
      value = try LiteralConversion.convert(payload, to: type)
    } catch let error as LiteralConversionError {
      throw fail(error.code, error.message, id)
    }
    return EvaluatedValue(
      type: type, value: value, cost: cost, syntax: id, fields: fields,
      elements: dictionary ? [] : values, representation: .collectionLiteral)
  }

  private func call(_ id: Int, context: ConstructionType?) throws -> EvaluatedValue {
    let node = admission.nodes[id]
    let parts = node.text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let name: String
    let member: String
    if node.text == "Agents", node.kind == .call {
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
      $0.type == name && $0.member == member && $0.callable == (node.kind == .call)
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
