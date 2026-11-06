import AgentsCore
import AgentsDescription

/// Local evaluated values and source coordinates. Construction performs no linking or source I/O.
public struct ManifestDump: Sendable {
  public struct Location: Sendable {
    public let pointer: String
    public let span: SourceSpan
    public let origins: [SourceSpan]
    public let defaulted: Bool
    public let editability: ManifestJSONValue
  }

  public let schemaVersion = 1
  public let kind = "manifest"
  public let languageVersion = "1.0"
  public let sourceDigest: String
  public let declaration: ManifestJSONValue
  public let locations: [Location]
  public let diagnostics: [ManifestDiagnostic]

  public init(bytes: [UInt8]) throws {
    try self.init(
      document: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")))
  }

  public init(document: DeclarationDocument) throws {
    var projection = DumpProjection()
    declaration = projection.value(document.evaluation.root.value, old: "", new: "")
    sourceDigest = document.digest
    locations = try document.sourceMap.entries.map { entry -> Location in
      guard let pointer = projection.pointers[entry.pointer],
        let node = document.node(at: entry.pointer)
      else {
        throw document.source.failure(
          "manifest.dump.mismatch", "source map pointer is absent from the evaluated declaration",
          entry.span.start)
      }
      let editability: ManifestJSONValue
      switch document.editability(of: node) {
      case .direct: editability = .object(["kind": .string("direct")])
      case .readOnly(let reason):
        editability = .object(["kind": .string("readOnly"), "reason": .string(reason)])
      case .sharedConstant(let uses):
        editability = .object([
          "kind": .string("sharedConstant"),
          "uses": .array(
            uses.map { spanJSON(document.source.span(document.admission.nodes[$0.syntax].range)) }),
        ])
      }
      return Location(
        pointer: pointer, span: manifestSpan(entry.span), origins: entry.origins.map(manifestSpan),
        defaulted: entry.defaulted, editability: editability)
    }.sorted {
      $0.pointer == $1.pointer ? $0.span.start < $1.span.start : utf8Less($0.pointer, $1.pointer)
    }
    diagnostics = document.diagnostics.map {
      ManifestDiagnostic(
        code: $0.code, severity: $0.severity, message: $0.message, span: manifestSpan($0.span),
        related: $0.related.map(manifestSpan))
    }.sorted { ($0.span.start, $0.code) < ($1.span.start, $1.code) }
    _ = try locationJSON.encodedCount(
      limit: ManifestLimits.SourceMap.encodedBytes, budget: "source map encoded bytes")
    _ = try json.encodedCount(limit: ManifestLimits.Output.encodedBytes - 1)
  }

  public func encodedJSON() throws -> [UInt8] { try json.encodedJSON() }

  private var locationJSON: ManifestJSONValue {
    .array(
      locations.map { location in
        .object([
          "pointer": .string(location.pointer), "span": spanJSON(location.span),
          "origins": .array(location.origins.map(spanJSON)),
          "defaulted": .boolean(location.defaulted),
          "editability": location.editability,
        ])
      })
  }

  private var json: ManifestJSONValue {
    .object([
      "schemaVersion": .integer(schemaVersion), "kind": .string(kind),
      "languageVersion": .string(languageVersion),
      "sourceDigest": .string(sourceDigest), "declaration": declaration, "locations": locationJSON,
      "diagnostics": .array(
        diagnostics.map {
          .object([
            "code": .string($0.code), "severity": .string($0.severity.rawValue),
            "message": .string($0.message),
            "span": spanJSON($0.span), "related": .array($0.related.map(spanJSON)),
          ])
        }),
    ])
  }
}

private func manifestSpan(_ span: SourceSpan) -> SourceSpan {
  SourceSpan(
    document: DocumentIdentity("manifest"), start: span.start, end: span.end, line: span.line,
    column: span.column)
}

private func spanJSON(_ span: SourceSpan) -> ManifestJSONValue {
  .object([
    "document": .string("manifest"), "start": .integer(span.start), "end": .integer(span.end),
    "line": .integer(span.line), "column": .integer(span.column),
  ])
}

private struct DumpProjection {
  var pointers: [String: String] = [:]

  mutating func value(_ value: ConstructionValue, old: String, new: String) -> ManifestJSONValue {
    pointers[old] = new
    switch value {
    case .text(let text): return .string(text)
    case .integer(let number): return .integer(number)
    case .boolean(let flag): return .boolean(flag)
    case .none: return .null
    case .version(let version): return .string(version.normalized)
    case .range(let range): return requirement(Lowering.requirement(range), old: old, new: new)
    case .object(let fields):
      var result: [String: ManifestJSONValue] = [:]
      for key in fields.keys.sorted(by: utf8Less) {
        let suffix = "/" + pointerEscape(key)
        result[key] = self.value(fields[key]!, old: old + suffix, new: new + suffix)
      }
      return .object(result)
    case .array(let values):
      return array(values, old: old, new: new, sort: nil)
    case .node(let type, let member, let fields):
      if let spelling = Vocabulary.scalarValues[type]?[member] { return .string(spelling) }
      if type == "SkillSelection" {
        return member == "all"
          ? .string("all") : array(fields["names"]!.array!, old: old, new: new, sort: scalarKey)
      }
      if type == "Requirement", case .requirement(let requirement) = Lowering.lower(value) {
        return self.requirement(requirement, old: old, new: new)
      }
      var result: [String: ManifestJSONValue] = [:]
      if Vocabulary.taggedRecordTypes.contains(type) {
        let kind = Lowering.recordKind(type: type, member: member, fields: fields)
        pointers[old + "/kind"] = new + "/kind"
        result["kind"] = .string(kind)
      }
      for key in fields.keys.sorted(by: utf8Less) {
        let suffix = "/" + pointerEscape(key)
        let field = fields[key]!
        if type == "Source", key == "url", let url = field.text {
          pointers[old + suffix] = new + suffix
          result[key] = .string(SourceDeclaration(kind: .git, location: url).gitURL)
        } else if case .array(let values) = field {
          let sort: ((ConstructionValue) -> String)?
          if ["agents", "defaultAgents", "exports", "watch", "scopes", "platforms", "exclude"]
            .contains(key)
          {
            sort = scalarKey
          } else if ["sources", "groups", "chatGPT", "overrides"].contains(key) {
            sort = { $0.fields["name"]?.text ?? "" }
          } else {
            sort = nil
          }
          pointers[old + suffix] = new + suffix
          result[key] = array(values, old: old + suffix, new: new + suffix, sort: sort)
        } else {
          result[key] = self.value(field, old: old + suffix, new: new + suffix)
        }
      }
      return .object(result)
    }
  }

  private mutating func array(
    _ values: [ConstructionValue], old: String, new: String, sort: ((ConstructionValue) -> String)?
  ) -> ManifestJSONValue {
    var entries = Array(values.enumerated())
    if let sort { entries.sort { utf8Less(sort($0.element), sort($1.element)) } }
    var result: [ManifestJSONValue] = []
    for (index, entry) in entries.enumerated() {
      result.append(value(entry.element, old: old + "/\(entry.offset)", new: new + "/\(index)"))
    }
    return .array(result)
  }

  private mutating func requirement(_ requirement: SourceRequirement, old: String, new: String)
    -> ManifestJSONValue
  {
    let fields: [String: ManifestJSONValue]
    switch requirement {
    case .branch(let text): fields = ["branch": .string(text)]
    case .revision(let text): fields = ["revision": .string(text)]
    case .exact(let text): fields = ["exact": .string(text)]
    case .upToNextMajor(let text): fields = ["from": .string(text)]
    case .upToNextMinor(let text): fields = ["upToNextMinor": .string(text)]
    case .range(let lower, let upper): fields = ["from": .string(lower), "to": .string(upper)]
    }
    for key in fields.keys { pointers[old + "/" + key] = new + "/" + key }
    return .object(fields)
  }

  private func scalarKey(_ value: ConstructionValue) -> String {
    if let text = Lowering.lower(value).string { return text }
    if case .node("ComponentReference", let kind, let fields) = value {
      return kind + "\0" + (fields["name"]?.text ?? "")
    }
    return (value.fields["kind"]?.member ?? "") + "\0" + (value.fields["name"]?.text ?? "")
  }
}
