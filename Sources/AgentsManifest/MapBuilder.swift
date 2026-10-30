import AgentsCore
import AgentsDescription

struct BuiltMap {
  var entries: [SourceMapEntry] = []
  var locations: [String: NodeID] = [:]
  var values: [String: EvaluatedValue] = [:]
}

final class MapBuilder {
  private let source: SourceText
  private let admission: Admission
  private let digest: String
  private var result = BuiltMap()
  private var originCount = 0
  private var encodedBytes = 0

  init(source: SourceText, admission: Admission, digest: String) {
    self.source = source
    self.admission = admission
    self.digest = digest
  }

  func build(_ evaluation: Evaluation) throws -> BuiltMap {
    try append(evaluation.root, pointer: "", origins: [], use: nil)
    // Constants are separately addressable; declaration locations remain language independent.
    for (name, value) in evaluation.constants where name != "agents" {
      let pointer = "/constants/" + pointerEscape(name)
      result.locations[pointer] = NodeID(digest: digest, pointer: pointer, syntax: value.syntax)
      result.values[pointer] = value
    }
    result.entries.sort { ($0.pointer, $0.span.start) < ($1.pointer, $1.span.start) }
    return result
  }

  private func append(
    _ value: EvaluatedValue, pointer: String, origins: [SourceSpan], use: SourceSpan?,
    ownOrigins: [SourceSpan] = []
  ) throws {
    let range = admission.nodes[value.syntax].range
    let span = use ?? source.span(range)
    var inherited = origins
    let definition = source.span(range)
    if use != nil, definition != span, inherited.last != definition { inherited.append(definition) }
    var resolved = value
    while let next = resolved.referent {
      inherited.append(source.span(admission.nodes[next.syntax].range))
      resolved = next
    }
    if value.referent != nil {
      guard resolved.cost.nodes <= ManifestLimits.SourceMap.locations - result.entries.count,
        value.cost.origins <= ManifestLimits.SourceMap.origins - originCount
      else {
        throw source.failure("manifest.limit", "reference source map expansion", range.lowerBound)
      }
    }
    let recordedOrigins = inherited + ownOrigins
    let estimate =
      pointer.utf8.count + (source.identity.rawValue.utf8.count + 160) * (recordedOrigins.count + 1)
      + 80
    guard result.entries.count < ManifestLimits.SourceMap.locations,
      recordedOrigins.count <= ManifestLimits.SourceMap.origins - originCount,
      estimate <= ManifestLimits.SourceMap.encodedBytes - encodedBytes
    else {
      throw source.failure(
        "manifest.limit", "source map locations, origins or encoded bytes", range.lowerBound)
    }
    originCount += recordedOrigins.count
    encodedBytes += estimate
    result.entries.append(
      SourceMapEntry(
        pointer: pointer, span: span, origins: recordedOrigins, defaulted: value.defaulted))
    result.locations[pointer] = NodeID(digest: digest, pointer: pointer, syntax: value.syntax)
    result.values[pointer] = value
    let useSpan = value.referent != nil || use != nil ? span : nil
    if case .node(let type, let member, let fields) = resolved.value {
      if Vocabulary.taggedRecordTypes.contains(type),
        case .record(let record) = Lowering.lower(resolved.value)
      {
        let discriminator = EvaluatedValue(
          type: .untyped, value: .text(record.kind), cost: ValueCost.scalar(record.kind),
          syntax: resolved.syntax, representation: .synthetic)
        try append(discriminator, pointer: pointer + "/kind", origins: inherited, use: useSpan)
      }
      if type == "SkillSelection" {
        for (offset, child) in resolved.elementsForUse.enumerated() {
          try append(child, pointer: pointer + "/\(offset)", origins: inherited, use: useSpan)
        }
        return
      }
      if type == "ConfigurationValue",
        resolved.representation == .scalarLiteral || resolved.representation == .collectionLiteral,
        let payload = fields["value"]
      {
        guard
          let childType = Vocabulary.literalConstructions[type]?.values.first(where: {
            $0.member == member
          })?.payloadType
        else {
          throw source.failure(
            "manifest.type", "literal payload has no registered type", range.lowerBound)
        }
        let child = EvaluatedValue(
          type: childType, value: payload, cost: resolved.cost, syntax: resolved.syntax,
          fields: resolved.fields, elements: resolved.elements)
        try append(child, pointer: pointer + "/value", origins: inherited, use: useSpan)
        return
      }
      for (key, childValue) in fields {
        if type == "Source", key == "requirement" {
          let trace = SourceRequirements.parameters.compactMap {
            resolved.fields[$0.name]
          }.first
          if let trace, childValue != .none {
            let shape = requirementShape(childValue, trace: trace)
            var definitions: [SourceSpan] = []
            var referent = trace.referent
            while let definition = referent {
              definitions.append(source.span(admission.nodes[definition.syntax].range))
              referent = definition.referent
            }
            try append(
              shape, pointer: pointer + "/requirement", origins: inherited, use: useSpan,
              ownOrigins: definitions)
          } else {
            let absent = EvaluatedValue(
              type: .untyped, value: .none, cost: ValueCost(), syntax: resolved.syntax,
              defaulted: true, representation: .synthetic)
            try append(absent, pointer: pointer + "/requirement", origins: inherited, use: useSpan)
          }
          continue
        }
        let child: EvaluatedValue
        if let field = resolved.fields[key] {
          child = field
        } else {
          child = EvaluatedValue(
            type: .untyped, value: childValue, cost: ValueCost(), syntax: resolved.syntax,
            defaulted: (key == "source" || key == "condition") && childValue == .none
              || resolved.defaulted, representation: .synthetic)
        }
        try append(
          child, pointer: pointer + "/" + pointerEscape(key), origins: inherited, use: useSpan)
      }
    } else if !resolved.fields.isEmpty {
      for (key, child) in resolved.fields {
        try append(
          child, pointer: pointer + "/" + pointerEscape(key), origins: inherited, use: useSpan)
      }
    } else if !resolved.elements.isEmpty {
      for (offset, child) in resolved.elements.enumerated() {
        try append(child, pointer: pointer + "/\(offset)", origins: inherited, use: useSpan)
      }
    } else {
      try synthetic(
        resolved.value, syntax: resolved.syntax, pointer: pointer, span: span, origins: inherited,
        defaulted: value.defaulted)
    }
  }

  private func requirementShape(_ value: ConstructionValue, trace: EvaluatedValue) -> EvaluatedValue
  {
    let requirement = Lowering.lower(value)
    var fields: [String: ConstructionValue] = [:]
    var traces: [String: EvaluatedValue] = [:]
    if case .requirement(let requirement) = requirement {
      let lower = trace.field("from") ?? trace.elementsForUse.first ?? trace
      switch requirement {
      case .branch(let text):
        fields["branch"] = .text(text)
        traces["branch"] = trace
      case .revision(let text):
        fields["revision"] = .text(text)
        traces["revision"] = trace
      case .exact(let text):
        fields["exact"] = .text(text)
        traces["exact"] = trace
      case .upToNextMajor(let text):
        fields["from"] = .text(text)
        traces["from"] = lower
      case .upToNextMinor(let text):
        fields["upToNextMinor"] = .text(text)
        traces["upToNextMinor"] = lower
      case .range(let from, let to):
        fields["from"] = .text(from)
        fields["to"] = .text(to)
        traces["from"] = lower
        traces["to"] = trace.elementsForUse.last ?? trace
      }
    }
    return EvaluatedValue(
      type: .named("Requirement"), value: .object(fields), cost: trace.cost, syntax: trace.syntax,
      fields: traces, representation: .synthetic)
  }

  private func synthetic(
    _ value: ConstructionValue, syntax: Int, pointer: String, span: SourceSpan,
    origins: [SourceSpan], defaulted: Bool
  ) throws {
    let fields: [(String, ConstructionValue)]
    switch value {
    case .node(_, _, let values), .object(let values): fields = Array(values)
    case .array(let values): fields = values.enumerated().map { (String($0.offset), $0.element) }
    default: return
    }
    for (key, child) in fields {
      let v = EvaluatedValue(
        type: .untyped, value: child, cost: ValueCost(), syntax: syntax, defaulted: defaulted,
        representation: .synthetic)
      try append(v, pointer: pointer + "/" + pointerEscape(key), origins: origins, use: span)
    }
  }
}
