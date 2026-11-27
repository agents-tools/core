import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@Suite("Consumer local source provenance", .serialized)
struct ConsumerSourceRegressionTests {
  private func declare(_ fixture: UpdateFixture, mode: InstallMode = .copy, source: URL? = nil)
    throws
  {
    try fixture.store.save(
      declaration: Declaration(
        sources: ["local": .init(kind: .local, location: (source ?? fixture.repo).path)],
        skills: ["local": .init(select: .all, agents: [.codex], mode: mode)]),
      ledger: fixture.store.loadLedger())
  }

  @Test(arguments: [InstallMode.copy, .link])
  func retainedGitSelectionRefusesWorkingTreeDowngrade(_ mode: InstallMode) throws {
    let fixture = try UpdateFixture()
    try declare(fixture, mode: mode)
    _ = try fixture.apply()
    let committed = try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md"))
    let revision = try fixture.git(["rev-parse", "HEAD"])
    try fixture.writeSource("uncommitted working tree")
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")) == committed)
    #expect(try fixture.store.loadResolved().skills["demo"]?.revision == revision)
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
    let before = try fixture.snapshot()
    do {
      _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
      Issue.record("a recorded Git selection became a working-tree snapshot")
    } catch {
      let diagnostic = String(describing: error)
      #expect(diagnostic.contains("Git could not "))
      #expect(diagnostic.contains(fixture.repo.path))
      #expect(diagnostic.contains("fatal:"))
      #expect(diagnostic.contains(fixture.store.declarationURL.path))
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func genuineDirectoryTracksItsWorkingContent() throws {
    let fixture = try UpdateFixture()
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
    try declare(fixture)
    _ = try fixture.apply()
    try fixture.writeSource("new directory bytes")
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("new directory bytes"))
    #expect(try fixture.store.loadResolved().skills["demo"]?.revision == nil)
  }

  @Test func explicitEditRemainsLiveAfterGitMetadataDisappears() throws {
    let fixture = try UpdateFixture()
    try declare(fixture)
    _ = try fixture.apply()
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
    try fixture.writeSource("live edit bytes")
    try declare(fixture, mode: .edit)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      fixture.target().resolvingSymlinksInPath().path
        == fixture.repo.appendingPathComponent("skills/demo").resolvingSymlinksInPath().path)
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("live edit bytes"))
    try fixture.writeSource("later live bytes")
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("later live bytes"))
  }

  @Test func aliasRebindingUsesActualRecordedSourceIdentity() throws {
    let fixture = try UpdateFixture()
    try declare(fixture)
    _ = try fixture.apply()
    let directory = fixture.root.appendingPathComponent("directory")
    try fixture.write(
      "---\nname: demo\ndescription: Directory\n---\nRebound content\n",
      to: directory.appendingPathComponent("skills/demo/SKILL.md"))
    try declare(fixture, source: directory)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target().appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("Rebound content"))
    #expect(try fixture.store.loadResolved().skills["demo"]?.source == "local:" + directory.path)
  }
}

@Suite("Consumer native instruction projection", .serialized)
struct ConsumerProjectionRegressionTests {
  @Test(arguments: [InstallScope.project, .user])
  func nativeCommandDoesNotBecomeInstructionTarget(_ scope: InstallScope) throws {
    let fixture = try UpdateFixture(scope: scope)
    try fixture.write(
      """
      version: 1
      sources: {rules: {path: "\(fixture.repo.path)"}}
      components:
        - {kind: command, name: review, description: Review, prompt: Review sources., agents: [claude-code]}
        - {kind: instructions, agents: [codex, claude-code], sections: [{name: rules, source: rules}]}
      """, to: fixture.store.declarationURL)
    if scope == .project {
      try fixture.write(
        "# Existing Claude instructions\n", to: fixture.root.appendingPathComponent("CLAUDE.md"))
    }
    _ = try fixture.apply()
    let ledger = try fixture.store.loadLedger()
    #expect(ledger.deployments.contains { $0.route == "agents/claude-components@1" })
    if scope == .project {
      #expect(ledger.deployments.contains { $0.route == "agents/claude-import@1" })
    }
    let healthy = try InstructionOperations.doctor(scope: scope, environment: fixture.environment)
    #expect(!healthy.diagnostics.contains { $0.kind == .invalidTarget })
    let file = fixture.instruction()
    let original = try fixture.bytes(file)
    try (original + Data("\nEdited target\n".utf8)).write(to: file)
    let drift = try InstructionOperations.doctor(scope: scope, environment: fixture.environment)
    #expect(drift.diagnostics.contains { $0.kind == .drift && $0.path == file })
    try FileManager.default.removeItem(at: file)
    let missing = try InstructionOperations.doctor(scope: scope, environment: fixture.environment)
    #expect(missing.diagnostics.contains { $0.kind == .missingTarget && $0.path == file })
  }
}
