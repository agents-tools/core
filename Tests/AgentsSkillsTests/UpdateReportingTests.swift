import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Skill update metadata")
struct UpdateReportingTests {
  @Test(arguments: [false, true])
  func versionsFollowResolvedTagsIncludingSameCommit(_ sameCommit: Bool) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "old")
    try fixture.commit()
    func git(_ args: [String]) throws {
      try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", fixture.repo.path] + args)
    }
    try git(["-c", "tag.gpgsign=false", "tag", "-a", "v1.2.0", "-m", "fixture"])
    let old = try fixture.head()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "fixture", agents: [.codex], mode: .copy, all: true,
        sourceRequirement: .upToNextMajor(from: "1.2.0"), environment: fixture.environment))
    if !sameCommit {
      try fixture.skill("demo", body: "new")
      try fixture.commit()
    }
    try git(["-c", "tag.gpgsign=false", "tag", "-a", "v1.3.0", "-m", "fixture"])
    let result = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(result.oldVersion == "1.2.0" && result.newVersion == "1.3.0")
    #expect(try result.oldRevision == old && result.newRevision == fixture.head())
    #expect(result.changed)
    if sameCommit { #expect(result.changes.isEmpty) }
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try SkillOperations.updateInstalled(environment: fixture.environment).allSatisfy {
        !$0.changed
      })
  }

  @Test(arguments: [InstallMode.copy, .link], [InstallScope.project, .user])
  func executableOnlyUpdatesKeepHashes(_ mode: InstallMode, _ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "unchanged")
    let file = fixture.repo.appendingPathComponent("skills/demo/run.sh")
    let bytes = Data("#!/bin/sh\necho hello\n".utf8)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try fixture.commit()
    _ = try fixture.add(mode: mode, scope: scope)
    let target = fixture.target("demo", scope: scope).appendingPathComponent("run.sh")
    for executable in [true, false] {
      try FileManager.default.setAttributes(
        [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
      try fixture.commit()
      let preview = try SkillOperations.updateInstalled(
        scope: scope, environment: fixture.environment)
      let result = try #require(preview.first)
      #expect(result.changed && result.oldHash == result.newHash)
      let diff = try #require(result.changes.first { $0.path.hasSuffix("/run.sh") })
      #expect(diff.before == .file(bytes, executable: !executable))
      #expect(diff.after == .file(bytes, executable: executable))
      _ = try SkillOperations.updateInstalled(
        scope: scope, environment: fixture.environment, apply: true
      ) {
        #expect($0 == preview)
        let current = try flag(target)
        #expect(current == !executable)
      }
      #expect(try flag(target) == executable)
      #expect(
        try SkillOperations.updateInstalled(scope: scope, environment: fixture.environment)
          .allSatisfy { !$0.changed })
    }
  }

  @Test func installedCopyModeDriftIsRepairedAtTheSamePin() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "same")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let file = fixture.target("demo").appendingPathComponent("SKILL.md")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    let result = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(
      result.changed && result.oldRevision == result.newRevision && result.oldHash == result.newHash
    )
    #expect(result.oldVersion == nil && result.newVersion == nil)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try !flag(file))
  }

  @Test(arguments: [[AgentID.codex, .claudeCode], [.codex, .cursor]])
  func liveMembershipAndLostLockPreserveOwnership(_ agents: [AgentID]) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    let store = fixture.store()
    try store.save(
      declaration: Declaration(
        sources: ["fixture": SourceDeclaration(kind: .local, location: fixture.repo.path)],
        skills: ["fixture": SkillDeclaration(select: .all, agents: agents, mode: .edit)]),
      ledger: ResolvedLedger())
    let initial = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(initial.membership.count == agents.count)
    #expect(
      initial.membership.allSatisfy { $0.before == .absent && $0.after == .installed(mode: .edit) })
    #expect(initial.oldVersion == nil && initial.newVersion == nil && initial.newHash == nil)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let repeatReport = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(!repeatReport.changed && repeatReport.membership.allSatisfy { $0.before == $0.after })
    try FileManager.default.removeItem(at: store.resolvedURL)
    let lost = try #require(SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(lost.lockMissing && lost.changed && lost.changes.isEmpty)
    #expect(
      lost.membership.allSatisfy { $0.before == .absent && $0.after == .installed(mode: .edit) })
    #expect(throws: CoreError.self) {
      try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    }
    for path in Set(lost.membership.map(\.path)) {
      try FileManager.default.removeItem(atPath: path)
    }
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try SkillOperations.updateInstalled(environment: fixture.environment).allSatisfy {
        !$0.changed
      })
    for path in Set(lost.membership.map(\.path)) {
      try FileManager.default.removeItem(atPath: path)
    }
    let repair = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(repair.membership.allSatisfy { $0.before == $0.after } && !repair.changes.isEmpty)
    var declaration = try store.loadDeclaration()
    try declaration.setSkills(nil)
    try store.save(declaration: declaration, ledger: store.loadLedger())
    let removed = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(removed.changed && removed.changes.isEmpty && removed.newVersion == nil)
    #expect(
      removed.membership.allSatisfy { $0.before == .installed(mode: .edit) && $0.after == .absent })
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.repo.appendingPathComponent("skills/demo/SKILL.md").path))
  }

  @Test func recipientChangesAndModeTransitionsRemainExplicit() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    try fixture.commit()
    _ = try fixture.add(mode: .edit)
    let store = fixture.store()
    var declaration = try store.loadDeclaration()
    try declaration.updateSkills { $0?["fixture"]?.agents = [.codex, .cursor, .claudeCode] }
    try store.save(declaration: declaration, ledger: store.loadLedger())
    let added = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(added.membership.first { $0.agent == .codex }?.before == .installed(mode: .edit))
    #expect(added.membership.first { $0.agent == .cursor }?.before == .absent)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    try declaration.updateSkills { $0?["fixture"]?.agents = [.codex, .cursor] }
    try declaration.updateSkills { $0?["fixture"]?.mode = .copy }
    try store.save(declaration: declaration, ledger: store.loadLedger())
    let changed = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(changed.membership.first { $0.agent == .claudeCode }?.after == .absent)
    #expect(
      changed.membership.filter { $0.agent != .claudeCode }.allSatisfy {
        $0.before == .installed(mode: .edit) && $0.after == .installed(mode: .copy)
      })
    #expect(Set(changed.changes.map(\.path)).count == changed.changes.count)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let partial = try #require(
      UpdateOperations.preview(
        UpdateRequest(operation: .remove, kinds: [.skills], names: ["demo"], agents: [.codex]),
        environment: fixture.environment
      ).skills.first)
    #expect(partial.changes.isEmpty)
    #expect(partial.membership.first { $0.agent == .cursor }?.after == .installed(mode: .copy))
    #expect(try fixture.body(fixture.target("demo")).contains("live"))
  }

  @Test func lossOfRecordAndSelectionDoesNotInventRemoval() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    _ = try fixture.add(mode: .edit)
    let store = fixture.store()
    try store.save(declaration: Declaration(), ledger: ResolvedLedger())
    try FileManager.default.removeItem(at: store.resolvedURL)
    #expect(try SkillOperations.updateInstalled(environment: fixture.environment).isEmpty)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(FileManager.default.fileExists(atPath: fixture.target("demo").path))
  }
}

private func flag(_ file: URL) throws -> Bool {
  let mode =
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
  return (mode?.uint16Value ?? 0) & 0o111 != 0
}
