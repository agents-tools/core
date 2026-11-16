import AgentsCore

/// OpenCode 2 remote is Streamable HTTP. protocol selects MCP negotiation, not transport.
enum OpenCodeAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    try input.literal(input.name, field: ["name"])
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      entry.fields["type"] = .init("local")
      try entry.command(run, argv: true)
      try entry.workingDirectory(run)
      try entry.bindings(run.environment, field: "environment", reference: .openCode)
    case .streamableHTTP(let url, let headers):
      entry.fields["type"] = .init("remote")
      try entry.url(url)
      try entry.bindings(headers, field: "headers", reference: .openCode)
    case .sse:
      throw input.issue(
        ["transport", "kind"], .unsupported,
        "the pinned remote client constructs StreamableHTTPClientTransport only")
    }
    var rules: [String: MCPNativeField] = [
      "disabled": .boolean, "codemode": .boolean, "pool": .boolean,
      "protocol": .oneOf(["legacy", "auto", "2026-07-28"]),
      "timeout": .positiveIntegerObject(["startup", "catalog", "execution"]),
    ]
    if case .streamableHTTP = input.transport { rules["oauth"] = .falseOnly }
    try entry.nativeFields(rules)
    if case .streamableHTTP = input.transport, entry.fields["codemode"] == nil {
      // The native default rewrites the endpoint with a codemode query parameter.
      entry.fields["codemode"] = .init(boolean: false)
    }
    return entry
  }
}
