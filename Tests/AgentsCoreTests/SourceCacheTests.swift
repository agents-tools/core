import Foundation
import Testing

@testable import AgentsCore

@Suite("Source cache")
struct SourceCacheTests {
  @Test func sharesExactTreesAndPrunesOnlyUnreferencedPins() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("A".utf8).write(to: repo.appendingPathComponent("content"))
    try initGitRepo(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let cache = SourceCache(store: StateStore(scope: .project, environment: environment))
    let source = SourceDeclaration(kind: .local, location: repo.path)
    let id = try source.identity(environment: environment)
    let locked = LockedSource(kind: .local)
    let first = try cache.resolve(source)
    let tree = try cache.materialize(sourceID: id, source: locked, revision: first.revision)
    #expect(try cache.materialize(sourceID: id, source: locked, revision: first.revision) == tree)
    #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path))
    try Data("B".utf8).write(to: repo.appendingPathComponent("content"))
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-am", "B"])
    let second = try cache.resolve(source)
    #expect(first != second)
    #expect(try String(contentsOf: tree.appendingPathComponent("content"), encoding: .utf8) == "A")
    try cache.withSnapshot(sourceID: id, source: locked, revision: second.revision) {
      snapshot throws in
      #expect(
        try String(contentsOf: snapshot.appendingPathComponent("content"), encoding: .utf8) == "B")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: cache.materializedURL(sourceID: id, revision: second.revision).path))
    let section = LockedSection(
      name: "rules", source: id, revision: first.revision, path: "content",
      hash: "sha256:" + String(repeating: "a", count: 64))
    try cache.prune(
      referencedBy: ResolvedState(
        sources: [id: locked],
        instructions: LockedInstructions(chatgpt: ["prompt": LockedPrompt(sections: [section])])))
    #expect(FileManager.default.fileExists(atPath: tree.path))
    try cache.prune(referencedBy: ResolvedState())
    #expect(!FileManager.default.fileExists(atPath: tree.path))
  }

  @Test func resolvesBoundsAndIgnoresWorkingTreeChanges() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("committed".utf8).write(to: repo.appendingPathComponent("content"))
    try initGitRepo(repo)
    for tag in ["v1.0.0", "v1.0.4", "v1.1.0", "v1.5.0-beta.1", "v2.0.0"] {
      try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", tag])
    }
    try Data("dirty".utf8).write(to: repo.appendingPathComponent("content"))
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let cache = SourceCache(store: StateStore(scope: .project, environment: environment))
    for (requirement, expected) in [
      (SourceRequirement.upToNextMajor(from: "1.0.0"), "1.1.0"),
      (.upToNextMinor(from: "1.0.0"), "1.0.4"), (.exact("1.0.0"), "1.0.0"),
    ] {
      let source = SourceDeclaration(kind: .local, location: repo.path, requirement: requirement)
      let pin = try cache.resolve(source)
      #expect(pin.version == expected)
      let tree = try cache.materialize(
        sourceID: source.identity(environment: environment), source: LockedSource(kind: .local),
        revision: pin.revision)
      #expect(
        try String(contentsOf: tree.appendingPathComponent("content"), encoding: .utf8)
          == "committed")
    }
  }

  @Test func fixturesIgnoreConfiguredDefaultBranch() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("gitconfig")
    try Data("[init]\n defaultBranch = main\n".utf8).write(to: config)
    let repo = root.appendingPathComponent("repo")
    try ProcessRunner.run(
      "/usr/bin/env",
      arguments: [
        "GIT_CONFIG_GLOBAL=" + config.path, "git", "init", "--initial-branch=fixture", repo.path,
      ])
    #expect(
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["git", "-C", repo.path, "symbolic-ref", "--short", "HEAD"]
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture")
  }
}
