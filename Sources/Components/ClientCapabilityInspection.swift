import AgentsCore

/// Describes registry evidence only; field, resource and integration admission belongs to preview.
package struct ClientCapabilityEvidence {
  package let surface: NativeClientSurface
  package let displayName: String
  package let kind: DeclaredComponentKind
  package let scope: String
  package let placement: String
  package let status: String
  package let evidence: NativeSchemaEvidence?
  package let reason: String?
}

extension NativeClientSurface {
  package var displayName: String {
    switch self {
    case .antigravity: "Antigravity"
    case .claudeCode: "Claude Code"
    case .codexCLI: "Codex CLI"
    case .geminiCLI: "Gemini CLI"
    case .openCodeCLI: "OpenCode CLI"
    case .cursorEditor: "Cursor Editor"
    case .cursorCLI: "Cursor CLI"
    case .cursorCloud: "Cursor Cloud"
    }
  }
}

package enum ClientCapabilityInspection {
  package static func entries(for agent: AgentID) -> [ClientCapabilityEvidence] {
    NativeClientSurface.allCases.filter { $0.agent == agent }.flatMap { surface in
      DeclaredComponentKind.allCases.flatMap { kind -> [ClientCapabilityEvidence] in
        let scopes = kind == .mcpServer ? ["project", "local", "user"] : ["project", "user"]
        return scopes.flatMap { scope in
          let placements = kind == .command ? ["standalone", "pluginMember"] : ["standalone"]
          return placements.map { placement in
            var evidence: NativeSchemaEvidence?
            var status = "unverified"
            var reason: String?
            do {
              if surface == .antigravity && (kind == .skills || kind == .instructions) {
                evidence = CapabilityRegistry.antigravityEvidence(
                  kind == .skills ? "skills" : "rules")
              } else if kind == .skills || kind == .instructions {
                reason =
                  "Existing domain locations are available; comparable frozen schema evidence is not recorded."
              } else if kind == .mcpServer {
                evidence = try CapabilityRegistry.mcp(
                  .init(surface: surface, scope: NativeMCPScope(rawValue: scope)!), component: ""
                ).evidence
              } else {
                evidence = try CapabilityRegistry.component(
                  .init(surface: surface, scope: InstallScope(rawValue: scope)!),
                  kind: kind, name: "", inPlugin: placement == "pluginMember"
                ).evidence
              }
              if evidence != nil { status = "recorded" }
            } catch let issue as NativeAdapterIssue {
              status = issue.reason == .unsupported ? "unsupportedUnderEvidence" : "unverified"
              reason = issue.detail
            } catch let issue as NativeComponentIssue {
              status = issue.reason == .unsupported ? "unsupportedUnderEvidence" : "unverified"
              reason = issue.detail
            } catch {
              reason = "Registry evidence could not be projected."
            }
            return ClientCapabilityEvidence(
              surface: surface, displayName: surface.displayName, kind: kind,
              scope: scope, placement: placement, status: status, evidence: evidence, reason: reason
            )
          }
        }
      }
    }
  }
}
