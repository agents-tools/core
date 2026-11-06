import AgentsCore
import Components
import Foundation
import Testing

@Suite("Component targeting and impact", .serialized)
struct ImpactTests {
  @Test func conditionsNarrowAndNamedHooksCoalesce() throws {
    let fixture = try LinkFixture()
    let graph = try fixture.link(
      """
      let agents = Agents(defaultAgents: [.claudeCode, .codex], components: [
        .hook(name: "format", event: .afterTool, run: .executable("never-run")),
        .hook(name: "format", event: .afterTool, run: .executable("never-run")),
        .hook(name: "format", event: .afterTool, run: .executable("different"), condition: .when(agents: [])),
        .mcpServer(name: "empty", transport: .stdio("never-run"), agents: []),
        .mcpServer(name: "linux", transport: .stdio("never-run"), condition: .when(platforms: [.linux]))])
      """)
    #expect(graph.components.count == 4)
    #expect(graph.components[0].origins.count == 2)
    #expect(graph.components.dropFirst().allSatisfy { $0.recipients.isEmpty })
    #expect(throws: LinkError.self) {
      try fixture.link(
        """
        let agents = Agents(components: [
          .hook(name: "format", event: .afterTool, run: .executable("one")),
          .hook(name: "format", event: .afterTool, run: .executable("two"))])
        """)
    }
  }

  @Test func directSkillAndInstructionPinsRemainIndependent() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("review", at: repository)
    try fixture.instruction("rules", at: repository, own: false)
    let firstPin = try fixture.commit(repository, tag: "1.0.0")
    let expression = """
      let agents = Agents(sources: [.source(name: "s", path: "\(repository.path)")], components: [
        .skills(source: "s", select: ["review"]),
        .instructions(sections: [.section(name: "rules", source: "s")])])
      """
    let before = try fixture.link(expression)
    let sectionKey = try #require(before.components.last?.key)
    try fixture.write(
      "---\ndescription: Changed\n---\n# rules\nChanged\n", to: "instructions/rules.md",
      base: repository)
    try fixture.write(
      "---\nname: review\ndescription: Changed\n---\nChanged\n", to: "skills/review/SKILL.md",
      base: repository)
    let secondPin = try fixture.commit(repository, tag: "1.1.0")
    let after = try fixture.link(
      expression, directPins: [sectionKey: try #require(before.components.last?.pin)])
    #expect(after.components[0].snapshot.revision == secondPin)
    #expect(after.components[1].snapshot.revision == firstPin)
    #expect(after.protectedChanges(from: before, allowing: [.skills]).isEmpty)
    let combined = try fixture.link(expression)
    #expect(combined.protectedChanges(from: before, allowing: [.skills]) == [sectionKey])
  }

  @Test func sharedTransitivePinChangesAreProtected() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("review", at: repository)
    try fixture.manifest(
      """
      let agents = Agents(exports: ["skills", "mcp"], groups: [
        .group(name: "skills", components: [.skills(source: ".", select: ["review"])]),
        .group(name: "mcp", components: [.mcpServer(name: "server", transport: .stdio("never-run"))])])
      """, at: repository)
    let firstPin = try fixture.commit(repository, tag: "1.0.0")
    let expression = """
      let agents = Agents(sources: [.source(name: "s", path: "\(repository.path)")], uses: [
        .group(name: "skills", source: "s"), .group(name: "mcp", source: "s")])
      """
    let before = try fixture.link(expression)
    try fixture.write("change", to: "unrelated.txt", base: repository)
    try fixture.commit(repository, tag: "1.1.0")
    let after = try fixture.link(expression)
    #expect(after.protectedChanges(from: before, allowing: [.skills]).map(\.name) == ["server"])
    #expect(
      before.protectedPins(allowing: [.skills])["local:" + repository.path]?.revision == firstPin)
    let preserved = try fixture.link(
      expression, preserving: before.protectedPins(allowing: [.skills]))
    #expect(preserved.protectedChanges(from: before, allowing: [.skills]).isEmpty)
    #expect(throws: LinkError.self) { try after.requireEditable(after.components[0].key) }
  }

  @Test func chatGPTUsesScopeAndPlatformProjection() throws {
    let fixture = try LinkFixture()
    try fixture.instruction(
      "rules", at: fixture.project,
      restrictions: "agents: []\nscopes: [\"project\"]\nplatforms: [\"macos\"]\n")
    let graph = try fixture.link(
      """
      let agents = Agents(components: [.instructions(sections: ["rules"], chatGPT: [.prompt(name: "p", sections: ["rules"])])])
      """)
    #expect(graph.components[0].recipients.isEmpty)
    #expect(!graph.components[0].chatGPT)
    #expect(graph.components[1].chatGPT)
  }
}

extension ImpactTests {
  @Test func identicalNamedHooksUnionRecipientsAndKeepRestrictionOrigins() throws {
    let fixture = try LinkFixture()
    let graph = try fixture.link(
      """
      let agents = Agents(components: [
        .hook(name: "format", event: .afterTool, run: .executable("never-run"), condition: .when(agents: [.codex])),
        .hook(name: "format", event: .afterTool, run: .executable("never-run"), condition: .when(agents: [.claudeCode]))])
      """)
    #expect(graph.components.count == 1)
    #expect(graph.components[0].recipients == [.codex, .claudeCode])
    try #require(graph.components[0].origins.count == 2)
    #expect(graph.components[0].origins[0].recipients == [.codex])
    #expect(graph.components[0].origins[1].recipients == [.claudeCode])
  }
}

extension ImpactTests {
  @Test func resourceAliasSpellingDoesNotChangeProtectedContent() throws {
    let fixture = try LinkFixture()
    let source = fixture.root.appendingPathComponent("source")
    try fixture.write("Review", to: "review.md", base: source)
    func expression(_ alias: String) -> String {
      "let agents = Agents(sources: [.source(name: \"\(alias)\", path: \"\(source.path)\")], components: [.command(name: \"review\", description: \"Review\", prompt: .file(\"review.md\", source: \"\(alias)\"))])"
    }
    let before = try fixture.link(expression("old"))
    let after = try fixture.link(expression("renamed"))
    #expect(after.protectedChanges(from: before, allowing: [.skills]).isEmpty)
  }
}
