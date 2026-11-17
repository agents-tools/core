import AgentsCore
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

struct FiniteSkillInstallationTests {
  @Test func registeredLoaderAliasExposesLogicalAndPhysicalReadLocations() throws {
    let f = try UpdateFixture()
    let physical = f.root.appendingPathComponent("physical-claude")
    try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent(".claude"), withDestinationURL: physical)
    _ = try SkillOperations.add(
      AddOptions(
        source: f.repo.path, agents: [.claudeCode], mode: .copy,
        all: true, environment: f.environment))
    let expected = Set([
      f.target(.claudeCode).path, physical.appendingPathComponent("skills/demo").path,
    ])
    #expect(Set(try f.preview().readLocations.map(\.path)).isSuperset(of: expected))
    #expect(
      Set(try UpdateOperations.inspect(environment: f.environment).readLocations.map(\.path))
        .isSuperset(of: expected))
  }

  @Test func liveMetadataUsesDeclaredNameWhileInstallationUsesCanonicalName() throws {
    let f = try UpdateFixture(scope: .user)
    let file = f.repo.appendingPathComponent("skills/demo/SKILL.md")
    try f.write("---\nname: Demo Skill\ndescription: fixture\n---\nLive body\n", to: file)
    try f.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: f.repo.path, agents: [.claudeCode], scope: .user,
        mode: .edit, all: true, environment: f.environment))
    let current = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(current.deployments.first?.location.lastPathComponent == "demo-skill")
    #expect(current.deployments.first?.status == .current)
    try f.write("---\nname: Other Skill\ndescription: fixture\n---\nLive body\n", to: file)
    let changed = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(changed.deployments.first?.status == .drifted)
  }

  @Test(arguments: [InstallMode.link, .copy, .edit])
  func userClaudeSkillUsesLegacyIntentionAcrossPublicLifecycle(_ mode: InstallMode) throws {
    let f = try UpdateFixture(scope: .user)
    _ = try SkillOperations.add(
      AddOptions(
        source: f.repo.path, alias: "fixture", agents: [.claudeCode], scope: .user,
        mode: mode, all: true, environment: f.environment))
    let target = f.target(.claudeCode)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))
    if mode != .copy {
      #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil)
    }
    let before = try FileHash.folderHash(f.root)
    let preview = try f.preview()
    #expect(try FileHash.folderHash(f.root) == before)
    #expect(try SkillOperations.listManaged(scope: .user, environment: f.environment).count == 1)
    #expect(try SkillOperations.listInstalled(scope: .user, environment: f.environment).count == 1)
    #expect(try SkillOperations.doctor(scope: .user, environment: f.environment).checks.isEmpty)
    _ = try UpdateOperations.withPreparedUpdate(scope: .user, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    try f.advance()
    _ = try SkillOperations.updateInstalled(scope: .user, environment: f.environment, apply: true)
    #expect(
      try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8).contains(
        "new"))
    try FileManager.default.removeItem(at: target)
    _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
    #expect(
      try UpdateOperations.inspect(scope: .user, environment: f.environment).deployments.allSatisfy
      { $0.status == .current })
    if mode == .edit {
      let alternate = f.root.appendingPathComponent("equal-live-source")
      try FileManager.default.copyItem(
        at: f.repo.appendingPathComponent("skills/demo"), to: alternate)
      try FileManager.default.removeItem(at: target)
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: alternate)
      let drift = try UpdateOperations.inspect(scope: .user, environment: f.environment)
      #expect(drift.deployments.first?.status == .drifted)
      _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
      #expect(
        try UpdateOperations.inspect(scope: .user, environment: f.environment).deployments.first?
          .status == .current)
    }
    _ = try SkillOperations.remove(skillNames: ["demo"], scope: .user, environment: f.environment)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try SkillOperations.listManaged(scope: .user, environment: f.environment).isEmpty)
  }
}
