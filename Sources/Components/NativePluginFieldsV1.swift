import AgentsCore
import Foundation
import NativeDocuments

/// Validates documented native container fields against the frozen bundle. Native source
/// bytes and discovery precedence are preserved; this is not decomposition or installation.
struct NativePluginFieldsV1 {
  let surface: NativeClientSurface
  let entries: [LedgerEntry]
  let budget: NativeDocumentBudget
  let readJSON: (String, [String]) throws -> NativeValue
  let issue: ([String], String, NativeAdapterIssue.Reason) -> Error
  var claude: Bool { surface == .claudeCode }

  init(input: ComponentRenderInput, resource: LedgerResource, root: URL) {
    surface = input.request.surface
    entries = resource.entries
    budget = input.budget
    issue = { input.issue(["manifest"] + $0, $2, $1) }
    readJSON = { relative, field in
      try input.budget.step(resource.entries.count)
      guard let entry = resource.entries.first(where: { $0.path == relative }),
        entry.kind == .file, let size = entry.byteCount, size <= input.limits.resourceBytes
      else {
        throw input.issue(
          ["manifest"] + field, .invalid, "native JSON resource is not a bounded frozen file")
      }
      try input.budget.allocate(size, stage: "native plugin JSON")
      try input.budget.step(size)
      let bytes = try Data(contentsOf: PathSafety.resolvedChild(base: root, subpath: relative))
      guard bytes.count == size else {
        throw input.issue(["manifest"] + field, .invalid, "native JSON resource size changed")
      }
      do {
        let document = try NativeDocument(bytes: bytes, format: .json, budget: input.budget)
        guard let value = try document.read(.init(keys: []))?.value else {
          throw input.issue(
            ["manifest"] + field, .invalid, "native JSON resource has no root value")
        }
        return value
      } catch NativeDocumentError.invalidDocument {
        throw input.issue(["manifest"] + field, .invalid, "native JSON resource is malformed")
      }
    }
  }

  init(
    surface: NativeClientSurface, entries: [LedgerEntry], budget: NativeDocumentBudget,
    documents: [String: NativeValue]
  ) {
    self.surface = surface
    self.entries = entries
    self.budget = budget
    issue = { NativeComponentFieldIssue(field: $0, reason: $2, detail: $1) }
    readJSON = { relative, field in
      guard entries.contains(where: { $0.path == relative && $0.kind == .file }),
        let value = documents[relative]
      else {
        throw NativeComponentFieldIssue(
          field: field, reason: .invalid, detail: "referenced native JSON document was not supplied"
        )
      }
      return value
    }
  }
  static func validClaudeName(_ name: String) -> Bool {
    !name.isEmpty
      && name.unicodeScalars.allSatisfy {
        !CharacterSet.whitespacesAndNewlines.contains($0)
          && !"@:/\\".unicodeScalars.contains($0) && $0.properties.generalCategory != .control
          && ![0x61C, 0x200E, 0x200F].contains($0.value)
          && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
      }
  }

  func fail(_ path: [String], _ detail: String, _ reason: NativeAdapterIssue.Reason = .invalid)
    -> Error
  {
    issue(path, detail, reason)
  }

  func text(_ value: NativeValue, _ path: [String]) throws -> String {
    guard case .string(let text) = value, !text.utf8.contains(0) else {
      throw fail(path, "native field requires a string without NUL")
    }
    return text
  }

  func strings(_ value: NativeValue, _ path: [String]) throws {
    guard case .array(let values) = value else {
      throw fail(path, "native field requires an array of strings")
    }
    for (index, value) in values.enumerated() { _ = try text(value, path + [String(index)]) }
  }

  func path(
    _ value: NativeValue, _ field: [String], kind: LedgerEntry.Kind? = nil, suffix: String? = nil
  ) throws -> String {
    let authored = try text(value, field)
    if claude, !authored.hasPrefix("./"), !(field.first == "skills" && authored == ".") {
      throw fail(field, "native Claude component paths require a dot-slash prefix")
    }
    if authored.contains("\\") {
      throw fail(
        field, "native backslash paths need exact frozen resource-path identity", .unverified)
    }
    let relative: String
    do {
      relative = try PathSafety.sanitizeSubpath(authored)
      guard !authored.hasPrefix("/"), !authored.split(separator: "/").contains(".."),
        !authored.contains("://")
      else { throw CoreError.invalidState("invalid path") }
    } catch { throw fail(field, "native component path must remain inside its frozen plugin root") }
    if relative == ".", kind != .file, suffix == nil { return relative }
    try budget.step(entries.count)
    guard let entry = entries.first(where: { $0.path == relative }) else {
      try budget.step(entries.count)
      if entries.contains(where: {
        $0.kind == .symlink && relative.hasPrefix($0.path + "/")
      }) {
        throw fail(
          field, "native referenced symlink requires E's contained resource closure",
          .integrationRequired)
      }
      throw fail(field, "native component path is absent from the frozen bundle")
    }
    guard entry.kind != .symlink else {
      throw fail(
        field, "native referenced symlink requires E's final contained resource closure",
        .integrationRequired)
    }
    guard kind == nil || entry.kind == kind, suffix == nil || relative.hasSuffix(suffix!) else {
      throw fail(field, "native component path has the wrong file or directory kind")
    }
    return relative
  }

  func paths(
    _ value: NativeValue, _ field: [String], kind: LedgerEntry.Kind? = nil, suffix: String? = nil
  ) throws {
    if case .array(let values) = value {
      for (index, value) in values.enumerated() {
        _ = try path(value, field + [String(index)], kind: kind, suffix: suffix)
      }
    } else {
      _ = try path(value, field, kind: kind, suffix: suffix)
    }
  }

  func json(_ relative: String, field: [String]) throws -> NativeValue {
    try readJSON(relative, field)
  }

  func validate(_ fields: [String: NativeValue]) throws {
    if claude {
      guard Self.validClaudeName(try text(fields["name"] ?? .null, ["name"])) else {
        throw fail(["name"], "native plugin identifier contains a forbidden character")
      }
    } else {
      let name = try text(fields["name"] ?? .null, ["name"])
      guard
        name.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
      else {
        throw fail(
          ["name"],
          "Cursor native plugin name must be a lowercase alphanumeric/hyphen/period identifier")
      }
    }
    if !claude, case .string(let version) = fields["version"] {
      do {
        guard try SourceRequirement.exact(version).canonicalized() == .exact(version) else {
          throw fail(["version"], "native plugin version must be canonical SemVer")
        }
      } catch {
        throw fail(["version"], "native plugin version must be canonical SemVer")
      }
    }
    for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
      try budget.step()
      switch key {
      case "name", "version", "description", "homepage", "repository", "license":
        _ = try text(value, [key])
      case "displayName" where claude: _ = try text(value, [key])
      case "keywords": try strings(value, [key])
      case "author":
        guard case .object(let author) = value, author["name"] != nil else {
          throw fail([key], "native author requires a name")
        }
        for (field, value) in author {
          guard ["name", "email"].contains(field) || (claude && field == "url") else {
            throw fail([key, field], "native author field is not established", .unverified)
          }
          _ = try text(value, [key, field])
        }
      case "metadata" where claude:
        guard case .object = value else { throw fail([key], "native metadata requires an object") }
      case "defaultEnabled" where claude:
        guard case .boolean = value else {
          throw fail([key], "native defaultEnabled requires a boolean")
        }
      case "commands":
        if claude, case .object(let commands) = value {
          for (name, value) in commands {
            guard case .object(let command) = value,
              (command["source"] == nil) != (command["content"] == nil)
            else {
              throw fail([key, name], "native command requires exactly one source or content")
            }
            for (field, value) in command {
              switch field {
              case "source": _ = try path(value, [key, name, field], kind: .file, suffix: ".md")
              case "content", "description", "argumentHint", "model":
                _ = try text(value, [key, name, field])
              case "allowedTools": try strings(value, [key, name, field])
              default:
                throw fail(
                  [key, name, field], "unknown native command field would lose intent", .unverified)
              }
            }
          }
        } else {
          try paths(value, [key])
        }
      case "agents":
        try paths(value, [key], kind: claude ? .file : nil, suffix: claude ? ".md" : nil)
      case "skills": try paths(value, [key], kind: claude ? .directory : nil)
      case "rules" where !claude: try paths(value, [key])
      case "hooks", "mcpServers": try configurations(value, field: key)
      case "lspServers" where claude: try configurations(value, field: key)
      case "variables" where !claude:
        try variables(value, field: [key], root: true)
      case "userConfig" where claude:
        try userConfig(value)
      case "dependencies" where claude:
        throw fail(
          [key],
          "native plugin dependencies require linked/frozen dependency closure rather than native installer resolution",
          .integrationRequired)
      case "logo" where !claude:
        let logo = try text(value, [key])
        if !logo.hasPrefix("https://") && !logo.hasPrefix("http://") {
          _ = try path(value, [key], kind: .file)
        }
      default:
        throw fail(
          [key], "native field needs its exact container/registration contract", .unverified)
      }
    }
    // Native defaults retain their own merge/replacement behavior. They are not rewritten.
    let defaults = try NativeComponentFieldsV1.pluginDefaults(
      surface: surface, explicitFields: Set(fields.keys))
    try budget.step(entries.count * 3)
    for field in claude ? ["hooks", "mcpServers", "lspServers"] : ["hooks", "mcpServers"] {
      guard let file = defaults[field], entries.contains(where: { $0.path == file }) else {
        continue
      }
      let value = try json(file, field: [field, "default"])
      try configuration(value, field: field, wrapped: true)
    }
  }

  func configurations(_ value: NativeValue, field: String) throws {
    try budget.step()
    if case .array(let values) = value {
      guard claude || field == "mcpServers" else {
        throw fail([field], "native hooks do not accept an array of configuration sources")
      }
      for value in values { try configurations(value, field: field) }
    } else if case .string = value {
      if claude, field == "mcpServers" {
        let source = try text(value, [field])
        if source.hasSuffix(".mcpb") || source.hasSuffix(".dxt") {
          throw fail(
            [field],
            "native MCP bundle extraction and registration require frozen typed children and closed E/D routes",
            .integrationRequired)
        }
      }
      let relative = try path(value, [field], kind: .file, suffix: ".json")
      try configuration(json(relative, field: [field]), field: field, wrapped: true)
    } else {
      guard claude else {
        throw fail(
          [field],
          "the exact inline Cursor container wrapper requires a primary schema/example beyond its documented object type",
          .unverified)
      }
      try configuration(value, field: field, wrapped: false)
    }
  }

  func configuration(_ value: NativeValue, field: String, wrapped: Bool) throws {
    guard case .object(let root) = value else {
      throw fail([field], "native config requires an object")
    }
    let map: [String: NativeValue]
    if wrapped && field != "lspServers" {
      let allowed: Set<String>
      if field == "mcpServers" {
        allowed = [field, "$schema"]
      } else {
        allowed = claude ? [field, "description"] : [field, "version"]
      }
      guard Set(root.keys).isSubset(of: allowed) else {
        throw fail(
          [field], "native file root contains fields outside the captured wrapper profile",
          .unverified)
      }
      guard case .object(let entries) = root[field] else {
        throw fail(
          [field], "native file requires its component wrapper",
          field == "mcpServers" ? .unverified : .invalid)
      }
      if let description = root["description"] {
        _ = try text(description, [field, "description"])
      }
      if let schema = root["$schema"] { _ = try text(schema, [field, "$schema"]) }
      if let version = root["version"] {
        let one: Bool
        switch version {
        case .integer(let value): one = value == 1
        case .decimal(let value): one = Double(value) == 1
        default: one = false
        }
        guard one else {
          throw fail(
            [field, "version"], "native hook file version is outside the fixed version-one profile",
            .unverified)
        }
      }
      map = entries
    } else {
      map = root
    }
    switch field {
    case "hooks": try hooks(map)
    case "lspServers":
      for (name, value) in map { try lsp(value, field: [field, name]) }
    case "mcpServers":
      for (name, value) in map { try mcp(value, field: [field, name]) }
    default: throw fail([field], "unknown native config profile")
    }
  }

  func hooks(_ events: [String: NativeValue]) throws {
    for (event, value) in events {
      try budget.step()
      guard
        (claude ? NativeDocumentedHooksV1.claudeEvents : NativeDocumentedHooksV1.cursorEvents)
          .contains(event), case .array(let entries) = value
      else {
        throw fail(["hooks", event], "native hook event or handler array is invalid")
      }
      for entry in entries {
        guard case .object(let object) = entry else {
          throw fail(["hooks", event], "native hook entry requires an object")
        }
        if claude {
          guard Set(object.keys).isSubset(of: ["matcher", "hooks"]),
            case .array(let handlers) = object["hooks"]
          else {
            throw fail(["hooks", event], "Claude hook group requires matcher/hooks fields")
          }
          if let matcher = object["matcher"] {
            let pattern = try text(matcher, ["hooks", event, "matcher"])
            guard NativeDocumentedHooksV1.admittedMatcher(pattern) else {
              throw fail(
                ["hooks", event, "matcher"],
                "exact native JavaScript regex admission is required beyond this fragment profile",
                .unverified)
            }
            guard !NativeDocumentedHooksV1.claudeWithoutMatcher.contains(event) else {
              throw fail(
                ["hooks", event, "matcher"], "this native event ignores matchers", .unsupported)
            }
          }
          for handler in handlers { try handlerFields(handler, event: event) }
        } else {
          try handlerFields(entry, event: event)
        }
      }
    }
  }

  func handlerFields(_ value: NativeValue, event: String) throws {
    try budget.step()
    guard case .object(let handler) = value else {
      throw fail(["hooks", event], "native handler requires an object")
    }
    let type = try text(
      handler["type"] ?? (claude ? .null : .string("command")), ["hooks", event, "type"])
    guard
      claude
        ? ["command", "http", "prompt", "agent", "mcp_tool"].contains(type) : type == "command"
    else {
      throw fail(
        ["hooks", event, "type"],
        claude ? "native handler type is not established" : "Cursor plugin hooks are command-only",
        .unsupported)
    }
    if claude {
      let promptAndAgentEvents: Set<String> = [
        "PermissionDenied", "PostToolBatch", "PostToolUse", "PostToolUseFailure", "PreToolUse",
        "Stop", "SubagentStop", "TaskCompleted", "TaskCreated", "TeammateIdle",
        "UserPromptExpansion", "UserPromptSubmit",
      ]
      if (type == "agent" && !promptAndAgentEvents.contains(event))
        || (type == "prompt" && !promptAndAgentEvents.contains(event)
          && event != "PermissionRequest")
        || (type == "http" && ["SessionStart", "Setup"].contains(event))
      {
        throw fail(
          ["hooks", event, "type"], "native event skips this handler type", .unsupported)
      }
    }
    let required: [String]
    switch type {
    case "command": required = ["command"]
    case "http": required = ["url"]
    case "prompt", "agent": required = ["prompt"]
    default: required = ["server", "tool"]
    }
    for key in required { _ = try text(handler[key] ?? .null, ["hooks", event, key]) }
    let specific: Set<String>
    switch type {
    case "command":
      specific =
        claude
        ? ["command", "args", "async", "asyncRewake", "shell", "onFailure"]
        : ["command", "matcher", "failClosed", "loop_limit"]
    case "http": specific = ["url", "headers", "allowedEnvVars", "onFailure"]
    case "prompt", "agent": specific = ["prompt", "model"]
    default: specific = ["server", "tool", "input"]
    }
    for (key, value) in handler {
      let field = ["hooks", event, key]
      guard
        specific.contains(key)
          || (claude ? ["type", "if", "timeout", "statusMessage"] : ["type", "timeout"]).contains(
            key)
      else {
        throw fail(field, "native handler field is not established for its type", .unverified)
      }
      switch key {
      case "type", "command", "url", "prompt", "model", "server", "tool": _ = try text(value, field)
      case "headers":
        guard case .object(let headers) = value else {
          throw fail(field, "native HTTP headers require a string map")
        }
        for (name, value) in headers {
          let header = try text(value, field + [name])
          guard !header.utf8.contains(13), !header.utf8.contains(10) else {
            throw fail(field + [name], "native header contains a line break")
          }
        }
      case "allowedEnvVars": try strings(value, field)
      case "input":
        guard case .object = value else {
          throw fail(field, "native MCP tool input requires an object")
        }
      case "args" where claude: try strings(value, field)
      case "statusMessage" where claude: _ = try text(value, field)
      case "if" where claude:
        _ = try text(value, field)
        guard
          [
            "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "PermissionDenied",
          ].contains(event)
        else { throw fail(field, "native if filters never run on this event", .unsupported) }
      case "matcher" where !claude:
        let pattern = try text(value, field)
        guard NativeDocumentedHooksV1.admittedMatcher(pattern) else {
          throw fail(
            field,
            "exact native JavaScript regex admission is required beyond this fragment profile",
            .unverified)
        }
        guard NativeDocumentedHooksV1.cursorMatcherEvents.contains(event) else {
          throw fail(field, "native matcher target is not established for this event", .unverified)
        }
      case "async" where claude, "asyncRewake" where claude:
        guard case .boolean = value else { throw fail(field, "native flag requires a boolean") }
      case "failClosed" where !claude:
        guard case .boolean = value else { throw fail(field, "native flag requires a boolean") }
        if event == "sessionStart", value == .boolean(true) {
          throw fail(field, "native sessionStart cannot block creation", .unsupported)
        }
      case "timeout":
        guard MCPNativeField.positiveNumber.accepts(value) else {
          throw fail(field, "native timeout requires positive seconds")
        }
        let seconds: Double
        switch value {
        case .integer(let number): seconds = Double(number)
        case .decimal(let number): seconds = Double(number) ?? 0
        default: seconds = 0
        }
        if claude, event == "SessionEnd", seconds > 60 {
          throw fail(field, "native SessionEnd budget is capped at sixty seconds", .unsupported)
        }
      case "loop_limit" where !claude:
        guard ["stop", "subagentStop"].contains(event), MCPNativeField.numberOrNull.accepts(value)
        else {
          throw fail(
            field, "loop_limit applies only to stop/subagentStop and requires a number or null")
        }
      case "shell" where claude:
        guard [.string("bash"), .string("powershell")].contains(value) else {
          throw fail(field, "invalid native shell")
        }
        if handler["args"] != nil {
          throw fail(field, "exec-form native hooks ignore shell", .unsupported)
        }
      case "onFailure" where claude:
        guard [.string("continue"), .string("block")].contains(value) else {
          throw fail(field, "invalid native failure policy")
        }
        if ["Stop", "SubagentStop", "TaskCompleted", "TeammateIdle"].contains(event)
          || handler["async"] == .boolean(true) || handler["asyncRewake"] == .boolean(true)
        {
          throw fail(field, "native hook ignores this failure policy", .unsupported)
        }
      default:
        throw fail(field, "native handler field is not established by this profile", .unverified)
      }
    }
    if claude, type == "mcp_tool", ["SessionStart", "Setup"].contains(event) {
      throw fail(
        ["hooks", event, "type"], "MCP hook availability is not guaranteed during native startup",
        .unverified)
    }
    if claude, handler["timeout"] != nil,
      handler["async"] == .boolean(true) || handler["asyncRewake"] == .boolean(true)
    {
      throw fail(
        ["hooks", event, "timeout"], "native background hook ignores timeout", .unsupported)
    }
  }

  func lsp(_ value: NativeValue, field: [String]) throws {
    try budget.step()
    guard case .object(let config) = value, let command = config["command"],
      case .object(let languages) = config["extensionToLanguage"], !languages.isEmpty
    else {
      throw fail(field, "native LSP requires command and nonempty extensionToLanguage")
    }
    let executable = try text(command, field + ["command"])
    guard !executable.isEmpty, !executable.contains(" ") || executable.hasPrefix("/") else {
      throw fail(field + ["command"], "native executable with spaces must be absolute")
    }
    for (ext, value) in languages {
      guard ext.hasPrefix("."), !(try text(value, field + ["extensionToLanguage", ext])).isEmpty
      else {
        throw fail(
          field + ["extensionToLanguage"],
          "native extensions require a dot prefix and a language ID")
      }
    }
    let rules: [String: MCPNativeField] = [
      "command": .string, "args": .strings, "extensionToLanguage": .object,
      "transport": .oneOf(["stdio", "socket"]), "env": .object,
      "initializationOptions": .object, "settings": .object, "workspaceFolder": .string,
      "startupTimeout": .positiveInteger, "shutdownTimeout": .positiveInteger,
      "requestTimeout": .positiveInteger, "restartOnCrash": .boolean,
      "maxRestarts": .nonnegativeInteger, "diagnostics": .boolean,
    ]
    for (key, value) in config {
      guard let rule = rules[key] else {
        throw fail(field + [key], "unknown strict native LSP field", .unverified)
      }
      guard rule.accepts(value) else {
        throw fail(field + [key], "invalid native LSP field type or range")
      }
      if key == "env", case .object(let env) = value {
        for (name, value) in env { _ = try text(value, field + [key, name]) }
      }
    }
  }

  func mcp(_ value: NativeValue, field: [String]) throws {
    try budget.step()
    guard case .object(let server) = value, (server["command"] == nil) != (server["url"] == nil)
    else {
      throw fail(field, "native MCP needs exactly one command or URL")
    }
    for (key, value) in server {
      switch key {
      case "command", "url": _ = try text(value, field + [key])
      case "cwd" where !claude: _ = try text(value, field + [key])
      case "args": try strings(value, field + [key])
      case "env", "headers":
        guard case .object(let fields) = value else {
          throw fail(field + [key], "native MCP requires a string map")
        }
        for (name, value) in fields { _ = try text(value, field + [key, name]) }
      case "type" where claude:
        guard
          (server["command"] != nil ? [.string("stdio")] : [.string("http"), .string("sse")])
            .contains(value)
        else {
          throw fail(field + [key], "native MCP transport profile is not established", .unverified)
        }
      default:
        throw fail(
          field + [key], "native MCP field/selector requires an exact source contract", .unverified)
      }
    }
  }

  func variables(_ value: NativeValue, field: [String], root: Bool = false) throws {
    try budget.step()
    guard case .object(let schema) = value else {
      throw fail(field, "native variables require a schema object")
    }
    if root, schema["type"] != .string("object") {
      throw fail(field, "native variable schema root must have object type")
    }
    if root {
      guard case .object = schema["properties"] else {
        throw fail(field, "native variable schema root requires properties")
      }
    }
    for (key, value) in schema {
      switch key {
      case "type":
        guard
          [
            .string("object"), .string("string"), .string("number"), .string("integer"),
            .string("boolean"), .string("array"), .string("null"),
          ].contains(value)
        else { throw fail(field + [key], "native variable schema type is invalid") }
      case "title", "description": _ = try text(value, field + [key])
      case "required": try strings(value, field + [key])
      case "properties":
        guard case .object(let properties) = value else {
          throw fail(field + [key], "native schema properties require an object")
        }
        for (name, value) in properties { try variables(value, field: field + [key, name]) }
      case "items": try variables(value, field: field + [key])
      case "enum":
        guard case .array = value else {
          throw fail(field + [key], "native schema enum requires an array")
        }
      case "default", "const": break
      default:
        throw fail(
          field + [key], "native variable schema keyword is not in the captured fixed profile",
          .unverified)
      }
    }
  }

  func userConfig(_ value: NativeValue) throws {
    guard case .object(let entries) = value else {
      throw fail(["userConfig"], "native userConfig requires an object")
    }
    for (name, value) in entries {
      try budget.step()
      let field = ["userConfig", name]
      guard MCPReferenceSyntax.isName(name), case .object(let option) = value,
        case .string(let type) = option["type"],
        ["string", "number", "boolean", "directory", "file"].contains(type)
      else { throw fail(field, "native userConfig requires an identifier and a supported type") }
      _ = try text(option["title"] ?? .null, field + ["title"])
      _ = try text(option["description"] ?? .null, field + ["description"])
      for (key, value) in option {
        switch key {
        case "type", "title", "description": _ = try text(value, field + [key])
        case "required", "multiple", "sensitive":
          guard case .boolean = value else {
            throw fail(field + [key], "native option flag requires a boolean")
          }
          if key == "multiple", type != "string" {
            throw fail(field + [key], "multiple applies only to string options", .unsupported)
          }
        case "min", "max":
          guard type == "number", case .integer = value else {
            if type == "number", case .decimal(let number) = value, Double(number)?.isFinite == true
            {
              continue
            }
            throw fail(
              field + [key], "native numeric bounds require a number option and a finite number")
          }
        case "options":
          guard type == "string", option["multiple"] != .boolean(true),
            option["sensitive"] != .boolean(true), case .array(let options) = value
          else {
            throw fail(field + [key], "native picker options require a non-sensitive single string")
          }
          for value in options {
            let label = try text(value, field + [key])
            guard (1...64).contains(label.utf16.count) else {
              throw fail(field + [key], "native picker label is outside its documented length")
            }
          }
          if let fallback = option["default"], !options.contains(fallback) {
            throw fail(field + ["default"], "native picker default must be a listed option")
          }
          if option["default"] == nil, option["required"] != .boolean(true) {
            throw fail(field + [key], "native picker needs a listed default or required selection")
          }
        case "default":
          if option["sensitive"] == .boolean(true), value != .string("") {
            throw fail(
              field + [key], "sensitive native defaults cannot enter frozen public resources",
              .integrationRequired)
          }
          switch value {
          case .string, .integer, .boolean: break
          case .decimal(let number):
            guard Double(number)?.isFinite == true else {
              throw fail(field + [key], "native default must be finite")
            }
          case .array: try strings(value, field + [key])
          default: throw fail(field + [key], "native default has an unsupported value type")
          }
        default: throw fail(field + [key], "unknown strict native userConfig field")
        }
      }
    }
  }
}
