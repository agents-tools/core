import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Source regressions")
struct SourceRegressionTests {
  @Test func localSnapshotsPreserveAliasedTreesMetadataAndMemoizedIdentity() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let live = root.appendingPathComponent("source")
    let nested = live.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("executable")
    let bytes = Data(repeating: 0xa5, count: 200_000)
    try bytes.write(to: file)
    let link = live.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "nested/executable")
    try FileManager.default.createSymbolicLink(
      atPath: live.appendingPathComponent("dangling").path, withDestinationPath: "nested/missing")
    for (url, mode): (URL, mode_t) in [
      (live, 0o750), (nested, 0o751), (file, 0o751), (link, 0o755),
    ] {
      try setFixtureMetadata(url, mode: mode, value: Data(url.lastPathComponent.utf8))
    }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live)
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    let source = SourceDeclaration(kind: .local, location: alias.path)
    let session = try SourceResolutionSession(store: store)
    defer { try? session.close() }
    let snapshot = try session.localSnapshot(source)
    #expect(snapshot.liveRoot == alias)
    #expect(try Data(contentsOf: snapshot.resource("link")) == bytes)
    #expect(try FileHash.folderHash(snapshot.root) == FileHash.folderHash(live))
    #expect(try FileHash.executableFlags(snapshot.root) == FileHash.executableFlags(live))
    for path in [".", "nested", "nested/executable", "link"] {
      #expect(
        try fixtureMetadata(snapshot.root.appendingPathComponent(path))
          == fixtureMetadata(live.appendingPathComponent(path)))
    }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: snapshot.root.appendingPathComponent("link").path) == "nested/executable")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: snapshot.root.appendingPathComponent("dangling").path) == "nested/missing")
    let repeated = try SourceResolutionSession.withTemporaryRead(store: store) {
      try $0.localSnapshot(source).snapshot
    }
    #expect(repeated == snapshot.snapshot)
    try Data("changed".utf8).write(to: file)
    let memoized = try session.localSnapshot(source)
    #expect(memoized.snapshot == snapshot.snapshot && memoized.root == snapshot.root)
    #expect(try Data(contentsOf: memoized.resource("link")) == bytes)
    let changed = try SourceResolutionSession.withTemporaryRead(store: store) {
      try $0.localSnapshot(source).snapshot
    }
    #expect(changed != snapshot.snapshot)
    let workspace = snapshot.root.deletingLastPathComponent()
    try session.close()
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
  }

  @Test(arguments: ["unsupported", "escaping-link"])
  func localSnapshotRefusesUnsafeEntriesAndCleansPartialCopies(_ kind: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    let live = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let session = try SourceResolutionSession(store: store)
    defer { try? session.close() }
    let first = try session.localSnapshot(SourceDeclaration(kind: .local, location: live.path))
    let invalid = root.appendingPathComponent("invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data("copied first".utf8).write(to: invalid.appendingPathComponent("a"))
    if kind == "unsupported" {
      try #require(mkfifo(invalid.appendingPathComponent("z").path, 0o600) == 0)
    } else {
      try FileManager.default.createSymbolicLink(
        atPath: invalid.appendingPathComponent("z").path, withDestinationPath: "../source")
    }
    #expect(throws: CoreError.self) {
      try session.localSnapshot(SourceDeclaration(kind: .local, location: invalid.path))
    }
    let workspace = first.root.deletingLastPathComponent()
    try session.close()
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
  }

  @Test func parsesLocalPathsAndGitLabSubgroupsAndTrees() throws {
    let cwd = URL(fileURLWithPath: "/workspace/project")
    for (input, expected) in [
      (".", "/workspace/project"), ("..", "/workspace"), ("./skills", "/workspace/project/skills"),
      ("../skills", "/workspace/skills"), ("/absolute/skills", "/absolute/skills"),
    ] {
      let parsed = try SourceParser.parse(input, currentDirectory: cwd)
      #expect(parsed.type == .local)
      #expect(parsed.localPath == expected)
    }
    for repository in ["group/subgroup/repo", "org/team/project/repo"] {
      for suffix in ["", ".git", "/", "/-/tree/main", "/-/tree/main/skills/demo"] {
        let parsed = try SourceParser.parse("https://gitlab.com/" + repository + suffix)
        #expect(parsed.type == .git)
        #expect(try SourceParser.identity(for: parsed) == "gitlab.com/" + repository)
        #expect(parsed.requirement == (suffix.contains("/tree/") ? .branch("main") : nil))
        #expect(parsed.subpath == (suffix.hasSuffix("skills/demo") ? "skills/demo" : nil))
      }
    }
    let location = "https://gitlab.example.test/team/subgroup/repo/-/tree/release/skills"
    let authority = try SourceAuthority(host: "gitlab.example.test")
    #expect(try SourceParser.parse(location, sourceAccess: .init()).type == .wellKnown)
    let hosted = try SourceParser.parse(
      location, sourceAccess: .init(providers: [authority: .gitlab]))
    #expect(hosted.type == .git)
    #expect(hosted.requirement == .branch("release"))
    #expect(hosted.subpath == "skills")
  }

  @Test func rejectsTraversalAndAbsoluteSubpathsAndAcceptsSafePaths() throws {
    let base = URL(fileURLWithPath: "/repository")
    for path in [
      "../etc", "../../etc/passwd", "skills/../../etc", "..\\..\\secret", "/absolute",
      "C:\\absolute", "a\0b",
    ] {
      #expect(throws: CoreError.self) { try PathSafety.resolvedChild(base: base, subpath: path) }
      #expect(throws: CoreError.self) {
        try Declaration(sources: [
          "fixture": SourceDeclaration(kind: .local, location: "/repository", path: path)
        ]).validate(environment: RuntimeEnvironment(projectDirectory: base))
      }
    }
    for path in ["skills/my-skill", "path/to/skill", "src", ".hidden", "file.txt", "..skill"] {
      #expect(try PathSafety.sanitizeSubpath(path) == path)
      #expect(
        try PathSafety.resolvedChild(base: base, subpath: path) == base.appendingPathComponent(path)
      )
    }
    #expect(try PathSafety.sanitizeSubpath("skills\\demo") == "skills/demo")
    #expect(try PathSafety.resolvedChild(base: base, subpath: ".") == base)
  }

  @Test func explicitBranchFollowsFetchedHeadWithoutMovingExistingTree() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("A".utf8).write(to: repo.appendingPathComponent("content"))
    try initGitRepo(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let cache = SourceCache(store: StateStore(scope: .project, environment: environment))
    let source = SourceDeclaration(
      kind: .local, location: repo.path, requirement: .branch("master"))
    let first = try cache.resolve(source)
    let tree = try cache.materialize(
      sourceID: source.identity(environment: environment), source: LockedSource(kind: .local),
      revision: first.revision)
    try Data("B".utf8).write(to: repo.appendingPathComponent("content"))
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-am", "B"])
    let second = try cache.resolve(source)
    #expect(second.revision == (try gitHead(repo)))
    #expect(second.revision != first.revision)
    #expect(try String(contentsOf: tree.appendingPathComponent("content"), encoding: .utf8) == "A")
  }

  @Test(arguments: [
    (
      SourceRequirement.range(from: "1.0.0", to: "1.1.0"),
      ["1.0.0", "1.0.5", "1.1.0-alpha.1", "1.1.0"], "1.0.5"
    ),
    (
      .range(from: "1.0.0", to: "2.0.0-beta.3"),
      ["1.0.0", "2.0.0-beta.1", "2.0.0-beta.3", "2.0.0"], "2.0.0-beta.1"
    ),
    (
      .upToNextMajor(from: "1.0.0"), ["1.0.0", "1.5.0+build.2", "1.5.0+build.1", "2.0.0-alpha.1"],
      "1.5.0+build.2"
    ),
  ])
  func resolvesRangeBoundsAndBuildMetadataTies(
    _ requirement: SourceRequirement, _ tags: [String], _ expected: String
  ) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = try taggedCache(root: root, tags: tags)
    let source = SourceDeclaration(
      kind: .local, location: root.appendingPathComponent("repo").path, requirement: requirement)
    let pin = try cache.resolve(source)
    #expect(pin.version == expected)
    let tree = try cache.materialize(
      sourceID: source.identity(environment: cache.store.environment),
      source: LockedSource(kind: .local), revision: pin.revision)
    #expect(
      try String(contentsOf: tree.appendingPathComponent("content"), encoding: .utf8) == expected)
  }

  @Test(arguments: ["1.0.0-alpha.1", "1.5.0-alpha.1", "2.0.0-alpha.1"])
  func stableRangeRejectsSourcesWithoutEligibleTags(_ tag: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = try taggedCache(root: root, tags: [tag])
    #expect(throws: CoreError.self) {
      try cache.resolve(
        SourceDeclaration(
          kind: .local, location: root.appendingPathComponent("repo").path,
          requirement: .upToNextMajor(from: "1.0.0")))
    }
  }

  private func taggedCache(root: URL, tags: [String]) throws -> SourceCache {
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("initial".utf8).write(to: repo.appendingPathComponent("content"))
    try initGitRepo(repo)
    for tag in tags {
      try Data(tag.utf8).write(to: repo.appendingPathComponent("content"))
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-am", tag])
      try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v" + tag])
    }
    return SourceCache(
      store: StateStore(
        scope: .project,
        environment: RuntimeEnvironment(
          projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
          environment: [:])))
  }
}
