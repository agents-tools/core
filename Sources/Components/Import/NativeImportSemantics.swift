import AgentsCore

/// Reuses F's finite conversion/validation rather than maintaining another native field table.
enum NativeImportSemantics {
  static func mcp(
    name: String, transport: MCPTransportDeclaration,
    native: [String: NativeValue], profile: SourceImportProfile, resources: [String]
  ) throws {
    let surface: NativeClientSurface
    switch NativeImportInput.agent(profile) {
    case .claudeCode: surface = .claudeCode
    case .codex: surface = .codexCLI
    case .geminiCLI: surface = .geminiCLI
    case .cursor: surface = .cursorEditor
    case .opencode: surface = .openCodeCLI
    }
    // These field converters do not consume scope or produce a deployment. Project is an
    // error-context value only; no scope, route or ownership is returned by the importer.
    let descriptor = try CapabilityRegistry.mcp(
      .init(surface: surface, scope: .project), component: name)
    let input = MCPInput(
      descriptor: descriptor, name: name, transport: transport, native: native, resources: resources
    )
    switch surface {
    case .claudeCode: _ = try ClaudeAdapter.mcp(input)
    case .codexCLI: _ = try CodexAdapter.mcp(input)
    case .geminiCLI: _ = try GeminiAdapter.mcp(input)
    case .cursorEditor, .cursorCLI, .cursorCloud: _ = try CursorAdapter.mcp(input)
    case .openCodeCLI: _ = try OpenCodeAdapter.mcp(input)
    }
  }
}
