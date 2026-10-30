import AgentsManifest
import Foundation
import Testing

@testable import AgentsCore

@Suite("Source cache")
struct SourceCacheTests {
  @Test func sharesExactTreesAndPrunesOnlyUnreferencedPins() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
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

  @Test(arguments: [
    ("../missing/file.pdf", true), ("missing", true), ("../sub/file", true), ("../sub", true),
    ("../../outside", false), ("/etc/hosts", false), ("/nonexistent/file", false),
  ])
  func materializationKeepsInTreeLinksAndRejectsEscapes(_ destination: String, _ kept: Bool)
    throws
  {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: repo.appendingPathComponent("sub/file"))
    try FileManager.default.createSymbolicLink(
      atPath: repo.appendingPathComponent("docs/link").path, withDestinationPath: destination)
    try initGitRepo(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let cache = SourceCache(store: StateStore(scope: .project, environment: environment))
    let source = SourceDeclaration(kind: .local, location: repo.path)
    let pin = try cache.resolve(source)
    let materialize = {
      try cache.materialize(
        sourceID: source.identity(environment: environment), source: LockedSource(kind: .local),
        revision: pin.revision)
    }
    if kept {
      let tree = try materialize()
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: tree.appendingPathComponent("docs/link").path) == destination)
    } else {
      #expect(throws: CoreError.self) { try materialize() }
    }
  }

  @Test func resolvesBoundsAndIgnoresWorkingTreeChanges() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
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
    defer { removeTemporaryDirectory(root) }
    let config = root.appendingPathComponent("gitconfig")
    try Data("[init]\n defaultBranch = main\n".utf8).write(to: config)
    let repo = root.appendingPathComponent("repo")
    try ProcessRunner.run(
      "/usr/bin/env",
      arguments: [
        "GIT_CONFIG_GLOBAL=" + config.path, "git", "-c", "maintenance.auto=false", "-c",
        "gc.auto=0", "init", "--initial-branch=fixture", repo.path,
      ])
    #expect(
      try ProcessRunner.run(
        "/usr/bin/env",
        arguments: [
          "git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-C", repo.path,
          "symbolic-ref", "--short", "HEAD",
        ]
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture")
  }
}

extension SourceCacheTests {
  @Test(arguments: ["state", "cache", "materialized", "source", "pin"])
  func rejectsSymlinkedCacheAncestryWithoutDeletingExternalFiles(_ level: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let cache = SourceCache(store: store)
    let id = "local:/fixture"
    let revision = String(repeating: "a", count: 40)
    let pin = cache.materializedURL(sourceID: id, revision: revision)
    let source = pin.deletingLastPathComponent()
    let external = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(
      at: external.appendingPathComponent(revision), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: external.appendingPathComponent("unrelated"))
    let link: URL
    switch level {
    case "state":
      link = store.directory
      try FileManager.default.removeItem(at: link)
    case "cache": link = store.cacheDirectory
    case "materialized": link = store.cacheDirectory.appendingPathComponent("materialized")
    case "source": link = source
    default: link = pin
    }
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    let state = ResolvedState(
      sources: [id: LockedSource(kind: .local)],
      skills: [
        "demo": LockedSkill(
          source: id, revision: revision, path: ".",
          hash: "sha256:" + String(repeating: "b", count: 64), installs: ["codex": .link])
      ])
    #expect(throws: CoreError.self) { try cache.prune(referencedBy: state) }
    #expect(
      try String(contentsOf: external.appendingPathComponent("unrelated"), encoding: .utf8)
        == "keep")
    #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent(revision).path))
  }

  @Test func retainsArtifactContentContainingLiveEditSources() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let content = store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + String(repeating: "a", count: 64))
    try FileManager.default.createDirectory(
      at: content.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("live".utf8).write(to: content.appendingPathComponent("nested/SKILL.md"))
    let id = "local:" + content.path
    let state = ResolvedState(
      sources: [id: LockedSource(kind: .local)],
      skills: ["live": LockedSkill(source: id, path: "nested", installs: ["codex": .edit])])
    try SourceCache(store: store).prune(referencedBy: state)
    #expect(
      FileManager.default.fileExists(atPath: content.appendingPathComponent("nested/SKILL.md").path)
    )
  }
}
