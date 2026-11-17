import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import AgentsUpdates

struct FirstUserDeclarationTests {
  @Test func firstUserMCPDeclarationCanConfirmPurePreview() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "first-user-declaration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root, environment: [:])
    let store = StateStore(scope: .user, environment: environment)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("version: 1\ndefaultAgents: [codex]\n".utf8).write(to: store.declarationURL)
    var declaration = try store.loadDeclaration()
    declaration.components.append(
      .mcpServer(
        name: "documentation", transport: .stdio(.init(executable: "fixture-command"))))
    let request = UpdateRequest(operation: .declaration(declaration))
    let before = try FileHash.folderHash(root)
    let preview = try UpdateOperations.preview(request, scope: .user, environment: environment)
    #expect(try FileHash.folderHash(root) == before)
    let selectedText = try #require(preview.components.first?.symbolicAfter)
    let selectedFields = try #require(
      JSONSerialization.jsonObject(with: Data(selectedText.utf8)) as? [String: Any])
    #expect(selectedFields["command"] as? String == "fixture-command")
    #expect(selectedFields["kind"] == nil && selectedFields["object"] == nil)
    #expect(
      try UpdateOperations.preview(request, scope: .user, environment: environment)
        .displayedFingerprint == preview.displayedFingerprint)
    _ = try UpdateOperations.withPreparedUpdate(request, scope: .user, environment: environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let current = try UpdateOperations.inspect(scope: .user, environment: environment)
    #expect(current.components.count == 1)
    #expect(current.components.first?.name == "documentation")
    #expect(current.deployments.allSatisfy { $0.status == .current })
    let config = root.appendingPathComponent(".codex/config.toml")
    #expect(try String(contentsOf: config, encoding: .utf8).contains("fixture-command"))
  }
  @Test func readablePreviewContainsOnlySelectedSymbolicConfiguration() throws {
    let f = try UpdateFixture()
    let sibling = "UNMANAGED-SIBLING-MUST-STAY-PRIVATE"
    let config = f.root.appendingPathComponent(".mcp.json")
    try f.write(
      "{\"mcpServers\":{\"unmanaged\":{\"command\":\"" + sibling + "\"}}}", to: config)
    try f.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "selected", transport: .stdio(.init(executable: "fixture-command")),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    let before = try FileHash.folderHash(f.root)
    let preview = try f.preview()
    #expect(try FileHash.folderHash(f.root) == before)
    #expect(preview.components.first?.symbolicBefore == nil)
    let after = try #require(preview.components.first?.symbolicAfter)
    #expect(after.contains("fixture-command"))
    #expect(!after.contains(sibling) && !after.contains("unmanaged"))
    #expect(!String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(sibling))
    _ = try UpdateOperations.withPreparedUpdate(environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(try String(contentsOf: config, encoding: .utf8).contains(sibling))
  }

  @Test func readableProjectionPreservesNumericLexemesAndSymbolicReferences() throws {
    let payload = LedgerValue(object: [
      "limit": .init("1e200", kind: .decimal),
      "environment": .init("FIXTURE_INPUT", kind: .environment),
      "credential": .init("fixture-token", kind: .secret),
      "text": .init("quoted \"field\"\nnext line"),
    ])
    let rendered = try UpdateOperations.symbolicConfigurationText(payload)
    #expect(rendered.contains("1e200"))
    let fields = try #require(
      JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
    #expect((fields["environment"] as? [String: String])?["environment"] == "FIXTURE_INPUT")
    #expect((fields["credential"] as? [String: String])?["secret"] == "fixture-token")
    #expect(fields["text"] as? String == "quoted \"field\"\nnext line")
  }

  @Test func nativeAccessChangeInvalidatesDisplayedConfirmation() throws {
    let f = try UpdateFixture(scope: .user)
    try f.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "documentation", transport: .stdio(.init(executable: "fixture-command")),
          agents: [.codex])
      ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let before = try f.preview()
    let config = f.environment.homeDirectory.appendingPathComponent(".codex/config.toml")
    let parent = config.deletingLastPathComponent()
    let mode = try #require(
      try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)
    try FileManager.default.setAttributes(
      [.posixPermissions: mode.intValue == 0o700 ? 0o755 : 0o700], ofItemAtPath: parent.path)
    let after = try f.preview()
    #expect(before.displayedFingerprint != after.displayedFingerprint)
    let bytes = try Data(contentsOf: config)
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(scope: .user, environment: f.environment) {
        try $0.apply(ifUnchangedFrom: before.displayedFingerprint)
      }
    }
    #expect(try Data(contentsOf: config) == bytes)
  }

}
