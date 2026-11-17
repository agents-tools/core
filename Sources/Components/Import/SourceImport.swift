import AgentsCore
import AgentsManifest
import Foundation

package enum SourceImport {
  /// First explicit config is the project config; the optional second is its local override.
  /// Each document retains its caller-selected boundary. No ambient config or lock is discovered.
  package static func previewRulesync(
    configs: [SourceImportInput], locks: [SourceImportInput] = [],
    limits: SourceImportLimits = .init()
  ) throws -> SourceImportProposal {
    var diagnostics = ImportDiagnostics(proposal: .init(profile: .rulesyncConfig))
    do {
      try RulesyncConfigImport.read(
        configs: configs, locks: locks, limits: limits, into: &diagnostics)
    } catch is CancellationError { throw CancellationError() } catch let failure
      as ImportLocatedFailure
    {
      diagnostics.add(.invalidInput, failure.location, "Explicit JSONC input is not admitted.")
    } catch CoreError.unsafePath {
      diagnostics.add(
        .unsafePath, .init(document: configs.first?.document ?? "", pointer: ""),
        "Input path escapes its explicit root.")
    } catch {
      diagnostics.add(
        .invalidInput, .init(document: configs.first?.document ?? "", pointer: ""),
        "Explicit rulesync inputs are not admitted.")
    }
    return diagnostics.proposal
  }

  /// Reads only the chosen local document and explicitly supplied content. No source resolution,
  /// component execution, config discovery, ownership inference or filesystem write occurs here.
  package static func preview(
    _ input: SourceImportInput, limits: SourceImportLimits = .init()
  ) throws -> SourceImportProposal {
    try Task.checkCancellation()
    let origin = ImportLocation(document: input.document, pointer: "")
    var diagnostics = ImportDiagnostics(proposal: .init(profile: input.profile))
    do {
      _ = try ImportInput.path(input.document)
      switch input.profile {
      case .apmManifest, .apmLock, .rulesyncGitHubV1, .rulesyncAPMV1:
        try YAMLSourceImport.read(input, limits: limits, into: &diagnostics)
      case .rulesyncConfig:
        try RulesyncConfigImport.read(input, limits: limits, into: &diagnostics)
      case .rulesyncSourcesV1, .rulesyncNpmV1:
        try RulesyncSourceImport.read(
          ImportInput.document(input, limits: limits), input: input, into: &diagnostics)
      case .claudeSettingsV1, .codexConfigV1, .cursorMCPV1, .geminiSettingsV1, .openCodeConfigV2,
        .claudePluginV1, .cursorPluginV1, .geminiExtensionV1, .claudeMarketplaceV1,
        .claudeCommandV1, .claudeAgentV1, .geminiCommandV1, .geminiAgentV1,
        .openCodeCommandV2, .openCodeAgentV2, .cursorCommandV1, .cursorAgentV1, .geminiIgnoreV1,
        .cursorIgnoreV1:
        try NativeSourceImport.read(input, limits: limits, into: &diagnostics)
      case .vercelProjectV2, .vercelUserV3:
        try VercelSourceImport.read(
          ImportInput.document(input, limits: limits), input: input, limits: limits,
          into: &diagnostics)
      }
    } catch is CancellationError { throw CancellationError() } catch let failure as YAMLReadFailure
    {
      diagnostics.add(
        .invalidInput, .init(document: input.document, pointer: "", span: failure.span),
        "Input is not admitted YAML.")
    } catch let failure as ImportLocatedFailure {
      diagnostics.add(.invalidInput, failure.location, "Explicit JSONC input is not admitted.")
    } catch CoreError.unsafePath {
      diagnostics.add(.unsafePath, origin, "Input path escapes its explicit root.")
    } catch {
      diagnostics.add(
        .invalidInput, origin, "Input is not an admitted, readable producer document.")
    }
    return diagnostics.proposal
  }
}
