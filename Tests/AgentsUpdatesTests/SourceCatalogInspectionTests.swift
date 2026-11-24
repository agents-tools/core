import AgentsCore
import AgentsManifest
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

extension SourceCatalogInspectionTests {
  @Test(arguments: [AgentID.claudeCode, .cursor], [PluginModeDeclaration.native, .components])
  func nativeCatalogSelectionPublishesExactRegistrationAndSelectedGeneratedMembers(
    _ agent: AgentID, _ strategy: PluginModeDeclaration
  ) throws {
    let f = try UpdateFixture(scope: .user)
    let producer = f.root.appendingPathComponent("catalog-package")
    let container = producer.appendingPathComponent("bundle")
    let manifest =
      agent == .claudeCode ? ".claude-plugin/plugin.json" : ".cursor-plugin/plugin.json"
    let profile: SourceImportProfile = agent == .claudeCode ? .claudePluginV1 : .cursorPluginV1
    try f.write(#"{"name":"producer-package"}"#, to: container.appendingPathComponent(manifest))
    for (name, body) in [("review", "Selected captured command"), ("other", "Unselected command")] {
      try f.write(
        agent == .claudeCode ? "---\ndescription: Review\n---\n\(body)\n" : body + "\n",
        to: container.appendingPathComponent("commands/\(name).md"))
    }
    try f.write(
      "---\nname: helper\ndescription: Helper\n---\nSelected captured skill\n",
      to: container.appendingPathComponent("skills/helper/SKILL.md"))
    let script = container.appendingPathComponent("scripts/never-run")
    try f.write("#!/bin/sh\n# Never executed.\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let before = try FileHash.folderHash(f.root)
    let catalog = try UpdateOperations.inspectSource(
      alias: "consumer-alias",
      source: .init(kind: .local, location: producer.path, path: "bundle"), scope: .user,
      environment: f.environment)
    let native = try #require(
      catalog.availableChoices.first {
        if case .nativePlugin = $0.unit { return true }
        return false
      })
    let metadata = try #require(
      try SourceImport.preview(
        .init(
          profile: profile, root: producer,
          document: "bundle/" + manifest)
      ).packageMetadata)
    #expect(native.unavailableReason == nil)
    #expect(native.origin.document == metadata.nameLocation.document)
    #expect(native.origin.pointer == metadata.nameLocation.pointer)
    #expect(native.origin.span == metadata.nameLocation.span)
    #expect(native.effects.first?.name.utf8.elementsEqual(metadata.name.utf8) == true)
    #expect(native.effects.first?.recipients == [agent])
    let choices: [SourceCatalogChoiceID]
    if strategy == .native {
      choices = [native.id]
    } else {
      choices = catalog.availableChoices.compactMap {
        guard case .pluginMember(let selector) = $0.unit else { return nil }
        switch selector {
        case .command(name: "review"), .skill(name: "helper"): return $0.id
        default: return nil
        }
      }
      #expect(choices.count == 2)
    }
    let discovery = try #require(try catalog.select(choices, options: .init(agents: [agent])))
    let request = discovery.updateRequest()
    guard case .declaration(let declaration) = request.operation else {
      Issue.record("missing captured declaration")
      return
    }
    #expect(declaration.components.count == 1)
    guard
      case .plugin(_, _, _, let mode, let select, let exclude, let recipients, _, _) =
        declaration.components[0]
    else {
      Issue.record("missing plugin declaration")
      return
    }
    #expect(mode == strategy && recipients == [agent])
    if strategy == .native { #expect(select == nil && exclude.isEmpty) }
    #expect(try FileHash.folderHash(f.root) == before)
    let preview = try UpdateOperations.preview(request, scope: .user, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, scope: .user, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installed = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    let tree = try #require(
      installed.deployments.first {
        FileManager.default.fileExists(atPath: $0.location.appendingPathComponent(manifest).path)
      }?.location)
    #expect(
      try String(contentsOf: tree.appendingPathComponent("commands/review.md"), encoding: .utf8)
        .contains("Selected captured command"))
    #expect(
      try String(contentsOf: tree.appendingPathComponent("skills/helper/SKILL.md"), encoding: .utf8)
        .contains("Selected captured skill"))
    #expect(
      FileManager.default.fileExists(atPath: tree.appendingPathComponent("commands/other.md").path)
        == (strategy == .native))
    let frozen = try FileHash.folderHash(tree)
    let flags = try FileHash.executableFlags(tree)
    if strategy == .native { #expect(flags["scripts/never-run"] == true) }
    try FileManager.default.removeItem(at: producer)
    if FileManager.default.fileExists(atPath: f.store.cacheDirectory.path) {
      try FileManager.default.removeItem(at: f.store.cacheDirectory)
    }
    try FileManager.default.removeItem(at: tree)
    _ = try UpdateOperations.restore(scope: .user, environment: f.environment)
    #expect(try FileHash.folderHash(tree) == frozen)
    #expect(try FileHash.executableFlags(tree) == flags)
  }
}

extension SourceCatalogInspectionTests {
  @Test func selectionRejectsChangedExternalDependencyWithUnchangedCatalogRoot() throws {
    let f = try UpdateFixture()
    let a = f.root.appendingPathComponent("producer-a")
    let b = f.root.appendingPathComponent("producer-b")
    try f.write(
      """
      version: 1
      sources: {b: {path: '\(b.path)'}}
      exports: [outer]
      groups:
        outer:
          uses: [{source: b, group: inner}]
      """, to: a.appendingPathComponent(".agent/agents.yaml"))
    func dependency(_ prompt: String) throws {
      try f.write(
        """
        version: 1
        exports: [inner]
        groups:
          inner:
            components:
              - {kind: command, name: review, description: Review, prompt: '\(prompt)', agents: [claude-code]}
        """, to: b.appendingPathComponent(".agent/agents.yaml"))
    }
    try dependency("before")
    let rootHash = try FileHash.folderHash(a)
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: a.path), environment: f.environment)
    let choice = try #require(
      catalog.availableChoices.first {
        if case .group = $0.unit { return true }
        return false
      })
    let discovery = try #require(try catalog.select([choice.id]))
    try dependency("after")
    #expect(try FileHash.folderHash(a) == rootHash)
    #expect(throws: (any Error).self) { try catalog.select([choice.id]) }
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
    }
  }
}

extension SourceCatalogInspectionTests {
  @Test func protectedUnrelatedRevisionCannotAttestSelectedSkill() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(
        sources: ["fixture": .init(kind: .local, location: f.repo.path)],
        skills: ["fixture": .init(select: .names(["demo"]), agents: [.codex], mode: .copy)],
        instructions: .init(agents: [.claudeCode], sections: ["fixture:rules"])),
      ledger: ResolvedLedger())
    _ = try f.apply()
    try f.writeSource("new")
    try f.commit()
    _ = try UpdateOperations.withPreparedUpdate(
      .init(kinds: [.instructions]), environment: f.environment
    ) { try $0.apply() }
    let catalog = try UpdateOperations.inspectSource(
      alias: "fixture", source: .init(kind: .local, location: f.repo.path),
      environment: f.environment)
    let choice = try #require(catalog.availableChoices.first { $0.label == "Skill demo" })
    let retained = try f.store.loadLedger()
    #expect(retained.sources.values.contains { $0.revision == catalog.revision })
    #expect(throws: (any Error).self) {
      _ = try catalog.select([choice.id], options: .init(agents: [.codex], skillMode: .copy))
    }
  }
}

extension SourceCatalogInspectionTests {
  @Test(arguments: [InstallMode.copy, .edit])
  func unchangedSkillCompositionRetainsConsumerModeAndRestrictions(_ mode: InstallMode) throws {
    let f = try UpdateFixture()
    let catalog = try UpdateOperations.inspectSource(
      alias: "catalog", source: .init(kind: .local, location: f.repo.path),
      environment: f.environment)
    let choice = try #require(catalog.availableChoices.first { $0.label == "Skill demo" })
    let discovery = try #require(
      try catalog.select(
        [choice.id], options: .init(agents: [.codex], skillMode: mode)))
    #expect(discovery.components.count == 1)
    #expect(discovery.components[0].recipients == [.codex])
    _ = try UpdateOperations.preview(discovery.updateRequest(), environment: f.environment)
  }
}

extension SourceCatalogInspectionTests {
  @Test func directEditDoesNotEraseExportedSkillRevisionEvidence() throws {
    let f = try UpdateFixture()
    try f.git(["tag", "1.0.0"])
    let oldRevision = try f.git(["rev-parse", "HEAD"])
    try f.write("Unrelated producer change\n", to: f.repo.appendingPathComponent("README.md"))
    try f.commit()
    try f.git(["tag", "1.1.0"])
    let newRevision = try f.git(["rev-parse", "HEAD"])
    try #require(newRevision != oldRevision)

    let producer = f.root.appendingPathComponent("mixed-producer")
    try f.write(
      "---\nname: helper\ndescription: Helper\n---\nUnchanged live skill\n",
      to: producer.appendingPathComponent("skills/helper/SKILL.md"))
    try f.write(
      """
      version: 1
      sources: {b: {path: '\(f.repo.path)'}}
      exports: [empty, review]
      groups:
        empty:
          components: []
        review:
          components:
            - kind: skills
              source: b
              select: [demo]
              agents: [claude-code]
              mode: copy
      """, to: producer.appendingPathComponent(".agent/agents.yaml"))
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    let catalog = try SourceCatalog.inspect(
      alias: "mixed", source: .init(kind: .local, location: producer.path),
      store: f.store, platform: platform)
    let direct = try #require(catalog.choices.first { $0.label == "Skill helper" })
    let review = try #require(
      catalog.choices.first {
        if case .group(let use) = $0.unit { return use.name == "review" }
        return false
      })
    let source = try SourceDeclaration(kind: .local, location: f.repo.path)
      .identity(environment: f.environment)
    let expected = try #require(review.graph?.components.first)
    let expectedResource = try #require(expected.resources.first)
    try requireCopiedReview(expected, source: source, revision: newRevision)

    let declaration = try catalog.additions(
      [direct.id, review.id], agents: nil, condition: nil, mode: .edit)
    let identity = DocumentIdentity(f.store.declarationURL.path)
    let bytes = try #require(
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: declaration, in: nil, identity: identity,
        environment: f.environment))
    let document = try DeclarationDocument(bytes: bytes, identity: identity)
    let expectation = CatalogCompositionExpectation(choices: [direct, review], skillMode: .edit)

    for revision in [oldRevision, newRevision] {
      try ComponentLinker.withLinkedComponents(
        document: document, store: f.store, platform: platform,
        directPins: [expected.key: SourceRevision(revision: revision)]
      ) { linked, _ in
        let copied = try #require(linked.components.first { $0.key == expected.key })
        try requireCopiedReview(copied, source: source, revision: revision)
        let resource = try #require(copied.resources.first)
        try #require(resource.path == expectedResource.path)
        try #require(resource.hash == expectedResource.hash)
        try #require(resource.snapshot == copied.snapshot)
        let helper = try #require(linked.components.first { $0.key.name == "helper" })
        guard case .skill(_, .edit, _) = helper.payload else {
          Issue.record("Expected the direct helper to be linked in edit mode")
          return
        }
        if revision == oldRevision {
          #expect(
            throws: CoreError.invalidState(
              "catalog addition changed dependency; refresh inspection")
          ) {
            try expectation.validate(linked)
          }
        } else {
          try expectation.validate(linked)
        }
      }
    }
  }

  private func requireCopiedReview(_ component: LinkedComponent, source: String, revision: String)
    throws
  {
    guard case .skill(_, .copy, _) = component.payload else {
      throw CoreError.invalidState("Expected the review skill to be linked in copy mode")
    }
    try #require(component.key.name == "demo")
    try #require(component.key.group == "review")
    try #require(component.snapshot.source == source)
    try #require(component.snapshot.revision == revision)
    try #require(component.origins.contains { $0.dependencies.contains(component.snapshot) })
  }
}
