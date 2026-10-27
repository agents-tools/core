import AgentsCore
import AgentsSkills
import Foundation
import Testing

@Suite("Watch subscriptions")
struct WatchSubscriptionTests {
  @Test func reportsThreeCommitsAndBothKindsThenAdvancesSeen() throws {
    let fixture = try SkillFixture()
    try fixture.skill("changed", body: "old")
    try fixture.skill("removed", body: "old")
    try writeInstruction("changed", body: "old", fixture: fixture)
    try writeInstruction("removed", body: "old", fixture: fixture)
    try fixture.commit()
    let initial = try fixture.head()
    try fixture.store().save(declaration: Declaration(), resolved: ResolvedState())
    let watch = SkillOperations.watchOperations()
    #expect(
      try watch.add(fixture.repo.path, alias: "upstream", environment: fixture.environment)
        == .revision(initial))
    #expect(try fixture.store().loadDeclaration().skills == nil)
    #expect(try fixture.store().loadResolved().skills.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.target("changed").path))

    try fixture.skill("new", body: "added")
    try writeInstruction("new", body: "added", fixture: fixture)
    try fixture.commit()
    let first = try fixture.head()
    try fixture.skill("changed", body: "new")
    try Data("extra".utf8).write(
      to: fixture.repo.appendingPathComponent("skills/changed/extra.txt"))
    try writeInstruction("changed", body: "new", fixture: fixture)
    try fixture.commit()
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("skills/removed"))
    try FileManager.default.removeItem(
      at: fixture.repo.appendingPathComponent("instructions/removed.md"))
    try fixture.commit()
    let current = try fixture.head()
    let bytes = try stateBytes(fixture)
    let status = try #require(watch.status(environment: fixture.environment).first)
    #expect(status.alias == "upstream")
    #expect(status.commitCount == 3)
    #expect(status.seen == .revision(initial) && status.current == .revision(current))
    #expect(status.changes.count == 6)
    for kind in [WatchItemKind.skill, .instructions] {
      let changes = status.changes.filter { $0.kind == kind }
      #expect(changes.first { $0.name == "new" }?.change == .new)
      #expect(changes.first { $0.name == "changed" }?.change == .changed)
      #expect(changes.first { $0.name == "removed" }?.change == .removed)
      #expect(changes.first { $0.name == "changed" }?.fileCount == (kind == .skill ? 2 : 1))
    }
    let diff = try watch.diff(
      "upstream", name: "changed", kind: .instructions, environment: fixture.environment)
    let file = try #require(diff.changes.first?.files.first)
    #expect(file.before == .file(Data("# changed\n\nold\n".utf8), executable: false))
    #expect(file.after == .file(Data("# changed\n\nnew\n".utf8), executable: false))
    #expect(try stateBytes(fixture) == bytes)
    #expect(try fixture.head() == current)

    try watch.seen("upstream", environment: fixture.environment)
    #expect(try watch.status(environment: fixture.environment).first?.changes.isEmpty == true)
    try fixture.skill("later", body: "later")
    try fixture.commit()
    let later = try #require(watch.status(environment: fixture.environment).first)
    #expect(later.commitCount == 1)
    #expect(later.changes.map(\.name) == ["later"])
    try watch.seen("upstream", revision: String(first.prefix(10)), environment: fixture.environment)
    let rewind = try #require(watch.status(environment: fixture.environment).first)
    #expect(rewind.seen == .revision(first) && rewind.commitCount == 3)
    #expect(!rewind.changes.contains { $0.name == "new" })
    let beforeInvalid = try stateBytes(fixture)
    #expect(throws: (any Error).self) {
      try watch.seen("upstream", revision: "missing-revision", environment: fixture.environment)
    }
    #expect(try stateBytes(fixture) == beforeInvalid)
  }

  @Test(arguments: [InstallScope.project, .user])
  func removePreservesInstalledSkillsAndOtherState(_ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "installed")
    try fixture.commit()
    _ = try fixture.add(scope: scope)
    let watch = SkillOperations.watchOperations()
    let store = fixture.store(scope)
    let lock = try Data(contentsOf: store.resolvedURL)
    let installed = try fixture.body(fixture.target("demo", scope: scope))
    try watch.add("fixture", scope: scope, environment: fixture.environment)
    try watch.remove(fixture.repo.path, scope: scope, environment: fixture.environment)
    #expect(try store.loadWatch().sources.isEmpty)
    #expect(try store.loadDeclaration().watch == [])
    #expect(try store.loadDeclaration().skills?["fixture"] != nil)
    #expect(try Data(contentsOf: store.resolvedURL) == lock)
    #expect(try fixture.body(fixture.target("demo", scope: scope)) == installed)
    #expect(try watch.status(scope: scope, environment: fixture.environment).isEmpty)
  }

  @Test func followsDefaultBranchInsteadOfInstallationVersionAndIgnoresUncommittedFiles() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "tagged")
    try fixture.commit()
    try git(fixture, ["tag", "v1.0.0"])
    try fixture.store().save(
      declaration: Declaration(sources: [
        "source": SourceDeclaration(
          kind: .local, location: fixture.repo.path,
          requirement: .exact("1.0.0"))
      ]), resolved: ResolvedState())
    try fixture.skill("demo", body: "head")
    try fixture.commit()
    let watch = SkillOperations.watchOperations()
    #expect(try watch.add("source", environment: fixture.environment) == .revision(fixture.head()))
    try fixture.skill("demo", body: "uncommitted")
    #expect(try watch.status(environment: fixture.environment).first?.changes.isEmpty == true)
    try git(fixture, ["checkout", "-b", "next-default"])
    try fixture.commit()
    let status = try #require(watch.status(environment: fixture.environment).first)
    #expect(status.commitCount == 1)
    #expect(status.current == .revision(try fixture.head()))
  }

  @Test func followsDeclaredBranchAndSearchRoot() throws {
    let fixture = try SkillFixture()
    try fixture.skill("outside", body: "outside")
    try write(
      fixture.repo.appendingPathComponent("bundle/skills/inside/SKILL.md"),
      "---\nname: inside\ndescription: Test\n---\nold")
    try write(
      fixture.repo.appendingPathComponent("bundle/.agents/instructions/rule.md"), "# Rule\nold")
    try fixture.commit()
    try git(fixture, ["branch", "topic"])
    let watch = SkillOperations.watchOperations()
    try watch.add(
      fixture.repo.path, alias: "source", requirement: .branch("topic"), path: "bundle",
      environment: fixture.environment)
    try fixture.skill("outside", body: "changed")
    try fixture.commit()
    #expect(try watch.status(environment: fixture.environment).first?.commitCount == 0)
    try git(fixture, ["checkout", "topic"])
    try write(
      fixture.repo.appendingPathComponent("bundle/skills/inside/SKILL.md"),
      "---\nname: inside\ndescription: Test\n---\nnew")
    try write(
      fixture.repo.appendingPathComponent("bundle/.agents/instructions/rule.md"), "# Rule\nnew")
    try fixture.commit()
    let status = try #require(watch.status(environment: fixture.environment).first)
    #expect(status.commitCount == 1)
    #expect(Set(status.changes.map(\.name)) == ["inside", "rule"])
  }

  @Test func namesNestedInstructionsByTheirContainerPathAndSkipsTargets() throws {
    let fixture = try SkillFixture()
    try write(fixture.repo.appendingPathComponent("instructions/epd/review.md"), "old")
    try write(fixture.repo.appendingPathComponent("instructions/notes.txt"), "ignored")
    try write(fixture.repo.appendingPathComponent("instructions/AGENTS.md"), "generated")
    try write(fixture.repo.appendingPathComponent(".agents/instructions/AGENTS.md"), "generated")
    try fixture.commit()
    let watch = SkillOperations.watchOperations()
    try watch.add(fixture.repo.path, alias: "source", environment: fixture.environment)
    try write(fixture.repo.appendingPathComponent("instructions/epd/review.md"), "new")
    try write(fixture.repo.appendingPathComponent("instructions/notes.txt"), "still ignored")
    try write(fixture.repo.appendingPathComponent("instructions/AGENTS.md"), "regenerated")
    try fixture.commit()
    let status = try #require(watch.status(environment: fixture.environment).first)
    #expect(status.changes.map(\.name) == ["epd/review"])
    #expect(status.changes.first?.newPath == "instructions/epd/review.md")
  }

  @Test func retainsSeenHistoryAcrossForcePushAndMirrorGarbageCollection() throws {
    let fixture = try SkillFixture()
    try fixture.skill("old", body: "old")
    try fixture.commit()
    let old = try fixture.head()
    let watch = SkillOperations.watchOperations()
    try watch.add(fixture.repo.path, alias: "source", environment: fixture.environment)
    try git(fixture, ["checkout", "--orphan", "replacement"])
    try git(fixture, ["rm", "-rf", "."])
    try fixture.skill("new", body: "new")
    try fixture.commit()
    let replacement = try fixture.head()
    try git(fixture, ["branch", "-D", "master"])
    _ = try watch.status(environment: fixture.environment)
    try mirrorGit(fixture, ["reflog", "expire", "--expire=now", "--all"])
    try mirrorGit(fixture, ["gc", "--prune=now"])
    let status = try #require(watch.status(environment: fixture.environment).first)
    #expect(status.seen == .revision(old) && status.commitCount == 1)
    #expect(status.changes.first { $0.name == "old" }?.change == .removed)
    #expect(status.changes.first { $0.name == "new" }?.change == .new)
    let diff = try watch.diff("source", name: "old", environment: fixture.environment)
    #expect(diff.changes.first?.files.first?.before != nil)
    try watch.seen("source", environment: fixture.environment)
    #expect(
      try mirrorGit(fixture, ["for-each-ref", "--format=%(objectname)", "refs/agents-watch/"])
        == replacement)
    try mirrorGit(fixture, ["gc", "--prune=now"])
    #expect(throws: (any Error).self) { try mirrorGit(fixture, ["cat-file", "-e", old]) }

    try git(fixture, ["checkout", "--orphan", "later"])
    try git(fixture, ["rm", "-rf", "."])
    try fixture.skill("later", body: "later")
    try fixture.commit()
    try git(fixture, ["branch", "-D", "replacement"])
    _ = try watch.status(environment: fixture.environment)
    let later = try fixture.head()
    try mirrorGit(fixture, ["update-ref", "refs/other/keep", later])
    try watch.remove("source", environment: fixture.environment)
    #expect(
      try mirrorGit(fixture, ["for-each-ref", "--format=%(refname)", "refs/agents-watch/"]).isEmpty)
    #expect(try mirrorGit(fixture, ["rev-parse", "refs/other/keep"]) == later)
    try mirrorGit(fixture, ["reflog", "expire", "--expire=now", "--all"])
    try mirrorGit(fixture, ["gc", "--prune=now"])
    #expect(throws: (any Error).self) { try mirrorGit(fixture, ["cat-file", "-e", replacement]) }
  }

  @Test func retainsWatchRefUntilTheLastInstalledConsumerIsRemoved() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "installed")
    try fixture.commit()
    let installed = try fixture.head()
    _ = try fixture.add()
    let watch = SkillOperations.watchOperations()
    try watch.add("fixture", environment: fixture.environment)
    try git(fixture, ["checkout", "--orphan", "replacement"])
    try git(fixture, ["rm", "-rf", "."])
    try fixture.skill("demo", body: "replacement")
    try fixture.commit()
    try git(fixture, ["branch", "-D", "master"])
    try watch.seen("fixture", environment: fixture.environment)
    try watch.remove("fixture", environment: fixture.environment)
    #expect(
      try mirrorGit(fixture, ["for-each-ref", "--format=%(objectname)", "refs/agents-watch/"])
        == installed)
    try mirrorGit(fixture, ["gc", "--prune=now"])
    #expect(try fixture.body(fixture.target("demo")).contains("installed"))
    try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    #expect(
      try mirrorGit(fixture, ["for-each-ref", "--format=%(objectname)", "refs/agents-watch/"])
        .isEmpty)
    try mirrorGit(fixture, ["reflog", "expire", "--expire=now", "--all"])
    try mirrorGit(fixture, ["gc", "--prune=now"])
    #expect(throws: (any Error).self) { try mirrorGit(fixture, ["cat-file", "-e", installed]) }
  }

  @Test(arguments: ["skill-md", "files", "archive"])
  func wellKnownDiffUsesRetainedBaselineAndDoesNotWriteState(_ format: String) throws {
    let fixture = try SkillFixture()
    let oldBytes = markdown("old")
    let newBytes = markdown("new")
    let oldFetch = try artifactFetch(fixture: fixture, format: format, content: oldBytes)
    let oldWatch = SkillOperations.watchOperations(fetch: oldFetch)
    let base = "https://watch.example.test"
    try oldWatch.add(base, alias: "remote", environment: fixture.environment)
    let oldSeen = try #require(fixture.store().loadWatch().sources[base]?.seen)
    #expect(!FileManager.default.fileExists(atPath: fixture.target("demo").path))
    let fetch = try artifactFetch(fixture: fixture, format: format, content: newBytes)
    let watch = SkillOperations.watchOperations(fetch: fetch)
    // A skill mutation prunes the shared cache while the old artifact is only watch-referenced.
    try fixture.skill("installed", body: "installed")
    try fixture.commit()
    _ = try fixture.add()
    let before = try stateBytes(fixture)
    let tree = try FileHash.folderHash(fixture.store().cacheDirectory)
    let status = try #require(watch.status(environment: fixture.environment).first)
    let change = try #require(status.changes.first)
    #expect(status.commitCount == nil && status.seen == oldSeen)
    #expect(change.kind == .artifact && change.change == .changed && change.fileCount == 1)
    #expect(change.oldDigest != change.newDigest)
    let diff = try watch.diff("remote", name: "demo", environment: fixture.environment)
    let file = try #require(diff.changes.first?.files.first)
    #expect(file.before == .file(oldBytes, executable: false))
    #expect(file.after == .file(newBytes, executable: false))
    #expect(try stateBytes(fixture) == before)
    #expect(try FileHash.folderHash(fixture.store().cacheDirectory) == tree)
    #expect(throws: (any Error).self) {
      try watch.seen("remote", revision: "HEAD", environment: fixture.environment)
    }
    #expect(try stateBytes(fixture) == before)
    try watch.seen("remote", environment: fixture.environment)
    #expect(try watch.status(environment: fixture.environment).first?.changes.isEmpty == true)
    try watch.remove("remote", environment: fixture.environment)
    #expect(try fixture.store().loadResolved().skills["installed"] != nil)
  }

  @Test func filesDigestIsStableAcrossIndexOrderAndReportsNewAndRemovedArtifacts() throws {
    let fixture = try SkillFixture()
    let base = "https://watch.example.test"
    let original = filesFetch(names: ["demo", "removed"], reversed: false)
    let reordered = filesFetch(names: ["removed", "demo"], reversed: true)
    let watch = SkillOperations.watchOperations(fetch: original)
    try watch.add(base, alias: "remote", environment: fixture.environment)
    let same = SkillOperations.watchOperations(fetch: reordered)
    #expect(try same.status(environment: fixture.environment).first?.changes.isEmpty == true)
    let changed = SkillOperations.watchOperations(
      fetch: filesFetch(names: ["demo", "new"], reversed: false))
    let status = try #require(changed.status(environment: fixture.environment).first)
    #expect(status.changes.first { $0.name == "new" }?.change == .new)
    #expect(status.changes.first { $0.name == "removed" }?.change == .removed)
    #expect(status.changes.count == 2)
  }

  @Test func corruptWatchStopsEveryScopeMutationBeforeChangingAnything() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "old")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let watch = SkillOperations.watchOperations()
    try watch.add("fixture", environment: fixture.environment)
    try fixture.skill("demo", body: "new")
    try fixture.commit()
    try Data(#"{"version":1,"sources":{"local:/bad":{"seen":"invalid"}}}"#.utf8).write(
      to: fixture.store().watchURL)
    let before = try FileHash.folderHash(fixture.environment.projectDirectory)
    let mutations: [() throws -> Void] = [
      { _ = try watch.add("fixture", environment: fixture.environment) },
      { _ = try watch.seen("fixture", environment: fixture.environment) },
      { try watch.remove("fixture", environment: fixture.environment) },
      { _ = try fixture.add() },
      { _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true) },
      { _ = try SkillOperations.installResolvedReport(environment: fixture.environment) },
      { _ = try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment) },
      {
        try fixture.store().save(
          declaration: Declaration(), resolved: ResolvedState(), watch: WatchState())
      },
    ]
    for mutate in mutations {
      #expect(throws: (any Error).self) { try mutate() }
      #expect(try FileHash.folderHash(fixture.environment.projectDirectory) == before)
    }
  }

  @Test func rejectsNonGitLocalSubscriptionAndPreservesInstructionState() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "local")
    let watch = SkillOperations.watchOperations()
    #expect(throws: (any Error).self) {
      try watch.add(fixture.repo.path, environment: fixture.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().declarationURL.path))
    try fixture.commit()
    let declaration = Declaration(
      sources: ["rules": SourceDeclaration(kind: .local, location: fixture.repo.path)],
      instructions: InstructionsDeclaration(sections: ["rules:canonical"]))
    let lock = ResolvedState(
      sources: ["local:" + fixture.repo.path: LockedSource(kind: .local)],
      instructions: LockedInstructions(sections: [
        LockedSection(
          name: "canonical", source: "local:" + fixture.repo.path,
          revision: try fixture.head(), path: "instructions/canonical.md",
          hash: "sha256:" + String(repeating: "a", count: 64))
      ]))
    try fixture.store().save(declaration: declaration, resolved: lock)
    let lockBytes = try Data(contentsOf: fixture.store().resolvedURL)
    try watch.add("rules", environment: fixture.environment)
    try watch.seen("rules", environment: fixture.environment)
    try watch.remove("rules", environment: fixture.environment)
    #expect(try fixture.store().loadDeclaration().instructions == declaration.instructions)
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lockBytes)
  }
}

private func stateBytes(_ fixture: SkillFixture) throws -> [Data?] {
  try [fixture.store().declarationURL, fixture.store().resolvedURL, fixture.store().watchURL].map {
    FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil
  }
}

@discardableResult
private func mirrorGit(_ fixture: SkillFixture, _ arguments: [String]) throws -> String {
  let mirrorRoot = fixture.store().cacheDirectory.appendingPathComponent("mirrors")
  let mirror = try #require(
    FileManager.default.contentsOfDirectory(at: mirrorRoot, includingPropertiesForKeys: nil)
      .first { $0.pathExtension == "git" })
  return try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", mirror.path] + arguments
  ).stdout
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func git(_ fixture: SkillFixture, _ arguments: [String]) throws {
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", fixture.repo.path] + arguments)
}

private func write(_ url: URL, _ text: String) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}

private func writeInstruction(_ name: String, body: String, fixture: SkillFixture) throws {
  try write(
    fixture.repo.appendingPathComponent("instructions/\(name).md"), "# \(name)\n\n\(body)\n")
}

private func markdown(_ body: String) -> Data {
  Data("---\nname: demo\ndescription: Test\n---\n\(body)\n".utf8)
}

private func artifactFetch(fixture: SkillFixture, format: String, content: Data) throws
  -> @Sendable (URL) throws -> Data
{
  let index: Data
  let bytes: Data
  if format == "files" {
    index = Data(#"{"skills":[{"name":"demo","description":"Test","files":["SKILL.md"]}]}"#.utf8)
    bytes = content
  } else {
    if format == "archive" {
      let source = fixture.root.appendingPathComponent("archive-source")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try content.write(to: source.appendingPathComponent("SKILL.md"))
      let archive = fixture.root.appendingPathComponent("artifact.tar.gz")
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["tar", "-czf", archive.path, "-C", source.path, "."])
      bytes = try Data(contentsOf: archive)
    } else {
      bytes = content
    }
    index = try JSONSerialization.data(withJSONObject: [
      "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
      "skills": [
        [
          "name": "demo", "description": "Test", "type": format,
          "url": format == "archive" ? "/demo.tar.gz" : "/demo/SKILL.md",
          "digest": "sha256:" + FileHash.sha256Hex(data: bytes),
        ]
      ],
    ])
  }
  return { $0.path.hasSuffix("index.json") ? index : bytes }
}

private func filesFetch(names: [String], reversed: Bool) -> @Sendable (URL) throws -> Data {
  let files = reversed ? ["reference.txt", "SKILL.md"] : ["SKILL.md", "reference.txt"]
  return { url in
    if url.path.hasSuffix("index.json") {
      return try JSONSerialization.data(withJSONObject: [
        "skills": names.map {
          ["name": $0, "description": "Test", "files": files] as [String: Any]
        }
      ])
    }
    return Data((url.path.hasSuffix("SKILL.md") ? "skill" : "reference").utf8)
  }
}
