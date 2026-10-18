import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Legacy Watch Ledger")
struct LegacyWatchLedgerTests {
  @Test func loadsLegacyWatchLedgerButSavesStateFile() throws {
    let project = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let agentDirectory = project.appendingPathComponent(".agent")
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
    try """
    schema_version: 1
    watches:
    - watch_id: legacy
      source:
        identity: legacy
        kind: localFileSystem
        location: /tmp/legacy
        state: {}
        skills: []
      checkout_path:
      watch_baseline: baseline
      current_head: baseline
      watched_paths:
      - path: skills/legacy
        tracking: {}
        review_coverage: {}
      events: []
    """.write(
      to: agentDirectory.appendingPathComponent("watched-skills.yaml"),
      atomically: true,
      encoding: .utf8)

    let ledger = try SkillOperations.watches.store.load(environment: environment)
    #expect(ledger.watches.map(\.watchID) == ["legacy"])

    let seen = try SkillOperations.watches.seen(
      watchID: "legacy", path: "skills/legacy", commit: "seen", environment: environment,
      apply: true)
    #expect(seen.watchedPaths[0].lastSeen == "seen")
    #expect(try SkillOperations.watches.store.load(environment: environment).watches[0] == seen)
    try WatchLedgerStore.save(ledger, environment: environment)
    #expect(
      FileManager.default.fileExists(
        atPath: agentDirectory.appendingPathComponent("skills-state.json").path))
    #expect(
      FileManager.default.fileExists(
        atPath: agentDirectory.appendingPathComponent("watched-skills.yaml").path))
  }

}
