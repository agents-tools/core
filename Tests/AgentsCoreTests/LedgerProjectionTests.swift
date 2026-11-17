import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger domain projection")
struct LedgerProjectionTests {
  @Test func instructionTargetsUseTheirActualRoutes() throws {
    let root = URL(fileURLWithPath: "/projection-project")
    let home = URL(fileURLWithPath: "/projection-home")
    var ledger = ResolvedLedger()
    let hash = "sha256:" + String(repeating: "a", count: 64)
    ledger.sources["root"] = .init(kind: .local, revision: "live")
    ledger.components["input"] = .init(
      declaringSource: "root", source: "root", root: ".", kind: "command", name: "review",
      payload: .init(), conditions: [], recipients: [.claudeCode], chatGPT: false, resources: [])
    for (index, record) in [
      ("agents/instructions@1", "AGENTS.md", LedgerDeployment.Ownership.generated),
      ("agents/claude-import@1", "CLAUDE.md", .importBlock),
      ("agents/claude-components@1", ".claude/commands/review.md", .generated),
      ("agents/claude-components@1", ".claude/plugins/review", .generated),
      ("agents/skill@1", ".claude/skills/review", .generated),
    ].enumerated() {
      let id = "deployment-\(index)"
      ledger.deployments.append(
        .init(
          id: id, target: .init(kind: .registered, root: "project", path: record.1),
          route: record.0, owners: ["input"], recipients: [.claudeCode], ownership: record.2,
          expectedHash: hash, created: index == 1, importReference: index == 1 ? "AGENTS.md" : nil))
      ledger.lowerings.append(
        .init(
          id: "lowering-\(index)", format: record.0, inputs: ["input"], resources: [],
          deployments: [id], layout: .init(), platform: "macos", artifacts: []))
    }
    try ledger.validate()
    let projection = try ledger.domainProjection(roots: ["project": root, "home": home])
    #expect(Set(projection.instructions.targets.keys) == ["AGENTS.md", "CLAUDE.md"])
    #expect(projection.instructions.targets["CLAUDE.md"]?.import == "AGENTS.md")
    #expect(projection.instructions.targets["CLAUDE.md"]?.created == true)
    #expect(projection.instructions.targets["AGENTS.md"]?.blockHash == hash)
  }
}
