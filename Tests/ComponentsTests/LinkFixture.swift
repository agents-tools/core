import AgentsCore
import AgentsManifest
import Components
import Foundation
import Testing

final class LinkFixture {
  let root: URL
  let project: URL
  let home: URL
  var environment: RuntimeEnvironment {
    RuntimeEnvironment(projectDirectory: project, homeDirectory: home, environment: [:])
  }
  var store: StateStore { StateStore(scope: .project, environment: environment) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "component-tests-" + UUID().uuidString)
    project = root.appendingPathComponent("project")
    home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  deinit {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }

  func write(_ text: String, to path: String, base: URL? = nil) throws {
    let file = (base ?? root).appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func manifest(_ expression: String, at directory: URL) throws {
    try write(Self.text(expression), to: ".agent/Agents.swift", base: directory)
  }

  static func text(_ expression: String) -> String {
    "// agents-tools-version: 1.0\nimport AgentsDescription\n" + expression + "\n"
  }

  func document(_ expression: String) throws -> DeclarationDocument {
    try DeclarationDocument(
      bytes: Array(Self.text(expression).utf8), identity: DocumentIdentity("consumer/Agents.swift"))
  }

  func link(
    _ expression: String, preserving pins: [String: SourceRevision] = [:],
    directPins: [ComponentKey: SourceRevision] = [:]
  ) throws -> LinkedComponents {
    try ComponentLinker.withLinkedComponents(
      document: document(expression), store: store,
      platform: .macOS, preserving: pins, directPins: directPins
    ) { graph, _ in graph }
  }

  @discardableResult
  func git(_ directory: URL, _ arguments: [String]) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", directory.path] + arguments)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func initialize(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try git(directory, ["init", "--initial-branch=main"])
    for (key, value) in [
      ("maintenance.auto", "false"), ("gc.auto", "0"),
      ("user.name", "Fixture"), ("user.email", "fixture@example.test"), ("commit.gpgsign", "false"),
    ] {
      try git(directory, ["config", key, value])
    }
  }

  @discardableResult
  func commit(_ directory: URL, tag: String? = nil) throws -> String {
    try git(directory, ["add", "."])
    try git(directory, ["commit", "-m", "fixture"])
    if let tag { try git(directory, ["tag", tag]) }
    return try git(directory, ["rev-parse", "HEAD"])
  }

  func skill(_ name: String, at directory: URL, restrictions: String = "") throws {
    try write(
      "---\nname: \(name)\ndescription: Fixture skill\n\(restrictions)---\nBody\n",
      to: "skills/\(name)/SKILL.md", base: directory)
  }

  func instruction(_ name: String, at directory: URL, own: Bool = true, restrictions: String = "")
    throws
  {
    try write(
      "---\ndescription: Fixture section\n\(restrictions)---\n# \(name)\nBody\n",
      to: (own ? ".agent/instructions/" : "instructions/") + name + ".md", base: directory)
  }
}
