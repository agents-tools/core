import AgentsCore
import AgentsInstructions
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

final class UpdateFixture {
  let root: URL
  let repo: URL
  let environment: RuntimeEnvironment
  let store: StateStore

  init(scope: InstallScope = .project) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "update-tests-" + UUID().uuidString)
    repo = root.appendingPathComponent("source")
    environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
      environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path])
    store = StateStore(scope: scope, environment: environment)
    do {
      for directory in [root, repo, environment.homeDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try git(["init", "--initial-branch=main"])
      try git(["config", "user.name", "Fixture"])
      try git(["config", "user.email", "fixture@example.invalid"])
      try git(["config", "maintenance.auto", "false"])
      try git(["config", "gc.auto", "0"])
      try writeSource("old")
      try commit()
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }

  @discardableResult
  func git(_ args: [String]) throws -> String {
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repo.path, "-c", "commit.gpgsign=false"] + args
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func writeSource(_ text: String) throws {
    try write(
      "---\nname: demo\ndescription: fixture\n---\n\n\(text)\n",
      to: repo.appendingPathComponent("skills/demo/SKILL.md"))
    try write("#!/bin/sh\necho fixture\n", to: repo.appendingPathComponent("skills/demo/run.sh"))
    try write(
      "---\ndescription: Fixture instructions.\n---\n# Rules\n\n\(text)\n",
      to: repo.appendingPathComponent("instructions/rules.md"))
  }

  func commit() throws {
    try git(["add", "."])
    try git(["commit", "-m", "fixture"])
  }

  func declare(mode: InstallMode = .copy, agents: [AgentID] = [.codex, .claudeCode]) throws {
    try store.save(
      declaration: Declaration(
        sources: ["fixture": SourceDeclaration(kind: .local, location: repo.path)],
        skills: ["fixture": SkillDeclaration(select: .all, agents: agents, mode: mode)],
        instructions: InstructionsDeclaration(
          agents: agents, sections: ["fixture:rules"],
          chatgpt: ["weekly": PromptDeclaration(sections: ["fixture:rules"])])),
      resolved: ResolvedState())
  }

  func install(mode: InstallMode = .copy, agents: [AgentID] = [.codex, .claudeCode]) throws {
    try declare(mode: mode, agents: agents)
    _ = try apply()
  }

  func advance() throws {
    try writeSource("new")
    try commit()
  }

  func target(_ agent: AgentID = .codex) -> URL {
    AgentRegistry.installSkillsDirectory(for: agent, scope: store.scope, environment: environment)
      .appendingPathComponent("demo")
  }

  func instruction(_ agent: AgentID = .codex) -> URL {
    InstructionLocations.file(for: agent, scope: store.scope, environment: environment)!
  }

  func apply() throws -> UpdateApplyResult {
    try UpdateOperations.withPreparedUpdate(scope: store.scope, environment: environment) {
      try $0.apply()
    }
  }

  func preview() throws -> CombinedUpdateReport {
    try UpdateOperations.preview(scope: store.scope, environment: environment)
  }

  func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

  func snapshot() throws -> [String: Data] {
    let files =
      [store.declarationURL, store.resolvedURL, store.watchURL]
      + AgentID.allCases.map { target($0).appendingPathComponent("SKILL.md") }
      + AgentID.allCases.compactMap {
        InstructionLocations.file(for: $0, scope: store.scope, environment: environment)
      }
    return Dictionary(
      files.compactMap { url in
        (try? bytes(url)).map { (url.path, $0) }
      }, uniquingKeysWith: { first, _ in first })
  }
}
