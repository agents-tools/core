import AgentsCore
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

struct AntigravityAdapterTests {
  @Test(arguments: [InstallScope.project, .user])
  func namedHooksAndMCPMergeReplayAndRemove(_ scope: InstallScope) throws {
    let f = try UpdateFixture(scope: scope)
    let root =
      scope == .project
      ? f.root.appendingPathComponent(".agents")
      : f.environment.homeDirectory.appendingPathComponent(".gemini/config")
    let hooks = root.appendingPathComponent("hooks.json")
    let mcp = root.appendingPathComponent("mcp_config.json")
    let handwrittenHook = #"""
      "local-hook": {"SessionStart":[{"command":"never-run-local"}]}
      """#
    let handwrittenServer = #"""
      "local-server": {"command":"never-run-local"}
      """#
    let originalHooks = "{\n  \(handwrittenHook)\n}\n"
    let originalMCP =
      "{\n  \"settings\": {\"keep\": true}, \"mcpServers\": {\n    \(handwrittenServer)\n  }\n}\n"
    try f.write(originalHooks, to: hooks)
    try f.write(originalMCP, to: mcp)
    let events = [
      "SessionStart", "PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop",
    ]
    let handlers: [ComponentDeclaration] = events.map { event in
      .hook(
        name: "managed-" + event, event: .native(event),
        run: .init(executable: "never-run", arguments: ["two words", "it's literal"]),
        matcher: event.hasSuffix("ToolUse") ? "run_command|view_file" : nil,
        timeoutSeconds: 8, agents: [.antigravity], condition: .init(scopes: [scope]),
        native: ["antigravity": ["enabled": .boolean(false)]])
    }
    let components =
      handlers + [
        .mcpServer(
          name: "managed-http",
          transport: .streamableHTTP(
            url: "https://fixture.invalid/mcp", headers: ["X-Profile": .literal("compact")]),
          agents: [.antigravity]),
        .mcpServer(
          name: "managed-stdio",
          transport: .stdio(
            .init(
              executable: "never-run", arguments: ["--test"],
              environment: ["MODE": .literal("fixture")])),
          agents: [.antigravity]),
      ]
    let excluded = ComponentDeclaration.hook(
      name: "other-scope", event: .native("Stop"), run: .init(executable: "never-run"),
      agents: [.antigravity], condition: .init(scopes: [scope == .project ? .user : .project]))
    try f.store.save(declaration: .init(components: components + [excluded]), ledger: .init())
    let preview = try f.preview()
    #expect(preview.components.count == components.count)
    #expect(try f.bytes(hooks) == Data(originalHooks.utf8))
    #expect(try f.bytes(mcp) == Data(originalMCP.utf8))
    try UpdateOperations.withPreparedUpdate(scope: scope, environment: f.environment) {
      _ = try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installedHooks = try f.bytes(hooks)
    let installedMCP = try f.bytes(mcp)
    #expect(String(decoding: installedHooks, as: UTF8.self).contains(handwrittenHook))
    #expect(String(decoding: installedMCP, as: UTF8.self).contains(handwrittenServer))
    let hookDocument = try json(installedHooks)
    #expect(hookDocument["other-scope"] == nil)
    for event in events {
      let definition = try #require(hookDocument["managed-" + event] as? [String: Any])
      #expect(definition["enabled"] as? Bool == false)
      let outer = try #require((definition[event] as? [[String: Any]])?.first)
      let handler: [String: Any]
      if event.hasSuffix("ToolUse") {
        #expect(outer["matcher"] as? String == "run_command|view_file")
        handler = try #require((outer["hooks"] as? [[String: Any]])?.first)
      } else {
        handler = outer
      }
      #expect(handler["type"] as? String == "command")
      #expect(handler["timeout"] as? Int == 8)
      #expect(handler["command"] as? String == #"'never-run' 'two words' 'it'\''s literal'"#)
    }
    let servers = try #require(try json(installedMCP)["mcpServers"] as? [String: [String: Any]])
    #expect(servers["managed-http"]?["serverUrl"] as? String == "https://fixture.invalid/mcp")
    #expect(servers["managed-http"]?["headers"] as? [String: String] == ["X-Profile": "compact"])
    #expect(servers["managed-stdio"]?["args"] as? [String] == ["--test"])
    #expect(servers["managed-stdio"]?["env"] as? [String: String] == ["MODE": "fixture"])

    let installed = try UpdateOperations.inspect(scope: scope, environment: f.environment)
    #expect(installed.deployments.count == components.count)
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    let locked = try f.bytes(f.store.resolvedURL)
    try f.write(originalHooks, to: hooks)
    try f.write(originalMCP, to: mcp)
    _ = try UpdateOperations.restore(scope: scope, environment: f.environment)
    #expect(try f.bytes(hooks) == installedHooks)
    #expect(try f.bytes(mcp) == installedMCP)
    #expect(try f.bytes(f.store.resolvedURL) == locked)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: installed.components.map(\.selection)),
      scope: scope, environment: f.environment
    ) { try $0.apply() }
    let remainingHooks = try f.bytes(hooks)
    let remainingMCP = try f.bytes(mcp)
    #expect(try Set(json(remainingHooks).keys) == ["local-hook"])
    #expect(String(decoding: remainingHooks, as: UTF8.self).contains(handwrittenHook))
    #expect(
      try (json(remainingMCP)["mcpServers"] as? [String: Any])?.keys.sorted() == ["local-server"])
    #expect(String(decoding: remainingMCP, as: UTF8.self).contains(handwrittenServer))
    #expect(try (json(remainingMCP)["settings"] as? [String: Bool])?["keep"] == true)
  }

  @Test func workspaceSkillRetainsSharedPhysicalInstallationUntilLastRecipient() throws {
    let f = try UpdateFixture()
    let sibling = f.root.appendingPathComponent(".agents/skills/handwritten/SKILL.md")
    try f.write("---\nname: handwritten\ndescription: Fixture.\n---\nHandwritten.\n", to: sibling)
    let handwritten = try f.bytes(sibling)
    let agents: [AgentID] = [.antigravity, .codex]
    _ = try SkillOperations.add(
      .init(source: f.repo.path, agents: agents, environment: f.environment))
    let target = f.root.appendingPathComponent(".agents/skills/demo/SKILL.md")
    #expect(FileManager.default.fileExists(atPath: target.path))
    _ = try SkillOperations.remove(
      skillNames: ["demo"], agents: [.antigravity], environment: f.environment)
    #expect(try f.store.loadResolved().skills["demo"]?.installs.keys.sorted() == ["codex"])
    #expect(FileManager.default.fileExists(atPath: target.path))
    _ = try SkillOperations.remove(
      skillNames: ["demo"], agents: [.codex], environment: f.environment)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try f.bytes(sibling) == handwritten)
  }

  @Test func unsupportedTranslationsAndNamedOwnerCollisionsReportBeforePublication() throws {
    let f = try UpdateFixture()
    let file = f.root.appendingPathComponent(".agents/hooks.json")
    let handwritten = #"{"check":{"Stop":[{"command":"never-run-local"}]}}"#
    try f.write(handwritten, to: file)
    func hook(
      _ event: HookEventDeclaration, executable: String = "never-run", matcher: String? = nil
    )
      -> ComponentDeclaration
    {
      .hook(
        name: "check", event: event, run: .init(executable: executable), matcher: matcher,
        agents: [.antigravity])
    }
    func rejection(_ components: [ComponentDeclaration], contains text: String) throws {
      try f.store.save(declaration: .init(components: components), ledger: .init())
      do {
        _ = try f.preview()
        Issue.record("Expected planning to reject \(text)")
      } catch {
        #expect(String(describing: error).localizedCaseInsensitiveContains(text))
      }
      #expect(try f.bytes(file) == Data(handwritten.utf8))
    }
    try rejection([hook(.native("Stop"), matcher: "*")], contains: "ignores matchers")
    try rejection([hook(.sessionEnd)], contains: "explicit native event")
    try rejection([hook(.native("SessionEnd"))], contains: "absent from")
    try rejection(
      [
        .mcpServer(
          name: "legacy", transport: .sse(url: "https://fixture.invalid/sse"),
          agents: [.antigravity])
      ], contains: "requires Streamable HTTP")
    try rejection(
      [hook(.native("Stop")), hook(.native("Stop"), executable: "different")],
      contains: "conflict")
    try rejection([hook(.native("Stop"))], contains: "ownership does not match")
  }

  private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
