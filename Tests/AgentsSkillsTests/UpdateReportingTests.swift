import Foundation
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

  @Test(arguments: ["prepared", "cached", "staged"])
  func rejectsModeDisagreementBeforePublication(_ kind: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "same")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let store = fixture.store()
    let before = try fixture.stateAndTargetBytes()
    try store.withLock {
      let resolutions = try SourceResolutionSession(store: store)
      let plan = try SkillOperations.prepareUpdate(
        store: store, declaration: store.readDeclaration(), previous: store.readResolved(),
        resolutions: resolutions)
      if kind == "prepared" {
        let lifecycle = try SkillLifecycle(store: store, provider: WellKnownProvider())
        let source = try lifecycle.discover(
          store.readDeclaration().sources["fixture"]!, live: false, fullDepth: true)
        let prepared = try lifecycle.prepare(
          source.skills[0], in: source,
          declaration: SkillDeclaration(select: .all, mode: .copy), defaultAgents: [.codex])
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: prepared.directory.appendingPathComponent("SKILL.md").path)
        #expect(throws: CoreError.self) { try lifecycle.validate(prepared, name: "demo") }
      } else if kind == "cached" {
        let record = try #require(plan.next.skills["demo"])
        let path = SourceCache(store: store).materializedURL(
          sourceID: record.source, revision: record.revision!
        )
        .appendingPathComponent("skills/demo/SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        #expect(throws: CoreError.self) { try plan.retain() }
      } else {
        let retained = try plan.retain()
        let transaction = FileTransaction(store: store) { step in
          if step == "stage.0.constructed" {
            let parent = fixture.target("demo").deletingLastPathComponent()
            let staged = try #require(
              FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
              ).first { $0.lastPathComponent.hasPrefix(".agents-") }
            )
            .appendingPathComponent("entry.0.staged")
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o755],
              ofItemAtPath: staged.appendingPathComponent("SKILL.md").path)
          }
        }
        try plan.stage(retained: retained, transaction: transaction)
        #expect(throws: CoreError.self) { try transaction.commit() }
      }
    }
    #expect(try fixture.stateAndTargetBytes() == before)
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
      resolved: ResolvedState())
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
    declaration.skills = nil
    try store.save(declaration: declaration, resolved: store.loadResolved())
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
    declaration.skills?["fixture"]?.agents = [.codex, .cursor, .claudeCode]
    try store.save(declaration: declaration, resolved: store.loadResolved())
    let added = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(added.membership.first { $0.agent == .codex }?.before == .installed(mode: .edit))
    #expect(added.membership.first { $0.agent == .cursor }?.before == .absent)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    declaration.skills?["fixture"]?.agents = [.codex, .cursor]
    declaration.skills?["fixture"]?.mode = .copy
    try store.save(declaration: declaration, resolved: store.loadResolved())
    let changed = try #require(
      SkillOperations.updateInstalled(environment: fixture.environment).first)
    #expect(changed.membership.first { $0.agent == .claudeCode }?.after == .absent)
    #expect(
      changed.membership.filter { $0.agent != .claudeCode }.allSatisfy {
        $0.before == .installed(mode: .edit) && $0.after == .installed(mode: .copy)
      })
    #expect(Set(changed.changes.map(\.path)).count == changed.changes.count)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
  }

  @Test func lossOfRecordAndSelectionDoesNotInventRemoval() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    _ = try fixture.add(mode: .edit)
    let store = fixture.store()
    try store.save(declaration: Declaration(), resolved: ResolvedState())
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
