import AgentsCore

/// Codex env_vars forwards the same variable name; it is not an environment rename operation.
enum CodexAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      try entry.command(run)
      try entry.workingDirectory(run)
      var forwarded: [LedgerValue] = []
      var environment: [String: LedgerValue] = [:]
      for (key, binding) in run.environment.sorted(by: { $0.key < $1.key }) {
        if case .environment(let source) = binding, source == key {
          try input.environmentName(source, field: ["transport", "environment", key])
          entry.placements.append(
            .init(
              path: [.key("env_vars"), .index(forwarded.count)], binding: binding, reference: true))
          forwarded.append(.init(source))
        } else {
          environment[key] = try entry.binding(
            binding, path: [.key("env"), .key(key)], reference: nil)
        }
      }
      if !environment.isEmpty { entry.fields["env"] = .init(object: environment) }
      if !forwarded.isEmpty { entry.fields["env_vars"] = .init(array: forwarded) }
    case .streamableHTTP(let url, let headers):
      try entry.url(url)
      var literal: [String: LedgerValue] = [:]
      var references: [String: LedgerValue] = [:]
      for (key, binding) in headers.sorted(by: { $0.key < $1.key }) {
        if case .environment(let name) = binding {
          try input.environmentName(name, field: ["transport", "headers", key])
          references[key] = .init(name)
          entry.placements.append(
            .init(path: [.key("env_http_headers"), .key(key)], binding: binding, reference: true))
        } else {
          literal[key] = try entry.binding(
            binding, path: [.key("http_headers"), .key(key)], reference: nil)
        }
      }
      if !literal.isEmpty { entry.fields["http_headers"] = .init(object: literal) }
      if !references.isEmpty { entry.fields["env_http_headers"] = .init(object: references) }
    case .sse:
      throw input.issue(
        ["transport", "kind"], .unsupported,
        "the pinned Codex transport enum has no legacy SSE variant")
    }
    var rules: [String: MCPNativeField] = [
      "enabled": .boolean, "required": .boolean,
      "startup_timeout_sec": .durationSeconds, "tool_timeout_sec": .durationSeconds,
    ]
    if case .streamableHTTP = input.transport { rules["bearer_token_env_var"] = .environmentName }
    try entry.nativeFields(rules)
    if input.native["bearer_token_env_var"] != nil {
      let hasAuthorization = ["http_headers", "env_http_headers"].contains { field in
        entry.fields[field]?.object?.keys.contains { $0.lowercased() == "authorization" } == true
      }
      guard !hasAuthorization else {
        throw input.issue(
          ["native", "bearer_token_env_var"], .invalid,
          "bearer token and explicit Authorization header overlap")
      }
    }
    return entry
  }
}
