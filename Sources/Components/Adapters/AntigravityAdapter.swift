import AgentsCore

/// The App and CLI share a JSON format and customization directories.
enum AntigravityAdapter {
  static func mcp(_ input: MCPInput) throws -> MCPEntry {
    var entry = MCPEntry(input)
    switch input.transport {
    case .stdio(let run):
      guard input.native["authProviderType"] == nil else {
        throw input.issue(
          ["native", "antigravity", "authProviderType"], .unsupported,
          "native authentication applies to remote MCP servers")
      }
      try entry.command(run)
      try entry.workingDirectory(run)
      try entry.bindings(run.environment, field: "env", reference: nil)
    case .streamableHTTP(let url, let headers):
      try entry.url(url, field: "serverUrl")
      try entry.bindings(headers, field: "headers", reference: nil)
    case .sse:
      throw input.issue(
        ["transport", "kind"], .unsupported, "Antigravity remote MCP requires Streamable HTTP")
    }
    try entry.nativeFields([
      "disabled": .boolean, "enabledTools": .strings, "disabledTools": .strings,
      "authProviderType": .oneOf(["google_credentials"]),
    ])
    return entry
  }

  private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
  private static let events = toolEvents.union([
    "SessionStart", "PreInvocation", "PostInvocation", "Stop",
  ])

  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    let event = try NativeDocumentedHooksV1.event(input, allowed: events)
    var hook = try input.checkedNative(["enabled": .boolean])
    var handler: [String: LedgerValue] = [
      "type": .init("command"), "command": try NativeDocumentedHooksV1.program(input),
    ]
    if let timeout = input.fields["timeoutSeconds"] {
      guard timeout.integer.map({ $0 > 0 }) == true else {
        throw input.issue(["timeoutSeconds"], .invalid, "native timeout must be positive seconds")
      }
      handler["timeout"] = timeout
    }
    let matcher = input.fields["matcher"]
    if toolEvents.contains(event) {
      let pattern = matcher?.text ?? ""
      guard NativeDocumentedHooksV1.admittedMatcher(pattern) else {
        throw input.issue(["matcher"], .unverified, "matcher is outside the verified regex profile")
      }
      let group: [String: LedgerValue] = [
        "matcher": .init(pattern), "hooks": .init(array: [.init(object: handler)]),
      ]
      hook[event] = .init(array: [.init(object: group)])
    } else {
      guard matcher == nil else {
        throw input.issue(["matcher"], .unsupported, "this native event ignores matchers")
      }
      hook[event] = .init(array: [.init(object: handler)])
    }
    return try input.emitted(
      lowering,
      input.envelope(
        route: .antigravityHooks, keys: [input.record.name], selection: "antigravityHook",
        value: .init(object: hook)))
  }

  static func commandPath(in value: LedgerValue) -> [String]? {
    guard let event = value.object?.keys.first(where: events.contains) else { return nil }
    return toolEvents.contains(event)
      ? [event, "0", "hooks", "0", "command"] : [event, "0", "command"]
  }
}
