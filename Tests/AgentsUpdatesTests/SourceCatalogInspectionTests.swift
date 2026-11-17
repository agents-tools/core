import AgentsCore
import Foundation
import Testing

@testable import AgentsUpdates
@testable import Components

@Suite("Captured source catalog additions", .serialized)
struct SourceCatalogInspectionTests {
  @Test func instructionSelectionPreparesAppliesAndRejectsForeignDestination() throws {
    let f = try UpdateFixture()
    let other = try UpdateFixture()
    var environment = f.environment
    environment.environment["PRIVATE_CATALOG_ENV"] = "CATALOG_ENV_CANARY"
    let before = try FileHash.folderHash(f.root)
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: f.repo.path), environment: environment
    )
    #expect(!String(reflecting: catalog).contains("CATALOG_ENV_CANARY"))
    #expect(!String(reflecting: catalog).contains("agents-resolution-"))
    let choice = try #require(
      catalog.availableChoices.first {
        if case .instruction = $0.unit { return true }
        return false
      })
    let otherCatalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: f.repo.path), environment: environment
    )
    #expect(throws: (any Error).self) { try otherCatalog.select([choice.id]) }
    #expect(throws: (any Error).self) { try catalog.select([choice.id, choice.id]) }
    let discovery = try #require(try catalog.select([choice.id], options: .init(agents: [.codex])))
    #expect(try FileHash.folderHash(f.root) == before)
    let request = discovery.updateRequest()
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, environment: other.environment)
    }
    let preview = try UpdateOperations.preview(request, environment: environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(
      try UpdateOperations.inspect(environment: environment).components.contains {
        $0.kind == .instructions
      })
  }

  @Test func emptySelectionDoesNotReadDeletedSourceAndStaleRequestsReject() throws {
    let f = try UpdateFixture()
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: f.repo.path),
      environment: f.environment)
    let choice = try #require(
      catalog.availableChoices.first {
        if case .skill = $0.unit { return true }
        return false
      })
    let discovery = try #require(
      try catalog.select([choice.id], options: .init(agents: [.codex], skillMode: .copy)))
    try f.advance()
    #expect(throws: (any Error).self) { try catalog.select([choice.id]) }
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
    }
    try FileManager.default.removeItem(at: f.repo)
    #expect(try catalog.select([]) == nil)
    #expect(!FileManager.default.fileExists(atPath: f.store.declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: f.store.resolvedURL.path))
  }

  @Test func importerRealKeyRetainsAllFamiliesAndFixedEffectsAndOriginalFreshness() throws {
    let f = try UpdateFixture()
    let producer = f.root.appendingPathComponent("import-source")
    try f.write(
      #"{"mcp":{"servers":{"same":{"type":"local","command":["never-run"]}}},"commands":{"same":{"template":"Review"},"other":{"template":"Other"}},"agents":{"same":{"system":"Review","mode":"subagent"}},"lsp":{"fixed":{"command":["never-run"]}}}"#,
      to: producer.appendingPathComponent("opencode.json"))
    let before = try FileHash.folderHash(f.root)
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: producer.path),
      importing: .init(format: "openCodeConfigV2", document: "opencode.json", selection: []),
      environment: f.environment)
    let key = try #require(
      catalog.availableChoices.first { $0.importedEffects?.components.count == 3 })
    #expect(
      Set(key.importedEffects!.components.map(\.declaration.kind)) == [
        .mcpServer, .command, .subagent,
      ])
    #expect(catalog.fixedEffects?.components.map(\.declaration.kind) == [.lspServer])
    let discovery = try #require(try catalog.select([key.id]))
    #expect(discovery.components.count == 4)
    #expect(try FileHash.folderHash(f.root) == before)
    _ = try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
    // Inline canonical declarations alone cannot attest this original adapter document.
    try f.write("{}", to: producer.appendingPathComponent("opencode.json"))
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
    }
    try f.write(
      #"{"commands":{"review":{"template":"Review captured sources"}}}"#,
      to: producer.appendingPathComponent("opencode.json"))
    let refreshed = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: producer.path),
      importing: .init(format: "openCodeConfigV2", document: "opencode.json"),
      environment: f.environment)
    let refreshedChoice = try #require(refreshed.availableChoices.first)
    let selected = try #require(try refreshed.select([refreshedChoice.id]))
    let preview = try UpdateOperations.preview(selected.updateRequest(), environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      selected.updateRequest(), environment: f.environment
    ) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(
      try UpdateOperations.inspect(environment: f.environment).components.contains {
        $0.kind == .command
      })
  }

  @Test func membersComposeOneContainerAndNativeStrategyConflicts() throws {
    let f = try UpdateFixture()
    let producer = f.root.appendingPathComponent("plugin-source")
    try f.write(
      #"{"name":"exact-package","version":"1.2.3"}"#,
      to: producer.appendingPathComponent("gemini-extension.json"))
    try f.write(
      "description = \"First\"\nprompt = \"One\"\n",
      to: producer.appendingPathComponent("commands/one.toml"))
    try f.write(
      "description = \"Second\"\nprompt = \"Two\"\n",
      to: producer.appendingPathComponent("commands/two.toml"))
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: producer.path),
      environment: f.environment)
    let members = catalog.availableChoices.filter {
      if case .pluginMember = $0.unit { return true }
      return false
    }
    #expect(members.count == 2)
    let discovery = try #require(try catalog.select(members.map(\.id)))
    let request = discovery.updateRequest()
    guard case .declaration(let declaration) = request.operation else {
      Issue.record("missing addition")
      return
    }
    #expect(declaration.components.count == 1)
    guard
      case .plugin(_, _, _, let strategy, let kinds, let exclusions, _, _, _) =
        declaration.components[0]
    else {
      Issue.record("missing container")
      return
    }
    #expect(strategy == .components && kinds == [.command] && exclusions.isEmpty)
    let native = try #require(
      catalog.availableChoices.first {
        if case .nativePlugin = $0.unit { return true }
        return false
      })
    let metadata = try #require(
      try SourceImport.preview(
        .init(profile: .geminiExtensionV1, root: producer, document: "gemini-extension.json")
      ).packageMetadata)
    #expect(native.origin.pointer == metadata.nameLocation.pointer)
    #expect(native.origin.span == metadata.nameLocation.span)
    #expect(throws: (any Error).self) { try catalog.select([native.id, members[0].id]) }
  }
}

extension SourceCatalogInspectionTests {
  @Test func symbolicGroupAdditionPreservesUnrelatedCommittedPins() throws {
    let f = try UpdateFixture()
    try f.install(agents: [.codex])
    let previous = try f.store.loadLedger()
    try f.advance()
    let producer = f.root.appendingPathComponent("export-source")
    try f.write(
      """
      version: 1
      exports: [review]
      groups:
        review:
          components:
            - {kind: command, name: review, description: Review, prompt: Exact, agents: [claude-code]}
      """, to: producer.appendingPathComponent(".agent/agents.yaml"))
    let catalog = try UpdateOperations.inspectSource(
      alias: "exports", source: .init(kind: .local, location: producer.path),
      environment: f.environment)
    let choice = try #require(
      catalog.availableChoices.first {
        if case .group = $0.unit { return true }
        return false
      })
    let discovery = try #require(try catalog.select([choice.id]))
    let request = discovery.updateRequest()
    guard case .declaration(let declaration) = request.operation else {
      Issue.record("missing declaration")
      return
    }
    #expect(declaration.uses == [.init(name: "review", source: "exports")])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let next = try f.store.loadLedger()
    for (id, component) in previous.components {
      #expect(next.components[id] == component)
      #expect(next.sources[component.source] == previous.sources[component.source])
    }
  }

  @Test func rawResourceRewriteCannotBeClearedThroughCatalogBindingInput() throws {
    let f = try UpdateFixture()
    let producer = f.root.appendingPathComponent("credential-source")
    try f.write(
      #"{"mcpServers":{"review":{"command":"never-run","env":{"TOKEN":"CATALOG_PRIVATE_CANARY"}}}}"#,
      to: producer.appendingPathComponent("settings.json"))
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: producer.path),
      importing: .init(format: "claudeSettingsV1", document: "settings.json"),
      environment: f.environment)
    let choice = try #require(catalog.availableChoices.first)
    let binding = try #require(catalog.requiredInputs.first { $0.kind == .bindingReference })
    #expect(!String(reflecting: catalog).contains("CATALOG_PRIVATE_CANARY"))
    #expect(throws: (any Error).self) {
      try catalog.select(
        [choice.id], inputs: [.init(id: binding.id, value: .binding(.environment("REVIEW_TOKEN")))])
    }
    #expect(!FileManager.default.fileExists(atPath: f.store.declarationURL.path))
  }
}
