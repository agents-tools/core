import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import Components

@Suite("Explicit source catalogs", .serialized)
struct SourceCatalogTests {
  private func inspect(
    _ fixture: LinkFixture, path: String = ".", importing document: SourceCatalogImport? = nil
  ) throws -> Components.SourceCatalog {
    try Components.SourceCatalog.inspect(
      alias: "producer", source: .init(kind: .local, location: fixture.project.path, path: path),
      store: fixture.store, platform: .macOS, importing: document)
  }

  @Test func directMembersAndSymbolicGroupsHaveCompleteCapturedEffects() throws {
    let fixture = try LinkFixture()
    try fixture.skill("demo", at: fixture.project, restrictions: "agents: [codex]\n")
    try fixture.instruction("rules", at: fixture.project, own: false)
    try fixture.manifest(
      """
      version: 1
      exports: [outer, empty]
      groups:
        outer:
          components:
            - {kind: command, name: review, description: Review, prompt: Exact, agents: [codex]}
          uses: [{group: inner}, {group: inner}]
        inner:
          components:
            - {kind: mcpServer, name: safe, transport: {kind: stdio, executable: fixture-server}, agents: [codex]}
        empty: {}
      """, at: fixture.project)
    let before = try FileHash.folderHash(fixture.root)
    let catalog = try inspect(fixture)
    #expect(catalog.choices.count == 4)
    let skill = try #require(
      catalog.choices.first {
        if case .skill = $0.unit { return true }
        return false
      })
    #expect(skill.graph?.components.first?.recipients == [.codex])
    let group = try #require(
      catalog.choices.first {
        if case .group(let use) = $0.unit { return use.name == "outer" && use.source == "producer" }
        return false
      })
    #expect(group.unavailableReason == nil)
    #expect(group.graph?.references.count == 3)
    #expect(group.graph?.components.flatMap(\.origins).count == 3)
    #expect(
      group.graph?.components.allSatisfy { $0.origins.allSatisfy { !$0.consumerEditable } } == true)
    let empty = try #require(
      catalog.choices.first {
        if case .group(let use) = $0.unit { return use.name == "empty" }
        return false
      })
    #expect(empty.graph?.components.isEmpty == true)
    #expect(empty.graph?.references.count == 1)
    #expect(try catalog.selected([]) == nil)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(!String(reflecting: catalog).contains("agents-resolution-"))
    let other = try inspect(fixture)
    #expect(throws: (any Error).self) { try other.selected([group.id]) }
    #expect(throws: (any Error).self) { try catalog.selected([group.id, group.id]) }
    #expect(try catalog.selected([group.id])?.count == 1)
  }

  @Test func pluginStrategiesAndTypedMemberExclusionsRemainExplicit() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"upstream"}"#, to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    for name in ["one", "two"] {
      try fixture.write(
        "---\ndescription: Review\n---\nExact body\n", to: "bundle/commands/\(name).md",
        base: fixture.project)
    }
    for (path, name) in [("first", "cafe\u{301}"), ("second", "caf\u{e9}")] {
      try fixture.write(
        "---\nname: \(name)\ndescription: Agent\n---\nBody\n",
        to: "bundle/agents/\(path).md", base: fixture.project)
    }
    let before = try FileHash.folderHash(fixture.root)
    let catalog = try inspect(fixture, path: "bundle")
    #expect(catalog.choices.count == 6)
    for choice in catalog.choices {
      switch choice.unit {
      case .nativePlugin(let declaration):
        #expect(choice.unavailableReason?.contains("adapter-issued container name") == true)
        #expect(throws: (any Error).self) { try catalog.selected([choice.id]) }
        guard
          case .plugin(_, _, _, let mode, let select, let exclude, let agents, _, _) = declaration
        else {
          Issue.record("wrong native unit")
          continue
        }
        #expect(mode == .native && select == nil && exclude.isEmpty && agents == [.claudeCode])
        #expect(choice.graph?.components.count == 1)
      case .componentsPlugin(let declaration):
        guard case .plugin(_, _, _, let mode, let select, let exclude, _, _, _) = declaration
        else {
          Issue.record("wrong components container")
          continue
        }
        #expect(mode == .components && select == nil && exclude.isEmpty)
        #expect(
          choice.graph?.components.filter { $0.key.kind == .command }.count == 2
            && choice.graph?.components.filter { $0.key.kind == .subagent }.count == 2)
      case .pluginMember(let declaration, _):
        guard case .plugin(_, _, _, let mode, let select, let exclude, _, _, _) = declaration
        else {
          Issue.record("wrong components unit")
          continue
        }
        #expect(
          mode == .components && [.command, .subagent].contains(select?.first) && exclude.count == 1
        )
        #expect(choice.graph?.components.filter { $0.key.kind != .plugin }.count == 1)
      default: Issue.record("unexpected source choice")
      }
    }
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(!String(reflecting: catalog).contains("agents-resolution-"))
  }

  @Test func importerKeysKeepAllFamiliesFixedEffectsAndProducerClaimsSeparate() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"mcp":{"servers":{"same":{"type":"local","command":["fixture-server"]}}},"commands":{"same":{"description":"Review","template":"Body"}},"agents":{"same":{"description":"Help","system":"Body","mode":"subagent"}},"lsp":{"fixed":{"command":["fixture-lsp"],"extensions":[".fixture"]}}}"#,
      to: "opencode.json", base: fixture.project)
    let before = try FileHash.folderHash(fixture.root)
    let catalog = try inspect(
      fixture,
      importing: .init(profile: .openCodeConfigV2, document: "opencode.json", selection: []))
    #expect(catalog.choices.count == 1)
    let choice = try #require(catalog.choices.first)
    guard case .importer(let metadata) = choice.unit else {
      Issue.record("not an importer key")
      return
    }
    #expect(metadata.key == "same")
    #expect(
      Set(choice.imported!.components.map(\.declaration.kind)) == [.mcpServer, .command, .subagent])
    #expect(catalog.fixedEffects?.components.contains { $0.declaration.kind == .lspServer } == true)
    #expect(catalog.importDocument?.selection == [])
    #expect(!String(reflecting: catalog).contains("agents-resolution-"))
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func unavailableClosureRemainsVisibleAndEmptySourceDoesNotAddAnything() throws {
    let fixture = try LinkFixture()
    #expect(try inspect(fixture).selected([]) == nil)
    try fixture.manifest(
      "version: 1\nsources: {absent: {path: ../missing}}\nexports: [broken]\ngroups: {broken: {uses: [{group: missing, source: absent}]}}",
      at: fixture.project)
    let catalog = try inspect(fixture)
    #expect(catalog.choices.count == 1)
    #expect(catalog.choices[0].graph == nil)
    #expect(catalog.choices[0].unavailableReason != nil)
  }
  @Test func emptyPluginStillOffersExplicitStrategiesAndSnapshotEvidence() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"empty"}"#, to: ".claude-plugin/plugin.json", base: fixture.project)
    let catalog = try inspect(fixture)
    #expect(catalog.choices.count == 2)
    let expanded = try #require(
      catalog.choices.first {
        if case .componentsPlugin = $0.unit { return true }
        return false
      })
    #expect(expanded.unavailableReason == nil)
    #expect(expanded.graph?.components.count == 1)
    #expect(expanded.graph?.components[0].origins[0].pluginExpansion?.children == [])
    #expect(expanded.graph?.sourceSnapshots.contains { $0.snapshot == catalog.snapshot } == true)
  }

  @Test func gitCatalogUsesSelectedCommitAndChangesItsContentEvidence() throws {
    let fixture = try LinkFixture()
    try fixture.initialize(fixture.project)
    try fixture.skill("committed", at: fixture.project)
    let first = try fixture.commit(fixture.project)
    try fixture.skill("dirty", at: fixture.project)
    let catalog = try inspect(fixture)
    #expect(catalog.snapshot.revision == first)
    #expect(catalog.choices.count == 1)
    #expect(catalog.choices[0].unavailableReason == nil)
    _ = try fixture.commit(fixture.project)
    let next = try inspect(fixture)
    #expect(next.choices.count == 2)
    #expect(next.contentHash != catalog.contentHash)
    #expect(!String(reflecting: next).contains("agents-resolution-"))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }

  @Test func importedLocalCoordinatesStayRelativeToCapturedSource() throws {
    let fixture = try LinkFixture()
    try fixture.skill("local", at: fixture.project.appendingPathComponent("content"))
    try fixture.write(
      "name: package\nversion: '1.0.0'\ndependencies:\n  apm:\n    - path: content\n",
      to: "apm.yml", base: fixture.project)
    let catalog = try inspect(
      fixture, importing: .init(profile: .apmManifest, document: "apm.yml"))
    let choice = try #require(catalog.choices.first)
    let source = try #require(choice.imported?.sources.first)
    #expect(source.declaration?.location == "content")
    #expect(source.declaration?.environment == nil)
    #expect(!String(reflecting: catalog).contains("agents-resolution-"))
  }

  @Test func nativeRegistrationUsesAdapterIssuedName() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"actual-producer","version":"1.0.0"}"#,
      to: "gemini-extension.json", base: fixture.project)
    let catalog = try inspect(fixture)
    let choice = try #require(
      catalog.choices.first {
        if case .nativePlugin = $0.unit { return true }
        return false
      })
    guard
      case .nativePlugin(
        .plugin(let name, _, let source, let mode, let select, let exclude, let agents, _, _)) =
        choice.unit
    else {
      Issue.record("missing native declaration")
      return
    }
    #expect(name == "actual-producer" && source == "producer")
    #expect(mode == .native && select == nil && exclude.isEmpty && agents == [.geminiCLI])
    #expect(choice.unavailableReason == nil)
  }

}
