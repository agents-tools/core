import AgentsCore

/// Claude's local audience is a project even though Core routes it to the shared global file.
enum ClaudeAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      try input.rejectWorkingDirectory(run)
      entry.fields["type"] = .init("stdio")
      try entry.command(run)
      try entry.bindings(run.environment, field: "env", reference: .claude)
    case .streamableHTTP(let url, let headers):
      entry.fields["type"] = .init("http")
      try entry.url(url)
      try entry.bindings(headers, field: "headers", reference: .claude)
    case .sse(let url, let headers):
      entry.fields["type"] = .init("sse")
      try entry.url(url)
      try entry.bindings(headers, field: "headers", reference: .claude)
    }
    try entry.nativeFields([:])
    return entry
  }
}
