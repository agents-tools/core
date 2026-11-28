import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation
import StateTestSupport
import Testing

@testable import AgentsUpdates

@Suite("Semantic requirement updates")
struct RequirementUpdateTests {
  @Test func skillInstructionAndCombinedUpdatesKeepPinsAndOriginalLedgerBytes() throws {
    let fixture = try UpdateFixture()
    try fixture.git(["tag", "1.2.0"])
    try fixture.declare(agents: [.codex])
    var declaration = try fixture.store.loadDeclaration()
    declaration.agents = [.codex]
    try declaration.updateInstructions { $0?.agents = nil }
    declaration.sources["fixture"]?.requirement = .upToNextMajor(from: "1.2.0")
    try fixture.store.save(declaration: declaration, ledger: fixture.store.loadLedger())
    _ = try fixture.apply()
    let original = try fixture.store.loadResolved()
    var object = try #require(
      JSONSerialization.jsonObject(with: fixture.bytes(fixture.store.resolvedURL)) as? [String: Any]
    )
    var sourceUses = try #require(object["sourceUses"] as? [[String: Any]])
    let id = try #require(sourceUses.indices.first { sourceUses[$0]["requirement"] != nil })
    sourceUses[id]["requirement"] = ["from": "v1.2.0+lower", "to": "2.0.0+upper"]
    object["sourceUses"] = sourceUses
    let recordedBytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    try recordedBytes.write(to: fixture.store.resolvedURL)
    let beforeAttributes = try FileManager.default.attributesOfItem(
      atPath: fixture.store.resolvedURL.path)
    #expect(try !fixture.preview().hasChanges)
    let skills = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(skills.allSatisfy { !$0.changed })
    let instructions = try InstructionOperations.updateInstalled(
      environment: fixture.environment, apply: true)
    #expect(!instructions.hasChanges)
    let combined = try fixture.apply()
    #expect(!combined.report.hasChanges)
    #expect(try fixture.bytes(fixture.store.resolvedURL) == recordedBytes)
    #expect(try fixture.store.loadResolved() == original)
    let afterAttributes = try FileManager.default.attributesOfItem(
      atPath: fixture.store.resolvedURL.path)
    #expect(
      beforeAttributes[.systemFileNumber] as? UInt64 == afterAttributes[.systemFileNumber]
        as? UInt64)
    #expect(
      beforeAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date)
    let intentOnly = try InstructionOperations.updateInstalled(
      agents: [.codex], environment: fixture.environment, apply: true)
    #expect(intentOnly.hasChanges)
    #expect(try fixture.store.loadDeclaration().instructions?.agents == [.codex])
    #expect(try fixture.bytes(fixture.store.resolvedURL) == recordedBytes)
    try fixture.advance()
    try fixture.git(["tag", "1.3.0"])
    _ = try fixture.apply()
    let changed = try fixture.bytes(fixture.store.resolvedURL)
    #expect(changed != recordedBytes)
    let rewritten = try #require(JSONSerialization.jsonObject(with: changed) as? [String: Any])
    let rewrittenSources = try #require(rewritten["sourceUses"] as? [[String: Any]])
    #expect(rewrittenSources[id]["requirement"] as? [String: String] == ["from": "1.2.0"])
    #expect(
      try fixture.store.loadResolved().skills["demo"]?.revision
        == fixture.git(["rev-parse", "HEAD"]))
  }
}
