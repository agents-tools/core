import AgentsCore
import AgentsManifest
import AgentsSkills
import Components
import Foundation
import Testing

@Suite("Component linking acceptance")
struct LinkingAcceptanceTests {
  @Test("A later transitive constraint selects an older feasible Git version")
  func laterTransitiveConstraintBacktracks() throws {
    let fixture = try LinkingFixture()
    defer { fixture.remove() }

    let repository = try fixture.gitRepository("a")
    try fixture.write(
      repository, ".agent/Agents.swift",
      manifest(
        """
        exports: ["server"],
        groups: [
          .group(name: "server", components: [
            .mcpServer(
              name: "server", transport: .stdio("server-v1"), agents: [.codex])
          ])
        ]
        """))
    let older = try fixture.commit(repository, tag: "1.0.0")
    try fixture.write(
      repository, ".agent/Agents.swift",
      manifest(
        """
        exports: ["server"],
        groups: [
          .group(name: "server", components: [
            .mcpServer(
              name: "server", transport: .stdio("server-v2"), agents: [.codex])
          ])
        ]
        """))
    _ = try fixture.commit(repository, tag: "2.0.0")

    let bridge = fixture.root.appendingPathComponent("bridge", isDirectory: true)
    try fixture.write(
      bridge, ".agent/Agents.swift",
      manifest(
        """
        exports: ["bridge"],
        sources: [.source(name: "a", path: "../a", exact: "1.0.0")],
        groups: [
          .group(name: "bridge", uses: [.group(name: "server", source: "a")])
        ]
        """))
    let document = try fixture.document(
      manifest(
        """
        sources: [
          .source(name: "a", path: "../a", from: "1.0.0"),
          .source(name: "bridge", path: "../bridge"),
        ],
        uses: [
          .group(name: "server", source: "a"),
          .group(name: "bridge", source: "bridge"),
        ]
        """))

    let graph = try fixture.link(document)
    let selected = try #require(graph.selections.values.first { $0.revision == older })
    #expect(selected.version == "1.0.0")
    #expect(graph.references.map(\.group) == ["server", "bridge", "server"])
    #expect(graph.references[2].parent == graph.references[1].occurrence)
    #expect(
      graph.constraints.filter { $0.source == graph.references[0].snapshot.source }.count == 2)
    let server = try #require(graph.components.first { $0.key.name == "server" })
    let servers = graph.components.filter { $0.key == server.key }
    let serverOrigins = servers.flatMap(\.origins)
    #expect(servers.allSatisfy { $0.snapshot.revision == older })
    #expect(servers.allSatisfy { $0.recipients == [.codex] })
    #expect(serverOrigins.count == 2)
    #expect(Set(serverOrigins.map(\.occurrence)).count == 2)
    #expect(serverOrigins.map(\.provenance.referenceChain).allSatisfy { !$0.isEmpty })
  }

  @Test("Diamond references preserve occurrences, producer targeting and ownership")
  func diamondOccurrencesAndTargeting() throws {
    let fixture = try LinkingFixture()
    defer { fixture.remove() }

    let producer = fixture.root.appendingPathComponent("producer", isDirectory: true)
    try fixture.write(
      producer, ".agent/Agents.swift",
      manifest(
        """
        defaultAgents: [.claudeCode, .codex],
        exports: ["left", "right"],
        components: [
          .mcpServer(name: "root-only", transport: .stdio("root-only"))
        ],
        groups: [
          .group(
            name: "leaf",
            components: [
              .mcpServer(name: "leaf-server", transport: .stdio("leaf")),
              .mcpServer(
                name: "empty-server", transport: .stdio("empty"),
                condition: .when(agents: [])),
            ],
            condition: .when(agents: [.codex], scopes: [.project])),
          .group(name: "left", uses: ["leaf"]),
          .group(name: "right", uses: ["leaf"]),
        ]
        """))
    let document = try fixture.document(
      manifest(
        """
        defaultAgents: [.cursor],
        sources: [.source(name: "producer", path: "../producer")],
        uses: [
          .group(name: "left", source: "producer"),
          .group(name: "right", source: "producer"),
          .group(name: "left", source: "producer"),
        ]
        """))

    let graph = try fixture.link(document)
    #expect(graph.references.map(\.group) == ["left", "leaf", "right", "leaf", "left", "leaf"])
    #expect(graph.references[1].parent == graph.references[0].occurrence)
    #expect(graph.references[3].parent == graph.references[2].occurrence)
    #expect(graph.references[5].parent == graph.references[4].occurrence)
    #expect(!graph.components.contains { $0.key.name == "root-only" })
    let leaf = try #require(graph.components.first { $0.key.name == "leaf-server" })
    let leaves = graph.components.filter { $0.key == leaf.key }
    let leafOrigins = leaves.flatMap(\.origins)
    #expect(leaves.allSatisfy { $0.recipients == [.codex] })
    #expect(leaves.allSatisfy { $0.snapshot == leaf.snapshot })
    #expect(leafOrigins.count == 3)
    #expect(Set(leafOrigins.map(\.occurrence)).count == 3)
    #expect(leafOrigins.allSatisfy { $0.provenance.referenceChain.count == 2 })
    let empty = try #require(graph.components.first { $0.key.name == "empty-server" })
    #expect(graph.components.filter { $0.key == empty.key }.allSatisfy { $0.recipients.isEmpty })
    do {
      try graph.requireEditable(leaf.key)
      Issue.record("An imported child must not be editable in the consumer declaration")
    } catch let error as LinkError {
      guard case .notEditableHere(let key, let provenance) = error else {
        Issue.record("Expected notEditableHere, got \(error)")
        return
      }
      #expect(key == leaf.key)
      #expect(provenance.relativePath.hasSuffix(".agent/Agents.swift"))
      #expect(!provenance.referenceChain.isEmpty)
    }
  }

  @Test("Protected impact follows actual pins and ignores unrelated root skills")
  func protectedImpactAndStablePreparation() throws {
    let fixture = try LinkingFixture()
    defer { fixture.remove() }

    let repository = try fixture.gitRepository("shared")
    let producer = manifest(
      """
      exports: ["server", "empty"],
      groups: [
        .group(name: "server", components: [
          .mcpServer(name: "shared-server", transport: .stdio("shared"), agents: [.codex])
        ]),
        .group(name: "empty"),
      ]
      """)
    try fixture.write(repository, ".agent/Agents.swift", producer)
    let older = try fixture.commit(repository, tag: "1.0.0")
    try fixture.write(repository, "revision-marker", "second snapshot\n")
    let newer = try fixture.commit(repository, tag: "2.0.0")
    let skills = fixture.root.appendingPathComponent("skills", isDirectory: true)
    try fixture.write(
      skills, "draft/SKILL.md",
      "---\nname: draft\ndescription: A local draft.\n---\n\n# Draft\n")

    func root(version: String, includeSkill: Bool, includeEmpty: Bool) -> String {
      let component =
        includeSkill
        ? #".skills(source: "drafts", select: ["draft"], mode: .edit, agents: [.codex])"#
        : ""
      let extra = includeEmpty ? #", .group(name: "empty", source: "shared")"# : ""
      return manifest(
        """
        sources: [
          .source(name: "shared", path: "../shared", exact: "\(version)"),
          .source(name: "drafts", path: "../skills"),
        ],
        components: [\(component)],
        uses: [.group(name: "server", source: "shared")\(extra)]
        """)
    }

    let initial = try fixture.document(
      root(version: "1.0.0", includeSkill: false, includeEmpty: false))
    let withSkill = try fixture.document(
      root(version: "1.0.0", includeSkill: true, includeEmpty: false))
    let bookkeeping = try fixture.document(
      root(version: "1.0.0", includeSkill: true, includeEmpty: true))
    let changedPin = try fixture.document(
      root(version: "2.0.0", includeSkill: true, includeEmpty: false))

    let beforeFiles = try fixture.inventory()
    let first = try fixture.link(initial)
    let skillGraph = try fixture.link(withSkill)
    let repeated = try fixture.link(withSkill)
    let bookkeepingGraph = try fixture.link(bookkeeping)
    let changed = try fixture.link(changedPin)
    #expect(skillGraph == repeated)
    #expect(try fixture.inventory() == beforeFiles)
    #expect(skillGraph.protectedChanges(from: first, allowing: [.skills]).isEmpty)
    #expect(bookkeepingGraph.protectedChanges(from: skillGraph, allowing: [.skills]).isEmpty)

    let server = try #require(skillGraph.components.first { $0.key.name == "shared-server" })
    #expect(server.snapshot.revision == older)
    #expect(changed.components.first { $0.key == server.key }?.snapshot.revision == newer)
    #expect(changed.protectedChanges(from: skillGraph, allowing: [.skills]).contains(server.key))
    #expect(skillGraph.protectedPins(allowing: [.skills]).values.contains { $0.revision == older })

    let draft = try #require(skillGraph.components.first { $0.key.name == "draft" })
    guard case .skill(let skill, let mode, _) = draft.payload else {
      Issue.record("Expected the live skill payload")
      return
    }
    #expect(mode == .edit)
    #expect(skill.livePath == skills.appendingPathComponent("draft").path)
    try fixture.write(
      skills, "draft/SKILL.md",
      "---\nname: draft\ndescription: A changed local draft.\n---\n\n# Draft\n")
    let edited = try fixture.link(withSkill)
    let editedDraft = try #require(edited.components.first { $0.key.name == "draft" })
    guard case .skill(let editedSkill, _, _) = editedDraft.payload else {
      Issue.record("Expected the edited live skill payload")
      return
    }
    #expect(editedSkill.livePath == skill.livePath)
    #expect(editedSkill.hash != skill.hash)
  }
}

private func manifest(_ arguments: String) -> String {
  """
  // agents-tools-version: 1.0
  import AgentsDescription

  let agents = Agents(
  \(arguments)
  )
  """
}

private struct LinkingFixture {
  let root: URL
  let project: URL
  let home: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "linking-acceptance-\(UUID().uuidString)", isDirectory: true)
    project = root.appendingPathComponent("project", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ directory: URL, _ path: String, _ contents: String) throws {
    let file = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: file)
  }

  func document(_ text: String) throws -> DeclarationDocument {
    try DeclarationDocument(
      bytes: Array(text.utf8), identity: DocumentIdentity("consumer/.agent/Agents.swift"))
  }

  func link(_ document: DeclarationDocument) throws -> LinkedComponents {
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home, environment: ["HOME": home.path])
    let store = StateStore(scope: .project, environment: environment)
    return try ComponentLinker.withLinkedComponents(
      document: document, store: store, platform: .macOS
    ) { graph, _ in graph }
  }

  func gitRepository(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try git(directory, ["init", "--initial-branch=main"])
    _ = try git(directory, ["config", "--local", "user.name", "Fixture"])
    _ = try git(directory, ["config", "--local", "user.email", "fixture@example.invalid"])
    _ = try git(directory, ["config", "--local", "gc.auto", "0"])
    _ = try git(directory, ["config", "--local", "maintenance.auto", "false"])
    return directory
  }

  func commit(_ repository: URL, tag: String) throws -> String {
    _ = try git(repository, ["add", "."])
    _ = try git(repository, ["commit", "-m", "Fixture \(tag)"])
    _ = try git(repository, ["tag", tag])
    return try git(repository, ["rev-parse", "HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  func git(_ directory: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
      "HOME": home.path,
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_AUTHOR_DATE": "2001-01-01T00:00:00Z",
      "GIT_COMMITTER_DATE": "2001-01-01T00:00:00Z",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw FixtureError.git(arguments, String(decoding: data, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
  }

  func inventory() throws -> [String: Data] {
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: project, includingPropertiesForKeys: [.isRegularFileKey], options: [])
    else { throw FixtureError.inventory }
    var files: [String: Data] = [:]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      if values.isRegularFile == true {
        files[String(url.path.dropFirst(project.path.count + 1))] = try Data(contentsOf: url)
      } else {
        files[String(url.path.dropFirst(project.path.count + 1)) + "/"] = Data()
      }
    }
    return files
  }
}

private enum FixtureError: Error {
  case git([String], String)
  case inventory
}
