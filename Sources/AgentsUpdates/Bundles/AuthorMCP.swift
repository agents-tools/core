import AgentsCore
import Components
import Foundation

enum AuthorMCP {
  struct Sanitized {
    let transport: MCPTransportDeclaration
    let native: NativeConfiguration
    let omissions: Int
  }

  static func sanitize(
    _ transport: MCPTransportDeclaration, native: NativeConfiguration, named member: String,
    registry: MCPRegistryEvidence? = nil, registrySchemas: [MCPRegistryServer] = []
  ) throws -> Sanitized {
    var omitted = 0
    func validateBindings(_ fields: [String: RuntimeBinding]) throws {
      var portableNames: Set<String>?
      for name in fields.keys.sorted() {
        let value = fields[name]!
        guard !name.isEmpty, !name.utf8.contains(0) else {
          throw CoreError.invalidSource("invalid MCP binding name")
        }
        switch value {
        case .literal(let text):
          if portableNames == nil, let registry {
            if registrySchemas.isEmpty {
              portableNames = try registry.portableLiteralBindings(in: transport)
            } else {
              try registry.validate(matching: transport)
              portableNames =
                MCPRegistryServer.attestsBindings(
                  in: transport, for: registry, schemas: registrySchemas) ? Set(fields.keys) : []
            }
          }
          guard portableNames?.contains(name) == true, !RegistryInput.isCredentialName(name),
            !looksSecret(text), !personalPath(text)
          else {
            let label = looksSecret(name) ? "binding" : "binding " + name
            throw CoreError.invalidSource(
              "MCP \(member) \(label) has an unattested literal; use an environment or secret "
                + "reference, or supply the exact registry schema for a public value")
          }
        case .environment(let key), .secret(let key):
          guard !key.isEmpty, !key.utf8.contains(0), !looksSecret(key), !personalPath(key) else {
            throw CoreError.invalidSource("invalid symbolic MCP binding key")
          }
        }
      }
    }
    func clean(_ value: NativeValue) throws -> NativeValue? {
      switch value {
      case .string(let text):
        if looksSecret(text) {
          omitted += 1
          return nil
        }
        guard !personalPath(text) else {
          throw CoreError.invalidSource("MCP native overrides cannot contain local paths")
        }
        return value
      case .object(let object):
        return try .object(
          object.reduce(into: [:]) { result, pair in
            if credentialKey(pair.key) || looksSecret(pair.key) {
              omitted += 1
            } else {
              result[pair.key] = try clean(pair.value)
            }
          })
      case .array(let items): return try .array(items.compactMap(clean))
      default: return value
      }
    }
    let cleaned: MCPTransportDeclaration
    switch transport {
    case .stdio(var run):
      guard !looksSecret(run.executable),
        !run.executable.isEmpty, !run.executable.utf8.contains(0)
      else { throw CoreError.invalidSource("nonportable MCP executable") }
      if run.executable.contains("/") {
        _ = try resourcePath(run.executable)
      } else {
        guard
          run.executable.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression)
            != nil
        else { throw CoreError.invalidSource("nonportable MCP executable") }
      }
      if let workingDirectory = run.workingDirectory {
        _ = try resourcePath(workingDirectory.path)
      }
      try validateBindings(run.environment)
      var args: [String] = []
      var pending = run.arguments[...]
      while let argument = pending.popFirst() {
        if argument.hasPrefix("-"),
          credentialKey(String(argument.prefix { $0 != "=" && !$0.isWhitespace }))
        {
          omitted += 1
          if !argument.contains("="), !argument.contains(where: \.isWhitespace),
            pending.first.map({ !$0.hasPrefix("-") }) == true
          {
            _ = pending.popFirst()
            omitted += 1
          }
        } else if looksSecret(argument) {
          omitted += 1
        } else {
          guard !argument.utf8.contains(0), !personalPath(argument) else {
            throw CoreError.invalidSource("MCP arguments cannot contain local absolute paths")
          }
          args.append(argument)
        }
      }
      run.arguments = args
      cleaned = .stdio(run)
    case .streamableHTTP(let url, let headers):
      try endpoint(url)
      try validateBindings(headers)
      cleaned = transport
    case .sse(let url, let headers):
      try endpoint(url)
      try validateBindings(headers)
      cleaned = transport
    }
    var nativeOutput: NativeConfiguration = [:]
    for (client, fields) in native {
      guard !looksSecret(client) else {
        throw CoreError.invalidSource("invalid MCP native client name")
      }
      var unverified = fields
      let bearerKey = "bearer_token_env_var"
      let bearer =
        client == AgentID.codex.rawValue ? unverified.removeValue(forKey: bearerKey) : nil
      guard case .object(var result) = try clean(.object(unverified)) else { continue }
      if let bearer {
        guard case .string(let variable) = bearer, !looksSecret(variable) else {
          throw CoreError.invalidSource(
            "Codex bearer authentication needs an environment variable name")
        }
        try DeploymentConstruction.validateMCP(
          cleaned, named: member, agent: .codex, scope: .project,
          native: [client: [bearerKey: bearer]], requiresSymbolicBindings: false)
        result[bearerKey] = bearer
      }
      if !result.isEmpty { nativeOutput[client] = result }
    }
    return Sanitized(transport: cleaned, native: nativeOutput, omissions: omitted)
  }

  static func configuration(
    name: String, transport: MCPTransportDeclaration, native: NativeConfiguration
  ) throws -> LedgerValue {
    let value = try LedgerPayload.component(
      .mcpServer(
        name: name, transport: transport, agents: nil, condition: nil, native: native, registry: nil
      ))
    return .init(object: [
      "transport": value.object!["transport"]!, "native": value.object!["native"]!,
    ])
  }

  static func resourcePath(_ path: String) throws -> String {
    let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    try BundleItem.validatePath(relative)
    try AuthorContentAudit.requirePublishable(relative)
    return relative
  }

  private static func endpoint(_ url: String) throws {
    _ = try SourceOrigin.http(url)
    guard !looksSecret(url), let components = URLComponents(string: url),
      !(components.queryItems ?? []).contains(where: {
        credentialKey($0.name) || $0.value.map(looksSecret) == true
      })
    else { throw CoreError.invalidSource("MCP endpoint cannot contain credential literals") }
  }

  private static func credentialKey(_ key: String) -> Bool {
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return ["env", "environment", "headers", "authorization", "auth", "cookie"].contains(normalized)
      || normalized.hasSuffix("headers")
      || ["token", "secret", "password", "credential", "key"].contains(where: normalized.contains)
  }

  private static func personalPath(_ value: String) -> Bool {
    value.range(
      of: #"(?i)(?:^|[\s=])(?:/|~(?:/|[[:alnum:]]+/)|[a-z]:[/\\]|file:)"#,
      options: .regularExpression) != nil
  }

  private static func looksSecret(_ text: String) -> Bool {
    text.range(
      of:
        #"(?i)(?:\b(?:bearer|basic)\s+\S+|\b[a-z][a-z0-9+.-]*://[^/\s@]+@|(?:^|\s)(?:--)?[\w-]*(?:token|secret|password|credential|api[-_]?key)[\w-]*[=\s]+\S+|^[A-Z][A-Z0-9_]*=\S+|(?:gh[pousr]_|github_pat_|sk-(?:proj-)?|xox[baprs]-|AKIA|ASIA|AIza|glpat-|npm_|pypi-|hf_|(?:sk|rk)_(?:test|live)_|SG\.|dapi)[a-z0-9_-]{12,})"#,
      options: .regularExpression) != nil
  }
}

extension BundleItem {
  func forSharing(registrySchemas: [MCPRegistryServer]) throws -> (item: Self, omissions: Int) {
    guard kind == .mcpServer else { return (self, 0) }
    let result = try AuthorMCP.sanitize(
      transport(), native: native(), named: name, registry: mcpRegistry,
      registrySchemas: registrySchemas)
    guard result.omissions != 0 else { return (self, 0) }
    return try (
      .init(
        kind: kind, name: name, sources: sources, entries: entries, discovery: discovery,
        configuration: AuthorMCP.configuration(
          name: name, transport: result.transport, native: result.native),
        mcpRegistry: mcpRegistry), result.omissions
    )
  }
}
