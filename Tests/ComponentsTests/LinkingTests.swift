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
        version: 1
        exports: ["g"]
        groups: {"g": {"components": [{"kind": "mcpServer", "name": "\(name)", "transport": {"kind": "stdio", "executable": "never-run"}}]}}
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
      version: 1
      exports: ["g"]
      sources: {"relative": {"path": "../../dependency", "requirement": {"exact": "1.0.0"}}, "absolute": {"path": "\(absoluteDependency.path)", "requirement": {"exact": "1.0.0"}}, "home": {"path": "~/home-dependency", "requirement": {"exact": "1.0.0"}}}
      groups: {"g": {"components": [{"kind": "command", "name": "review", "description": "Review", "prompt": {"file": {"path": "prompt.md"}}}], "uses": [{"source": "relative", "group": "g"}, {"source": "absolute", "group": "g"}, {"source": "home", "group": "g"}]}}
      """, at: discovery)
    let producerPin = try fixture.commit(producer, tag: "1.0.0")
    try fixture.write("live prompt shadow", to: "prompt.md", base: discovery)
    let document = try fixture.document(
      """
      version: 1
      sources: {"dependency": {"path": "\(dependency.path)", "requirement": {"from": "1.0.0"}}, "p": {"path": "\(producer.path)", "subpath": "published", "requirement": {"exact": "1.0.0"}}}
      uses: [{"source": "dependency", "group": "g"}, {"source": "p", "group": "g"}]
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
        #expect(command.origins[0].provenance.relativePath == "published/.agent/agents.yaml")
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
      version: 1
      defaultAgents: ["claude-code"]
      exports: ["bundle"]
      components: [{"kind": "mcpServer", "name": "not-imported", "transport": {"kind": "stdio", "executable": "never-run"}}]
      groups: {"leaf": {"components": [{"kind": "instructions", "sections": [{"name": "section"}]}]}, "left": {"uses": [{"group": "leaf"}]}, "right": {"uses": [{"group": "leaf"}]}, "bundle": {"components": [{"kind": "mcpServer", "name": "first", "transport": {"kind": "stdio", "executable": "never-run"}}], "uses": [{"group": "left"}, {"group": "right"}]}}
      """, at: producer)
    let expression = """
      version: 1
      defaultAgents: ["codex"]
      sources: {"p": {"path": "\(producer.path)"}}
      components: [{"kind": "mcpServer", "name": "root", "transport": {"kind": "stdio", "executable": "never-run"}}]
      uses: [{"source": "p", "group": "bundle"}, {"source": "p", "group": "bundle"}]
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
      version: 1
      exports: ["loop"]
      sources: {"self": {"path": "."}}
      groups: {"loop": {"uses": [{"source": "self", "group": "loop"}]}}
      """, at: producer)
    #expect(throws: LinkError.self) {
      try fixture.link(
        "version: 1\nsources: {\"p\": {\"path\": \"\(producer.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"loop\"}]\n"
      )
    }
    try fixture.manifest("version: 1\ngroups: {\"private\": {}}\n", at: producer)
    #expect(throws: LinkError.self) {
      try fixture.link(
        "version: 1\nsources: {\"p\": {\"path\": \"\(producer.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"private\"}]\n"
      )
    }
  }

  @Test func versionBacktrackingAndFixedBranchEvidence() throws {
    let fixture = try LinkFixture()
    let dependency = fixture.root.appendingPathComponent("dependency")
    try fixture.initialize(dependency)
    try fixture.manifest(
      "version: 1\nexports: [\"d\"]\ngroups: {\"d\": {\"components\": [{\"kind\": \"mcpServer\", \"name\": \"dep-one\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"never-run\"}}]}}\n",
      at: dependency)
    let depOne = try fixture.commit(dependency, tag: "1.0.0")
    try fixture.manifest(
      "version: 1\nexports: [\"d\"]\ngroups: {\"d\": {\"components\": [{\"kind\": \"mcpServer\", \"name\": \"dep-two\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"never-run\"}}]}}\n",
      at: dependency)
    try fixture.commit(dependency, tag: "2.0.0")
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(producer)
    let url = "file://localhost" + dependency.path
    func writeProducer(_ version: String) throws {
      try fixture.manifest(
        """
        version: 1
        exports: ["p"]
        sources: {"d": {"url": "\(url)", "requirement": {"exact": "\(version)"}}}
        groups: {"p": {"uses": [{"source": "d", "group": "d"}]}}
        """, at: producer)
    }
    try writeProducer("1.0.0")
    let lower = try fixture.commit(producer, tag: "1.0.0")
    try writeProducer("2.0.0")
    try fixture.commit(producer, tag: "1.1.0")
    let graph = try fixture.link(
      """
      version: 1
      sources: {"p": {"path": "\(producer.path)", "requirement": {"from": "1.0.0"}}, "d": {"url": "\(url)", "requirement": {"exact": "1.0.0"}}}
      uses: [{"source": "p", "group": "p"}, {"source": "d", "group": "d"}]
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
      version: 1
      defaultAgents: ["codex"]
      sources: {"s": {"path": "\(source.path)"}}
      components: [{"kind": "skills", "source": "s", "select": ["review"], "mode": "edit", "overrides": {"review": {"agents": ["claude-code", "codex"]}}}]
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
        "version: 1\nsources: {\"s\": {\"path\": \"\(source.path)\"}}\ncomponents: [{\"kind\": \"skills\", \"source\": \"s\"}]\n"
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
      "version: 1\nexports: [\"d\"]\ngroups: {\"d\": {}}\n", at: dependency)
    let first = try fixture.commit(dependency, tag: "1.0.0")
    try fixture.write("new", to: "prompt.md", base: dependency)
    try fixture.commit(dependency, tag: "1.1.0")
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.manifest(
      """
      version: 1
      exports: ["tools"]
      sources: {"r": {"url": "file://localhost\(dependency.path)", "requirement": {"from": "1.0.0"}}}
      groups: {"tools": {"components": [{"kind": "command", "name": "review", "description": "Review", "prompt": {"file": {"path": "prompt.md", "source": "r"}}}]}}
      """, at: producer)
    let graph = try fixture.link(
      """
      version: 1
      sources: {"p": {"path": "\(producer.path)"}, "d": {"url": "file://localhost\(dependency.path)", "requirement": {"exact": "1.0.0"}}}
      uses: [{"source": "p", "group": "tools"}, {"source": "d", "group": "d"}]
      """)
    #expect(graph.components.first?.resources.first?.snapshot.revision == first)
    #expect(graph.constraints.filter { $0.source.hasPrefix("localhost/") }.count == 2)
  }
}
