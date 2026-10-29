import AgentsCore
import AgentsDescription
import Foundation

public struct MigrationDiagnostic: Sendable, Equatable {
  public let pointer: String
  public let code: String
  public let message: String
  public let value: ManifestJSONValue?
  public let oldAlias: String?
  public let newAlias: String?
  public let budget: String?

  init(
    pointer: String, code: String, message: String, value: ManifestJSONValue? = nil,
    oldAlias: String? = nil, newAlias: String? = nil, budget: String? = nil
  ) {
    self.pointer = pointer
    self.code = code
    self.message = message
    self.value = value
    self.oldAlias = oldAlias
    self.newAlias = newAlias
    self.budget = budget
  }
}

public struct MigrationFailure: Error, Sendable {
  public let diagnostics: [MigrationDiagnostic]

  static func limit(_ budget: String) -> Self {
    Self(diagnostics: [
      MigrationDiagnostic(
        pointer: "", code: "migration.limit", message: "migration exceeds \(budget)", budget: budget
      )
    ])
  }
}

public struct ManifestMigrationResult: Sendable {
  public let bytes: [UInt8]
  public let declaration: DeclarationIR
  public let diagnostics: [MigrationDiagnostic]
}

/// Pure generation: callers own declaration-file creation, removal and every state transaction.
public enum ManifestMigration {
  public static func generate(
    json bytes: [UInt8], environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ManifestMigrationResult {
    try generate(json: bytes, environment: environment, checking: { $0 })
  }

  // A private-to-the-module comparison seam exercises self-check failures without changing output.
  static func generate(
    json bytes: [UInt8], environment: RuntimeEnvironment,
    checking expected: (DeclarationIR) -> DeclarationIR
  ) throws -> ManifestMigrationResult {
    var legacy = try StateStore.decode(Data(bytes), as: Declaration.self)
    try legacy.validate(environment: environment)
    // The strict decoder checks duplicates, UTF-8 and discarded values. Check field names
    // independently as well, including unknown fields whose value is JSON null.
    let input = try JSONSerialization.jsonObject(with: Data(bytes)) as! [String: Any]
    try validateKeys(input)
    var diagnostics: [MigrationDiagnostic] = []
    for alias in (legacy.skills ?? [:]).keys.sorted(by: utf8Less) {
      guard let selection = legacy.skills?[alias], case .names(let names) = selection.select else {
        continue
      }
      let selected = Set(names)
      for name in (selection.overrides ?? [:]).keys.sorted(by: utf8Less)
      where !selected.contains(name) {
        let pointer = "/skills/" + pointerEscape(alias) + "/overrides/" + pointerEscape(name)
        let full =
          ((input["skills"] as! [String: Any])[alias] as! [String: Any])["overrides"]
          as! [String: Any]
        diagnostics.append(
          MigrationDiagnostic(
            pointer: pointer, code: "migration.inertOverride",
            message:
              "override is outside the explicit skill selection and cannot affect installation",
            value: try ManifestJSONValue.json(full[name]!)))
        legacy.skills?[alias]?.overrides?.removeValue(forKey: name)
      }
    }
    if let dot = legacy.sources.removeValue(forKey: ".") {
      var alias = "source"
      var suffix = 2
      while legacy.sources[alias] != nil {
        alias = "source-\(suffix)"
        suffix += 1
      }
      legacy.sources[alias] = dot
      if let selection = legacy.skills?.removeValue(forKey: ".") {
        legacy.skills?[alias] = selection
      }
      legacy.watch = legacy.watch?.map { $0 == "." ? alias : $0 }
      func rewrite(_ references: [String]) -> [String] {
        references.map { $0.hasPrefix(".:") ? alias + $0.dropFirst() : $0 }
      }
      if let instructions = legacy.instructions {
        legacy.instructions?.sections = rewrite(instructions.sections)
        for name in (instructions.chatgpt ?? [:]).keys {
          legacy.instructions?.chatgpt?[name]?.sections = rewrite(
            instructions.chatgpt![name]!.sections)
        }
      }
      diagnostics.append(
        MigrationDiagnostic(
          pointer: "/sources/.", code: "migration.sourceAliasRenamed",
          message: "reserved source alias renamed", oldAlias: ".", newAlias: alias))
    }
    diagnostics.sort {
      $0.pointer == $1.pointer ? utf8Less($0.code, $1.code) : utf8Less($0.pointer, $1.pointer)
    }
    let projection = try legacy.compatibilityProjection()
    let construction = MigrationConstruction.root(projection)
    try preflight(construction)
    let output = try CanonicalPrinter().manifest(construction)
    let document: DeclarationDocument
    do {
      document = try DeclarationDocument(bytes: output, identity: DocumentIdentity("manifest"))
    } catch let failure as ManifestFailure {
      if let limit = failure.diagnostics.first(where: { $0.code == "manifest.limit" }) {
        throw MigrationFailure.limit(limit.message)
      }
      throw failure
    }
    guard document.declaration == expected(projection) else {
      throw MigrationFailure(diagnostics: [
        MigrationDiagnostic(
          pointer: "", code: "migration.mismatch",
          message: "generated declaration differs from compatibility projection")
      ])
    }
    return ManifestMigrationResult(bytes: output, declaration: projection, diagnostics: diagnostics)
  }

  static func preflight(_ value: ConstructionValue) throws {
    var pending = [(value, 1)]
    var nodes = 0
    var strings = 0
    while let (value, depth) = pending.popLast() {
      nodes += 1
      guard nodes <= ManifestLimits.Values.nodes else {
        throw MigrationFailure.limit("expanded nodes")
      }
      guard depth <= ManifestLimits.Values.depth else {
        throw MigrationFailure.limit("expanded depth")
      }
      let children: [ConstructionValue]
      switch value {
      case .array(let values): children = values
      case .object(let fields), .node(_, _, let fields):
        strings = fields.keys.reduce(strings) { ValueCost.add($0, $1.utf8.count) }
        children = fields.keys.sorted(by: utf8Less).map { fields[$0]! }
      case .text(let text):
        strings = ValueCost.add(strings, text.utf8.count)
        children = []
      case .version(let version):
        strings = ValueCost.add(strings, version.normalized.utf8.count)
        children = []
      case .range(let range): children = [.version(range.lowerBound), .version(range.upperBound)]
      default: children = []
      }
      guard children.count <= ManifestLimits.Values.entries else {
        throw MigrationFailure.limit("collection entries")
      }
      guard strings <= ManifestLimits.Values.stringBytes else {
        throw MigrationFailure.limit("decoded string bytes")
      }
      guard children.count <= ManifestLimits.Values.nodes - nodes - pending.count else {
        throw MigrationFailure.limit("expanded nodes")
      }
      pending += children.map { ($0, depth + 1) }
    }
    let cost = constructionCost(value)
    guard cost.encoded <= ManifestLimits.Output.encodedBytes else {
      throw MigrationFailure.limit("encoded output bytes")
    }
  }

  private static func validateKeys(_ root: [String: Any]) throws {
    func keys(_ value: [String: Any], _ allowed: Set<String>) throws {
      if let unknown = value.keys.sorted(by: utf8Less).first(where: { !allowed.contains($0) }) {
        throw CoreError.invalidState("unknown state field: \(unknown)")
      }
    }
    try keys(root, ["agents", "sources", "skills", "instructions", "watch"])
    for source in (root["sources"] as? [String: [String: Any]] ?? [:]).values {
      try keys(
        source,
        [
          "git", "local", "well-known", "path", "branch", "revision", "exact", "from", "to",
          "upToNextMinor",
        ])
    }
    for selection in (root["skills"] as? [String: [String: Any]] ?? [:]).values {
      try keys(selection, ["select", "exclude", "agents", "mode", "overrides"])
      for override in (selection["overrides"] as? [String: [String: Any]] ?? [:]).values {
        try keys(override, ["agents", "mode"])
      }
    }
    if let instructions = root["instructions"] as? [String: Any] {
      try keys(instructions, ["agents", "sections", "chatgpt"])
      for prompt in (instructions["chatgpt"] as? [String: [String: Any]] ?? [:]).values {
        try keys(prompt, ["sections", "append"])
      }
    }
  }
}

private enum MigrationConstruction {
  static func root(_ ir: DeclarationIR) -> ConstructionValue {
    record(
      DeclarationRecord(
        kind: "Agents",
        fields: [
          "defaultAgents": ir.defaultAgents.map { .array($0.map { .string($0) }) } ?? .null,
          "exports": .array(ir.exports.map { .string($0) }),
          "sources": .array(ir.sources.map { .record($0) }),
          "components": .array(ir.components.map { .record($0) }),
          "groups": .array(ir.groups.map { .record($0) }),
          "uses": .array(ir.uses.map { .record($0) }),
          "watch": .array(ir.watch.map { .string($0) }),
        ]), as: "Agents")
  }

  private static func record(_ record: DeclarationRecord, as type: String) -> ConstructionValue {
    if type == "Source" {
      return .node(
        type: type, member: "source",
        fields: record.fields.mapValues { value($0, as: .named("String")) })
    }
    let signature = Vocabulary.signatures.first { $0.type == type && $0.member == record.kind }!
    return .node(
      type: type, member: record.kind,
      fields: record.fields.reduce(into: [:]) { result, field in
        let parameter = signature.parameters.first { $0.name == field.key }!
        result[field.key] = value(field.value, as: parameter.type)
      })
  }

  private static func value(_ input: DeclarationValue, as type: ConstructionType)
    -> ConstructionValue
  {
    switch input {
    case .null: return .none
    case .string(let text):
      if case .named(let name) = type.unwrapped {
        if let member = Vocabulary.scalarValues[name]?.first(where: { $0.value == text })?.key {
          return .node(type: name, member: member, fields: [:])
        }
        if name == "SkillSelection" { return .node(type: name, member: "all", fields: [:]) }
      }
      return .text(text)
    case .integer(let number): return .integer(number)
    case .boolean(let flag): return .boolean(flag)
    case .array(let values):
      if case .named("SkillSelection") = type.unwrapped {
        return .node(
          type: "SkillSelection", member: "names",
          fields: ["names": .array(values.map { value($0, as: .named("String")) })])
      }
      guard case .array(let element) = type.unwrapped else {
        preconditionFailure("projection array type")
      }
      return .array(values.map { value($0, as: element) })
    case .dictionary(let fields):
      guard case .dictionary(let element) = type.unwrapped else {
        preconditionFailure("projection dictionary type")
      }
      return .object(fields.mapValues { value($0, as: element) })
    case .record(let node):
      guard case .named(let name) = type.unwrapped else {
        preconditionFailure("projection record type")
      }
      return record(node, as: name)
    case .requirement(let requirement):
      func version(_ text: String) -> Version { Version(stringLiteral: text) }
      switch requirement {
      case .upToNextMajor(let lower): return .range(.upToNextMajor(from: version(lower)))
      case .upToNextMinor(let lower): return .range(.upToNextMinor(from: version(lower)))
      case .range(let lower, let upper): return .range(version(lower)..<version(upper))
      case .exact(let text), .branch(let text), .revision(let text):
        return .node(type: "Requirement", member: requirement.kind, fields: ["value": .text(text)])
      }
    }
  }
}
