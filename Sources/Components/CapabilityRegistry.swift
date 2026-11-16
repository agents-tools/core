import AgentsCore
import NativeDocuments

/// Surfaces with independently evidenced loading contracts. Marketing names do not select one.
package enum NativeClientSurface: String, CaseIterable, Sendable {
  case claudeCode, codexCLI, geminiCLI, openCodeCLI, cursorEditor, cursorCLI, cursorCloud

  package var agent: AgentID {
    switch self {
    case .claudeCode: .claudeCode
    case .codexCLI: .codex
    case .geminiCLI: .geminiCLI
    case .openCodeCLI: .opencode
    case .cursorEditor, .cursorCLI, .cursorCloud: .cursor
    }
  }
}

package enum NativeMCPScope: String, CaseIterable, Sendable { case project, local, user }

package struct NativeMCPRequest: Equatable, Sendable {
  package let surface: NativeClientSurface
  package let scope: NativeMCPScope

  package init(surface: NativeClientSurface, scope: NativeMCPScope) {
    self.surface = surface
    self.scope = scope
  }
}

/// Schema evidence is separate from runtime acceptance of a particular deployed candidate.
package struct NativeSchemaEvidence: Equatable, Sendable {
  package let revision: String
  package let sources: [String]
}

package struct NativeMCPDescriptor {
  package let request: NativeMCPRequest
  package let format: String
  package let documentFormat: NativeDocumentFormat
  package let evidence: NativeSchemaEvidence
  package var knownReaders: Set<AgentID> { [request.surface.agent] }

  /// Core supplies the native canonical project key; it is not a machine path saved in layout.
  package func region(server: String, nativeProjectKey: String? = nil) throws -> NativeRegion {
    var keys: [String]
    switch request.surface {
    case .codexCLI: keys = ["mcp_servers"]
    case .openCodeCLI: keys = ["mcp", "servers"]
    case .claudeCode where request.scope == .local:
      guard let nativeProjectKey, nativeProjectKey.hasPrefix("/"), !nativeProjectKey.contains("\0")
      else {
        throw NativeAdapterIssue(
          request: request, component: server, field: ["region", "nativeProjectKey"],
          reason: .integrationRequired, detail: "Core must supply the native canonical project key")
      }
      keys = ["projects", nativeProjectKey, "mcpServers"]
    default: keys = ["mcpServers"]
    }
    return NativeRegion(keys: keys + [server])
  }

}

package struct NativeAdapterIssue: Error, Equatable, CustomStringConvertible {
  package enum Reason: String, Sendable {
    case invalid, unsupported, unverified, integrationRequired
  }
  package let request: NativeMCPRequest
  package let component: String
  package let field: [String]
  package let reason: Reason
  package let detail: String

  package var description: String {
    "\(request.surface.rawValue)/mcpServer/\(component)/\(request.scope.rawValue) "
      + "\(field.joined(separator: ".")): \(reason.rawValue) (\(detail))."
  }
}

package enum CapabilityRegistry {
  package static func mcp(
    _ request: NativeMCPRequest, component: String
  ) throws -> NativeMCPDescriptor {
    func issue(_ field: String, _ detail: String) -> NativeAdapterIssue {
      .init(
        request: request, component: component, field: [field], reason: .unverified, detail: detail)
    }
    if request.surface == .cursorCloud {
      throw issue("surface", "Cloud MCP configuration loading needs separate evidence")
    }
    if request.scope == .local && request.surface != .claudeCode {
      throw issue("scope", "a separate local MCP scope is not established by this schema evidence")
    }
    let name: String
    let document: NativeDocumentFormat
    let evidence: NativeSchemaEvidence
    switch request.surface {
    case .claudeCode:
      name = "claude"
      document = .json
      evidence = .init(
        revision: "installed:2.1.309",
        sources: ["claude-mcp-routes.json", "https://code.claude.com/docs/en/mcp"])
    case .codexCLI:
      name = "codex"
      document = .toml
      evidence = .init(
        revision: "092d3acd6bec3e3a14bdc7e7a2810ab628ab759d",
        sources: ["codex-rs/config/src/config_toml.rs", "codex-rs/config/src/mcp_types.rs"])
    case .geminiCLI:
      name = "gemini"
      document = .jsonc(trailingCommas: false)
      evidence = .init(
        revision: "5a5c7180ff3f0a02511f54b54db7f228d4982a30",
        sources: [
          "packages/core/src/config/config.ts", "packages/cli/src/config/settings.ts",
          "packages/cli/src/utils/envVarResolver.ts",
        ])
    case .openCodeCLI:
      name = "opencode"
      document = .jsonc(trailingCommas: true)
      evidence = .init(
        revision: "fedc6f208aa2bd54c1019227214568083f6380ad",
        sources: [
          "packages/schema/src/mcp.ts", "packages/schema/src/config/mcp.ts",
          "packages/core/src/mcp/client.ts", "packages/core/src/config/variable.ts",
        ])
    case .cursorEditor, .cursorCLI, .cursorCloud:
      name = "cursor"
      document = .json
      evidence = .init(
        revision: "sha256:f5e70852d7122b56fd3136b3659dfc1d430ab363f763431f617839fdea8df7d4",
        sources: ["https://cursor.com/docs/mcp", "https://cursor.com/docs/cli/using"])
    }
    return .init(
      request: request, format: "agents/\(name)-mcp@1", documentFormat: document,
      evidence: evidence)
  }
}

package struct NativeComponentDescriptor {
  package let request: NativeComponentRequest
  package let kind: DeclaredComponentKind
  package let format: String
  package let evidence: NativeSchemaEvidence
  package var knownReaders: Set<AgentID> { [request.surface.agent] }
}

extension CapabilityRegistry {
  package static func component(
    _ request: NativeComponentRequest,
    kind: DeclaredComponentKind, name: String
  ) throws -> NativeComponentDescriptor {
    func issue(_ field: String, _ reason: NativeAdapterIssue.Reason, _ detail: String)
      -> NativeComponentIssue
    {
      .init(
        request: request, kind: kind.rawValue, component: name, field: [field], reason: reason,
        detail: detail)
    }
    guard ![.skills, .instructions, .mcpServer].contains(kind) else {
      throw issue("kind", .invalid, "component belongs to its existing domain renderer")
    }
    guard request.surface != .cursorCloud else {
      throw issue(
        "surface", .unverified, "Cloud deployment/loading requires a separate registered surface")
    }
    if request.surface == .claudeCode && kind != .plugin {
      throw issue(
        "kind", .unverified,
        "captured Claude evidence lacks this component's complete fixed native schema")
    }
    if kind == .command {
      if request.surface == .codexCLI {
        throw issue(
          "kind", .unsupported,
          "the pinned TUI dispatch does not register persistent named prompt files")
      }
      if request.surface == .cursorCLI
        || (request.surface == .cursorEditor && request.scope == .user)
      {
        throw issue(
          "scope", .unverified,
          "named-command registration is not established for this surface/scope")
      }
    }
    if kind == .lspServer && request.surface != .openCodeCLI {
      throw issue(
        "kind", .unverified, "no complete LSP registration schema is captured for this surface")
    }
    if kind == .ignore {
      guard request.scope == .project else {
        throw issue("scope", .unverified, "no standalone user ignore file contract is established")
      }
      guard request.surface == .geminiCLI || request.surface == .cursorEditor else {
        throw issue(
          "purpose", .unverified,
          "file search/watcher filters do not establish context or indexing exclusion")
      }
    }
    if kind == .hook && request.surface == .openCodeCLI {
      throw issue(
        "event", .unverified,
        "OpenCode hooks require executable plugin API adaptation; equivalent event I/O is not established"
      )
    }
    if kind == .permissions && request.surface != .openCodeCLI {
      throw issue(
        "rules", .unverified,
        "native policy precedence differs from ordered last-match semantics; exact translation is not established"
      )
    }
    let pinned = try mcp(
      .init(
        surface: request.surface,
        scope: request.scope == .user ? .user : .project), component: name
    ).evidence
    let sources: [String]
    switch request.surface {
    case .geminiCLI:
      sources = [
        "docs/cli/custom-commands.md", "packages/core/src/agents/agentLoader.ts",
        "docs/hooks/reference.md", "packages/core/src/hooks/hookRunner.ts",
        "packages/cli/src/config/settings.ts", "packages/cli/src/utils/envVarResolver.ts",
        "docs/cli/gemini-ignore.md", "packages/cli/src/config/extension-manager.ts",
      ]
    case .openCodeCLI:
      sources = [
        "packages/schema/src/config/command.ts", "packages/schema/src/config/agent.ts",
        "packages/core/src/config/plugin/command.ts", "packages/schema/src/permission.ts",
        "packages/core/src/permission.ts", "packages/schema/src/config/lsp.ts",
      ]
    case .codexCLI:
      sources = [
        "codex-rs/config/src/config_toml.rs", "codex-rs/agent-roles/src/agent_role_config.rs",
        "codex-rs/agent-roles/src/loader.rs", "codex-rs/config/src/hook_config.rs",
        "codex-rs/hooks/src/engine/command_runner.rs",
      ]
    case .cursorEditor, .cursorCLI, .cursorCloud:
      sources = [
        "https://cursor.com/docs/subagents", "https://docs.cursor.com/en/agent/chat/commands",
        "https://cursor.com/docs/reference/ignore-file",
        "https://cursor.com/docs/reference/plugins",
      ]
    case .claudeCode: sources = ["claude-plugin-discovery.json", "route-evidence.md"]
    }
    let revision: String
    switch request.surface {
    case .cursorEditor, .cursorCLI, .cursorCloud:
      revision = "sha256:b5e03f48d099bce7b10892b57934b9b611a54b3d4c9cf64e309071760e1c163b"
    default: revision = pinned.revision
    }
    let evidence = NativeSchemaEvidence(revision: revision, sources: sources)
    return .init(
      request: request, kind: kind, format: NativeComponentLayoutsV1.format(request.surface),
      evidence: evidence)
  }
}
