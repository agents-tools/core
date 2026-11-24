import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

struct IntegratedConsumerRegressionTests {
  @Test func preciseRootMCPRemovalPreservesUnrelatedYAML() throws {
    let f = try UpdateFixture()
    try f.write(
      """
      # Keep this declaration comment.
      version: 1
      components:
        - kind: mcpServer
          name: first
          transport: {kind: stdio, executable: never-run}
          agents: [claude-code]
        # Keep the remaining component comment.
        - kind: mcpServer
          name: second
          transport: {kind: stdio, executable: never-run}
          agents: [claude-code]
      """, to: f.store.declarationURL)
    _ = try f.apply()
    let inspected = try UpdateOperations.inspect(environment: f.environment)
    let selected = try #require(inspected.components.first { $0.name == "first" })
    let request = UpdateRequest(operation: .remove, selections: [selected.selection])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let after = try UpdateOperations.inspect(environment: f.environment)
    #expect(after.components.map(\.name) == ["second"])
    let text = try String(contentsOf: f.store.declarationURL, encoding: .utf8)
    #expect(text.contains("# Keep this declaration comment."))
    #expect(text.contains("# Keep the remaining component comment."))
  }

  @Test func publicPromptUsesCurrentConsumerAppendAndLockedSectionOrder() throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.claudeCode])
    var declaration = try f.store.loadDeclaration()
    for index in declaration.components.indices {
      if case .instructions(var selection) = declaration.components[index] {
        selection.prompts[0].prompt.append = "append.md"
        declaration.components[index] = .instructions(selection)
      }
    }
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()  // An absent consumer file must not prevent publication.
    try f.write("First appendix", to: f.root.appendingPathComponent("append.md"))
    let first = try InstructionOperations.renderChatGPT(
      prompt: "weekly", environment: f.environment)
    try f.write("Current appendix", to: f.root.appendingPathComponent("append.md"))
    let before = try FileHash.folderHash(f.root)
    let current = try InstructionOperations.renderChatGPT(
      prompt: "weekly", environment: f.environment)
    #expect(String(decoding: first, as: UTF8.self).contains("First appendix"))
    #expect(String(decoding: current, as: UTF8.self).contains("Current appendix"))
    #expect(!String(decoding: current, as: UTF8.self).contains("First appendix"))
    #expect(try FileHash.folderHash(f.root) == before)
  }
}

extension IntegratedConsumerRegressionTests {
  @Test func documentedNativeImportKeepsUnavailableUpstreamRevisionNil() throws {
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("native-input")
    try f.write("{}", to: input.appendingPathComponent("settings.json"))
    let before = try FileHash.folderHash(f.root)
    let report = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: input, document: "settings.json")
    #expect(report.producerRevision == nil)
    #expect(report.specificationStatus.contains("Documented Claude Code format"))
    #expect(try FileHash.folderHash(f.root) == before)
  }
}

extension IntegratedConsumerRegressionTests {
  @Test func authoredNodeRemovalSelectsOneDirectOccurrenceAndRejectsReuse() throws {
    let f = try UpdateFixture()
    try f.write(
      """
      # Keep authored occurrence order.
      version: 1
      components:
        - {kind: mcpServer, name: repeated, transport: {kind: stdio, executable: first}, agents: [claude-code]}
        - {kind: mcpServer, name: repeated, transport: {kind: stdio, executable: second}, agents: [gemini-cli]}
      """, to: f.store.declarationURL)
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let document = try #require(snapshot.document)
    let node = try #require(document.node(at: "/components/1"))
    #expect(document.editability(of: node) == .direct)
    let request = UpdateRequest(
      operation: .edit([.removeComponent(node)]), expectedDeclarationDigest: document.digest)
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let remaining = try UpdateOperations.inspect(environment: f.environment)
    #expect(remaining.components.count == 1)
    #expect(remaining.components[0].recipients == [.claudeCode])
    #expect(
      try String(contentsOf: f.store.declarationURL, encoding: .utf8).contains(
        "# Keep authored occurrence order."))
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, environment: f.environment)
    }
  }
}
