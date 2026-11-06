import AgentsCore
import AgentsInstructions
import AgentsManifest
import Foundation
import Testing

/// Instruction writes through the scope's `Agents.swift` declaration document.
@Suite("Instruction declaration documents")
struct DeclarationDocumentTests {
  @Test func instructionEditsKeepCommentsAndUntouchedBytes() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.own("style")
    let declaration = fixture.store().declarationURL
    let header = """
      // agents-tools-version: 1.0
      import AgentsDescription

      // Project instructions.
      let agents = Agents(
        components: [
          // Shared guidance first.

      """
    let closing = "  ]\n)\n"
    try fixture.write(
      header + "    .instructions(sections: [\"guide\"], agents: [.codex]),\n" + closing,
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
        == header + "    .instructions(sections: [\"style\"], agents: [.claudeCode, .codex]),\n"
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
      "// agents-tools-version: 1.0\nimport AgentsDescription\n\nlet agents = Agents()\n".utf8)
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

  /// Sections held in a constant have no direct source range, so the add stops before the
  /// callback and any write.
  @Test func readOnlySectionsStopBeforeTheCallback() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.own("style")
    try fixture.write(
      """
      // agents-tools-version: 1.0
      import AgentsDescription

      let shared: [SectionReference] = ["guide"]
      let agents = Agents(components: [.instructions(sections: shared, agents: [.codex])])

      """, to: fixture.store().declarationURL)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    let before = try fixture.snapshot()
    var called = false
    #expect {
      try InstructionOperations.add(
        InstructionAddOptions(source: ".", names: ["style"], environment: fixture.environment),
        beforeApply: { _ in called = true })
    } throws: { error in
      (error as? ManifestFailure)?.diagnostics.first?.code == "manifest.edit.readOnly"
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
