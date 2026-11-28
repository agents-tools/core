import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Complete symbolic declarations")
struct FullDeclarationTests {
  @Test(arguments: [0, 101])
  func renamingSourceAtSameIdentityRetargetsAllReferences(_ referenceCount: Int) throws {
    let references = (0..<referenceCount).map {
      #"  - {kind: subagent, name: "agent\#($0)", description: d, prompt: {file: {path: x.md, source: s}}}"#
    }.joined(separator: "\n")
    let body = """
      # Keep the header.
      version: 1
      sources: {s: {path: ./missing}}
      components:
        # Keep this unrelated component.
        - {kind: ignore, name: keep, patterns: ["private/**"]}
      \(references)
      # Keep the tail.
      """
    let target = body.replacingOccurrences(of: "sources: {s:", with: "sources: {t:")
      .replacingOccurrences(of: "source: s", with: "source: t")
    let previous = try projected(body)
    let next = try projected(target)
    try previous.validate(environment: projectionEnvironment)
    try next.validate(environment: projectionEnvironment)
    #expect(next.components.count == referenceCount + 1)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.hasPrefix(manifestHeader + "# Keep the header.\n"))
    #expect(output.hasSuffix("\n# Keep the tail."))
    #expect(
      output.contains(
        "# Keep this unrelated component.\n  - {kind: ignore, name: keep, patterns: [\"private/**\"]}"
      ))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      document.declaration
        == YAMLConstruction.root(next))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(try planned(result, next, in: output) == nil)
  }

  @Test func changingLocalEditSourceToGitCopyKeepsCompleteIntent() throws {
    let body = """
      # Keep the header.
      version: 1
      sources: {s: {path: missing}}
      components:
        - {kind: skills, source: s, mode: edit}
        # Keep this unrelated component.
        - {kind: ignore, name: keep, patterns: ["private/**"]}
      # Keep the tail.
      """
    let target = body.replacingOccurrences(
      of: "path: missing", with: "url: https://example.invalid/repo.git"
    )
    .replacingOccurrences(of: "mode: edit", with: "mode: copy")
    let previous = try projected(body)
    let next = try projected(target)
    try previous.validate(environment: projectionEnvironment)
    try next.validate(environment: projectionEnvironment)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.hasPrefix(manifestHeader + "# Keep the header.\n"))
    #expect(output.hasSuffix("\n# Keep the tail."))
    #expect(
      output.contains(
        "# Keep this unrelated component.\n  - {kind: ignore, name: keep, patterns: [\"private/**\"]}"
      ))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      document.declaration
        == YAMLConstruction.root(next))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(try planned(result, next, in: output) == nil)
  }

  @Test func publicEditRejectsGitSourceWithExistingEditMode() throws {
    let doc = try document(
      """
      version: 1
      sources: {"s": {"path": "missing"}}
      components: [{"kind": "skills", "source": "s", "mode": "edit"}, {"kind": "ignore", "name": "keep", "patterns": []}]
      """)
    expectManifestFailure("manifest.domain") {
      try doc.preparing([
        .upsertSource(
          NamedSourceDeclaration(
            name: "s",
            source: SourceDeclaration(kind: .git, location: "https://example.invalid/repo.git")))
      ]
      )
    }
  }

  @Test func removingReferencedSourceAcrossBatchesProducesEmptyDeclaration() throws {
    let components = (0..<100).map {
      #"  - {kind: subagent, name: "agent\#($0)", description: d, prompt: {file: {path: x.md, source: s}}}"#
    }.joined(separator: "\n")
    let body = """
      version: 1
      sources: {"s": {"path": "missing"}}
      components:
      \(components)
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
      # Keep this header.
      version: 1
      components:
        - kind: instructions
          chatgpt:
            # Prompt a.
            a: {sections: [{name: first}]}
            # Prompt b.
            b: {sections: [{name: second}]}
      # Keep this tail.
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
    let expected = """
      # Keep this header.
      version: 1
      components:
        - kind: instructions
          chatgpt:
            # Prompt b.
            b: {sections: [{name: second}]}
            # Prompt a.
            a: {sections: [{name: first}]}
      # Keep this tail.
      """
    #expect(output == manifestHeader + expected)
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result.components == next.components)
    #expect(try planned(result, next, in: output) == nil)
  }

  @Test func equivalentSourceSpellingSurvivesFullComponentEdit() throws {
    let body = """
      version: 1
      sources:
        s:
          # keep source comment
          path: ./s
      components: [{kind: ignore, name: i, patterns: [old]}]
      """
    let previous = try projected(body)
    var next = previous
    next.sources["s"]?.location =
      projectionEnvironment.projectDirectory.appendingPathComponent("s").path
    next.components[0] = .ignore(name: "i", patterns: ["new"])
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.contains("s:\n    # keep source comment\n    path: ./s"))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result.components == next.components)
    #expect(ManifestProjection.equivalent(result, next, environment: projectionEnvironment))
  }

  @Test func projectionAndConstructionKeepDeclarationOrder() throws {
    let body = """
      version: 1
      exports: ["b", "a"]
      sources: {"web": {"url": "https://example.test/repo.git"}, "git": {"path": "missing"}}
      components: [{"kind": "ignore", "name": "b", "patterns": []}, {"kind": "ignore", "name": "a", "patterns": []}]
      groups: {"b": {}, "a": {}}
      uses: [{"group": "b"}, {"group": "a"}]
      watch: ["web", "git"]
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
      YAMLConstruction.root(declaration)
        == doc.declaration)
  }

  @Test func conditionsRecipientsAndPluginSelectionsKeepInheritanceAndExplicitEmpty() throws {
    let declaration = try projected(
      """
      version: 1
      defaultAgents: []
      sources: {"s": {"path": "missing"}}
      components: [{"kind": "subagent", "name": "inherited", "description": "d", "prompt": "p"}, {"kind": "subagent", "name": "empty", "description": "d", "prompt": "p", "tools": [], "agents": [], "condition": {"agents": [], "scopes": [], "platforms": []}}, {"kind": "plugin", "name": "all", "path": "plugins/p", "source": "s"}, {"kind": "plugin", "name": "none", "path": "plugins/p", "source": "s", "select": []}]
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
        "{\"kind\": \"skills\", \"source\": \"s\", \"select\": [\"a\", \"c\"], \"condition\": {\"scopes\": []}}",
        .skills(
          source: "s",
          SkillDeclaration(select: .names(["a", "b"]), condition: DeclarationCondition(scopes: [])))
      ),
      (
        #"""
        {kind: skills, source: s, select: [
          "a",
          "b",
          # keep member
          "c",
        ], condition: {scopes: []}}
        """#,
        .skills(
          source: "s",
          SkillDeclaration(select: .names(["c", "a"]), condition: DeclarationCondition(scopes: [])))
      ),
      (
        "{\"kind\": \"instructions\", \"sections\": [{\"name\": \"a\", \"condition\": {\"agents\": []}}]}",
        .instructions(instructions)
      ),
      (
        "{\"kind\": \"mcpServer\", \"name\": \"m\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"unused\"}}",
        .mcpServer(
          name: "m",
          transport: .streamableHTTP(
            url: "https://does-not-exist.invalid/mcp",
            headers: ["Authorization": .environment("TOKEN")]))
      ),
      (
        "{\"kind\": \"hook\", \"name\": \"h\", \"event\": \"afterTool\", \"run\": {\"executable\": \"unused\"}}",
        .hook(
          name: "h", event: .afterTool, run: ExecutableDeclaration(executable: "unused"),
          timeoutSeconds: 5)
      ),
      (
        "{\"kind\": \"subagent\", \"name\": \"a\", \"description\": \"d\", \"prompt\": \"p\"}",
        .subagent(name: "a", description: "d", prompt: .literal("p"), tools: [])
      ),
      (
        "{\"kind\": \"command\", \"name\": \"c\", \"description\": \"d\", \"prompt\": \"p\", \"parameters\": [{\"name\": \"x\", \"description\": \"d\", \"defaultValue\": \"old\"}]}",
        .command(
          name: "c", description: "d", prompt: .literal("p"),
          parameters: [PromptParameterDeclaration(name: "x", description: "d", defaultValue: "new")]
        )
      ),
      (
        "{\"kind\": \"lspServer\", \"name\": \"l\", \"run\": {\"executable\": \"unused\"}, \"languages\": {\".swift\": \"swift\"}, \"initializationOptions\": {\"enabled\": true}}",
        .lspServer(
          name: "l", run: ExecutableDeclaration(executable: "unused"),
          languages: [".swift": "swift"],
          initializationOptions: ["enabled": .boolean(false), "number": .decimal("1.25")])
      ),
      (
        "{\"kind\": \"permissions\", \"name\": \"p\", \"rules\": [{\"effect\": \"allow\", \"operation\": \"read\", \"pattern\": \"a/**\"}]}",
        .permissions(name: "p", rules: [.ask(.tool("lookup"), "*"), .deny(.write, "private/**")])
      ),
      (
        "{\"kind\": \"ignore\", \"name\": \"i\", \"patterns\": [\"a\"]}",
        .ignore(name: "i", patterns: ["a"], purpose: .indexing)
      ),
      (
        "{\"kind\": \"plugin\", \"name\": \"p\", \"path\": \"plugins/p\", \"source\": \"s\"}",
        .plugin(
          name: "p", path: "plugins/p", source: "s", select: [],
          exclude: [.command(name: "obsolete")])
      ),
    ]
    for (component, intended) in cases {
      let body =
        "version: 1\nsources: {s: {path: missing}}\ncomponents: [" + component + "]\n"
      let previous = try projected(body)
      var next = previous
      next.components[0] = intended
      let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
      let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
      #expect(
        actual.declaration
          == YAMLConstruction.root(next),
        "\(intended.kind)")
      if component.contains("# keep member") {
        #expect(String(decoding: bytes, as: UTF8.self).contains("# keep member"))
      }
    }
  }

  @Test func instructionRecipientsRoundTripThroughTypedEdits() throws {
    let body = """
      version: 1
      sources: {team/rules: {path: ./missing}}
      components:
        - kind: instructions
          sections:
            - {name: nested/review, source: team/rules}
            - {name: own, recipients: []}
      """
    let previous = try projected(body)
    var next = previous
    var instructions = try #require(try previous.instructions)
    #expect(instructions.sectionReferences.map(\.recipients) == [nil, []])
    instructions.sectionReferences[0].recipients = [.local(.codex), .chatGPTApp, .geminiApp]
    next.components = [.instructions(instructions)]
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      try ManifestProjection.declaration(of: actual, environment: projectionEnvironment) == next)

    let recipients = try #require(instructions.sectionReferences[0].recipients)
    let encoded = try JSONEncoder().encode(recipients)
    #expect(String(decoding: encoded, as: UTF8.self) == #"["codex","chatgpt-app","gemini-app"]"#)
    #expect(try JSONDecoder().decode([InstructionRecipient].self, from: encoded) == recipients)
    #expect(AgentID.allCases.count == 6)
  }

  @Test(arguments: ["[codex, codex]", "[gemini]", "[chatGPTApp]", "[7]"])
  func rejectsInvalidInstructionRecipients(_ recipients: String) {
    let yaml = """
      version: 1
      components:
        - kind: instructions
          sections:
            - name: rules
              recipients: \(recipients)
      """
    #expect(throws: ManifestFailure.self) { try document(yaml) }
  }

  @Test func sourceAliasesRetainTheirDeclaringDirectories() throws {
    let declaration = try projected(
      "version: 1\nsources: {\"s\": {\"path\": \"~/rules\"}}\n")
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
      version: 1
      sources: {"s": {"path": "missing"}}
      components: [{"kind": "skills", "source": "s", "condition": {"scopes": ["project"]}}, {"kind": "skills", "source": "s", "condition": {"scopes": ["user"]}}, {"kind": "skills", "source": "s", "condition": {"platforms": []}}]
      """
    let doc = try document(body)
    var declaration = try ManifestProjection.declaration(
      of: doc, environment: projectionEnvironment)
    #expect(declaration.components.count == 3)
    #expect(throws: CoreError.self) { try declaration.skills }
    #expect(throws: CoreError.self) { try declaration.setSkills(nil) }
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
      version: 1
      components: [{"kind": "mcpServer", "name": "tools", "transport": {"kind": "stdio", "executable": "never-start-this", "arguments": ["serve"]}}]
      groups: {"unused": {"components": [{"kind": "ignore", "name": "i", "patterns": ["keep"], "condition": {"platforms": []}}]}}
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
      version: 1
      sources: {"s": {"path": "unavailable"}}
      groups: {"local": {"components": [{"kind": "ignore", "name": "i", "patterns": []}]}}
      uses: [{"group": "local"}, {"source": "s", "condition": {"agents": []}, "group": "remote"}, {"group": "local"}]
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
      version: 1
      sources: {"a": {"path": "missing-a"}, "b": {"path": "missing-b"}}
      groups: {"local": {}}
      uses: [{"source": "a", "condition": {"agents": []}, "group": "review"}, {"source": "b", "condition": {"platforms": []}, "group": "review"}]
      """
    let previous = try projected(body)
    var next = previous
    next.uses.insert(GroupUseDeclaration(name: "local"), at: 1)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      actual.declaration
        == YAMLConstruction.root(next))
  }

  @Test func reorderingFullCollectionsCarriesOwnedComments() throws {
    let body = """
      version: 1
      sources:
        # Source a.
        a: {path: missing-a}
        # Source b.
        b: {path: missing-b}
      components:
        # Server a.
        - {kind: mcpServer, name: a, transport: {kind: stdio, executable: unused-a}}
        # Server b.
        - {kind: mcpServer, name: b, transport: {kind: stdio, executable: unused-b}}
      groups: {a: {}, b: {}}
      uses: [{group: a}, {group: b}]
      """
    let previous = try projected(body)
    var next = previous
    next.sourceDeclarations.reverse()
    next.components.reverse()
    next.groups.reverse()
    next.uses.reverse()
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.contains("# Source a.\n  a: {path: missing-a}"))
    #expect(output.contains("# Source b.\n  b: {path: missing-b}"))
    #expect(
      output.contains(
        "# Server a.\n  - {kind: mcpServer, name: a, transport: {kind: stdio, executable: unused-a}}"
      ))
    #expect(
      output.contains(
        "# Server b.\n  - {kind: mcpServer, name: b, transport: {kind: stdio, executable: unused-b}}"
      ))
    let actual = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      actual.declaration
        == YAMLConstruction.root(next))
  }

  @Test func fullBaselineAndFinalGuardsIncludeUnusedStructures() throws {
    let body =
      "version: 1\ngroups: {\"g\": {\"components\": [{\"kind\": \"ignore\", \"name\": \"i\", \"patterns\": [\"old\"]}]}}\n"
    let previous = try projected(body)
    var stale = previous
    stale.groups = []
    expectManifestFailure("manifest.edit.baseline") {
      try planned(stale, stale, in: manifestHeader + body)
    }
    var next = previous
    next.groups[0].components[0] = .ignore(name: "i", patterns: ["new"])
    expectManifestFailure("manifest.edit.mismatch") {
      try DeclarationEditPlan.compose(
        [], original: document(body), intended: IRTree.root(YAMLConstruction.root(next)),
        next: next, environment: projectionEnvironment)
    }
  }

  @Test func sharedAliasesCannotChangeUnusedGroupIntent() {
    #expect(throws: ManifestFailure.self) {
      try document("version: 1\ncomponents: &shared []\ngroups: {unused: {components: *shared}}\n")
    }
  }

  @Test func readingAndConstructingNeverReadsSourcesResourcesOrRunsPrograms() throws {
    let declaration = try projected(
      """
      version: 1
      sources: {"remote": {"url": "https://does-not-exist.invalid/repo.git"}}
      components: [{"kind": "mcpServer", "name": "tools", "transport": {"kind": "stdio", "executable": "program-does-not-exist", "environment": {"KEY": {"secret": "unbound"}}}}, {"kind": "hook", "name": "run", "event": "sessionStart", "run": {"executable": "program-does-not-exist"}}, {"kind": "subagent", "name": "agent", "description": "d", "prompt": {"file": {"path": "missing.md", "source": "remote"}}}]
      """)
    let bytes = try #require(try planned(Declaration(), declaration, in: nil))
    #expect(
      try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")).declaration
        .components.count == 3)
    #expect(
      try planned(declaration, declaration, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }
}
