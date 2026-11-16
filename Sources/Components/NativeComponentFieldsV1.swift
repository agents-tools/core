import AgentsCore
import Foundation
import NativeDocuments

/// Structural semantic failures contain no imported field values or machine paths.
package struct NativeComponentFieldIssue: Error {
  package let field: [String]
  package let reason: NativeAdapterIssue.Reason
  package let detail: String
}

/// Finite native field semantics shared by rendering and parsed source input.
/// Callers own syntax, source locations, aggregate admission and source capture.
package enum NativeComponentFieldsV1 {
  static func markdownRules(_ surface: NativeClientSurface, kind: String) -> [String:
    MCPNativeField]
  {
    switch (surface, kind) {
    case (.claudeCode, "command"):
      return [
        "argument-hint": .string, "allowed-tools": .strings,
        "disallowed-tools": .strings, "when_to_use": .string,
        "disable-model-invocation": .boolean, "user-invocable": .boolean,
        "model": .string, "context": .oneOf(["fork"]), "agent": .string,
        "background": .boolean, "effort": .oneOf(["low", "medium", "high", "xhigh", "max"]),
      ]
    case (.claudeCode, "subagent"):
      return [
        "disallowedTools": .strings,
        "permissionMode": .oneOf([
          "default", "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan",
        ]),
        "maxTurns": .positiveInteger, "skills": .strings,
        "memory": .oneOf(["user", "project", "local"]), "background": .boolean,
        "omitClaudeMd": .boolean, "isolation": .oneOf(["worktree"]),
        "effort": .oneOf(["low", "medium", "high", "xhigh", "max"]),
      ]
    case (.cursorEditor, "subagent"): return ["readonly": .boolean, "is_background": .boolean]
    case (.geminiCLI, "subagent"):
      return [
        "max_turns": .positiveInteger, "timeout_mins": .positiveInteger,
      ]
    default: return [:]
    }
  }
}

extension NativeComponentFieldsV1 {
  /// Applicable default coordinates beneath the explicitly selected producer container.
  /// Explicit Claude commands/agents replace discovery; skills add and configs merge.
  /// Cursor explicit component fields replace default discovery for that component.
  package static func pluginDefaults(
    surface: NativeClientSurface, explicitFields: Set<String>
  ) throws -> [String: String] {
    let defaults: [String: String]
    switch surface {
    case .claudeCode:
      defaults = [
        "commands": "commands", "agents": "agents", "skills": "skills",
        "hooks": "hooks/hooks.json", "mcpServers": ".mcp.json", "lspServers": ".lsp.json",
      ]
      return defaults.filter {
        !["commands", "agents"].contains($0.key) || !explicitFields.contains($0.key)
      }
    case .cursorEditor:
      defaults = [
        "commands": "commands", "agents": "agents", "skills": "skills", "rules": "rules",
        "hooks": "hooks/hooks.json", "mcpServers": "mcp.json",
      ]
      return defaults.filter { !explicitFields.contains($0.key) }
    default:
      throw failure([], .unverified, "native plugin defaults are not established for this surface")
    }
  }

  /// Values are already parsed. Resource entries/documents are relative to the producer's
  /// explicit container root; they convey presence and kind, never deployment ownership.
  package static func plugin(
    surface: NativeClientSurface, fields: [String: NativeValue],
    entries: [LedgerEntry], documents: [String: NativeValue], budget: NativeDocumentBudget
  ) throws -> [String: NativeValue] {
    guard surface == .claudeCode || surface == .cursorEditor else {
      throw failure([], .unverified, "this container profile has no shared parsed-field contract")
    }
    try admit(.object(fields), budget: budget)
    try budget.step(entries.count)
    var coordinates = Set<String>()
    for entry in entries {
      try budget.allocate(entry.path.utf8.count, stage: "native resource coordinate")
      try budget.step(entry.path.utf8.count)
      guard (try? PathSafety.sanitizeSubpath(entry.path)) == entry.path,
        coordinates.insert(entry.path).inserted
      else {
        throw failure([], .invalid, "native resource coordinates must be unique and contained")
      }
    }
    for (path, value) in documents {
      try budget.allocate(path.utf8.count, stage: "native document coordinate")
      try admit(value, budget: budget)
    }
    let validator = NativePluginFieldsV1(
      surface: surface, entries: entries, budget: budget, documents: documents)
    try validator.validate(fields)
    return fields
  }

  /// One native Claude/OpenCode LSP entry, without launch or placeholder expansion. Native
  /// placeholders remain source syntax; G must convert bindings before canonical capture.
  package static func lsp(
    surface: NativeClientSurface, fields: [String: NativeValue], budget: NativeDocumentBudget
  ) throws -> [String: NativeValue] {
    try admit(.object(fields), budget: budget)
    switch surface {
    case .claudeCode:
      try NativePluginFieldsV1(surface: surface, entries: [], budget: budget, documents: [:])
        .lsp(.object(fields), field: [])
    case .openCodeCLI:
      // A disabled built-in entry has no explicit executable to project into a declaration.
      if fields == ["disabled": .boolean(true)] { return fields }
      var rules = NativeLSPLayoutV1.openCodeNativeFields
      rules["command"] = .strings
      rules["env"] = .object
      rules["initialization"] = .object
      guard fields["command"] != nil else {
        throw failure(["command"], .invalid, "native LSP server entry requires command argv")
      }
      for (index, item) in fields.sorted(by: { $0.key < $1.key }).enumerated() {
        guard let rule = rules[item.key] else {
          throw failure(
            [String(index)], .unverified, "native LSP field is outside the finite profile")
        }
        guard rule.accepts(item.value) else {
          throw failure([item.key], .invalid, "native LSP field has an invalid type or range")
        }
        if item.key == "env", case .object(let values) = item.value,
          !values.values.allSatisfy({ if case .string = $0 { true } else { false } })
        {
          throw failure(["env"], .invalid, "native LSP environment requires string values")
        }
      }
    default:
      throw failure([], .unverified, "this surface has no shared native LSP input contract")
    }
    return fields
  }

  /// A finite command/subagent frontmatter object. Name is the source member coordinate,
  /// used only by schemas that permit a filename fallback. inPlugin is the actual source
  /// registration context, not inferred from the desired deployment scope. No fields are dropped.
  package static func markdown(
    surface: NativeClientSurface, kind: DeclaredComponentKind, name: String,
    fields: [String: NativeValue], inPlugin: Bool, budget: NativeDocumentBudget
  ) throws -> [String: NativeValue] {
    guard [.claudeCode, .cursorEditor, .geminiCLI].contains(surface),
      kind == .command || kind == .subagent,
      !(surface == .geminiCLI && kind == .command)
    else { throw failure([], .unverified, "native Markdown input is outside this finite profile") }
    try admit(.object(fields), budget: budget)
    try budget.allocate(name.utf8.count, stage: "native member coordinate")
    try budget.step(name.utf8.count)
    if kind == .command {
      guard name != ".", !name.isEmpty,
        (try? PathSafety.sanitizeSubpath(name)) == name
      else {
        throw failure(
          ["name"], .invalid, "native command requires an exact contained relative name")
      }
      if surface == .cursorEditor, name.contains("/") {
        throw failure(
          ["name"], .unverified, "nested command discovery is not established for this profile")
      }
    }

    var rules = markdownRules(surface, kind: kind.rawValue)
    if kind == .subagent {
      rules["name"] = .string
      rules["description"] = .string
      rules["model"] = .string
      if surface != .cursorEditor { rules["tools"] = .strings }
    } else if surface == .claudeCode {
      rules["description"] = .string
    }
    for (index, item) in fields.sorted(by: { $0.key < $1.key }).enumerated() {
      guard let rule = rules[item.key] else {
        throw failure(
          [String(index)], .unverified, "native frontmatter field has no verified projection")
      }
      // The native source format also admits comma-separated tools. Preserve its source
      // spelling for G's canonical projection rather than guessing tool-pattern tokenization.
      if surface == .claudeCode, kind == .subagent, item.key == "tools",
        case .string = item.value
      {
        continue
      }
      guard rule.accepts(item.value) else {
        throw failure([item.key], .invalid, "native frontmatter field has an invalid type or range")
      }
    }
    if inPlugin, surface == .claudeCode, kind == .subagent, fields["permissionMode"] != nil {
      throw failure(
        ["permissionMode"], .unsupported,
        "native plugin agents ignore this field; standalone policy projection would change meaning")
    }
    if surface == .claudeCode, kind == .command {
      for key in ["agent", "background"]
      where fields[key] != nil && fields["context"] != .string("fork") {
        throw failure([key], .unsupported, "native command field requires context fork")
      }
    }
    if kind == .subagent {
      if surface != .cursorEditor {
        guard case .string(let description) = fields["description"], !description.isEmpty,
          fields["name"] != nil
        else { throw failure([], .invalid, "native agent requires name and nonempty description") }
      }
      let effective: String
      if case .string(let supplied) = fields["name"] {
        effective = supplied
      } else {
        effective = name
      }
      guard !effective.isEmpty, !effective.contains("/"), !effective.contains("\\"),
        effective != ".", effective != "..", !effective.utf8.contains(0)
      else { throw failure(["name"], .invalid, "native agent requires a contained filename") }
      if surface == .claudeCode, effective.count > 256 || effective.contains(":") {
        throw failure(["name"], .invalid, "native agent name exceeds its native domain")
      }
      if surface == .geminiCLI {
        guard effective.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil else {
          throw failure(["name"], .invalid, "native agent requires a lowercase slug")
        }
        if case .array(let tools) = fields["tools"] {
          guard
            tools.allSatisfy({
              if case .string(let tool) = $0 { return GeminiAdapter.validAgentTool(tool) }
              return false
            })
          else { throw failure(["tools"], .invalid, "native tool is outside the pinned schema") }
        }
      }
    }
    return fields
  }

  private static func failure(
    _ field: [String], _ reason: NativeAdapterIssue.Reason, _ detail: String
  ) -> NativeComponentFieldIssue { .init(field: field, reason: reason, detail: detail) }

  private static func admit(_ value: NativeValue, budget: NativeDocumentBudget, depth: Int = 0)
    throws
  {
    try budget.node(depth: depth)
    switch value {
    case .string(let text), .decimal(let text):
      try budget.allocate(text.utf8.count, stage: "native parsed value")
      try budget.step(text.utf8.count)
    case .array(let values):
      for child in values { try admit(child, budget: budget, depth: depth + 1) }
    case .object(let fields):
      for (key, child) in fields {
        try budget.allocate(key.utf8.count, stage: "native parsed key")
        try budget.step(key.utf8.count)
        try admit(child, budget: budget, depth: depth + 1)
      }
    default: break
    }
  }
}
