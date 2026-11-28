import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

/// Instruction writes through the scope's `agents.yaml` declaration document.
@Suite("Instruction declaration documents")
struct DeclarationDocumentTests {
  @Test func instructionEditsKeepCommentsAndUntouchedBytes() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.own("style")
    let declaration = fixture.store().declarationURL
    let header = """
      # Project instructions.
      version: 1
      components:
        # Shared guidance first.

      """
    let closing = "\n"
    try fixture.write(
      header + "  - {kind: instructions, sections: [{name: guide}], agents: [codex]}" + closing,
      to: declaration)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    func text() throws -> String {
      String(decoding: try Data(contentsOf: declaration), as: UTF8.self)
    }

    try fixture.addOwn(names: ["style"])
    #expect(try text().hasPrefix(header))
    #expect(try fixture.store().loadDeclaration().instructions?.sections == ["guide", "style"])
    try InstructionOperations.remove(names: ["guide"], environment: fixture.environment)
    #expect(try text().hasPrefix(header))
    _ = try InstructionOperations.updateInstalled(
      agents: [.claudeCode, .codex], environment: fixture.environment, apply: true)
    #expect(
      try text()
        == header
        + "  - {kind: instructions, sections: [{\"name\": \"style\"}], agents: [\"claude-code\", codex]}"
        + closing)
    #expect(try fixture.store().loadResolved().instructions.sections.map(\.name) == ["style"])
  }

  /// A declaration another writer creates after preparation is kept, and no lock or target is
  /// published beside it.
  @Test func externallyCreatedDeclarationIsKept() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    let store = fixture.store()
    let external = Data(
      "version: 1\n".utf8)
    #expect(throws: CoreError.self) {
      try InstructionOperations.add(
        InstructionAddOptions(source: ".", names: ["guide"], environment: fixture.environment),
        beforeApply: { _ in try external.write(to: store.declarationURL) })
    }
    #expect(try Data(contentsOf: store.declarationURL) == external)
    #expect(!FileManager.default.fileExists(atPath: store.resolvedURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent("AGENTS.md").path))
  }

  /// Unsupported shared aliases fail before the callback and any write.
  @Test func unsupportedSectionsStopBeforeTheCallback() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.own("style")
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    try fixture.write(
      """
      version: 1
      components: [{kind: instructions, sections: &shared [{name: guide}], agents: [codex]}]
      """, to: fixture.store().declarationURL)
    let before = try fixture.snapshot()
    var called = false
    #expect {
      try InstructionOperations.add(
        InstructionAddOptions(source: ".", names: ["style"], environment: fixture.environment),
        beforeApply: { _ in called = true })
    } throws: { error in
      (error as? ManifestFailure)?.diagnostics.first?.code == "manifest.unsupported"
    }
    #expect(!called)
    #expect(try fixture.snapshot() == before)
  }

  /// A lock without its declaration stops instruction writes, including authoring a new file
  /// while the scope lock already exists.
  @Test func missingDeclarationStopsInstructionWrites() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.addOwn(names: ["guide"])
    let store = fixture.store()
    try FileManager.default.removeItem(at: store.declarationURL)
    let before = try fixture.snapshot()
    let missing = CoreError.missingDeclaration(store.declarationURL.path)
    #expect(throws: missing) {
      try InstructionOperations.initializeInstructions(
        named: "style", environment: fixture.environment)
    }
    #expect(throws: missing) {
      try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    }
    #expect(throws: missing) {
      try InstructionOperations.listManaged(environment: fixture.environment)
    }
    #expect(try fixture.snapshot() == before)
  }
}
