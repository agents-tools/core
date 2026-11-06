import AgentsCore
import AgentsManifest
import Components
import Foundation
import Testing

@Suite("Component source linking", .serialized)
struct LinkingTests {
  @Test func pinnedLocalProducerAliasesUseTheirOriginalDiscoveryEnvironment() throws {
    let fixture = try LinkFixture()
    let dependency = fixture.root.appendingPathComponent("dependency")
    let absoluteDependency = fixture.root.appendingPathComponent("absolute-dependency")
    let homeDependency = fixture.home.appendingPathComponent("home-dependency")
    for (repository, name) in [
      (dependency, "dependency"), (absoluteDependency, "absolute"), (homeDependency, "home"),
    ] {
      try fixture.initialize(repository)
      try fixture.manifest(
        """
        let agents = Agents(exports: ["g"], groups: [.group(name: "g", components: [
          .mcpServer(name: "\(name)", transport: .stdio("never-run"))])])
        """, at: repository)
      try fixture.commit(repository, tag: "1.0.0")
    }
    let older = try fixture.git(dependency, ["rev-parse", "HEAD"])
    try fixture.write("new version", to: "version.txt", base: dependency)
    try fixture.commit(dependency, tag: "2.0.0")
    let producer = fixture.root.appendingPathComponent("producer")
    let discovery = producer.appendingPathComponent("published")
    try fixture.initialize(producer)
    try fixture.write("pinned prompt", to: "prompt.md", base: discovery)
    try fixture.manifest(
      """
      let agents = Agents(exports: ["g"], sources: [
        .source(name: "relative", path: "../../dependency", exact: "1.0.0"),
        .source(name: "absolute", path: "\(absoluteDependency.path)", exact: "1.0.0"),
        .source(name: "home", path: "~/home-dependency", exact: "1.0.0")],
        groups: [.group(name: "g", components: [
          .command(name: "review", description: "Review", prompt: .file("prompt.md"))],
          uses: [.group(name: "g", source: "relative"),
                 .group(name: "g", source: "absolute"), .group(name: "g", source: "home")])])
      """, at: discovery)
    let producerPin = try fixture.commit(producer, tag: "1.0.0")
    try fixture.write("live prompt shadow", to: "prompt.md", base: discovery)
    let document = try fixture.document(
      """
      let agents = Agents(sources: [
        .source(name: "dependency", path: "\(dependency.path)", from: "1.0.0"),
        .source(name: "p", path: "\(producer.path)", exact: "1.0.0", subpath: "published")],
        uses: [.group(name: "g", source: "dependency"), .group(name: "g", source: "p")])
      """)
    func link() throws -> LinkedComponents {
      try ComponentLinker.withLinkedComponents(
        document: document, store: fixture.store, platform: .macOS
      ) { graph, session in
        let id = "local:" + dependency.path
        #expect(graph.selections[id]?.revision == older)
        #expect(graph.constraints.filter { $0.source == id }.count == 2)
        #expect(graph.components.filter { $0.key.name == "dependency" }.count == 2)
        #expect(graph.references[2].snapshot.source == id)
        #expect(graph.references[3].snapshot.source == "local:" + absoluteDependency.path)
        #expect(graph.references[4].snapshot.source == "local:" + homeDependency.path)
        let command = try #require(graph.components.first { $0.key.name == "review" })
        #expect(command.snapshot.revision == producerPin)
        #expect(command.origins[0].provenance.relativePath == "published/.agent/Agents.swift")
        let resource = try #require(command.resources.first)
        let file = try session.resource(snapshot: resource.snapshot, path: resource.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "pinned prompt")
        #expect(!graph.constraints.contains { $0.source.contains("agents-resolution-") })
        return graph
      }
    }
    #expect(try link() == link())
  }

  @Test func orderDiamondsRepeatsAndProducerDefaults() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.instruction("section", at: producer)
    try fixture.manifest(
      """
      let agents = Agents(defaultAgents: [.claudeCode], exports: ["bundle"],
        components: [.mcpServer(name: "not-imported", transport: .stdio("never-run"))],
        groups: [
          .group(name: "leaf", components: [.instructions(sections: ["section"])]),
          .group(name: "left", uses: ["leaf"]),
          .group(name: "right", uses: ["leaf"]),
          .group(name: "bundle", components: [.mcpServer(name: "first", transport: .stdio("never-run"))], uses: ["left", "right"])
        ])
      """, at: producer)
    let expression = """
      let agents = Agents(defaultAgents: [.codex],
        sources: [.source(name: "p", path: "\(producer.path)")],
        components: [.mcpServer(name: "root", transport: .stdio("never-run"))],
        uses: [.group(name: "bundle", source: "p"), .group(name: "bundle", source: "p")])
      """
    let graph = try fixture.link(expression)
    #expect(
      graph.components.map(\.key.name) == [
        "root", "first", "section", "section", "first", "section", "section",
      ])
    #expect(graph.components.dropFirst().allSatisfy { $0.recipients == [.claudeCode] })
    #expect(Set(graph.components.flatMap(\.origins).map(\.occurrence)).count == 7)
    #expect(graph.components[2].origins[0].provenance.referenceChain.count == 3)
    #expect(graph.references.count == 10)
    #expect(throws: LinkError.self) { try graph.requireEditable(graph.components[2].key) }
    #expect(try fixture.link(expression) == graph)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".agent").path)
    )
  }

  @Test func crossSourceCycleAndExplicitExports() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.manifest(
      """
      let agents = Agents(exports: ["loop"], sources: [.source(name: "self", path: ".")],
        groups: [.group(name: "loop", uses: [.group(name: "loop", source: "self")])])
      """, at: producer)
    #expect(throws: LinkError.self) {
      try fixture.link(
        "let agents = Agents(sources: [.source(name: \"p\", path: \"\(producer.path)\")], uses: [.group(name: \"loop\", source: \"p\")])"
      )
    }
    try fixture.manifest("let agents = Agents(groups: [.group(name: \"private\")])", at: producer)
    #expect(throws: LinkError.self) {
      try fixture.link(
        "let agents = Agents(sources: [.source(name: \"p\", path: \"\(producer.path)\")], uses: [.group(name: \"private\", source: \"p\")])"
      )
    }
  }

  @Test func versionBacktrackingAndFixedBranchEvidence() throws {
    let fixture = try LinkFixture()
    let dependency = fixture.root.appendingPathComponent("dependency")
    try fixture.initialize(dependency)
    try fixture.manifest(
      "let agents = Agents(exports: [\"d\"], groups: [.group(name: \"d\", components: [.mcpServer(name: \"dep-one\", transport: .stdio(\"never-run\"))])])",
      at: dependency)
    let depOne = try fixture.commit(dependency, tag: "1.0.0")
    try fixture.manifest(
      "let agents = Agents(exports: [\"d\"], groups: [.group(name: \"d\", components: [.mcpServer(name: \"dep-two\", transport: .stdio(\"never-run\"))])])",
      at: dependency)
    try fixture.commit(dependency, tag: "2.0.0")
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(producer)
    let url = "file://localhost" + dependency.path
    func writeProducer(_ version: String) throws {
      try fixture.manifest(
        """
        let agents = Agents(exports: ["p"], sources: [.source(name: "d", url: "\(url)", exact: "\(version)")],
          groups: [.group(name: "p", uses: [.group(name: "d", source: "d")])])
        """, at: producer)
    }
    try writeProducer("1.0.0")
    let lower = try fixture.commit(producer, tag: "1.0.0")
    try writeProducer("2.0.0")
    try fixture.commit(producer, tag: "1.1.0")
    let graph = try fixture.link(
      """
      let agents = Agents(sources: [
        .source(name: "p", path: "\(producer.path)", from: "1.0.0"),
        .source(name: "d", url: "\(url)", exact: "1.0.0")],
        uses: [.group(name: "p", source: "p"), .group(name: "d", source: "d")])
      """)
    #expect(graph.components.map(\.key.name) == ["dep-one", "dep-one"])
    #expect(graph.selections["local:" + producer.path]?.revision == lower)
    #expect(graph.selections.values.contains { $0.revision == depOne })
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }

  @Test func targetingAndLiveEdit() throws {
    let fixture = try LinkFixture()
    let source = fixture.root.appendingPathComponent("skills")
    try fixture.skill(
      "review", at: source,
      restrictions: "agents: [claude-code]\nscopes: [project]\nplatforms: [macos]\n")
    let graph = try fixture.link(
      """
      let agents = Agents(defaultAgents: [.codex], sources: [.source(name: "s", path: "\(source.path)")],
        components: [.skills(source: "s", select: ["review"], mode: .edit,
          overrides: [.skill(name: "review", agents: [.claudeCode, .codex])])])
      """)
    let component = try #require(graph.components.first)
    #expect(component.recipients == [.claudeCode])
    guard case .skill(let skill, .edit, _) = component.payload else {
      Issue.record("expected live skill")
      return
    }
    #expect(skill.livePath == source.appendingPathComponent("skills/review").path)
    try fixture.skill("review", at: source, restrictions: "agents: wrong\n")
    #expect(throws: (any Error).self) {
      try fixture.link(
        "let agents = Agents(sources: [.source(name: \"s\", path: \"\(source.path)\")], components: [.skills(source: \"s\")])"
      )
    }
  }
}

extension LinkingTests {
  @Test func packageResourcesShareTheExportSourceVariable() throws {
    let fixture = try LinkFixture()
    let dependency = fixture.root.appendingPathComponent("dependency")
    try fixture.initialize(dependency)
    try fixture.write("old", to: "prompt.md", base: dependency)
    try fixture.manifest(
      "let agents = Agents(exports: [\"d\"], groups: [.group(name: \"d\")])", at: dependency)
    let first = try fixture.commit(dependency, tag: "1.0.0")
    try fixture.write("new", to: "prompt.md", base: dependency)
    try fixture.commit(dependency, tag: "1.1.0")
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.manifest(
      """
      let agents = Agents(exports: ["tools"], sources: [.source(name: "r", url: "file://localhost\(dependency.path)", from: "1.0.0")], groups: [.group(name: "tools", components: [.command(name: "review", description: "Review", prompt: .file("prompt.md", source: "r"))])])
      """, at: producer)
    let graph = try fixture.link(
      """
      let agents = Agents(sources: [.source(name: "p", path: "\(producer.path)"), .source(name: "d", url: "file://localhost\(dependency.path)", exact: "1.0.0")], uses: [.group(name: "tools", source: "p"), .group(name: "d", source: "d")])
      """)
    #expect(graph.components.first?.resources.first?.snapshot.revision == first)
    #expect(graph.constraints.filter { $0.source.hasPrefix("localhost/") }.count == 2)
  }
}
