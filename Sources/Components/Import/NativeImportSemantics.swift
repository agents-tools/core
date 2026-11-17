import AgentsCore
import NativeDocuments

/// Reuses F's finite conversion/validation rather than maintaining another native field table.
enum NativeImportSemantics {
  static func surface(_ profile: SourceImportProfile) -> NativeClientSurface {
    switch NativeImportInput.agent(profile) {
    case .claudeCode: return .claudeCode
    case .codex: return .codexCLI
    case .geminiCLI: return .geminiCLI
    case .cursor: return .cursorEditor
    case .opencode: return .openCodeCLI
    }
  }

  static func report(
    _ issue: NativeComponentFieldIssue, at location: ImportLocation,
    into diagnostics: inout ImportDiagnostics
  ) {
    diagnostics.add(issue.reason == .invalid ? .invalidInput : .unconverted, location, issue.detail)
  }

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
