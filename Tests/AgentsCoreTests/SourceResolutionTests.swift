import Foundation
import Testing

@testable import AgentsCore

@Suite("Source Resolution")
struct SourceResolutionTests {
  @Test(arguments: [
    (SourceRequirement.upToNextMajor(from: "1.0.0"), ["1.0.0", "1.5.0", "2.0.0-alpha.1"], "1.5.0"),
    (
      SourceRequirement.upToNextMajor(from: "1.0.0"),
      ["1.0.0", "1.5.0+build.1", "1.5.0+build.2", "2.0.0-alpha.1"], "1.5.0+build.2"
    ),
    (SourceRequirement.upToNextMinor(from: "1.0.0"), ["1.0.0", "1.0.5", "1.1.0-alpha.1"], "1.0.5"),
    (
      SourceRequirement.range(from: "1.0.0", to: "1.1.0"),
      ["1.0.0", "1.0.5", "1.1.0-alpha.1"], "1.0.5"
    ),
  ])
  func resolvesStableRangesWithoutPrereleases(
    requirement: SourceRequirement, tags: [String], expectedVersion: String
  ) throws {
    let project = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let repo = try taggedRepository(in: project, tags: tags)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: project.appendingPathComponent("home"),
      environment: [:])

    let resolved = try SourceResolver.resolve(
      repo.path, environment: environment, requirement: requirement)

    #expect(resolved.requestedRef == "v\(expectedVersion)")
    #expect(resolved.resolvedVersion == expectedVersion)
    #expect(resolved.sourcePin.state.version == expectedVersion)
  }

  @Test(arguments: ["1.0.0-alpha.1", "1.5.0-alpha.1", "2.0.0-alpha.1"])
  func rejectsStableRangeWithoutEligibleTags(tag: String) throws {
    let project = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let repo = try taggedRepository(in: project, tags: [tag])
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: project.appendingPathComponent("home"),
      environment: [:])

    #expect(throws: CoreError.notFound("tag in range 1.0.0..<2.0.0")) {
      _ = try SourceResolver.resolve(
        repo.path, environment: environment, requirement: .upToNextMajor(from: "1.0.0"))
    }
  }

  @Test func resolvesPrereleasesAdmittedByUpperBound() throws {
    let project = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let repo = try taggedRepository(
      in: project, tags: ["1.0.0", "2.0.0-beta.1", "2.0.0-beta.3", "2.0.0-beta.4", "2.0.0"])
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: project.appendingPathComponent("home"),
      environment: [:])

    let resolved = try SourceResolver.resolve(
      repo.path, environment: environment,
      requirement: .range(from: "1.0.0", to: "2.0.0-beta.3"))

    #expect(resolved.requestedRef == "v2.0.0-beta.1")
    #expect(resolved.resolvedVersion == "2.0.0-beta.1")
    #expect(resolved.sourcePin.state.version == "2.0.0-beta.1")
  }

  private func taggedRepository(in project: URL, tags: [String]) throws -> URL {
    let repo = project.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try "Skills repository".write(
      to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try initGitRepo(repo)
    for tag in tags {
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v\(tag)"])
    }
    return repo
  }

  @Test func resolvesSemanticVersionRequirementsFromTags() throws {
    let project = try temporaryDirectory()
    let home = try temporaryDirectory()
    let repo = project.appendingPathComponent("repo")
    let skillDir = repo.appendingPathComponent("skills/demo")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    ---
    name: demo
    description: v1.0.0
    ---
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try initGitRepo(repo)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "1.0.0"])

    try """
    ---
    name: demo
    description: v1.1.0
    ---
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "v1.1.0"])
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v1.1.0"])

    try """
    ---
    name: demo
    description: v2.0.0
    ---
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "v2.0.0"])
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "2.0.0"])

    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let exact = try SourceResolver.resolve(
      "\(repo.path)@exact:1.0.0", environment: environment)
    #expect(exact.resolvedVersion == "1.0.0")
    #expect(exact.sourcePin.requirement == .exact("1.0.0"))
    #expect(exact.sourcePin.state.version == "1.0.0")
    let exactText = try String(
      contentsOf: exact.checkoutURL.appendingPathComponent("skills/demo/SKILL.md"),
      encoding: .utf8)
    #expect(exactText.contains("v1.0.0"))

    let from = try SourceResolver.resolve(
      repo.path,
      environment: environment,
      requirement: .upToNextMajor(from: "1.0.0")
    )
    #expect(from.resolvedVersion == "1.1.0")
    let range = try SourceResolver.resolve(
      repo.path,
      environment: environment,
      requirement: .range(from: "1.0.0", to: "1.1.0")
    )
    #expect(range.resolvedVersion == "1.0.0")

    #expect(throws: CoreError.self) {
      _ = try SourceResolver.resolve(
        "\(repo.path)@branch:main",
        environment: environment,
        requirement: .revision("abc123"))
    }
  }
}
