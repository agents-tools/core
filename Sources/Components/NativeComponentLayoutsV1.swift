import AgentsCore
import Foundation

package enum NativeComponentLayoutsV1 {
  package static func format(_ surface: NativeClientSurface) -> String {
    switch surface {
    case .claudeCode: "agents/claude-components@1"
    case .codexCLI: "agents/codex-components@1"
    case .geminiCLI: "agents/gemini-components@1"
    case .openCodeCLI: "agents/opencode-components@1"
    case .cursorEditor, .cursorCLI, .cursorCloud: "agents/cursor-components@1"
    }
  }

  package static func renderers(limits: LedgerLimits) -> [String: LedgerRenderer] {
    [
      "agents/claude-components@1": {
        try render($0, $1, $2, limits: limits, surface: .claudeCode)
      },
      "agents/codex-components@1": { try render($0, $1, $2, limits: limits, surface: .codexCLI) },
      "agents/gemini-components@1": { try render($0, $1, $2, limits: limits, surface: .geminiCLI) },
      "agents/opencode-components@1": {
        try render($0, $1, $2, limits: limits, surface: .openCodeCLI)
      },
      "agents/cursor-components@1": {
        try render($0, $1, $2, limits: limits, surface: .cursorEditor)
      },
    ]
  }

  private static func render(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger,
    _ resources: [String: URL], limits: LedgerLimits, surface: NativeClientSurface
  ) throws -> [ReplayedArtifact] {
    let input = try input(lowering, ledger: ledger, resources: resources, limits: limits)
    let record = input.record
    let declared = input.request.surface
    guard format(declared) == format(surface) else {
      throw CoreError.invalidState("invalid version 1 native component renderer")
    }
    if record.kind == "plugin" { return try NativePluginLayoutV1.render(lowering, input) }
    switch declared {
    case .geminiCLI: return try GeminiAdapter.components(lowering, input)
    case .openCodeCLI: return try OpenCodeAdapter.components(lowering, input)
    case .codexCLI: return try CodexAdapter.components(lowering, input)
    case .cursorEditor, .cursorCLI, .cursorCloud:
      return try CursorAdapter.components(lowering, input)
    case .claudeCode: return try ClaudeAdapter.components(lowering, input)
    }
  }

  static func input(
    _ lowering: LockedLowering, ledger: ResolvedLedger, resources: [String: URL]? = nil,
    limits: LedgerLimits
  ) throws -> ComponentRenderInput {
    func invalid() -> CoreError { .invalidState("invalid version 1 native component layout") }
    guard lowering.layout.kind == .object, let layout = lowering.layout.object,
      Set(layout.keys) == ["surface", "scope", "occurrences"],
      layout["surface"]?.kind == .string,
      let declared = layout["surface"]?.text.flatMap(NativeClientSurface.init(rawValue:)),
      layout["scope"]?.kind == .string,
      let scope = layout["scope"]?.text.flatMap(InstallScope.init(rawValue:)),
      lowering.format == format(declared), lowering.inputs.count == 1,
      let component = lowering.inputs.first, let record = ledger.components[component],
      record.payload.kind == .object,
      ledger.sources[record.source] != nil, ledger.sources[record.declaringSource] != nil,
      record.resources.allSatisfy({ ledger.resources[$0] != nil }),
      lowering.resources == record.resources,
      layout["occurrences"]?.kind == .array, let items = layout["occurrences"]?.array,
      items.allSatisfy({ $0.kind == .integer }), !items.isEmpty
    else { throw invalid() }
    let occurrences = items.compactMap(\.integer)
    guard Set(occurrences).count == occurrences.count,
      occurrences
        == ledger.occurrences.filter({ $0.component == component && occurrences.contains($0.id) })
        .map(\.id),
      ledger.occurrences.filter({ occurrences.contains($0.id) }).allSatisfy({
        $0.recipients.contains(declared.agent) && ($0.condition.scopes?.contains(scope) ?? true)
          && ($0.condition.agents?.contains(declared.agent) ?? true)
          && ($0.condition.platforms?.contains(lowering.platform) ?? true)
      })
    else { throw invalid() }
    let input = ComponentRenderInput(
      record: record, component: component,
      request: .init(surface: declared, scope: scope), occurrences: occurrences,
      resources: resources ?? [:], ledger: ledger, limits: limits)
    if let resources, !record.resources.allSatisfy({ resources[$0] != nil }) {
      throw invalid()
    }
    try input.validateProfile()
    return input
  }
}
