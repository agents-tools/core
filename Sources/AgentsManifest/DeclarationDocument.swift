import AgentsCore
import AgentsDescription
import Foundation
import SwiftSyntax

public struct DeclarationDocument: Sendable {
  public let declaration: DeclarationIR
  public let diagnostics: [ManifestDiagnostic]
  public let sourceMap: DeclarationSourceMap
  public let digest: String
  public let metrics: FrontEndMetrics
  public var bytes: [UInt8] { source.bytes }
  package let source: SourceText
  package let admission: Admission
  package let syntax: SourceFileSyntax
  package let evaluation: Evaluation
  package let locations: [String: NodeID]
  package let values: [String: EvaluatedValue]

  public init(bytes: [UInt8], identity: DocumentIdentity) throws {
    try self.init(bytes: bytes, identity: identity, validateDomain: true)
  }

  package init(bytes: [UInt8], identity: DocumentIdentity, validateDomain: Bool) throws {
    // Reject the extra byte before building line tables or decoding the snapshot.
    if bytes.count > 2_097_152 {
      let bounded = SourceText(Array(bytes.prefix(2_097_153)), identity: identity)
      throw bounded.failure("manifest.limit", "input byte limit", 2_097_152)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let source = SourceText(bytes, identity: identity)
    let admission: Admission
    var metrics = FrontEndMetrics()
    do {
      admission = try Recognizer(source: source).recognize()
    } catch let failure as ManifestFailure {
      metrics = failure.metrics
      metrics.admissionSeconds = seconds(start.duration(to: clock.now))
      throw ManifestFailure(failure.diagnostics[0], metrics: metrics)
    }
    metrics.admissionSeconds = seconds(start.duration(to: clock.now))
    metrics.tokens = admission.tokens.count
    metrics.syntaxReservation = admission.reservation
    let checked = try SyntaxValidation.parse(source, admission: admission, metrics: metrics)
    metrics = checked.metrics
    let evaluation: Evaluation
    let diagnostics: [ManifestDiagnostic]
    let digest = "sha256:" + FileHash.sha256Hex(data: Data(bytes))
    let mapping: BuiltMap
    let declaration: DeclarationIR
    var stage = "evaluation"
    var stageStart = clock.now
    do {
      evaluation = try Evaluator(source: source, admission: admission).evaluate()
      metrics.evaluationSeconds = seconds(stageStart.duration(to: clock.now))
      stage = "domain"
      stageStart = clock.now
      diagnostics =
        validateDomain
        ? try DomainValidator(source: source, admission: admission, evaluation: evaluation)
          .validate() : []
      metrics.domainSeconds = seconds(stageStart.duration(to: clock.now))
      stage = "lowering"
      stageStart = clock.now
      declaration = Lowering.declaration(evaluation.root.value)
      metrics.loweringSeconds = seconds(stageStart.duration(to: clock.now))
      stage = "sourceMap"
      stageStart = clock.now
      mapping = try MapBuilder(source: source, admission: admission, digest: digest).build(
        evaluation)
      metrics.sourceMapSeconds = seconds(stageStart.duration(to: clock.now))
    } catch let failure as ManifestFailure {
      let elapsed = seconds(stageStart.duration(to: clock.now))
      switch stage {
      case "evaluation": metrics.evaluationSeconds = elapsed
      case "domain": metrics.domainSeconds = elapsed
      case "sourceMap": metrics.sourceMapSeconds = elapsed
      default: metrics.loweringSeconds = elapsed
      }
      throw ManifestFailure(failure.diagnostics[0], metrics: metrics)
    }
    self.source = source
    self.admission = admission
    syntax = checked.tree
    self.evaluation = evaluation
    self.declaration = declaration
    self.diagnostics = diagnostics
    self.digest = digest
    sourceMap = DeclarationSourceMap(entries: mapping.entries)
    locations = mapping.locations
    values = mapping.values
    metrics.evaluationSteps = evaluation.steps
    metrics.expandedNodes = evaluation.total.nodes
    metrics.decodedBytes = evaluation.total.strings
    self.metrics = metrics
  }

  public func node(at pointer: String) -> NodeID? { locations[pointer] }
  public func constant(named name: String) -> NodeID? {
    locations["/constants/" + pointerEscape(name)]
  }
  public func uses(ofConstant name: String) -> [NodeID] {
    var pending = [name]
    var seen = Set<String>()
    var references = Set<Int>()
    while let name = pending.popLast() {
      if !seen.insert(name).inserted { continue }
      for id in evaluation.references[name] ?? [] {
        references.insert(id)
        let offset = admission.nodes[id].range.lowerBound
        if let owner = admission.declarations.first(where: { $0.range.contains(offset) }),
          owner.name != "agents"
        {
          pending.append(owner.name)
        }
      }
    }
    return references.sorted().map {
      NodeID(digest: digest, pointer: "/references/\($0)", syntax: $0)
    }
  }

  public func editability(of node: NodeID) -> Editability {
    guard node.digest == digest, values[node.pointer]?.syntax == node.syntax else {
      return .readOnly(reason: "stale snapshot handle")
    }
    if node.pointer.hasPrefix("/constants/") {
      let name = String(node.pointer.dropFirst("/constants/".count)).replacingOccurrences(
        of: "~1", with: "/"
      ).replacingOccurrences(of: "~0", with: "~")
      return .sharedConstant(uses: uses(ofConstant: name))
    }
    guard let value = values[node.pointer], !value.defaulted, value.type != .named("") else {
      return .readOnly(reason: "default field has no source range")
    }
    if value.referent != nil || hasAssembledAncestor(node.pointer) {
      return .readOnly(
        reason: "shared constant or assembled value; replace its definition explicitly")
    }
    let kind = admission.nodes[node.syntax].kind
    if kind == "sequence" || kind == "name" {
      return .readOnly(reason: "expanded value has no independent source range")
    }
    return .direct
  }

  package func hasAssembledAncestor(_ pointer: String) -> Bool {
    var prefix = pointer
    while let slash = prefix.lastIndex(of: "/"), slash != prefix.startIndex {
      prefix = String(prefix[..<slash])
      if let parent = values[prefix],
        parent.referent != nil || admission.nodes[parent.syntax].kind == "sequence"
      {
        return true
      }
    }
    return false
  }

  public func preparing(_ edits: [ManifestEdit]) throws -> DocumentChange {
    try DocumentEditor(document: self).prepare(edits)
  }
}

package func pointerEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

package struct BuiltMap {
  package var entries: [SourceMapEntry] = []
  package var locations: [String: NodeID] = [:]
  package var values: [String: EvaluatedValue] = [:]
}

package final class MapBuilder {
  private let source: SourceText
  private let admission: Admission
  private let digest: String
  private var result = BuiltMap()
  private var originCount = 0
  private var encodedBytes = 0

  package init(source: SourceText, admission: Admission, digest: String) {
    self.source = source
    self.admission = admission
    self.digest = digest
  }

  package func build(_ evaluation: Evaluation) throws -> BuiltMap {
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
      guard resolved.cost.nodes <= 100_000 - result.entries.count,
        value.cost.origins <= 1_000_000 - originCount
      else {
        throw source.failure("manifest.limit", "reference source map expansion", range.lowerBound)
      }
    }
    let recordedOrigins = inherited + ownOrigins
    let estimate =
      pointer.utf8.count + (source.identity.rawValue.utf8.count + 160) * (recordedOrigins.count + 1)
      + 80
    guard result.entries.count < 100_000, recordedOrigins.count <= 1_000_000 - originCount,
      estimate <= 16_777_216 - encodedBytes
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
      let tagged: Set<String> = [
        "Source", "Component", "MCPTransport", "ExecutableInvocation", "GroupReference",
        "PromptContent", "RuntimeValue", "ConfigurationValue", "HookEvent", "PermissionOperation",
        "ComponentReference", "PermissionRule",
      ]
      if tagged.contains(type), case .record(let record) = Lowering.lower(resolved.value) {
        let discriminator = EvaluatedValue(
          type: .named(""), value: .text(record.kind), cost: ValueCost.scalar(record.kind),
          syntax: resolved.syntax)
        try append(discriminator, pointer: pointer + "/kind", origins: inherited, use: useSpan)
      }
      if type == "SkillSelection" {
        for (offset, child) in resolved.elementsForUse.enumerated() {
          try append(child, pointer: pointer + "/\(offset)", origins: inherited, use: useSpan)
        }
        return
      }
      if type == "ConfigurationValue", resolved.fields["value"] == nil,
        let payload = fields["value"]
      {
        let childType: ConstructionType =
          member == "object"
          ? .dictionary(.named("ConfigurationValue"))
          : member == "array"
            ? .array(.named("ConfigurationValue"))
            : member == "integer"
              ? .named("Int") : member == "boolean" ? .named("Bool") : .named("String")
        let child = EvaluatedValue(
          type: childType, value: payload, cost: resolved.cost, syntax: resolved.syntax,
          fields: resolved.fields, elements: resolved.elements)
        try append(child, pointer: pointer + "/value", origins: inherited, use: useSpan)
        return
      }
      for (key, childValue) in fields {
        if type == "Source", key == "requirement" {
          let trace = ["from", "exact", "branch", "revision", "range"].compactMap {
            resolved.fields[$0]
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
              type: .named(""), value: .none, cost: ValueCost(), syntax: resolved.syntax,
              defaulted: true)
            try append(absent, pointer: pointer + "/requirement", origins: inherited, use: useSpan)
          }
          continue
        }
        let sourceKey =
          type == "Source" && key == "requirement"
          ? ["from", "exact", "branch", "revision", "range"].first(where: {
            resolved.fields[$0] != nil
          }) ?? key : key
        let child: EvaluatedValue
        if let field = resolved.fields[sourceKey] {
          child = field
        } else {
          child = EvaluatedValue(
            type: .named(""), value: childValue, cost: ValueCost(), syntax: resolved.syntax,
            defaulted: (key == "source" || key == "condition") && childValue == .none
              || resolved.defaulted)
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
      fields: traces)
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
        type: .named(""), value: child, cost: ValueCost(), syntax: syntax, defaulted: defaulted)
      try append(v, pointer: pointer + "/" + pointerEscape(key), origins: origins, use: span)
    }
  }
}
