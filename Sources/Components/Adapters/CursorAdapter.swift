import AgentsCore

/// The documented MCP shape is shared by IDE/CLI; surface acceptance remains separate.
enum CursorAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      try input.rejectWorkingDirectory(run)
      entry.fields["type"] = .init("stdio")
      try entry.command(run)
      // Captured documentation establishes interpolation fields but not its exact token grammar.
      try entry.bindings(run.environment, field: "env", reference: nil)
    case .streamableHTTP, .sse:
      throw input.issue(
        ["transport", "kind"], .unverified,
        "captured Cursor documentation does not fix an explicit remote transport selector")
    }
    try entry.nativeFields([:])
    return entry
  }
}
