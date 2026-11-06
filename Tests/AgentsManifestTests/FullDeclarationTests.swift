import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Complete symbolic declarations")
struct FullDeclarationTests {
  @Test func removingReferencedSourceAcrossBatchesProducesEmptyDeclaration() throws {
    let components = (0..<100).map {
      #"    .subagent(name: "agent\#($0)", description: "d", prompt: .file("x.md", source: "s")),"#
    }.joined(separator: "\n")
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "missing")], components: [
      \(components)
      ])
      """
    let previous = try projected(body)
    #expect(previous.components.count == 100)
    var next = previous
    next.components = []
    next.sourceDeclarations = []
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result == next)
  }

  @Test func reorderingPromptsMovesTheirCommentsAndRepeatsAsNoOp() throws {
    let body = """
      // Keep this header.
      let agents = Agents(components: [
        .instructions(chatGPT: [
          // Prompt a.
          .prompt(name: "a", sections: ["first"]),
          // Prompt b.
          .prompt(name: "b", sections: ["second"]),
        ]),
      ])
      // Keep this tail.
      """
    let previous = try projected(body)
    var next = previous
    guard case .instructions(var instructions) = next.components[0] else {
      Issue.record("expected instructions")
      return
    }
    instructions.prompts.reverse()
    next.components[0] = .instructions(instructions)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    let expected = body.replacingOccurrences(
      of: """
            // Prompt a.
            .prompt(name: "a", sections: ["first"]),
            // Prompt b.
            .prompt(name: "b", sections: ["second"]),
        """,
      with: """
            // Prompt b.
            .prompt(name: "b", sections: ["second"]),
            // Prompt a.
            .prompt(name: "a", sections: ["first"]),
        """)
    #expect(output == manifestHeader + expected)
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result.components == next.components)
    #expect(try planned(result, next, in: output) == nil)
  }

  @Test func equivalentSourceSpellingSurvivesFullComponentEdit() throws {
    let body = """
      let agents = Agents(
        sources: [.source(name: "s", /* keep source comment */ path: "./s")],
        components: [.ignore(name: "i", patterns: ["old"]) ]
      )
      """
    let previous = try projected(body)
    var next = previous
    next.sources["s"]?.location =
      projectionEnvironment.projectDirectory.appendingPathComponent("s").path
    next.components[0] = .ignore(name: "i", patterns: ["new"])
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.contains(#".source(name: "s", /* keep source comment */ path: "./s")"#))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result.components == next.components)
    #expect(ManifestProjection.equivalent(result, next, environment: projectionEnvironment))
  }

  @Test func projectionAndConstructionKeepDeclarationOrder() throws {
    let body = """
      let agents = Agents(
        exports: ["b", "a"],
        sources: [.source(name: "web", url: "https://example.test/repo.git"), .source(name: "git", path: "missing")],
        components: [.ignore(name: "b", patterns: []), .ignore(name: "a", patterns: [])],
        groups: [.group(name: "b"), .group(name: "a")],
        uses: ["b", "a"], watch: ["web", "git"]
      )
      """
    let doc = try document(body)
    let declaration = try ManifestProjection.declaration(
      of: doc, environment: projectionEnvironment)
    #expect(declaration.watch == ["web", "git"])
    #expect(
      declaration.components == [
        .ignore(name: "b", patterns: []), .ignore(name: "a", patterns: []),
      ])
    #expect(declaration.groups.map(\.name) == ["b", "a"])
    #expect(declaration.uses.map(\.name) == ["b", "a"])
    #expect(declaration.exports == ["b", "a"])
    #expect(
      Lowering.declaration(try DeclarationConstruction.root(declaration).constructionValue)
        == doc.declaration)
  }

  @Test func conditionsRecipientsAndPluginSelectionsKeepInheritanceAndExplicitEmpty() throws {
    let declaration = try projected(
      """
      let agents = Agents(defaultAgents: [], sources: [.source(name: "s", path: "missing")], components: [
        .subagent(name: "inherited", description: "d", prompt: "p"),
        .subagent(name: "empty", description: "d", prompt: "p", tools: [], agents: [], condition: .when(agents: [], scopes: [], platforms: [])),
        .plugin(name: "all", path: "plugins/p", source: "s"),
        .plugin(name: "none", path: "plugins/p", source: "s", select: []),
      ])
      """)
    #expect(declaration.agents == [])
    guard
      case .subagent(
        _, _, _, _, let inheritedTools, let inheritedAgents, let inheritedCondition, _) =
        declaration.components[0],
      case .subagent(_, _, _, _, let emptyTools, let emptyAgents, let emptyCondition, _) =
        declaration.components[1],
      case .plugin(_, _, _, _, let all, _, _, _, _) = declaration.components[2],
      case .plugin(_, _, _, _, let none, _, _, _, _) = declaration.components[3]
    else {
      Issue.record("unexpected component payload")
      return
    }
    #expect(inheritedTools == nil && inheritedAgents == nil && inheritedCondition == nil)
    #expect(emptyTools == [] && emptyAgents == [])
    #expect(emptyCondition == DeclarationCondition(agents: [], scopes: [], platforms: []))
    #expect(all == nil && none == [])
  }

  @Test func everyComponentFamilyCanBeEditedAsTypedIntent() throws {
    var instructions = InstructionsDeclaration()
    instructions.sectionReferences = [
      SectionDeclaration(name: "a", condition: DeclarationCondition(agents: [])),
      SectionDeclaration(name: "b"),
    ]
    let cases: [(String, ComponentDeclaration)] = [
      (
        #".skills(source: "s", select: ["a" /* keep member */, "c"], condition: .when(scopes: []))"#,
        .skills(
          source: "s",
          SkillDeclaration(select: .names(["a", "b"]), condition: DeclarationCondition(scopes: [])))
      ),
      (
        #"""
        .skills(source: "s", select: [
          "a",
          "b",
          /* keep member */
          "c",
        ], condition: .when(scopes: []))
        """#,
        .skills(
          source: "s",
          SkillDeclaration(select: .names(["c", "a"]), condition: DeclarationCondition(scopes: [])))
      ),
      (
        #".instructions(sections: [.section(name: "a", condition: .when(agents: []))])"#,
        .instructions(instructions)
      ),
      (
        #".mcpServer(name: "m", transport: .stdio("unused"))"#,
        .mcpServer(
          name: "m",
          transport: .streamableHTTP(
            url: "https://does-not-exist.invalid/mcp",
            headers: ["Authorization": .environment("TOKEN")]))
      ),
      (
        #".hook(name: "h", event: .afterTool, run: .executable("unused"))"#,
        .hook(
          name: "h", event: .afterTool, run: ExecutableDeclaration(executable: "unused"),
          timeoutSeconds: 5)
      ),
      (
        #".subagent(name: "a", description: "d", prompt: "p")"#,
        .subagent(name: "a", description: "d", prompt: .literal("p"), tools: [])
      ),
      (
        #".command(name: "c", description: "d", prompt: "p", parameters: [.parameter(name: "x", description: "d", defaultValue: "old")])"#,
        .command(
          name: "c", description: "d", prompt: .literal("p"),
          parameters: [PromptParameterDeclaration(name: "x", description: "d", defaultValue: "new")]
        )
      ),
      (
        #".lspServer(name: "l", run: .executable("unused"), languages: [".swift": "swift"], initializationOptions: ["enabled": true])"#,
        .lspServer(
          name: "l", run: ExecutableDeclaration(executable: "unused"),
          languages: [".swift": "swift"],
          initializationOptions: ["enabled": .boolean(false), "number": .decimal("1.25")])
      ),
      (
        #".permissions(name: "p", rules: [.allow(.read, "a/**")])"#,
        .permissions(name: "p", rules: [.ask(.tool("lookup"), "*"), .deny(.write, "private/**")])
      ),
      (
        #".ignore(name: "i", patterns: ["a"])"#,
        .ignore(name: "i", patterns: ["a"], purpose: .indexing)
      ),
      (
        #".plugin(name: "p", path: "plugins/p", source: "s")"#,
        .plugin(
          name: "p", path: "plugins/p", source: "s", select: [],
          exclude: [.command(name: "obsolete")])
      ),
    ]
    for (component, intended) in cases {
      let body =
        #"let agents = Agents(sources: [.source(name: "s", path: "missing")], components: ["#
        + component + "] )"
      let previous = try projected(body)
      var next = previous
      next.components[0] = intended
      let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
      let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
      #expect(
        actual.declaration
          == Lowering.declaration(try DeclarationConstruction.root(next).constructionValue),
        "\(intended.kind)")
      if intended.kind == .skills {
        #expect(String(decoding: bytes, as: UTF8.self).contains("/* keep member */"))
      }
    }
  }

  @Test func sourceAliasesRetainTheirDeclaringDirectories() throws {
    let declaration = try projected(
      "let agents = Agents(sources: [.source(name: \"s\", path: \"~/rules\")])")
    let source = try #require(declaration.sources["s"])
    let importing = RuntimeEnvironment(
      projectDirectory: URL(fileURLWithPath: "/importer"),
      homeDirectory: URL(fileURLWithPath: "/other-home"), environment: [:])
    #expect(
      source.environment
        == SourceEnvironment(
          projectDirectory: projectionEnvironment.projectDirectory,
          homeDirectory: projectionEnvironment.homeDirectory))
    #expect(try source.identity(environment: importing) == "local:/work/home/rules")
  }

  @Test func repeatedOccurrencesRequireAnExplicitOccurrence() throws {
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "missing")], components: [
        .skills(source: "s", condition: .when(scopes: [.project])),
        .skills(source: "s", condition: .when(scopes: [.user])),
        .skills(source: "s", condition: .when(platforms: [])),
      ])
      """
    let doc = try document(body)
    var declaration = try ManifestProjection.declaration(
      of: doc, environment: projectionEnvironment)
    #expect(declaration.components.count == 3)
    #expect(throws: CoreError.self) { try declaration.skills }
    #expect(throws: CoreError.self) { try declaration.setSkills(nil) }
    do {
      try doc.requireDeploymentSubset()
      Issue.record("ambiguous deployment selection accepted")
    } catch let failure as ManifestFailure {
      #expect(failure.diagnostics.map(\.code) == ["manifest.ambiguous"])
      #expect(failure.diagnostics.first?.related.count == 2)
    }
    guard case .skills(let source, var selection) = declaration.components[1] else { return }
    selection.agents = []
    declaration.components[1] = .skills(source: source, selection)
    let bytes = try #require(
      try planned(try projected(body), declaration, in: manifestHeader + body))
    let result = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(result.declaration.components[0] == doc.declaration.components[0])
    #expect(result.declaration.components[1]["agents"] == .array([]))
    #expect(result.declaration.components[2] == doc.declaration.components[2])
  }

  @Test func fullEditsPreserveUnusedGroupsConditionsAndUnchangedBytes() throws {
    let body = """
      // Header stays verbatim.
      let agents = Agents(
        components: [
          .mcpServer(name: "tools", transport: .stdio("never-start-this", arguments: ["serve"])), // server
        ],
        groups: [
          // This group is unused and must survive.
          .group(name: "unused", components: [.ignore(name: "i", patterns: ["keep"], condition: .when(platforms: []))]),
        ]
      )
      // Tail stays verbatim.
      """
    let previous = try projected(body)
    var next = previous
    next.components[0] = .mcpServer(
      name: "tools",
      transport: .stdio(
        ExecutableDeclaration(executable: "never-start-this", arguments: ["inspect"])))
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(
      output == manifestHeader + body.replacingOccurrences(of: "[\"serve\"]", with: "[\"inspect\"]")
    )
    #expect(try projected(String(output.dropFirst(manifestHeader.count))).groups == previous.groups)
  }

  @Test func groupUsesStaySymbolicAndOrderedDuringEdits() throws {
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "unavailable")], groups: [
        .group(name: "local", components: [.ignore(name: "i", patterns: [])]),
      ], uses: ["local", .group(name: "remote", source: "s", condition: .when(agents: [])), "local"])
      """
    let previous = try projected(body)
    var next = previous
    next.uses[1].condition = DeclarationCondition(scopes: [])
    next.exports = ["local"]
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(result.uses == next.uses)
    #expect(result.components.isEmpty)
    #expect(result.groups == previous.groups)
    #expect(result.exports == ["local"])
  }

  @Test func groupReferencesWithDifferentSourceAliasesRemainDistinct() throws {
    let body = """
      let agents = Agents(sources: [.source(name: "a", path: "missing-a"), .source(name: "b", path: "missing-b")],
        groups: [.group(name: "local")], uses: [
          .group(name: "review", source: "a", condition: .when(agents: [])),
          .group(name: "review", source: "b", condition: .when(platforms: [])),
        ])
      """
    let previous = try projected(body)
    var next = previous
    next.uses.insert(GroupUseDeclaration(name: "local"), at: 1)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      actual.declaration
        == Lowering.declaration(try DeclarationConstruction.root(next).constructionValue))
  }

  @Test func reorderingFullCollectionsCarriesOwnedComments() throws {
    let body = """
      let agents = Agents(
        sources: [
          // Source a.
          .source(name: "a", path: "missing-a"),
          // Source b.
          .source(name: "b", path: "missing-b"),
        ],
        components: [
          // Server a.
          .mcpServer(name: "a", transport: .stdio("unused-a")),
          // Server b.
          .mcpServer(name: "b", transport: .stdio("unused-b")),
        ],
        groups: [.group(name: "a"), .group(name: "b")],
        uses: ["a", "b"]
      )
      """
    let previous = try projected(body)
    var next = previous
    next.sourceDeclarations.reverse()
    next.components.reverse()
    next.groups.reverse()
    next.uses.reverse()
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.contains("// Source a.\n    .source(name: \"a\", path: \"missing-a\")"))
    #expect(output.contains("// Source b.\n    .source(name: \"b\", path: \"missing-b\")"))
    #expect(
      output.contains("// Server a.\n    .mcpServer(name: \"a\", transport: .stdio(\"unused-a\"))"))
    #expect(
      output.contains("// Server b.\n    .mcpServer(name: \"b\", transport: .stdio(\"unused-b\"))"))
    let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      actual.declaration
        == Lowering.declaration(try DeclarationConstruction.root(next).constructionValue))
  }

  @Test func fullBaselineAndFinalGuardsIncludeUnusedStructures() throws {
    let body =
      "let agents = Agents(groups: [.group(name: \"g\", components: [.ignore(name: \"i\", patterns: [\"old\"])])])"
    let previous = try projected(body)
    var stale = previous
    stale.groups = []
    expectManifestFailure("manifest.edit.baseline") {
      try planned(stale, stale, in: manifestHeader + body)
    }
    var next = previous
    next.groups[0].components[0] = .ignore(name: "i", patterns: ["new"])
    expectManifestFailure("manifest.edit.mismatch") {
      try DeclarationEditPlan.bytes(
        replacing: previous, with: next, in: Array((manifestHeader + body).utf8),
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: { _ in [] })
    }
  }

  @Test func sharedConstantChangesAccountForUnusedGroupImpact() throws {
    let doc = try document(
      """
      let recipients: [Agent] = [.codex]
      let agents = Agents(components: [.instructions(agents: recipients)], groups: [
        .group(name: "unused", components: [.ignore(name: "i", patterns: [], agents: recipients)]),
      ])
      """)
    let constant = try #require(doc.constant(named: "recipients"))
    let uses = doc.uses(ofConstant: "recipients")
    #expect(uses.count == 2)
    expectManifestFailure("manifest.edit.impact") {
      try doc.preparing([
        .replaceConstant(constant, with: .array([]), acceptingUses: Array(uses.prefix(1)))
      ])
    }
    let change = try doc.preparing([
      .replaceConstant(constant, with: .array([]), acceptingUses: uses)
    ])
    let typed = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: change.bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect((try typed.instructions)?.agents == [])
    #expect(
      change.expectedDeclaration.groups[0]["components"]?.elements?[0].record?["agents"]
        == .array([]))
    #expect(typed.groups.count == 1 && typed.components.count == 1)
  }

  @Test func readingAndConstructingNeverReadsSourcesResourcesOrRunsPrograms() throws {
    let declaration = try projected(
      """
      let agents = Agents(sources: [.source(name: "remote", url: "https://does-not-exist.invalid/repo.git")], components: [
        .mcpServer(name: "tools", transport: .stdio("program-does-not-exist", environment: ["KEY": .secret("unbound")])),
        .hook(name: "run", event: .sessionStart, run: .executable("program-does-not-exist")),
        .subagent(name: "agent", description: "d", prompt: .file("missing.md", source: "remote")),
      ])
      """)
    let bytes = try #require(try planned(Declaration(), declaration, in: nil))
    #expect(
      try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")).declaration
        .components.count == 3)
    #expect(
      try planned(declaration, declaration, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }
}
