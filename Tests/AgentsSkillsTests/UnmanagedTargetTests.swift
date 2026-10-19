import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Unmanaged targets")
struct UnmanagedTargetTests {
  enum Entry: CaseIterable { case directory, file, linkToDirectory }

  @Test(arguments: [InstallScope.project, .user], [InstallMode.link, .copy])
  func addLeavesUnmanagedContentAndStateUntouched(_ scope: InstallScope, _ mode: InstallMode)
    throws
  {
    for entry in Entry.allCases {
      let fixture = try SkillFixture()
      try fixture.skill("pdf", body: "managed")
      try fixture.commit()
      let store = fixture.store(scope)
      let target = SkillLifecycle.target(name: "pdf", agent: .claudeCode, store: store)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      let handwritten = Data("---\nname: pdf\ndescription: written by hand\n---\nmine\n".utf8)
      let owned = fixture.root.appendingPathComponent("owned-pdf")
      switch entry {
      case .directory:
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try handwritten.write(to: target.appendingPathComponent("SKILL.md"))
      case .file:
        try handwritten.write(to: target)
      case .linkToDirectory:
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try handwritten.write(to: owned.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: owned)
      }
      let stateBefore = [store.declarationURL, store.resolvedURL].map {
        FileManager.default.contents(atPath: $0.path)
      }

      #expect {
        try SkillOperations.add(
          AddOptions(
            source: fixture.repo.path, alias: "team", agents: [.claudeCode], skillNames: ["pdf"],
            scope: scope, mode: mode, environment: fixture.environment))
      } throws: { error in
        guard case CoreError.invalidSkill(let message) = error else { return false }
        return message.contains("skill 'pdf' in \(scope.rawValue) scope")
          && message.contains(SkillLifecycle.physicalTarget(target).path)
          && message.contains("move or remove it first")
      }
      let content =
        entry == .file
        ? FileManager.default.contents(atPath: target.path)
        : FileManager.default.contents(atPath: target.appendingPathComponent("SKILL.md").path)
      #expect(content == handwritten, "entry: \(entry)")
      #expect(
        [store.declarationURL, store.resolvedURL].map {
          FileManager.default.contents(atPath: $0.path)
        } == stateBefore)
    }
  }

  @Test(arguments: [InstallScope.project, .user])
  func danglingLinksHoldNoContentAndAreReplaced(_ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("pdf", body: "managed")
    try fixture.commit()
    let target = SkillLifecycle.target(
      name: "pdf", agent: .claudeCode, store: fixture.store(scope))
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: target.path, withDestinationPath: "missing-skill")
    let outcome = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "team", agents: [.claudeCode], skillNames: ["pdf"],
        scope: scope, mode: .copy, environment: fixture.environment))
    #expect(outcome.installed.map(\.skill) == ["pdf"])
    #expect(try fixture.body(target).contains("managed"))
  }

  @Test func reinstallingAManagedTargetStillReplacesIt() throws {
    let fixture = try SkillFixture()
    try fixture.skill("pdf", body: "first")
    try fixture.commit()
    let options = AddOptions(
      source: fixture.repo.path, alias: "team", agents: [.claudeCode], skillNames: ["pdf"],
      mode: .copy, environment: fixture.environment)
    _ = try SkillOperations.add(options)
    try fixture.skill("pdf", body: "second")
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let target = SkillLifecycle.target(name: "pdf", agent: .claudeCode, store: fixture.store())
    #expect(try fixture.body(target).contains("second"))
  }
}
