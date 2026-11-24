import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore
@testable import AgentsSkills

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("agents-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func removeTemporaryDirectory(_ directory: URL) {
  do {
    try FileManager.default.removeItem(at: directory)
  } catch let error as CocoaError where error.code == .fileNoSuchFile {
  } catch {
    Issue.record(error)
  }
}

/// A child that survives the termination deadline fails the test instead of blocking the run.
func terminateProcess(_ process: Process) {
  do { try ProcessWait.terminate(process) } catch { Issue.record(error) }
}

func initGitRepo(_ repo: URL) throws {
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "init", "--initial-branch=master", repo.path])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "config", "maintenance.auto", "false"])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "config", "gc.auto", "0"])
  try ProcessRunner.run(
    "/usr/bin/env",
    arguments: ["git", "-C", repo.path, "config", "user.email", "tests@example.com"])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "config", "user.name", "Tests"])
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
  try ProcessRunner.run(
    "/usr/bin/env", arguments: ["git", "-C", repo.path, "commit", "-m", "initial"])
}

func gitHead(_ repo: URL) throws -> String {
  try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "rev-parse", "HEAD"])
    .stdout
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

extension StateStore {
  /// Writes the document that a first write of `declaration` creates, without a lock, watch
  /// state or scope lock.
  func writeDeclaration(_ declaration: Declaration) throws {
    let change = try planDeclaration(
      declaration, replacing: Declaration(), prepared: StatePrecondition(store: self))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try (change?.bytes ?? manifestText()).write(to: declarationURL)
  }
}
