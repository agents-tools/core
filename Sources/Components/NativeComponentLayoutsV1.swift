import AgentsCore
import Foundation

package enum NativeComponentLayoutsV1 {
  static func profileVersion(_ surface: NativeClientSurface) -> Int {
    switch surface {
    case .claudeCode, .cursorEditor, .cursorCLI, .cursorCloud: 2
    default: 1
    }
  }
  package static func format(_ surface: NativeClientSurface) -> String {
    format(surface, version: profileVersion(surface))
  }
  private static func format(_ surface: NativeClientSurface, version: Int) -> String {
    switch surface {
    case .claudeCode: "agents/claude-components@\(version)"
    case .codexCLI: "agents/codex-components@1"
    case .geminiCLI: "agents/gemini-components@1"
    case .openCodeCLI: "agents/opencode-components@1"
    case .cursorEditor, .cursorCLI, .cursorCloud: "agents/cursor-components@\(version)"
    }
  }

  package static func renderers(limits: LedgerLimits) -> [String: LedgerRenderer] {
    [
      "agents/claude-components@1": {
        try render($0, $1, $2, limits: limits, surface: .claudeCode)
      },
      "agents/claude-components@2": {
        try render($0, $1, $2, limits: limits, surface: .claudeCode, version: 2)
      },
      "agents/codex-components@1": { try render($0, $1, $2, limits: limits, surface: .codexCLI) },
      "agents/gemini-components@1": { try render($0, $1, $2, limits: limits, surface: .geminiCLI) },
      "agents/opencode-components@1": {
        try render($0, $1, $2, limits: limits, surface: .openCodeCLI)
      },
      "agents/cursor-components@1": {
        try render($0, $1, $2, limits: limits, surface: .cursorEditor)
      },
      "agents/cursor-components@2": {
        try render($0, $1, $2, limits: limits, surface: .cursorEditor, version: 2)
      },
    ]
  }

  private static func render(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger,
    _ resources: [String: URL], limits: LedgerLimits, surface: NativeClientSurface, version: Int = 1
  ) throws -> [ReplayedArtifact] {
    func invalid() -> CoreError { .invalidState("invalid version 1 native component layout") }
    guard let layout = lowering.layout.object,
      Set(layout.keys) == ["surface", "scope", "occurrences"],
      let declared = layout["surface"]?.text.flatMap(NativeClientSurface.init(rawValue:)),
      format(declared) == format(surface),
      let scope = layout["scope"]?.text.flatMap(InstallScope.init(rawValue:)),
      lowering.format == format(declared, version: version), lowering.inputs.count == 1,
      let component = lowering.inputs.first, let record = ledger.components[component],
      lowering.resources == record.resources,
      record.resources.allSatisfy({ resources[$0] != nil }),
      let items = layout["occurrences"]?.array,
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
      resources: resources, ledger: ledger, limits: limits, profileVersion: version)
    try input.validateProfile()
    if record.kind == "plugin" { return try NativePluginLayoutV1.render(lowering, input) }
    switch declared {
    case .geminiCLI: return try GeminiAdapter.components(lowering, input)
    case .openCodeCLI: return try OpenCodeAdapter.components(lowering, input)
    case .codexCLI: return try CodexAdapter.components(lowering, input)
    case .cursorEditor, .cursorCLI, .cursorCloud:
      return try CursorAdapter.components(lowering, input)
    case .claudeCode:
      guard version == 2 else {
        throw input.issue(["kind"], .unverified, "complete fixed native schema is required")
      }
      return try ClaudeAdapter.components(lowering, input)
    }
  }
}
