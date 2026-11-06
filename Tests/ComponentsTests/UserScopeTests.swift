import AgentsCore
import Components
import Foundation
import Testing

@Suite("User package linking", .serialized)
struct UserScopeTests {
  @Test func packageResourcesAndSelfSkillsUseStateRootWithStableProvenance() throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: .user, environment: fixture.environment)
    for (directory, value) in [
      (fixture.project, "project shadow"), (fixture.home, "home shadow"),
      (store.directory, "package content"),
    ] {
      try fixture.write(value, to: "prompt.md", base: directory)
      try fixture.write(value, to: "tools/run", base: directory)
      try fixture.skill(value.replacingOccurrences(of: " ", with: "-"), at: directory)
    }
    let document = try fixture.document(
      """
      let agents = Agents(defaultAgents: [.codex], components: [
        .command(name: "review", description: "Review", prompt: .file("prompt.md")),
        .hook(name: "run", event: .afterTool, run: .executable("tools/run")),
        .skills(source: ".", mode: .edit)])
      """)
    func link() throws -> LinkedComponents {
      try ComponentLinker.withLinkedComponents(document: document, store: store, platform: .macOS) {
        graph, session in
        #expect(graph.components.map(\.key.name) == ["review", "run", "package-content"])
        for component in graph.components {
          #expect(component.recipients == [.codex])
          let provenance = try #require(component.origins.first?.provenance)
          #expect(provenance.sourceIdentity == "local:" + store.directory.path)
          #expect(provenance.relativePath == "Agents.swift")
        }
        for component in graph.components.prefix(2) {
          let resource = try #require(component.resources.first)
          let file = try session.resource(snapshot: resource.snapshot, path: resource.path)
          #expect(try String(contentsOf: file, encoding: .utf8) == "package content")
          #expect(resource.snapshot.source == "local:" + store.directory.path)
        }
        guard case .skill(let skill, .edit, _) = graph.components[2].payload else {
          Issue.record("expected live self-package skill")
          return graph
        }
        #expect(
          skill.livePath == store.directory.appendingPathComponent("skills/package-content").path)
        return graph
      }
    }
    #expect(try link() == link())
  }

  @Test func namedSourcesKeepDeclaringEnvironmentAndPromptAppendUsesHome() throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: .user, environment: fixture.environment)
    let source = fixture.project.appendingPathComponent("rules")
    try fixture.initialize(source)
    try fixture.instruction("rules", at: source, own: false, restrictions: "scopes: [\"user\"]\n")
    try fixture.commit(source)
    for directory in [fixture.home, store.directory] {
      try fixture.instruction("shadow", at: directory.appendingPathComponent("rules"), own: false)
    }
    for (directory, value) in [
      (fixture.project, "project append shadow"), (store.directory, "package append shadow"),
      (fixture.home, "home append"),
    ] {
      try fixture.write(value, to: "append.md", base: directory)
    }
    let document = try fixture.document(
      """
      let agents = Agents(sources: [.source(name: "rules", path: "rules")], components: [
        .instructions(sections: [.section(name: "rules", source: "rules")],
          chatGPT: [.prompt(name: "p", sections: [.section(name: "rules", source: "rules")], append: "append.md")])])
      """)
    try ComponentLinker.withLinkedComponents(document: document, store: store, platform: .macOS) {
      graph, session in
      #expect(graph.components.map(\.key.name) == ["rules", "rules"])
      #expect(graph.components[0].snapshot.source == "local:" + source.path)
      #expect(graph.components[1].chatGPT)
      let append = try #require(graph.components[1].resources.last)
      let file = try session.resource(snapshot: append.snapshot, path: append.path)
      #expect(try String(contentsOf: file, encoding: .utf8) == "home append")
      #expect(append.snapshot.source == "local:" + fixture.home.path)
      #expect(append.path == "append.md")
      #expect(graph.components[1].origins[0].dependencies.contains(append.snapshot))
      #expect(graph.components[1].origins[0].provenance.relativePath == "Agents.swift")
    }
  }

  @Test func rootOwnSectionsRequireNamedSourcesAndProducerOwnSectionsRemainValid() throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: .user, environment: fixture.environment)
    for directory in [fixture.project, fixture.home, store.directory] {
      try fixture.instruction("rules", at: directory)
    }
    for section in ["\"rules\"", ".section(name: \"rules\", source: \".\")"] {
      for selection in [
        ".instructions(sections: [\(section)])",
        ".instructions(chatGPT: [.prompt(name: \"p\", sections: [\(section)])])",
      ] {
        do {
          _ = try ComponentLinker.withLinkedComponents(
            document: fixture.document("let agents = Agents(components: [\(selection)])"),
            store: store, platform: .macOS
          ) { _, _ in Issue.record("expected named-source requirement") }
        } catch LinkError.invalid(let message, let spans) {
          #expect(message == "root user instructions require a named source")
          #expect(!spans.isEmpty)
        }
      }
    }
    let producer = fixture.project.appendingPathComponent("producer")
    try fixture.initialize(producer)
    try fixture.instruction("producer", at: producer)
    try fixture.write("producer append shadow", to: "append.md", base: producer)
    try fixture.write("package append shadow", to: "append.md", base: store.directory)
    try fixture.write("home append", to: "append.md", base: fixture.home)
    try fixture.manifest(
      """
      let agents = Agents(defaultAgents: [.claudeCode], exports: ["g"], groups: [
        .group(name: "g", components: [.instructions(sections: ["producer"],
          chatGPT: [.prompt(name: "p", sections: ["producer"], append: "append.md")])])])
      """, at: producer)
    let pin = try fixture.commit(producer)
    try ComponentLinker.withLinkedComponents(
      document: fixture.document(
        "let agents = Agents(sources: [.source(name: \"p\", path: \"producer\")], uses: [.group(name: \"g\", source: \"p\")])"
      ), store: store, platform: .macOS
    ) { graph, session in
      let component = try #require(graph.components.first)
      #expect(component.key.name == "producer")
      #expect(component.snapshot.revision == pin)
      #expect(component.recipients == [.claudeCode])
      #expect(component.origins[0].provenance.sourceIdentity == "local:" + producer.path)
      #expect(component.origins[0].provenance.relativePath == ".agent/Agents.swift")
      #expect(!component.origins[0].consumerEditable)
      let prompt = try #require(graph.components.last)
      #expect(prompt.chatGPT)
      #expect(prompt.snapshot == component.snapshot)
      #expect(prompt.origins[0].provenance == component.origins[0].provenance)
      let append = try #require(prompt.resources.last)
      let file = try session.resource(snapshot: append.snapshot, path: append.path)
      #expect(try String(contentsOf: file, encoding: .utf8) == "home append")
      #expect(append.snapshot.source == "local:" + fixture.home.path)
    }
  }
}
