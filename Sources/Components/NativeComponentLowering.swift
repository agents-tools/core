import AgentsCore
import Foundation
import NativeDocuments

package struct NativeComponentRequest: Equatable {
  package let surface: NativeClientSurface
  package let scope: InstallScope
  package init(surface: NativeClientSurface, scope: InstallScope) {
    self.surface = surface
    self.scope = scope
  }
}

package struct NativeComponentIssue: Error, CustomStringConvertible {
  package let request: NativeComponentRequest
  package let kind: String
  package let component: String
  package let field: [String]
  package let reason: NativeAdapterIssue.Reason
  package let detail: String
  package var description: String {
    "\(request.surface.rawValue)/\(kind)/\(component)/\(request.scope.rawValue) "
      + "\(field.joined(separator: ".")): \(reason.rawValue) (\(detail))."
  }
}

/// Closed recipes are resolved/admitted by Core/E. A source cannot supply a native path.
package enum NativeComponentRoute: String {
  case geminiCommand, geminiAgent, geminiSettings, geminiIgnore
  case openCodeConfig, codexConfig, codexAgent, codexHooks
  case cursorCommand, cursorAgent, cursorIgnore
  case claudeSkillPlugin, cursorLocalPlugin, geminiExtension
  case claudeCommand, claudeAgent, claudeSettings, cursorHooks

  /// Structured shared documents only. Whole files, ignore blocks and plugin trees have their
  /// concrete content shape on NativeComponentOutput and do not use a shared-document editor.
  package var documentFormat: NativeDocumentFormat? {
    switch self {
    case .claudeSettings, .codexHooks, .cursorHooks: .json
    case .codexConfig: .toml
    case .geminiSettings: .jsonc(trailingCommas: false)
    case .openCodeConfig: .jsonc(trailingCommas: true)
    default: nil
    }
  }
}

package enum NativeComponentLowering {
  package static func lower(
    _ linked: LinkedComponent, frozen: LedgerFreeze.Result,
    request: NativeComponentRequest, id: String, platform: DeclarationPlatform
  ) throws -> LockedLowering {
    let owner: (id: String, occurrences: [Int])
    do {
      owner = try FrozenNativeIdentity.match(
        linked, frozen: frozen,
        agent: request.surface.agent, scope: request.scope)
    } catch {
      throw NativeComponentIssue(
        request: request, kind: linked.key.kind.rawValue,
        component: linked.key.name, field: ["component"], reason: .invalid,
        detail: "linked component and frozen source identity do not match")
    }
    let selected = Set(owner.occurrences)
    guard
      frozen.ledger.occurrences.filter({ selected.contains($0.id) }).allSatisfy({
        $0.condition.platforms?.contains(platform.rawValue) ?? true
      })
    else {
      throw NativeComponentIssue(
        request: request, kind: linked.key.kind.rawValue,
        component: linked.key.name, field: ["platform"], reason: .invalid,
        detail: "frozen occurrence does not target the requested output platform")
    }
    let format = NativeComponentLayoutsV1.format(request.surface)
    let record = frozen.ledger.components[owner.id]!
    let input = ComponentRenderInput(
      record: record, component: owner.id, request: request,
      occurrences: owner.occurrences, resources: [:], ledger: frozen.ledger, limits: .standard)
    try input.validateProfile()
    return .init(
      id: id, format: format, inputs: [owner.id], resources: record.resources, deployments: [],
      layout: .init(object: [
        "surface": .init(request.surface.rawValue),
        "scope": .init(request.scope.rawValue),
        "occurrences": .init(array: owner.occurrences.map { .init(integer: $0) }),
      ]),
      platform: platform.rawValue, artifacts: [])
  }
}

/// A concrete profile emits its native file contents or regional values plus route/ownership
/// metadata. E alone groups these contributions into physical documents and transactions.
struct ComponentRenderInput {
  let record: LedgerComponent
  let component: String
  let request: NativeComponentRequest
  let occurrences: [Int]
  let resources: [String: URL]
  let ledger: ResolvedLedger
  let limits: LedgerLimits
  let budget: NativeDocumentBudget
  let inPlugin: Bool
  init(
    record: LedgerComponent, component: String, request: NativeComponentRequest,
    occurrences: [Int], resources: [String: URL], ledger: ResolvedLedger, limits: LedgerLimits,
    inPlugin: Bool = false
  ) {
    self.inPlugin = inPlugin
    self.record = record
    self.component = component
    self.request = request
    self.occurrences = occurrences
    self.resources = resources
    self.ledger = ledger
    self.limits = limits
    budget = .init(
      limits: .init(
        storage: limits.encodedBytes, work: limits.encodedBytes,
        nodes: limits.nodes, depth: limits.depth, uninterruptedBytes: limits.resourceBytes))
  }
  var fields: [String: LedgerValue] { record.payload.object! }
  var native: [String: LedgerValue] {
    fields["native"]?.object?[request.surface.agent.rawValue]?.object ?? [:]
  }

  func issue(_ field: [String], _ reason: NativeAdapterIssue.Reason, _ detail: String)
    -> NativeComponentIssue
  {
    .init(
      request: request, kind: record.kind, component: record.name, field: field,
      reason: reason, detail: detail)
  }

  func validateProfile() throws {
    func admit(_ value: LedgerValue, depth: Int) throws {
      try budget.node(depth: depth)
      if let text = value.text {
        try budget.allocate(text.utf8.count, stage: "native input string")
        try budget.step(text.utf8.count)
      }
      for item in value.array ?? [] { try admit(item, depth: depth + 1) }
      for (key, item) in value.object ?? [:] {
        try budget.allocate(key.utf8.count, stage: "native input key")
        try budget.step(key.utf8.count)
        try admit(item, depth: depth + 1)
      }
      var node = value
      if node.array != nil { node.array = [] }
      if node.object != nil { node.object = [:] }
      try node.validate()
    }
    try admit(record.payload, depth: 0)
    guard fields["name"] == .init(record.name) else {
      throw issue(["name"], .invalid, "frozen payload and component identity do not match")
    }
    for key in ["model", "matcher", "description", "purpose", "mode"] where fields[key] != nil {
      guard fields[key]?.kind == .string else {
        throw issue([key], .invalid, "frozen native field requires a string")
      }
    }
    for key in ["tools", "patterns"] where fields[key] != nil {
      guard let values = fields[key]?.array, values.allSatisfy({ $0.kind == .string }) else {
        throw issue([key], .invalid, "frozen native field requires strings")
      }
    }
    if let timeout = fields["timeoutSeconds"] {
      guard timeout.kind == .integer, timeout.integer.map({ $0 > 0 }) == true else {
        throw issue(["timeoutSeconds"], .invalid, "frozen native timeout requires positive seconds")
      }
    }
    if let native = fields["native"] {
      guard let clients = native.object,
        clients[request.surface.agent.rawValue] == nil
          || clients[request.surface.agent.rawValue]?.kind == .object
      else { throw issue(["native"], .invalid, "frozen native configuration requires objects") }
    }
    guard record.recipients.contains(request.surface.agent) else {
      throw issue(["recipients"], .invalid, "component does not target this recipient")
    }
    try literal(record.name, field: ["name"])
    for key in ["model", "tools", "matcher"] {
      if let value = fields[key] {
        try NativeProgramV1.validateLiterals(value, input: self, path: [key])
      }
    }
    guard let kind = DeclaredComponentKind(rawValue: record.kind) else {
      throw issue(["kind"], .invalid, "invalid frozen component kind")
    }
    _ = try CapabilityRegistry.component(request, kind: kind, name: record.name, inPlugin: inPlugin)
    if kind == .ignore, fields["purpose"]?.text != "context" {
      throw issue(
        ["purpose"], .unverified, "a distinct current indexing-only contract is not established")
    }
  }

  func checkedNative(_ rules: [String: MCPNativeField]) throws -> [String: LedgerValue] {
    for (key, value) in native.sorted(by: { $0.key < $1.key }) {
      guard let rule = rules[key] else {
        throw issue(
          ["native", request.surface.agent.rawValue, key], .unverified,
          "no verified field mapping in this native schema")
      }
      try NativeProgramV1.validateLiterals(
        value, input: self, path: ["native", request.surface.agent.rawValue, key])
      guard rule.accepts(try nativeValue(value)) else {
        throw issue(
          ["native", request.surface.agent.rawValue, key], .invalid,
          "value is outside the verified native field profile")
      }
    }
    return native
  }

  func text(_ key: String) throws -> String {
    guard let value = fields[key]?.text else {
      throw issue([key], .invalid, "required frozen string is missing")
    }
    try literal(value, field: [key])
    return value
  }

  func literal(_ value: String, field: [String], prompt: Bool = false) throws {
    guard !value.utf8.contains(0) else {
      throw issue(field, .invalid, "NUL is not a native string")
    }
    if prompt && value.contains("$${input:") {
      throw issue(
        field, .unverified, "literal input-token escaping needs a verified native representation")
    }
    let interpolation: Bool
    switch request.surface {
    case .claudeCode:
      interpolation =
        (record.kind == "hook" && value.contains("${"))
        || (prompt && (value.contains("$") || value.contains("!`") || value.contains("${")))
    case .openCodeCLI:
      interpolation =
        value.contains("{env:") || value.contains("{file:")
        || (prompt
          && (value.range(of: #"\$(?:ARGUMENTS|[1-9])|!`"#, options: .regularExpression) != nil))
    case .geminiCLI:
      interpolation =
        (record.kind == "hook"
          && value.range(
            of: #"\$(?:[A-Za-z0-9_]+|\{[^}]+?(?::-[^}]*)?\})"#, options: .regularExpression) != nil)
        || (prompt && (value.contains("{{args}}") || value.contains("!{") || value.contains("@{")))
    default: interpolation = false
    }
    guard !interpolation else {
      throw issue(
        field, .unverified, "exact literal preservation across native interpolation needs evidence")
    }
    if prompt && request.surface == .openCodeCLI,
      !NativeComponentText.isUntrimmed(value, rust: false)
    {
      throw issue(
        field, .unsupported, "the native template evaluator trims leading and trailing whitespace")
    }
  }

  func prompt() throws -> String {
    guard let prompt = fields["prompt"] else {
      throw issue(["prompt"], .invalid, "missing frozen prompt")
    }
    let value: String
    if prompt.kind == .literal {
      value = prompt.text!
    } else {
      guard let id = record.resources.first, let resource = ledger.resources[id],
        resource.path == prompt.object?["file"]?.object?["path"]?.text,
        let url = resources[id], resource.entries.count == 1,
        resource.entries[0].kind == .file, resource.entries[0].path == "."
      else { throw issue(["prompt"], .invalid, "frozen prompt resource is not a single file") }
      guard let size = resource.entries[0].byteCount, size <= limits.resourceBytes else {
        throw issue(["prompt"], .invalid, "prompt resource exceeds output budget")
      }
      try budget.allocate(size, stage: "frozen prompt bytes")
      try budget.allocate(size, stage: "frozen prompt UTF8")
      try budget.step(size)
      let bytes = try Data(contentsOf: url)
      guard bytes.count == size, let decoded = String(data: bytes, encoding: .utf8) else {
        throw issue(["prompt"], .invalid, "prompt resource is not exact UTF8")
      }
      value = decoded
    }
    guard value.utf8.count <= limits.resourceBytes else {
      throw issue(["prompt"], .invalid, "prompt exceeds output budget")
    }
    try literal(value, field: ["prompt"], prompt: record.kind == "command")
    return value
  }

  func relativeName() throws -> String {
    do {
      let name = try PathSafety.sanitizeSubpath(record.name)
      guard name == record.name, name != "." else { throw CoreError.invalidState("invalid name") }
      return name
    } catch {
      throw issue(["name"], .invalid, "native filename requires an exact contained relative name")
    }
  }

  func filename() throws -> String {
    let name = try relativeName()
    guard !name.contains("/") else {
      throw issue(
        ["name"], .unverified, "nested file discovery is not established by this native profile")
    }
    return name
  }

  func noParameters() throws {
    guard fields["parameters"]?.array?.isEmpty ?? true else {
      throw issue(
        ["parameters"], .unsupported,
        "native command schema does not represent named parameter descriptions/defaults")
    }
  }

  func nativeValue(_ value: LedgerValue) throws -> NativeValue {
    switch value.kind {
    case .string, .literal: return .string(value.text!)
    case .integer: return .integer(value.integer!)
    case .decimal: return .decimal(value.text!)
    case .boolean: return .boolean(value.boolean!)
    case .null: return .null
    case .array: return .array(try value.array!.map(nativeValue))
    case .object: return .object(try value.object!.mapValues(nativeValue))
    case .environment, .secret:
      throw issue(
        ["value"], .integrationRequired, "native binding requires private staged conversion")
    }
  }

  func envelope(
    route: NativeComponentRoute, path: String? = nil,
    keys: [String] = [], selection: String = "key", value: LedgerValue
  ) -> LedgerValue {
    var result: [String: LedgerValue] = [
      "route": .init(route.rawValue),
      "surface": .init(request.surface.rawValue), "scope": .init(request.scope.rawValue),
      "kind": .init(record.kind), "name": .init(record.name), "component": .init(component),
      "occurrences": .init(array: occurrences.map { .init(integer: $0) }),
      "recipients": LedgerPayload.strings([request.surface.agent.rawValue]),
      "knownReaders": LedgerPayload.strings(
        CapabilityRegistry.componentReaders(
          request, kind: DeclaredComponentKind(rawValue: record.kind)!
        ).map(\.rawValue).sorted()),
      "keys": LedgerPayload.strings(keys), "selection": .init(selection), "value": value,
    ]
    result["path"] = path.map { .init($0) }
    return .init(object: result)
  }

  func quoted(_ value: String) throws -> String {
    guard limits.resourceBytes >= 2, value.utf8.count <= (limits.resourceBytes - 2) / 6 else {
      throw issue(["output"], .invalid, "native string exceeds encoding budget")
    }
    try budget.allocate(value.utf8.count * 6 + 2, stage: "native scalar encoding")
    try budget.step(value.utf8.count)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
      .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  func joined(_ parts: [String], separator: String = "\n") throws -> String {
    var size = 0
    for part in parts {
      guard part.utf8.count <= limits.resourceBytes - size else {
        throw issue(["output"], .invalid, "native file exceeds output budget")
      }
      size += part.utf8.count
    }
    for _ in parts.dropFirst() {
      guard separator.utf8.count <= limits.resourceBytes - size else {
        throw issue(["output"], .invalid, "native file exceeds output budget")
      }
      size += separator.utf8.count
    }
    try budget.allocate(size, stage: "native file")
    try budget.step(size)
    return parts.joined(separator: separator)
  }

  func frontmatter(_ values: [String: LedgerValue], body: String) throws -> String {
    var lines = ["---"]
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
      let text: String
      if value.kind == .decimal, let decimal = value.text {
        text = decimal
      } else if let value = value.text {
        text = try quoted(value)
      } else if let values = value.array {
        text = try joined(values.map { try quoted($0.text!) }, separator: ", ")
        lines.append("\(key): [\(text)]")
        continue
      } else if let value = value.boolean {
        text = value ? "true" : "false"
      } else if let value = value.integer {
        text = String(value)
      } else {
        throw issue(["native", key], .invalid, "unsupported frontmatter scalar")
      }
      lines.append("\(key): \(text)")
    }
    lines.append("---")
    lines.append(body)
    return try joined(lines)
  }

  func emitted(_ lowering: LockedLowering, _ envelope: LedgerValue) throws -> [ReplayedArtifact] {
    try envelope.validate()
    func admit(_ value: LedgerValue, depth: Int) throws {
      try budget.node(depth: depth)
      if let text = value.text {
        try budget.allocate(text.utf8.count, stage: "native output")
        try budget.step(text.utf8.count)
      }
      for child in value.array ?? [] { try admit(child, depth: depth + 1) }
      for (key, child) in value.object ?? [:] {
        try budget.allocate(key.utf8.count, stage: "native output key")
        try admit(child, depth: depth + 1)
      }
    }
    try admit(envelope, depth: 0)
    return [.init(name: lowering.id, kind: .ownedValues, values: envelope)]
  }
}

/// Source-pinned loaders use JavaScript trim or Rust str::trim, whose Unicode edge sets differ.
enum NativeComponentText {
  static func whitespace(_ scalar: Unicode.Scalar, rust: Bool) -> Bool {
    let value = scalar.value
    return (9...13).contains(value)
      || [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(value)
      || (0x2000...0x200A).contains(value) || (rust ? value == 0x85 : value == 0xFEFF)
  }
  static func isUntrimmed(_ value: String, rust: Bool) -> Bool {
    guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else {
      return true
    }
    return !whitespace(first, rust: rust) && !whitespace(last, rust: rust)
  }
  static func isBlank(_ value: String, rust: Bool) -> Bool {
    value.unicodeScalars.allSatisfy { whitespace($0, rust: rust) }
  }
}
