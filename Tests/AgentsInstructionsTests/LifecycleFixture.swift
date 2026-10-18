import AgentsCore
import AgentsInstructions
import Foundation

final class InstructionFixture {
  let root: URL
  let project: URL
  let home: URL
  let repo: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "instruction-tests-" + UUID().uuidString)
    project = root.appendingPathComponent("project")
    home = root.appendingPathComponent("home")
    repo = root.appendingPathComponent("rules")
    do {
      for directory in [project, home, repo] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try git(["init", "--initial-branch=main"])
      try git(["config", "user.name", "Fixture"])
      try git(["config", "user.email", "fixture@example.invalid"])
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var environment: RuntimeEnvironment {
    RuntimeEnvironment(projectDirectory: project, homeDirectory: home, environment: [:])
  }

  func store(_ scope: InstallScope = .project, environment: RuntimeEnvironment? = nil) -> StateStore
  {
    StateStore(scope: scope, environment: environment ?? self.environment)
  }

  func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func section(_ name: String, body: String = "Original", container: String = "instructions") throws
  {
    try write(
      "# \(name)\n\n\(body)\n", to: repo.appendingPathComponent(container + "/" + name + ".md"))
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path] + arguments).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func commit() throws {
    try git(["add", "."])
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "fixture"])
  }

  @discardableResult
  func add(
    names: [String] = [], scope: InstallScope = .project, agents: [AgentID]? = nil,
    replace: Bool = false, path: String? = nil, environment: RuntimeEnvironment? = nil
  ) throws -> InstructionAddOutcome {
    try InstructionOperations.add(
      InstructionAddOptions(
        source: repo.path, alias: "rules", names: names, all: true, replace: replace,
        agents: agents, scope: scope, path: path, environment: environment ?? self.environment))
  }

  func bytes(_ path: String = "AGENTS.md") throws -> Data {
    try Data(contentsOf: project.appendingPathComponent(path))
  }
  func text(_ path: String = "AGENTS.md") throws -> String {
    String(decoding: try bytes(path), as: UTF8.self)
  }

  func snapshot(_ directory: URL? = nil, excludingCache: Bool = false) throws -> [String: Data] {
    let directory = directory ?? root
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return [:] }
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
      if excludingCache, file.lastPathComponent == "cache" {
        enumerator.skipDescendants()
        continue
      }
      let relative = PathSafety.relativePath(file.path, to: directory.path)
      if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
        result[relative] = Data(("link:" + link).utf8)
      } else if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[relative] = try Data(contentsOf: file)
      } else {
        result[relative + "/"] = Data()
      }
    }
    return result
  }
}
