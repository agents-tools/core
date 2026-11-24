import AgentsCore

/// Complete local intent and semantic source coordinates. No source resolution occurs.
public struct ManifestDump: Sendable {
  public struct Location: Sendable {
    public let pointer: String
    public let span: SourceSpan
    public let origins: [SourceSpan]
    public let defaulted: Bool
    public let editability: ManifestJSONValue
  }
  public let schemaVersion = 2
  public let kind = "manifest"
  public let format = "yaml"
  public let manifestVersion = 1
  public let sourceDigest: String
  public let declaration: ManifestJSONValue
  public let locations: [Location]
  public let diagnostics: [ManifestDiagnostic]

  public init(bytes: [UInt8]) throws {
    try self.init(
      document: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")))
  }
  public init(document: DeclarationDocument) throws {
    sourceDigest = document.digest
    let ir = document.declaration
    let fields: [String: ManifestJSONValue] = [
      "defaultAgents": ir.defaultAgents.map { .array($0.map(ManifestJSONValue.string)) } ?? .null,
      "sources": .array(ir.sources.map { Self.value(.record($0)) }),
      "components": .array(ir.components.map { Self.value(.record($0)) }),
      "groups": .array(ir.groups.map { Self.value(.record($0)) }),
      "uses": .array(ir.uses.map { Self.value(.record($0)) }),
      "exports": .array(ir.exports.map(ManifestJSONValue.string)),
      "watch": .array(ir.watch.map(ManifestJSONValue.string)),
    ]
    declaration = .object(fields)
    locations = document.sourceMap.entries.map {
      let editability: ManifestJSONValue
      if $0.pointer.hasSuffix("/kind") {
        editability = .object([
          "kind": .string("readOnly"),
          "reason": .string("record kind; replace its containing value"),
        ])
      } else {
        editability = .object(["kind": .string("direct")])
      }
      return Location(
        pointer: $0.pointer, span: Self.span($0.span), origins: $0.origins.map(Self.span),
        defaulted: $0.defaulted, editability: editability)
    }.sorted { utf8Less($0.pointer, $1.pointer) }
    diagnostics = document.diagnostics.map {
      ManifestDiagnostic(
        code: $0.code, severity: $0.severity, message: $0.message, span: Self.span($0.span),
        related: $0.related.map(Self.span))
    }
    _ = try json.encodedCount(limit: ManifestLimits.Output.encodedBytes - 1)
  }
  public func encodedJSON() throws -> [UInt8] { try json.encodedJSON() }

  private var json: ManifestJSONValue {
    .object([
      "schemaVersion": .integer(schemaVersion), "kind": .string(kind), "format": .string(format),
      "manifestVersion": .integer(manifestVersion), "sourceDigest": .string(sourceDigest),
      "declaration": declaration,
      "locations": .array(
        locations.map {
          .object([
            "pointer": .string($0.pointer), "span": Self.spanJSON($0.span),
            "origins": .array($0.origins.map(Self.spanJSON)), "defaulted": .boolean($0.defaulted),
            "editability": $0.editability,
          ])
        }),
      "diagnostics": .array(
        diagnostics.map {
          .object([
            "code": .string($0.code), "severity": .string($0.severity.rawValue),
            "message": .string($0.message), "span": Self.spanJSON($0.span),
            "related": .array($0.related.map(Self.spanJSON)),
          ])
        }),
    ])
  }
  private static func span(_ value: SourceSpan) -> SourceSpan {
    SourceSpan(
      document: DocumentIdentity("manifest"), start: value.start, end: value.end, line: value.line,
      column: value.column)
  }
  private static func spanJSON(_ value: SourceSpan) -> ManifestJSONValue {
    .object([
      "document": .string("manifest"), "start": .integer(value.start), "end": .integer(value.end),
      "line": .integer(value.line), "column": .integer(value.column),
    ])
  }
  private static func value(_ value: DeclarationValue) -> ManifestJSONValue {
    switch value {
    case .string(let value): return .string(value)
    case .integer(let value): return .integer(value)
    case .boolean(let value): return .boolean(value)
    case .null: return .null
    case .array(let values): return .array(values.map(Self.value))
    case .dictionary(let values): return .object(values.mapValues(Self.value))
    case .record(let record):
      return .object(
        record.fields.mapValues(Self.value).merging(["kind": .string(record.kind)]) { _, value in
          value
        })
    case .requirement(let requirement):
      var fields = [
        "kind": ManifestJSONValue.string(requirement.kind), "value": .string(requirement.value),
      ]
      if let upper = requirement.upperBound { fields["to"] = .string(upper) }
      return .object(fields)
    }
  }
}
