import Foundation
import Testing

@testable import AgentsCore

@Suite("Watch Review Receipts")
struct WatchReviewReceiptTests {
  @Test func recordsWatchReviewCloseoutReceiptFields() throws {
    let project = try commandBehaviorTemporaryDirectory()
    let home = try commandBehaviorTemporaryDirectory()
    let repo = project.appendingPathComponent("repo")
    _ = try writeCommandBehaviorSkill(root: repo, path: "skills/demo", name: "demo")
    try commandBehaviorInitGitRepo(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let source = try SourceResolver.resolve(repo.path, environment: environment)
    _ = try WatchService().add(
      source: source, path: "skills/demo", requestedID: "demo", environment: environment,
      apply: true)
    _ = try WatchService().done(
      watchID: "demo",
      path: "skills/demo",
      commit: "reviewed-commit",
      note: "external receipt",
      status: "reviewed",
      outcome: "accepted",
      openItems: 0,
      granularity: "path",
      environment: environment,
      apply: true)

    let coverage = try #require(
      WatchLedgerStore().load(environment: environment).watches.first?.watchedPaths.first?
        .reviewCoverage)
    #expect(coverage.reviewedCommit == "reviewed-commit")
    #expect(coverage.status == "reviewed")
    #expect(coverage.outcome == "accepted")
    #expect(coverage.openItems == 0)
    #expect(coverage.granularity == "path")
  }

}

private func commandBehaviorTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("skill-cli-command-behavior-tests")
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@discardableResult
private func writeCommandBehaviorSkill(root: URL, path: String, name: String) throws -> URL {
  let skillDir = root.appendingPathComponent(path)
  try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
  try """
  ---
  name: \(name)
  description: \(name) description
  ---
  body
  """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  return skillDir
}

private func commandBehaviorInitGitRepo(_ repo: URL) throws {
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "init", repo.path])
  try ProcessRunner.run(
    "/usr/bin/env",
    arguments: ["git", "-C", repo.path, "config", "user.email", "tests@example.com"])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "config", "user.name", "Tests"])
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "initial"])
}

private func commandBehaviorGitHead(_ repo: URL) throws -> String {
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "rev-parse", "HEAD"])
    .stdout
    .trimmingCharacters(in: .whitespacesAndNewlines)
}
