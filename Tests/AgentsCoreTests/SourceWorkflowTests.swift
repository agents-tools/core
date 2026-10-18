import Foundation
import Testing

@testable import AgentsCore

extension SourceParserTests {
  @Test func parsesHostedRepositoryURLsAndCompatibilitySelectors() throws {
    let github = try SourceParser.parse("https://github.com/owner/repo/tree/main/skills/my-skill")
    #expect(github.type == .github)
    #expect(github.url == "https://github.com/owner/repo.git")
    #expect(github.ref == "main")
    #expect(github.subpath == "skills/my-skill")

    let gitlab = try SourceParser.parse(
      "https://gitlab.com/group/subgroup/repo/-/tree/develop/path/to/skill")
    #expect(gitlab.type == .gitlab)
    #expect(gitlab.url == "https://gitlab.com/group/subgroup/repo.git")
    #expect(gitlab.ref == "develop")
    #expect(gitlab.subpath == "path/to/skill")

    let shorthand = try SourceParser.parse("owner/repo#branch@my-skill")
    #expect(shorthand.type == .github)
    #expect(shorthand.ref == "branch")
    #expect(shorthand.skillFilter == "my-skill")

    let blob = try SourceParser.parse("https://github.com/owner/repo/blob/main/README.md#L10")
    #expect(blob.ref == nil)

    let huggingFace = try SourceParser.parse("https://huggingface.co/spaces/owner/repo")
    #expect(huggingFace.type == .git)
  }
}

extension SourceResolutionTests {
  @Test func branchRequirementsCheckoutFetchedRemoteBranchHead() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let skill = source.appendingPathComponent("skills/demo")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try """
    ---
    name: demo
    description: initial branch head
    ---
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try initGitRepo(source)
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", source.path, "branch", "-M", "master"])

    let bare = root.appendingPathComponent("remote.git")
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "clone", "--bare", source.path, bare.path])

    let environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"),
      environment: [:])
    try FileManager.default.createDirectory(
      at: environment.projectDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: environment.homeDirectory, withIntermediateDirectories: true)
    let remote = URL(fileURLWithPath: bare.path).absoluteString

    let first = try SourceResolver.resolve(
      remote, environment: environment, requirement: .branch("master"))
    let initialRevision = try #require(first.revision)

    try """
    ---
    name: demo
    description: updated branch head
    ---
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", source.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", source.path, "commit", "-m", "update"])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", source.path, "push", bare.path, "master"])

    let second = try SourceResolver.resolve(
      remote, environment: environment, requirement: .branch("master"))
    #expect(second.revision != initialRevision)
    let text = try String(
      contentsOf: second.checkoutURL.appendingPathComponent("skills/demo/SKILL.md"),
      encoding: .utf8)
    #expect(text.contains("updated branch head"))
  }
}

extension PathSafetyAndSanitizationTests {
  @Test func rejectsTraversalInSourceSelectorsAndSubpaths() throws {
    #expect(throws: CoreError.self) {
      _ = try SourceParser.parse("owner/repo/../outside")
    }
    #expect(throws: CoreError.self) {
      _ = try PathSafety.sanitizeSubpath("/absolute")
    }
  }
}
