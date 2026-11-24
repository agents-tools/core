import AgentsManifest
import Foundation
import NativeDocuments
import Testing

@testable import AgentsCore
@testable import Components

@Suite("Frozen generated native plugins")
struct GeneratedPluginTests {
  private var platform: DeclarationPlatform {
    #if os(macOS)
      .macOS
    #else
      .linux
    #endif
  }

  private func freeze(
    _ fixture: LinkFixture, _ expression: String, scope: InstallScope = .project
  ) throws -> ([LinkedComponent], LedgerFreeze.Result) {
    let store = StateStore(scope: scope, environment: fixture.environment)
    return try ComponentLinker.withLinkedComponents(
      document: fixture.document(expression), store: store, platform: platform
    ) { graph, session in
      let locations = Dictionary(
        (graph.sourceSnapshots + graph.declaringSnapshots).filter {
          $0.source?.kind == .local && $0.container == nil
        }.map {
          (
            $0.snapshot.source,
            LedgerLocation(kind: .absolute, path: String($0.snapshot.source.dropFirst(6)))
          )
        }, uniquingKeysWith: { first, _ in first })
      return (
        graph.components,
        try LedgerFreeze.freezeWithSources(
          graph, session: session, locations: .init(sources: locations), limits: .standard)
      )
    }
  }

  private func budget() -> NativeDocumentBudget {
    .init(
      limits: .init(
        storage: 32_000_000, work: 100_000_000, nodes: 100_000, depth: 128,
        uninterruptedBytes: 1_000_000))
  }

  private func lower(
    _ components: [LinkedComponent], _ frozen: LedgerFreeze.Result,
    surface: NativeClientSurface = .claudeCode, scope: InstallScope = .project
  ) throws -> LockedLowering {
    try NativeGeneratedPluginLayoutV1.lower(
      components.first { $0.key.kind == .plugin }!, members: components, frozen: frozen,
      request: .init(surface: surface, scope: scope), id: "generated", platform: platform)
  }

  @Test func frozenClosureColdReplayPreservesOrderBindingsResourcesAndRegistration() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"source-name","mcpServers":{"server":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/server","env":{"TOKEN":"private-source-canary"}}},"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"first"}]},{"matcher":"Write","hooks":[{"type":"command","command":"second"}]}]}}"#,
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    try fixture.write(
      "---\ndescription: Review exactly\n---\nLiteral source body\n",
      to: "bundle/commands/review.md", base: fixture.project)
    try fixture.write(
      "---\nname: inspect\ndescription: Inspect\n---\nInspect exact sources\n",
      to: "bundle/agents/inspect.md", base: fixture.project)
    try fixture.write(
      "---\nname: helper\ndescription: Help\n---\nSkill body\n",
      to: "bundle/skills/helper/SKILL.md", base: fixture.project)
    try fixture.write(
      "#!/bin/sh\n# source-owned, never executed\n", to: "bundle/bin/server", base: fixture.project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.project.appendingPathComponent("bundle/bin/server").path)
    let (components, frozen) = try freeze(
      fixture,
      """
      version: 1
      components:
        - {kind: plugin, name: selected, source: ".", path: bundle, agents: ["claude-code"]}
        - {kind: command, name: review, description: Independent, prompt: Direct body, agents: ["claude-code"]}
      """)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(components, frozen)]
    #expect(ledger.lowerings[0].inputs.count == components.count - 1)
    #expect(
      !ledger.occurrences.filter { ledger.lowerings[0].inputs.contains($0.component) }.contains {
        $0.id == components.last!.origins[0].occurrence
      })
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("private-source-canary"))
    let expected = ledger.lowerings[0].artifacts
    try FileManager.default.removeItem(at: fixture.project)
    ledger = try ResolvedLedgerCodec.decode(encoded, limits: .standard)
    try LedgerReplay.withReplay(ledger, store: fixture.store, roots: [:], limits: .standard) {
      artifacts in
      #expect(try artifacts.map { try $0.digest(limits: .standard) } == expected)
      let contribution = try NativeGeneratedPluginContribution.decode(
        ledger.lowerings[0], ledger: ledger, artifacts: artifacts, limits: .standard)
      #expect(contribution.route == .claudeSkillPlugin)
      #expect(contribution.directory == "selected")
      #expect(contribution.recipients == [.claudeCode])
      #expect(Set(contribution.knownReaders) == [.claudeCode, .cursor])
      #expect(
        contribution.members.flatMap(\.occurrences)
          == ledger.occurrences[0].pluginExpansion!.children)
      var values: [String: Data] = [:]
      for member in contribution.members {
        if case .mcp(let server) = member.content {
          for binding in server.bindings {
            if case .secret(let name) = binding.binding {
              values[name] = Data("resolved-private-value".utf8)
            }
          }
        }
      }
      let paths = Dictionary(
        uniqueKeysWithValues: contribution.resourcePlacements.map {
          ($0.resource, "/registered/selected/" + $0.path)
        })
      let bundle = try contribution.stagedBundle(
        bindings: RuntimeBindingValues(values), environment: fixture.environment,
        resourcePaths: paths, budget: budget())
      #expect(
        String(decoding: bundle.files["commands/review.md"]!, as: UTF8.self).hasSuffix(
          "Literal source body\n"))
      guard case .object(let manifest) = bundle.documents[contribution.manifestPath],
        case .object(let events) = manifest["hooks"],
        case .array(let groups) = events["PreToolUse"]
      else {
        Issue.record("missing native hook groups")
        return
      }
      #expect(groups.count == 2)
      guard case .object(let first) = groups[0], case .object(let second) = groups[1] else {
        Issue.record("missing hook metadata")
        return
      }
      #expect(first["matcher"] == .string("Read"))
      #expect(second["matcher"] == .string("Write"))
      #expect(contribution.resourcePlacements.contains { $0.path == "skills/helper" })
      #expect(
        contribution.resources.values.contains {
          $0.entries.contains { $0.kind == .file && $0.executable }
        })
      var changed = artifacts
      changed[0].values!.object!["members"]!.array!.removeLast()
      #expect(throws: (any Error).self) {
        try NativeGeneratedPluginContribution.decode(
          ledger.lowerings[0], ledger: ledger, artifacts: changed, limits: .standard)
      }
    }
    var missing = frozen
    missing.ledger.occurrences[0].pluginExpansion = nil
    #expect(throws: (any Error).self) { try lower(components, missing) }
  }

  @Test func explicitEmptySelectionHasSealedManifestAndNoAdoptedChildren() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"upstream"}"#, to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    try fixture.write(
      "---\ndescription: Unselected\n---\nNever included\n", to: "bundle/commands/unselected.md",
      base: fixture.project)
    let (components, frozen) = try freeze(
      fixture,
      """
      version: 1
      components:
        - {kind: plugin, name: empty, source: ".", path: bundle, select: [], agents: ["claude-code"]}
      """)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(components, frozen)]
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard)
    try LedgerReplay.withReplay(ledger, store: fixture.store, roots: [:], limits: .standard) {
      artifacts in
      let result = try NativeGeneratedPluginContribution.decode(
        ledger.lowerings[0], ledger: ledger, artifacts: artifacts, limits: .standard)
      #expect(result.members.isEmpty)
      #expect(result.resources.isEmpty)
      let bundle = try result.stagedBundle(
        bindings: RuntimeBindingValues([:]), environment: fixture.environment, resourcePaths: [:],
        budget: budget())
      #expect(bundle.files.isEmpty)
      #expect(
        bundle.documents == [".claude-plugin/plugin.json": .object(["name": .string("empty")])])
    }
  }

  @Test func cursorPluginCommandUsesPluginScopeAndNativePlainBody() throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: .user, environment: fixture.environment)
    try fixture.write(
      #"{"name":"upstream"}"#, to: "bundle/.cursor-plugin/plugin.json", base: store.directory)
    try fixture.write("Exact plain body\n", to: "bundle/commands/review.md", base: store.directory)
    try fixture.write(
      #"{"mcpServers":{"native":{"command":"fixture-server"}}}"#,
      to: "bundle/mcp.json", base: store.directory)
    try fixture.write(
      #"{"version":1,"hooks":{"preToolUse":[{"type":"command","command":"fixture-hook"}]}}"#,
      to: "bundle/hooks/hooks.json", base: store.directory)
    let (components, frozen) = try freeze(
      fixture,
      """
      version: 1
      components:
        - {kind: plugin, name: selected, source: ".", path: bundle, agents: [cursor]}
      """, scope: .user)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(components, frozen, surface: .cursorEditor, scope: .user)]
    ledger = try LedgerReplay.prepareLowerings(ledger, store: store, roots: [:], limits: .standard)
    try LedgerReplay.withReplay(ledger, store: store, roots: [:], limits: .standard) { artifacts in
      let result = try NativeGeneratedPluginContribution.decode(
        ledger.lowerings[0], ledger: ledger, artifacts: artifacts, limits: .standard)
      #expect(result.route == .cursorLocalPlugin)
      let bundle = try result.stagedBundle(
        bindings: RuntimeBindingValues([:]), environment: fixture.environment, resourcePaths: [:],
        budget: budget(), cursorCommandShell: .posix)
      #expect(bundle.files["commands/review.md"] == Data("Exact plain body\n".utf8))
      guard case .object(let manifest) = bundle.documents[result.manifestPath] else {
        Issue.record("missing manifest")
        return
      }
      #expect(manifest["mcpServers"] == .string("./mcp.json"))
      #expect(manifest["hooks"] == .string("./hooks/hooks.json"))
      #expect(bundle.documents["mcp.json"] != nil)
      #expect(bundle.documents["hooks/hooks.json"] != nil)
    }
  }
  @Test func independentParentsKeepSeparateMemberOwnersAndNativeLSPFields() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"producer","lspServers":{"native-lsp":{"command":"fixture-lsp","extensionToLanguage":{".fixture":"fixture"},"restartOnCrash":true,"requestTimeout":1200}}}"#,
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    let (components, frozen) = try freeze(
      fixture,
      """
      version: 1
      components:
        - {kind: plugin, name: first, source: ".", path: bundle, agents: ["claude-code"]}
        - {kind: plugin, name: second, source: ".", path: bundle, agents: ["claude-code"]}
      """)
    let parents = components.filter { $0.key.kind == .plugin }
    var ledger = frozen.ledger
    ledger.lowerings = try parents.enumerated().map { index, parent in
      try NativeGeneratedPluginLayoutV1.lower(
        parent, members: components, frozen: frozen,
        request: .init(surface: .claudeCode, scope: .project), id: "parent/" + String(index),
        platform: platform)
    }
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard)
    try LedgerReplay.withReplay(ledger, store: fixture.store, roots: [:], limits: .standard) {
      artifacts in
      var ownerSets: [Set<Int>] = []
      for lowering in ledger.lowerings {
        let result = try NativeGeneratedPluginContribution.decode(
          lowering, ledger: ledger,
          artifacts: artifacts.filter { $0.name == lowering.id }, limits: .standard)
        ownerSets.append(Set(result.members.flatMap(\.occurrences)))
        let bundle = try result.stagedBundle(
          bindings: RuntimeBindingValues([:]), environment: fixture.environment, resourcePaths: [:],
          budget: budget())
        guard case .object(let manifest) = bundle.documents[result.manifestPath],
          case .object(let servers) = manifest["lspServers"],
          case .object(let server) = servers["native-lsp"]
        else {
          Issue.record("missing native LSP fields")
          return
        }
        #expect(server["requestTimeout"] == .integer(1200))
        #expect(server["restartOnCrash"] == .boolean(true))
      }
      #expect(ownerSets.count == 2)
      #expect(ownerSets[0].isDisjoint(with: ownerSets[1]))
      var corrupted = ledger
      corrupted.lowerings[0].layout.object!["members"]!.array![0].object!["occurrences"] =
        .init(array: ownerSets[1].map { .init(integer: $0) })
      #expect(throws: (any Error).self) {
        try NativeGeneratedPluginContribution.decode(
          corrupted.lowerings[0], ledger: corrupted,
          artifacts: artifacts.filter { $0.name == ledger.lowerings[0].id }, limits: .standard)
      }
    }
  }

  @Test(arguments: [String?.none, "1.2.3"], [false, true])
  func geminiUsesFrozenVersionAndNativeExtensionFiles(
    authoredVersion: String?, emptySelection: Bool
  ) throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: .user, environment: fixture.environment)
    let producerVersion = "9.0.0-e\u{301}"
    try fixture.write(
      """
      {"name":"upstream","version":"\(producerVersion)","mcpServers":{"native":{"command":"fixture-server"}}}
      """,
      to: "extension/gemini-extension.json", base: store.directory)
    try fixture.write(
      "description = \"Native review\"\nprompt = \"Literal review body\"\n".replacingOccurrences(
        of: "\\", with: ""),
      to: "extension/commands/review.toml", base: store.directory)
    let (components, frozen) = try freeze(
      fixture,
      """
      version: 1
      components:
        - kind: plugin
          name: selected
          source: "."
          path: extension
          agents: [gemini-cli]
          \(emptySelection ? "select: []" : "")
          native:
            gemini-cli:
              description: Consumer description
              \(authoredVersion.map { "version: \"\($0)\"" } ?? "")
      """, scope: .user)
    let expectedVersion = authoredVersion ?? producerVersion
    let parent = try #require(frozen.ledger.components.values.first { $0.kind == "plugin" })
    let effective = try #require(
      parent.payload.object?["native"]?.object?["gemini-cli"]?
        .object?["version"]?.text)
    #expect(effective.utf8.elementsEqual(expectedVersion.utf8))
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(components, frozen, surface: .geminiCLI, scope: .user)]
    ledger = try LedgerReplay.prepareLowerings(ledger, store: store, roots: [:], limits: .standard)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: store.directory.appendingPathComponent("extension"))
    ledger = try ResolvedLedgerCodec.decode(encoded, limits: .standard)
    try LedgerReplay.withReplay(ledger, store: store, roots: [:], limits: .standard) { artifacts in
      let result = try NativeGeneratedPluginContribution.decode(
        ledger.lowerings[0], ledger: ledger,
        artifacts: artifacts, limits: .standard)
      #expect(result.route == .geminiExtension)
      let bundle = try result.stagedBundle(
        bindings: RuntimeBindingValues([:]), environment: fixture.environment,
        resourcePaths: [:], budget: budget())
      guard case .object(let manifest) = bundle.documents["gemini-extension.json"] else {
        Issue.record("missing extension")
        return
      }
      guard case .string(let version) = manifest["version"] else {
        Issue.record("missing extension version")
        return
      }
      #expect(version.utf8.elementsEqual(expectedVersion.utf8))
      #expect(manifest["description"] == .string("Consumer description"))
      #expect((bundle.files["commands/review.toml"] == nil) == emptySelection)
      #expect((manifest["mcpServers"] == nil) == emptySelection)
    }
  }

  @Test func geminiUnavailableVersionKeepsImportRefusalAndBindingBoundary() throws {
    let fixture = try LinkFixture()
    let declaration = """
      version: 1
      components:
        - {kind: plugin, name: selected, source: ".", path: extension, select: [], agents: [gemini-cli]}
      """
    for field in ["", ", \"version\": \"\"", ", \"version\": 7"] {
      try fixture.write(
        "{\"name\":\"upstream\"\(field)}", to: "extension/gemini-extension.json",
        base: fixture.project)
      do {
        _ = try freeze(fixture, declaration)
        Issue.record("Invalid producer version was admitted")
      } catch {
        #expect(String(describing: error).contains("native plugin invalidInput"))
      }
    }
    try fixture.write(
      #"{"name":"upstream","version":"https://user:PRIVATE_VERSION_CANARY@example.test"}"#,
      to: "extension/gemini-extension.json", base: fixture.project)
    let (components, frozen) = try freeze(fixture, declaration)
    let parent = try #require(frozen.ledger.components.values.first { $0.kind == "plugin" })
    #expect(parent.payload.object?["native"]?.object?["gemini-cli"]?.object?["version"] == nil)
    let encoded = try ResolvedLedgerCodec.encode(frozen.ledger, limits: .standard)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_VERSION_CANARY"))
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(components, frozen, surface: .geminiCLI, scope: .user)]
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard)
    _ = try LedgerReplay.withReplay(ledger, store: fixture.store, roots: [:], limits: .standard) {
      artifacts in
      #expect(throws: (any Error).self) {
        try NativeGeneratedPluginContribution.decode(
          ledger.lowerings[0], ledger: ledger, artifacts: artifacts, limits: .standard)
      }
    }
  }

  @Test func geminiVersionComesFromSelectedProducerCommitAndContainer() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(repository)
    try fixture.write(
      #"{"name":"selected","version":"2.0.0"}"#,
      to: "chosen/gemini-extension.json", base: repository)
    try fixture.write(
      #"{"name":"other","version":"3.0.0"}"#,
      to: "other/gemini-extension.json", base: repository)
    let commit = try fixture.commit(repository, tag: "1.0.0")
    try fixture.write(
      #"{"name":"selected","version":"99.0.0"}"#,
      to: "chosen/gemini-extension.json", base: repository)
    let (_, frozen) = try freeze(
      fixture,
      """
      version: 1
      sources: {p: {url: "file://localhost\(repository.path)", requirement: {exact: "1.0.0"}}}
      components:
        - {kind: plugin, name: consumer, source: p, path: chosen, select: [], agents: [gemini-cli]}
      """)
    let parent = try #require(frozen.ledger.components.values.first { $0.kind == "plugin" })
    #expect(
      parent.payload.object?["native"]?.object?["gemini-cli"]?.object?["version"] == .init("2.0.0"))
    let expansion = try #require(frozen.ledger.occurrences.first?.pluginExpansion)
    #expect(expansion.document == "chosen/gemini-extension.json")
    #expect(frozen.ledger.sources[expansion.source]?.revision == commit)
  }

}
