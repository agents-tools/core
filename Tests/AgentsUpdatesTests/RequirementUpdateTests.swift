import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation
import Testing

@testable import AgentsUpdates

@Suite("Semantic requirement updates")
struct RequirementUpdateTests {
  @Test func sourceMergingAcceptsEqualRangesAndRejectsDifferentRootsAndRequirements() throws {
    let old = LockedSource(
      kind: .git, url: "https://example.org/team.git", requirement: .branch("main"))
    var legacy = old
    legacy.requirement = .range(from: "v1.2.0+lower", to: "2.0.0+upper")
    let canonical = LockedSource(
      kind: .git, url: "ssh://user@EXAMPLE.org/team", requirement: .upToNextMajor(from: "1.2.0"))
    let merged = try UpdatePlan.mergedSources(
      previous: ["id": old], skills: ["id": legacy], instructions: ["id": canonical])
    #expect(merged["id"] == canonical)
    let unchanged = try UpdatePlan.mergedSources(
      previous: ["id": legacy], skills: ["id": canonical], instructions: ["id": legacy])
    #expect(unchanged["id"]?.requirement == legacy.requirement)
    var different = canonical
    different.path = "other"
    #expect(throws: CoreError.self) {
      try UpdatePlan.mergedSources(
        previous: ["id": old], skills: ["id": legacy], instructions: ["id": different])
    }
    different = canonical
    different.requirement = .upToNextMinor(from: "1.2.0")
    #expect(throws: CoreError.self) {
      try UpdatePlan.mergedSources(
        previous: ["id": old], skills: ["id": legacy], instructions: ["id": different])
    }
  }

  @Test func skillInstructionAndCombinedUpdatesKeepPinsAndOriginalLedgerBytes() throws {
    let fixture = try UpdateFixture()
    try fixture.git(["tag", "1.2.0"])
    try fixture.declare(agents: [.codex])
    var declaration = try fixture.store.loadDeclaration()
    declaration.agents = [.codex]
    declaration.instructions?.agents = nil
    declaration.sources["fixture"]?.requirement = .upToNextMajor(from: "1.2.0")
    try fixture.store.save(declaration: declaration, resolved: fixture.store.loadResolved())
    _ = try fixture.apply()
    let original = try fixture.store.loadResolved()
    var object = try #require(
      JSONSerialization.jsonObject(with: fixture.bytes(fixture.store.resolvedURL)) as? [String: Any]
    )
    var sources = try #require(object["sources"] as? [String: [String: Any]])
    let id = try #require(sources.keys.first)
    sources[id]?["requirement"] = ["from": "v1.2.0+lower", "to": "2.0.0+upper"]
    object["sources"] = sources
    let legacyBytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    try legacyBytes.write(to: fixture.store.resolvedURL)
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
    #expect(try fixture.bytes(fixture.store.resolvedURL) == legacyBytes)
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
    #expect(try fixture.bytes(fixture.store.resolvedURL) == legacyBytes)
    try fixture.advance()
    try fixture.git(["tag", "1.3.0"])
    _ = try fixture.apply()
    let changed = try fixture.bytes(fixture.store.resolvedURL)
    #expect(changed != legacyBytes)
    let rewritten = try #require(JSONSerialization.jsonObject(with: changed) as? [String: Any])
    let rewrittenSources = try #require(rewritten["sources"] as? [String: [String: Any]])
    #expect(rewrittenSources[id]?["requirement"] as? [String: String] == ["from": "1.2.0+lower"])
    #expect(
      try fixture.store.loadResolved().skills["demo"]?.revision
        == fixture.git(["rev-parse", "HEAD"]))
  }
}
