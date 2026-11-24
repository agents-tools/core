import AgentsCore

/// Explicit type with url fixes transport; httpUrl is a deprecated Streamable HTTP field.
enum GeminiAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      try entry.command(run)
      try entry.workingDirectory(run)
      try entry.bindings(run.environment, field: "env", reference: .gemini)
    case .streamableHTTP(let url, let headers):
      entry.fields["type"] = .init("http")
      try entry.url(url)
      try entry.bindings(headers, field: "headers", reference: .gemini)
    case .sse(let url, let headers):
      entry.fields["type"] = .init("sse")
      try entry.url(url)
      try entry.bindings(headers, field: "headers", reference: .gemini)
    }
    try entry.nativeFields([
      "timeout": .positiveNumber, "description": .string,
      "includeTools": .strings, "excludeTools": .strings,
    ])
    return entry
  }
}
