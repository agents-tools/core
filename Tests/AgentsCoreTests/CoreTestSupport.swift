import Foundation
import Testing

@testable import AgentsCore

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

func stateTestProcess(root: URL, arguments: [String]) throws -> Process {
  var directory = Bundle(for: TransactionTestBundle.self).bundleURL.deletingLastPathComponent()
  while !FileManager.default.isExecutableFile(
    atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
  {
    directory.deleteLastPathComponent()
  }
  let process = Process()
  process.executableURL = directory.appendingPathComponent("StateTestProcess")
  process.arguments = [root.path] + arguments
  try process.run()
  return process
}
private final class TransactionTestBundle: NSObject {}
