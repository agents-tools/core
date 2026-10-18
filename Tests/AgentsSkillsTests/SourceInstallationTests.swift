import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Source Installation")
struct SourceInstallationTests {
  @Test func installsExactPrereleaseInsteadOfAnEarlierTagWithoutTheSkill() throws {
    let project = try temporaryDirectory()
    let home = try temporaryDirectory()
    let repo = project.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try "Skills repository".write(
      to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try initGitRepo(repo)
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v0.1.0-alpha.1"])

    let skillDir = repo.appendingPathComponent("skills/reminder-creator")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try """
    ---
    name: reminder-creator
    description: Prerelease skill
    ---
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "add prerelease skill"])
    let prereleaseRevision = try gitHead(repo)
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v0.1.0-alpha.4"])

    try "Stable release".write(
      to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "stable release"])
    let stableRevision = try gitHead(repo)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v0.1.0"])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "tag", "v0.1.0+build.1"])

    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let outcome = try SkillOperations.add(
      AddOptions(
        source: repo.path, agents: [.codex], skillNames: ["reminder-creator"],
        scope: .global, mode: .copy, path: "skills",
        sourceRequirement: .exact("0.1.0-alpha.4"), environment: environment))
    #expect(outcome.installed.map(\.skill) == ["reminder-creator"])
    #expect(outcome.source.revision == prereleaseRevision)
    #expect(outcome.source.resolvedVersion == "0.1.0-alpha.4")
    let lock = try InstallLockStore.load(scope: .global, environment: environment)
    #expect(lock.pins.first?.state.version == "0.1.0-alpha.4")
    #expect(lock.pins.first?.state.revision == prereleaseRevision)

    let stable = try SourceResolver.resolve(
      repo.path, environment: environment, requirement: .exact("0.1.0"))
    #expect(stable.requestedRef == "v0.1.0")
    #expect(stable.revision == stableRevision)
    let metadata = try SourceResolver.resolve(
      repo.path, environment: environment, requirement: .exact("0.1.0+build.1"))
    #expect(metadata.requestedRef == "v0.1.0+build.1")
    #expect(metadata.resolvedVersion == "0.1.0+build.1")
    let prereleaseRange = try SourceResolver.resolve(
      repo.path, environment: environment,
      requirement: .range(from: "0.1.0-alpha.1", to: "0.1.0"))
    #expect(prereleaseRange.revision == prereleaseRevision)
    #expect(prereleaseRange.resolvedVersion == "0.1.0-alpha.4")
  }

}
