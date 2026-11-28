import AgentsCore
import NativeDocuments

/// Reuses F's finite conversion/validation rather than maintaining another native field table.
enum NativeImportSemantics {
  static func surface(_ profile: SourceImportProfile) -> NativeClientSurface {
    NativeImportInput.surface(profile)
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
    let surface = surface(profile)
    // These field converters do not consume scope or produce a deployment. Project is an
    // error-context value only; no scope, route or ownership is returned by the importer.
    let descriptor = try CapabilityRegistry.mcp(
      .init(surface: surface, scope: .project), component: name)
    _ = try NativeMCPLowering.entry(
      transport, named: name, descriptor: descriptor, native: native, resources: resources)
  }
}
