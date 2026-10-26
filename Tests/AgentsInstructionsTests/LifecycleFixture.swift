import AgentsCore
import AgentsInstructions
import Foundation
import Testing

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
      removeTemporaryDirectory(root)
      throw error
    }
  }

  deinit { removeTemporaryDirectory(root) }

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

  func section(
    _ name: String, body: String = "Original", container: String = "instructions",
    heading: String? = nil, paths: [String] = []
  ) throws {
    try write(
      unitText(name, body: body, heading: heading, paths: paths),
      to: repo.appendingPathComponent(container + "/" + name + ".md"))
  }

  /// Writes one of the project's own instructions files in `.agent/instructions/`.
  func own(_ name: String, body: String = "Original", heading: String? = nil, paths: [String] = [])
    throws
  {
    try write(
      unitText(name, body: body, heading: heading, paths: paths),
      to: project.appendingPathComponent(".agent/instructions/" + name + ".md"))
  }

  @discardableResult
  func addOwn(
    names: [String], agents: [AgentID]? = nil, replace: Bool = false,
    environment: RuntimeEnvironment? = nil
  ) throws -> InstructionAddOutcome {
    try InstructionOperations.add(
      InstructionAddOptions(
        source: ".", names: names, replace: replace, agents: agents,
        environment: environment ?? self.environment))
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    try ProcessRunner.run(
      "/usr/bin/env",
      arguments: ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-C", repo.path]
        + arguments
    ).stdout
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

/// An instructions file: front matter, then the body under `heading`, by default `# <name>`.
func unitText(
  _ name: String, body: String = "Original", heading: String? = nil, paths: [String] = [],
  description: String? = nil
) -> String {
  var front = "---\ndescription: \(description ?? "Instructions for \(name).")\n"
  if !paths.isEmpty {
    front += "paths: [" + paths.map { "\"\($0)\"" }.joined(separator: ", ") + "]\n"
  }
  return front + "---\n" + (heading ?? "# \(name)") + "\n\n" + body + "\n"
}

/// A generated target: the notice, then each section body, one blank line apart.
func generated(_ bodies: [String]) -> String {
  ([Instructions.notice] + bodies).joined(separator: "\n\n") + "\n"
}

private func removeTemporaryDirectory(_ directory: URL) {
  do {
    try FileManager.default.removeItem(at: directory)
  } catch let error as CocoaError where error.code == .fileNoSuchFile {
  } catch {
    Issue.record(error)
  }
}
