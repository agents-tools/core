import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Ledger instruction compatibility")
struct LedgerCompatibilityTests {
  @Test func generatedAndImportRemovalKeepExistingOwnership() throws {
    let generated = Data((Instructions.notice + "\n\n# Section\nBody\n").utf8)
    let digest = try ResolvedLedgerCodec.digest("unused")
    var deployment = LedgerDeployment(
      id: "target", target: .init(kind: .registered, root: "project", path: "AGENTS.md"),
      route: "agents/instructions@1", owners: ["section"], recipients: [.codex],
      ownership: .generated,
      expectedHash: digest, created: false)
    // Use the production source renderer to obtain the v1 whole-file expected hash.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ledger-compatibility-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = Data("---\ndescription: A section\n---\n# Section\nBody\n".utf8)
    let rendered = try InstructionCompatibility.renderSections([source], ids: ["section"])
    #expect(rendered == generated)
    // A tiny complete ledger gives the expected SHA-256 through the object identity.
    let hash = try resourceHash(rendered, root: root)
    deployment.expectedHash = hash
    #expect(try InstructionCompatibility.obsolete(deployment, before: rendered) == nil)
    #expect(
      try InstructionCompatibility.obsolete(deployment, before: Data("drift".utf8))
        == Data("drift".utf8))
    #expect(try InstructionCompatibility.obsolete(deployment, before: nil) == nil)
    deployment.ownership = .importBlock
    deployment.importReference = "AGENTS.md"
    deployment.created = true
    let block = Data(ClaudeForwarding.renderBlock(for: .root).utf8)
    #expect(try InstructionCompatibility.obsolete(deployment, before: block) == nil)
    let custom = Data("# My instructions\n\n".utf8) + block
    let after = try InstructionCompatibility.obsolete(deployment, before: custom)
    #expect(after == Data("# My instructions\n".utf8))
    deployment.created = false
    #expect(try InstructionCompatibility.obsolete(deployment, before: block) != nil)
  }

  private func resourceHash(_ bytes: Data, root: URL) throws -> String {
    let file = root.appendingPathComponent("rendered")
    try bytes.write(to: file)
    return try LedgerResources.capture(file, embed: false, limits: .standard).hash
  }
}
