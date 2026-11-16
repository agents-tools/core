import AgentsCore
import Foundation
import NativeDocuments

enum NativeSourceImport {
  static func read(
    _ input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    switch input.profile {
    case .geminiIgnoreV1, .cursorIgnoreV1:
      let bytes = try ImportInput.bytes(input, limits: limits)
      guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
        throw ImportReadFailure.invalid
      }
      let patterns = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
      let origin = ImportLocation(document: input.document, pointer: "")
      NativeImportInput.emit(
        .ignore(
          name: "native-context", patterns: patterns,
          agents: [NativeImportInput.agent(input.profile)]),
        selector: .ignore(name: "native-context"), origin: origin, container: ".",
        profile: input.profile, into: &diagnostics)
      try NativeImportInput.resource(
        input.document, root: ".", input: input, origin: origin, limits: limits, into: &diagnostics)
    case .claudePluginV1, .cursorPluginV1, .geminiExtensionV1:
      try NativeContainerImport.read(input, limits: limits, into: &diagnostics)
    case .claudeMarketplaceV1:
      try NativeCatalogImport.read(input, limits: limits, into: &diagnostics)
    case .claudeCommandV1, .claudeAgentV1, .geminiCommandV1, .geminiAgentV1,
      .openCodeCommandV2, .openCodeAgentV2, .cursorCommandV1, .cursorAgentV1:
      try NativeMemberImport.read(input, container: ".", limits: limits, into: &diagnostics)
    default:
      let format: NativeDocumentFormat =
        input.profile == .codexConfigV1 ? .toml : .jsonc(trailingCommas: true)
      let parsed = try NativeImportDocument(input, format: format, limits: limits)
      let root = "."
      _ = NativeImportInput.source(input, root: root, origin: parsed.location(), into: &diagnostics)
      let wrapper =
        input.profile == .codexConfigV1
        ? "mcp_servers" : input.profile == .openCodeConfigV2 ? "mcp" : "mcpServers"
      if let value = parsed.fields[wrapper] {
        if input.profile == .openCodeConfigV2 {
          guard let fields = value.importObject else { throw ImportReadFailure.invalid }
          NativeImportInput.unknown(
            fields, allowed: ["servers"], at: parsed.location([wrapper]), into: &diagnostics)
          if let servers = fields["servers"] {
            try mcp(
              servers, parsed: parsed, keys: [wrapper, "servers"], container: root,
              limits: limits, into: &diagnostics)
          }
        } else {
          try mcp(
            value, parsed: parsed, keys: [wrapper], container: root, limits: limits,
            into: &diagnostics)
        }
      }
      var converted: Set<String> = [wrapper, "$schema"]
      if input.profile == .openCodeConfigV2 {
        for (key, kind) in [("commands", "command"), ("agents", "subagent")]
        where parsed.fields[key] != nil {
          try openCodeMembers(
            parsed.fields[key]!, kind: kind, parsed: parsed, key: key, into: &diagnostics)
          converted.insert(key)
        }
        if let value = parsed.fields["permissions"] {
          permissions(value, parsed: parsed, into: &diagnostics)
          converted.insert("permissions")
        }
      }
      if input.profile == .codexConfigV1, let agents = parsed.fields["agents"] {
        try codexAgents(agents, parsed: parsed, limits: limits, into: &diagnostics)
        converted.insert("agents")
      }
      if let value = parsed.fields["hooks"] {
        try hooks(
          value, parsed: parsed, keys: ["hooks"], container: root, limits: limits,
          into: &diagnostics)
        converted.insert("hooks")
      }
      if input.profile == .openCodeConfigV2, let value = parsed.fields["lsp"] {
        try lsp(
          value, parsed: parsed, keys: ["lsp"], container: root, limits: limits, into: &diagnostics)
        converted.insert("lsp")
      }
      if input.profile == .claudeSettingsV1, let value = parsed.fields["permissions"] {
        if let fields = value.importObject,
          Set(fields.keys).isSubset(of: ["allow", "ask", "deny"]),
          fields.values.allSatisfy(MCPNativeField.strings.accepts)
        {
          NativeImportInput.emit(
            .permissions(
              name: "native-policy", rules: [], agents: [.claudeCode],
              native: [AgentID.claudeCode.rawValue: fields]),
            selector: .permissions(name: "native-policy"), origin: parsed.location(["permissions"]),
            container: root,
            profile: input.profile, into: &diagnostics, admission: parsed.admission)
        } else {
          NativeImportInput.unconverted(
            value, at: parsed.location(["permissions"]), into: &diagnostics)
        }
        converted.insert("permissions")
      }
      NativeImportInput.unknown(
        parsed.fields, allowed: converted, at: parsed.location(), into: &diagnostics)
      let privateInput = diagnostics.proposal.bindings.contains {
        $0.location.document == input.document
      }
      try NativeImportInput.resource(
        input.document, root: root, input: input, origin: parsed.location(),
        limits: limits, rewrite: privateInput, into: &diagnostics, admission: parsed.admission)
    }
  }

  /// A full parsed map is classified even when only a subset contributes canonical members.
  static func classifyMembers(
    _ value: NativeValue, parsed: NativeImportDocument, keys: [String],
    into diagnostics: inout ImportDiagnostics
  ) throws {
    guard let members = value.importObject else { throw ImportReadFailure.invalid }
    for name in members.keys.sorted() {
      try Task.checkCancellation()
      let origin = try parsed.memberLocation(keys, name: name)
      if let fields = members[name]?.importObject {
        NativeImportInput.preservationBindings(
          fields, at: origin, profile: parsed.input.profile, into: &diagnostics)
      } else {
        _ = NativeImportInput.sensitive(members[name]!, at: origin, into: &diagnostics)
      }
    }
  }

  static func mcp(
    _ value: NativeValue, parsed: NativeImportDocument, keys: [String],
    container: String, limits: SourceImportLimits, into diagnostics: inout ImportDiagnostics
  ) throws {
    guard case .object(let servers) = value else { throw ImportReadFailure.invalid }
    try classifyMembers(value, parsed: parsed, keys: keys, into: &diagnostics)
    let agent = NativeImportInput.agent(parsed.input.profile)
    for name in servers.keys.sorted() {
      try Task.checkCancellation()
      if ![SourceImportProfile.claudePluginV1, .cursorPluginV1, .geminiExtensionV1].contains(
        parsed.input.profile),
        !(parsed.input.selection?.contains(name) ?? true)
      {
        continue
      }
      let location = try parsed.memberLocation(keys, name: name)
      guard NativeImportInput.name(name), case .object(let fields) = servers[name] else {
        NativeImportInput.unconverted(servers[name]!, at: location, into: &diagnostics)
        continue
      }
      do {
        guard
          ["type", "url", "httpUrl", "cwd"].allSatisfy({
            fields[$0] == nil || fields[$0]?.importString != nil
          })
        else { throw ImportReadFailure.invalid }
        var allowed: Set<String> = ["command", "args", "env", "type", "url", "headers"]
        if agent == .codex {
          allowed = [
            "command", "args", "env", "cwd", "env_vars", "url", "http_headers", "env_http_headers",
          ]
        }
        if agent == .geminiCLI {
          allowed.insert("cwd")
          allowed.insert("httpUrl")
        }
        if agent == .opencode {
          allowed = [
            "type", "command", "environment", "cwd", "url", "headers", "codemode", "oauth",
          ]
        }
        let extra = fields.filter { !allowed.contains($0.key) }
        for (index, key) in extra.keys.sorted().enumerated() where ImportInput.credentialField(key)
        {
          diagnostics.binding(location.appending("native/member[\(index)]"))
        }
        let transport: MCPTransportDeclaration
        let explicit = fields["type"]?.importString
        var native: NativeConfiguration = extra.isEmpty ? [:] : [agent.rawValue: extra]
        if agent == .opencode, fields["codemode"] != nil {
          guard case .boolean = fields["codemode"]! else { throw ImportReadFailure.invalid }
          native[agent.rawValue, default: [:]]["codemode"] = fields["codemode"]
        }
        if agent == .opencode, let oauth = fields["oauth"] {
          guard oauth == .boolean(false) else {
            NativeImportInput.unconverted(
              oauth, at: location.appending("oauth"), into: &diagnostics)
            continue
          }
          native[agent.rawValue, default: [:]]["oauth"] = oauth
        }
        if let url = fields["url"]?.importString ?? fields["httpUrl"]?.importString {
          guard fields["command"] == nil, ImportInput.safeLocator(url),
            let address = URLComponents(string: url), ["https", "http"].contains(address.scheme),
            address.host != nil
          else {
            if !ImportInput.safeLocator(url) { diagnostics.binding(location.appending("url")) }
            throw ImportReadFailure.invalid
          }
          let inappropriate: Set<String> = ["args", "env", "env_vars", "environment", "cwd"]
          if !Set(fields.keys).isDisjoint(with: inappropriate) {
            for key in inappropriate where fields[key] != nil {
              NativeImportInput.unconverted(
                fields[key]!, at: location.appending(key), into: &diagnostics)
            }
            continue
          }
          if agent == .opencode, fields["codemode"] == nil {
            native[agent.rawValue, default: [:]]["codemode"] = .boolean(true)
          }
          let headerKey = agent == .codex ? "http_headers" : "headers"
          var headers = try NativeImportInput.bindings(
            fields[headerKey], at: location.appending(headerKey), into: &diagnostics,
            profile: parsed.input.profile)
          if agent == .codex {
            let refs = try NativeImportInput.bindings(
              fields["env_http_headers"], at: location.appending("env_http_headers"),
              symbolic: true, into: &diagnostics, profile: parsed.input.profile)
            guard Set(headers.keys).isDisjoint(with: refs.keys) else {
              throw ImportReadFailure.invalid
            }
            headers.merge(refs) { first, _ in first }
          }
          if agent == .codex || (agent == .opencode && explicit == "remote") || explicit == "http"
            || fields["httpUrl"] != nil
          {
            transport = .streamableHTTP(url: url, headers: headers)
          } else if agent == .claudeCode || agent == .geminiCLI, explicit == "sse" {
            transport = .sse(url: url, headers: headers)
          } else {
            diagnostics.add(
              .unconverted, location,
              "Native remote transport is not fixed by this input; no HTTP/SSE transport is guessed."
            )
            continue
          }
        } else {
          guard explicit == nil || explicit == (agent == .opencode ? "local" : "stdio") else {
            throw ImportReadFailure.invalid
          }
          if fields["headers"] != nil || fields["http_headers"] != nil
            || fields["env_http_headers"] != nil
          {
            for key in ["headers", "http_headers", "env_http_headers"] where fields[key] != nil {
              _ = try NativeImportInput.bindings(
                fields[key], at: location.appending(key), into: &diagnostics)
              NativeImportInput.unconverted(
                fields[key]!, at: location.appending(key), into: &diagnostics)
            }
            continue
          }
          var executable: String
          var arguments: [String]
          if agent == .opencode {
            guard let argv = fields["command"]?.importStrings, let first = argv.first,
              !first.isEmpty
            else { throw ImportReadFailure.invalid }
            executable = first
            arguments = Array(argv.dropFirst())
          } else {
            guard let command = fields["command"]?.importString, !command.isEmpty else {
              throw ImportReadFailure.invalid
            }
            executable = command
            guard fields["args"] == nil || fields["args"]?.importStrings != nil else {
              throw ImportReadFailure.invalid
            }
            arguments = fields["args"]?.importStrings ?? []
          }
          guard !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") }) else {
            throw ImportReadFailure.invalid
          }
          var unrepresentableArgument = false
          for (offset, argument) in arguments.enumerated() {
            let flag =
              argument.hasPrefix("--")
              ? String(argument.dropFirst(2).split(separator: "=", maxSplits: 1).first ?? "") : ""
            if ImportInput.credentialField(flag)
              || (argument.contains("://") && !ImportInput.safeLocator(argument))
            {
              diagnostics.binding(location.appending("args/\(offset)"))
              diagnostics.add(
                .unconverted, location.appending("args/\(offset)"),
                "Secret arguments require a typed argument binding slot; the argument literal is not retained."
              )
              unrepresentableArgument = true
            }
            if argument.contains("${CLAUDE_PLUGIN_ROOT}") || argument.contains("${extensionPath}") {
              diagnostics.add(
                .unconverted, location.appending("args/\(offset)"),
                "Native argument resource substitution has no typed canonical argument-resource slot; no extraction path is substituted."
              )
              unrepresentableArgument = true
            }
          }
          if unrepresentableArgument { continue }
          let environmentKey = agent == .opencode ? "environment" : "env"
          var environment = try NativeImportInput.bindings(
            fields[environmentKey], at: location.appending(environmentKey), into: &diagnostics,
            profile: parsed.input.profile)
          if agent == .codex, let value = fields["env_vars"] {
            guard let variables = value.importStrings else { throw ImportReadFailure.invalid }
            for (offset, variable) in variables.enumerated() {
              guard
                variable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression)
                  != nil,
                environment[variable] == nil
              else { throw ImportReadFailure.invalid }
              environment[variable] = NativeImportInput.binding(
                location.appending("env_vars/\(offset)"), environment: variable, into: &diagnostics)
            }
          }
          var cwd: ResourceDeclaration?
          if let value = fields["cwd"] {
            guard [.codex, .geminiCLI, .opencode].contains(agent),
              let authoredPath = value.importString
            else { throw ImportReadFailure.invalid }
            let path = try nativePath(authoredPath, container: container)
            try NativeImportInput.resource(
              path, root: container, input: parsed.input, origin: location.appending("cwd"),
              limits: limits, into: &diagnostics, admission: parsed.admission)
            cwd = .init(path: path, source: "native-input")
          }
          if parsed.input.profile == .claudePluginV1, executable.hasPrefix("${CLAUDE_PLUGIN_ROOT}/")
          {
            executable = "./" + executable.dropFirst("${CLAUDE_PLUGIN_ROOT}/".count)
          } else if parsed.input.profile == .geminiExtensionV1,
            executable.hasPrefix("${extensionPath}/")
          {
            executable = "./" + executable.dropFirst("${extensionPath}/".count)
          }
          if executable.hasPrefix("./") {
            let path = try nativePath(executable, container: container)
            try NativeImportInput.resource(
              path, root: container, input: parsed.input, origin: location.appending("command"),
              limits: limits, into: &diagnostics, admission: parsed.admission)
            executable = path.contains("/") ? path : "./" + path
          } else if executable.contains("/") {
            diagnostics.add(
              .unconverted, location.appending("command"),
              "Native executable outside the explicit container requires a caller-selected resource; no host executable is read."
            )
            continue
          }
          transport = .stdio(
            .init(
              executable: executable, arguments: arguments, environment: environment,
              workingDirectory: cwd))
        }
        var resourceCoordinates: [String] = []
        if case .stdio(let run) = transport {
          if run.executable.contains("/") { resourceCoordinates.append(run.executable) }
          if let cwd = run.workingDirectory { resourceCoordinates.append(cwd.path) }
        }
        try NativeImportSemantics.mcp(
          name: name, transport: transport, native: native[agent.rawValue] ?? [:],
          profile: parsed.input.profile, resources: resourceCoordinates)
        if let bearer = extra["bearer_token_env_var"]?.importString {
          _ = NativeImportInput.binding(
            location.appending("bearer_token_env_var"), environment: bearer, into: &diagnostics)
        }
        NativeImportInput.emit(
          .mcpServer(name: name, transport: transport, agents: [agent], native: native),
          selector: .mcpServer(name: name), origin: location, container: container,
          profile: parsed.input.profile, into: &diagnostics)
      } catch let issue as NativeAdapterIssue {
        diagnostics.add(
          issue.reason == .invalid ? .invalidInput : .unconverted, location,
          "F's fixed native field profile cannot admit this member; its field/default semantics are not converted."
        )
      } catch is CancellationError { throw CancellationError() } catch CoreError.unsafePath {
        diagnostics.add(.unsafePath, location, "Native resource escapes its format-owned root.")
      } catch {
        diagnostics.add(
          .invalidInput, location,
          "Native MCP member is malformed or its resource is missing; no partial server is imported."
        )
      }
    }
  }

  static func nativePath(_ path: String, container: String) throws -> String {
    guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("://"),
      !path.split(separator: "/").contains("..")
    else { throw CoreError.unsafePath("native resource") }
    return try ImportInput.path(path)
  }

  private static func openCodeMembers(
    _ value: NativeValue, kind: String,
    parsed: NativeImportDocument, key: String, into diagnostics: inout ImportDiagnostics
  ) throws {
    guard case .object(let entries) = value else { throw ImportReadFailure.invalid }
    try classifyMembers(value, parsed: parsed, keys: [key], into: &diagnostics)
    for (index, name) in entries.keys.sorted().enumerated() {
      guard parsed.input.selection?.contains(name) ?? true else { continue }
      let origin = parsed.location([key, name], display: "/\(key)/member[\(index)]")
      guard NativeImportInput.name(name), let fields = entries[name]?.importObject else {
        NativeImportInput.unconverted(entries[name]!, at: origin, into: &diagnostics)
        continue
      }
      let bodyKey = kind == "command" ? "template" : "system"
      let allowed: Set<String> =
        kind == "command"
        ? ["template", "description"] : ["system", "description", "mode", "model"]
      NativeImportInput.unknown(fields, allowed: allowed, at: origin, into: &diagnostics)
      guard Set(fields.keys).isSubset(of: allowed), let body = fields[bodyKey]?.importString,
        fields["description"] == nil || fields["description"]?.importString != nil,
        fields["model"] == nil || fields["model"]?.importString != nil,
        kind == "command" || fields["mode"] == .string("subagent")
      else {
        NativeImportInput.unconverted(entries[name]!, at: origin, into: &diagnostics)
        continue
      }
      let description = fields["description"]?.importString ?? ""
      if kind == "command" {
        NativeImportInput.emit(
          .command(
            name: name, description: description, prompt: .literal(body), agents: [.opencode]),
          selector: .command(name: name), origin: origin, container: ".",
          profile: parsed.input.profile, into: &diagnostics)
      } else {
        NativeImportInput.emit(
          .subagent(
            name: name, description: description, prompt: .literal(body),
            model: fields["model"]?.importString, agents: [.opencode]),
          selector: .subagent(name: name), origin: origin, container: ".",
          profile: parsed.input.profile, into: &diagnostics)
      }
    }
  }

  private static func permissions(
    _ value: NativeValue, parsed: NativeImportDocument,
    into diagnostics: inout ImportDiagnostics
  ) {
    guard case .array(let entries) = value else {
      NativeImportInput.unconverted(value, at: parsed.location(["permissions"]), into: &diagnostics)
      return
    }
    var rules: [PermissionRuleDeclaration] = []
    for (index, entry) in entries.enumerated() {
      guard let fields = entry.importObject, Set(fields.keys) == ["action", "resource", "effect"],
        let action = fields["action"]?.importString,
        let resource = fields["resource"]?.importString,
        let effect = fields["effect"]?.importString, ["allow", "ask", "deny"].contains(effect)
      else {
        NativeImportInput.unconverted(
          entry, at: parsed.location(["permissions"]).appending(String(index)), into: &diagnostics)
        return
      }
      switch effect {
      case "allow": rules.append(.allow(.tool(action), resource))
      case "ask": rules.append(.ask(.tool(action), resource))
      default: rules.append(.deny(.tool(action), resource))
      }
    }
    NativeImportInput.emit(
      .permissions(name: "native-policy", rules: rules, agents: [.opencode]),
      selector: .permissions(name: "native-policy"), origin: parsed.location(["permissions"]),
      container: ".", profile: parsed.input.profile, into: &diagnostics)
  }

  private static func codexAgents(
    _ value: NativeValue, parsed: NativeImportDocument,
    limits: SourceImportLimits, into diagnostics: inout ImportDiagnostics
  ) throws {
    guard case .object(let agents) = value else { throw ImportReadFailure.invalid }
    try classifyMembers(value, parsed: parsed, keys: ["agents"], into: &diagnostics)
    for (index, name) in agents.keys.sorted().enumerated() {
      guard parsed.input.selection?.contains(name) ?? true else { continue }
      let origin = parsed.location(["agents", name], display: "/agents/member[\(index)]")
      guard NativeImportInput.name(name), let fields = agents[name]?.importObject,
        Set(fields.keys).isSubset(of: ["description", "config_file"]),
        let description = fields["description"]?.importString,
        let file = fields["config_file"]?.importString
      else {
        NativeImportInput.unconverted(agents[name]!, at: origin, into: &diagnostics)
        continue
      }
      // Codex role paths are relative to the declaring config directory, unlike plugin paths.
      let parent = (parsed.input.document as NSString).deletingLastPathComponent
      let relative = try nativePath(file, container: parent)
      let path = parent.isEmpty ? relative : parent + "/" + relative
      var request = parsed.input
      request = .init(profile: request.profile, root: request.root, document: path)
      let role = try NativeImportDocument(
        request, format: .toml, limits: limits, admission: parsed.admission)
      NativeImportInput.unknown(
        role.fields, allowed: ["developer_instructions", "model"], at: role.location(),
        into: &diagnostics)
      guard Set(role.fields.keys).isSubset(of: ["developer_instructions", "model"]),
        let body = role.fields["developer_instructions"]?.importString
      else { continue }
      NativeImportInput.emit(
        .subagent(
          name: name, description: description, prompt: .literal(body),
          model: role.fields["model"]?.importString, agents: [.codex]),
        selector: .subagent(name: name), origin: role.location(["developer_instructions"]),
        container: ".", profile: parsed.input.profile, into: &diagnostics)
      try NativeImportInput.resource(
        path, root: ".", input: parsed.input, origin: role.location(), limits: limits,
        into: &diagnostics, admission: parsed.admission)
    }
  }
}
