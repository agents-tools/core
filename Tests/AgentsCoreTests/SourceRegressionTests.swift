import Foundation
import Testing

@testable import AgentsCore

@Suite("Source regressions")
struct SourceRegressionTests {
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
    let hosted = try SourceParser.parse(
      "https://gitlab.example.test/team/subgroup/repo/-/tree/release/skills")
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
