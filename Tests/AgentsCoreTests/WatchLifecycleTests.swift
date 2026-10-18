import Foundation
import Testing

@testable import AgentsCore

@Suite("Watch Lifecycle")
struct WatchLifecycleTests {
  @Test func managesWatchPathsAndReviewCursors() throws {
    let project = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let repo = project.appendingPathComponent("repo")
    for name in ["demo", "extra"] {
      let directory = repo.appendingPathComponent("skills/\(name)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try """
      ---
      name: \(name)
      description: \(name) skill
      ---
      """.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    try initGitRepo(repo)
    let baseline = try gitHead(repo)
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: [:])
    let source = try SourceResolver.resolve(repo.path, environment: environment)
    let watches = WatchService()
    let added = try watches.add(
      source: source, path: "skills/demo", environment: environment, apply: true)
    #expect(added.watchBaseline == baseline)
    _ = try watches.addPath(
      watchID: added.watchID, path: "skills/extra", environment: environment, apply: true)
    let pruned = try watches.removePath(
      watchID: added.watchID, path: "skills/extra", environment: environment, apply: true)
    #expect(pruned.watchedPaths.map(\.path) == ["skills/demo"])
    try "changed".write(
      to: repo.appendingPathComponent("skills/demo/notes.md"), atomically: true, encoding: .utf8)
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "change"])
    let head = try gitHead(repo)
    _ = try watches.refreshWatchedHead(
      watchID: added.watchID, environment: environment, apply: true)
    let diff = try watches.diff(
      watchID: added.watchID, path: "skills/demo", environment: environment)
    #expect(diff.first?.changedFiles.contains { $0.path == "skills/demo/notes.md" } == true)
    #expect(
      try watches.record(matching: repo.path, environment: environment).watchedPaths[0].tracking
        .lastCheckedCommit == nil)
    _ = try watches.check(
      watchID: added.watchID, path: "skills/demo", environment: environment, apply: true)
    let seen = try watches.seen(
      watchID: added.watchID, path: "skills/demo", note: "looked", environment: environment,
      apply: true)
    #expect(seen.watchedPaths[0].lastSeen == head)
    #expect(seen.watchedPaths[0].reviewCoverage.reviewedCommit == nil)
    let done = try watches.done(
      watchID: added.watchID, path: "skills/demo", note: "accepted", environment: environment,
      apply: true)
    #expect(done.watchedPaths[0].reviewCoverage.reviewedCommit == head)
    #expect(done.events.contains { $0.type == "done" && $0.note == "accepted" })
    try watches.remove(watchID: added.watchID, environment: environment, apply: true)
    #expect(try watches.store.load(environment: environment).watches.isEmpty)
    #expect(throws: CoreError.self) {
      try watches.record(matching: repo.path, environment: environment)
    }
  }
}
