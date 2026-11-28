import AgentsCore
import Components
import Foundation
import Testing

struct NativeCoordinateLinkingTests {
  @Test(arguments: [false, true])
  func generatedExecutableAndCwdRebaseOnceAndConsumeAliases(_ nested: Bool) throws {
    let f = try LinkFixture()
    let producer = f.root.appendingPathComponent("producer")
    let container = nested ? "bundle" : "."
    let prefix = nested ? "bundle/" : ""
    try f.write(
      #"{"name":"producer","version":"1.2.3","mcpServers":{"server":{"command":"${extensionPath}/server","cwd":"./cwd"}}}"#,
      to: prefix + "gemini-extension.json", base: producer)
    try f.write("Never executed", to: prefix + "server", base: producer)
    try f.write("Working support", to: prefix + "cwd/config", base: producer)
    let graph = try f.link(
      """
      version: 1
      sources: {producer: {path: "\(producer.path)"}}
      components: [{kind: plugin, name: p, path: "\(container)", source: producer, agents: [gemini-cli]}]
      """)
    let member = try #require(graph.components.first { $0.key.kind == .mcpServer })
    guard case .declaration(.mcpServer(_, .stdio(let run), _, _, _, _)) = member.payload else {
      Issue.record("Expected generated MCP child")
      return
    }
    #expect(run.executable == (nested ? "bundle/server" : "./server"))
    #expect(run.executableSource == nil)
    #expect(run.workingDirectory == .init(path: prefix + "cwd"))
    #expect(member.resources.count == 2)
  }
  @Test(arguments: [false, true])
  func generatedHookAndLSPRetainResourceSpelling(_ nested: Bool) throws {
    let f = try LinkFixture()
    let producer = f.root.appendingPathComponent("producer")
    let prefix = nested ? "bundle/" : ""
    try f.write(#"{"name":"producer"}"#, to: prefix + ".claude-plugin/plugin.json", base: producer)
    try f.write("Never executed", to: prefix + "server", base: producer)
    try f.write(
      #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"./server"}]}]}}"#,
      to: prefix + "hooks/hooks.json", base: producer)
    try f.write(
      #"{"language":{"command":"./server","extensionToLanguage":{".swift":"swift"}}}"#,
      to: prefix + ".lsp.json", base: producer)
    let graph = try f.link(
      """
      version: 1
      sources: {producer: {path: "\(producer.path)"}}
      components: [{kind: plugin, name: p, path: "\(nested ? "bundle" : ".")", source: producer, agents: [claude-code]}]
      """)
    let members = graph.components.filter { [.hook, .lspServer].contains($0.key.kind) }
    #expect(members.count == 2)
    for member in members {
      let run: ExecutableDeclaration
      switch member.payload {
      case .declaration(.hook(_, _, let value, _, _, _, _, _)),
        .declaration(.lspServer(_, let value, _, _, _, _, _)):
        run = value
      default:
        Issue.record("Expected executable native child")
        continue
      }
      #expect(run.executable == (nested ? "bundle/server" : "./server"))
      #expect(run.executableSource == nil)
      #expect(member.resources.count == 1)
    }
  }

}
