import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@Suite("Public rich lifecycle consumers")
struct PublicInspectionTests {
  @Test func coherentInspectionCarriesDocumentGraphAndActualLocationsWithoutWrites() throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.claudeCode])
    var declaration = try f.store.loadDeclaration()
    declaration.components.append(
      .mcpServer(
        name: "metadata", transport: .stdio(.init(executable: "never-run")), agents: [.claudeCode]))
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    let before = try FileHash.folderHash(f.root)
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(try snapshot.document?.digest == f.store.loadManifest()?.digest)
    #expect(snapshot.declaration == declaration)
    #expect(snapshot.components.count == 4)
    #expect(snapshot.components.allSatisfy { !$0.occurrences.isEmpty })
    #expect(
      snapshot.components.allSatisfy {
        !$0.selection.identity.contains(f.store.cacheDirectory.path)
      })
    #expect(snapshot.sources.contains { $0.identity == "local:" + f.repo.path })
    #expect(snapshot.resources.allSatisfy { $0.location != nil })
    #expect(snapshot.readLocations.contains(f.store.watchURL))
    #expect(snapshot.readLocations.contains(f.root.appendingPathComponent(".mcp.json")))
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    #expect(!snapshot.recovery.pending)
    #expect(try FileHash.folderHash(f.root) == before)
    try f.write("external drift", to: f.target(.claudeCode).appendingPathComponent("SKILL.md"))
    let drift = try UpdateOperations.inspect(environment: f.environment)
    #expect(drift.deployments.contains { $0.format == "agents/skill@1" && $0.status == .drifted })
    #expect(drift.generation == snapshot.generation)
  }

  @Test func producerGroupInspectionPreservesRecordedJoinsAndProvenance() throws {
    let f = try UpdateFixture()
    try f.write(
      """
      version: 1
      groups:
        tools:
          components: [{kind: mcpServer, name: group-tool, transport: {kind: stdio, executable: never-run}, agents: [claude-code]}]
      exports: [tools]
      """, to: f.repo.appendingPathComponent(".agent/agents.yaml"))
    try f.commit()
    try f.write(
      """
      version: 1
      sources: {producer: {path: \(f.repo.path)}}
      uses: [{source: producer, group: tools}]
      """, to: f.store.declarationURL)
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let group = try #require(snapshot.groups.first)
    let component = try #require(snapshot.components.first)
    let occurrence = try #require(component.occurrences.first)
    let sourceRecords = Set(snapshot.sources.map(\.record))
    #expect(snapshot.groups.count == 1)
    #expect(group.name == "tools")
    #expect(sourceRecords.contains(group.sourceRecord))
    #expect(sourceRecords.contains(component.sourceRecord))
    #expect(sourceRecords.contains(component.declaringSourceRecord))
    #expect(occurrence.reference == group.id)
    #expect(occurrence.manifestPath == ".agent/agents.yaml")
    #expect(!occurrence.consumerEditable)
    #expect(occurrence.dependencyRecords.allSatisfy(sourceRecords.contains))
    #expect(component.recipients == [.claudeCode])
    #expect(snapshot.deployments.first?.ownerRecords == [component.record])
    #expect(snapshot.deployments.first?.status == .current)
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(
        .init(operation: .remove, selections: [component.selection]), environment: f.environment)
    }
  }

  @Test func preciseSelectionRemovesOneOfEqualNamesAndRejectsStaleOccurrence() throws {
    let f = try UpdateFixture()
    let a = f.root.appendingPathComponent("a")
    let b = f.root.appendingPathComponent("b")
    for root in [a, b] {
      try f.write(
        "---\nname: same\ndescription: Example\n---\nvalue\n",
        to: root.appendingPathComponent("same/SKILL.md"))
    }
    try f.store.save(
      declaration: Declaration(
        sources: [
          "a": .init(kind: .local, location: a.path), "b": .init(kind: .local, location: b.path),
        ],
        components: [
          .skills(source: "a", .init(select: .all, agents: [.codex], mode: .copy)),
          .skills(source: "b", .init(select: .all, agents: [.claudeCode], mode: .copy)),
        ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let inspected = try UpdateOperations.inspect(environment: f.environment)
    let selected = try #require(inspected.components.first { $0.source == "local:" + a.path })
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(
        .init(operation: .remove, kinds: [.skills], names: ["same"]), environment: f.environment)
    }
    let request = UpdateRequest(operation: .remove, selections: [selected.occurrences[0].selection])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    #expect(preview.skills.count == 1)
    #expect(preview.skills[0].sourceIdentity == "local:" + a.path)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let remaining = try UpdateOperations.inspect(environment: f.environment)
    #expect(remaining.components.count == 1)
    #expect(remaining.components[0].source == "local:" + b.path)
    #expect(remaining.deployments.allSatisfy { $0.status == .current })
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, environment: f.environment)
    }
  }

  @Test func preciseInstructionSelectionPreservesAnEqualNameFromAnotherSource() throws {
    let f = try UpdateFixture()
    let a = f.root.appendingPathComponent("instructions-a")
    let b = f.root.appendingPathComponent("instructions-b")
    for root in [a, b] {
      try f.write(
        "---\ndescription: Same name\n---\n# \(root.lastPathComponent)\n",
        to: root.appendingPathComponent("instructions/rules.md"))
    }
    try f.store.save(
      declaration: Declaration(
        sources: [
          "a": .init(kind: .local, location: a.path), "b": .init(kind: .local, location: b.path),
        ],
        components: [
          .instructions(.init(agents: [.claudeCode], sections: ["a:rules"])),
          .instructions(.init(agents: [.claudeCode], sections: ["b:rules"])),
        ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let selected = try #require(snapshot.components.first { $0.source == "local:" + a.path })
    let request = UpdateRequest(operation: .remove, selections: [selected.selection])
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let remaining = try UpdateOperations.inspect(environment: f.environment)
    #expect(remaining.components.count == 1)
    #expect(remaining.components[0].source == "local:" + b.path)
    #expect(remaining.deployments.allSatisfy { $0.status == .current })
  }

  @Test(arguments: AgentID.allCases)
  func registeredMCPRouteAppliesAndColdRestoresWithoutRunningClient(_ agent: AgentID) throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "quoted.server",
          transport: .stdio(.init(executable: "never-run", arguments: ["fixed"])), agents: [agent])
      ]), ledger: ResolvedLedger())
    let preview = try f.preview()
    #expect(preview.components.count == 1)
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let deployed = try #require(snapshot.deployments.first)
    #expect(deployed.status == .current)
    let bytes = try Data(contentsOf: deployed.location)
    let locked = try Data(contentsOf: f.store.resolvedURL)
    try FileManager.default.removeItem(at: deployed.location)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try Data(contentsOf: deployed.location) == bytes)
    #expect(try Data(contentsOf: f.store.resolvedURL) == locked)
  }

  @Test func publicProviderAndOuterTerminalRetainPrivateBoundary() throws {
    struct Provider: RuntimeBindingProvider {
      func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
        Data("private-canary".utf8)
      }
    }
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "private",
          transport: .stdio(
            .init(executable: "never-run", environment: ["TOKEN": .secret("token")])),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("configured-claude"), withIntermediateDirectories: true)
    let preview = try f.preview()
    #expect(
      !String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains("private-canary")
    )
    let completion = UpdateOperations.perform(
      environment: f.environment, bindingProvider: Provider()
    ) { update in
      try update.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    _ = try completion.result.get()
    #expect(completion.disposition == .committed)
    #expect(!completion.recovery.pending)
    #expect(
      !String(decoding: try Data(contentsOf: f.store.resolvedURL), as: UTF8.self).contains(
        "private-canary"))
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    #expect(snapshot.deployments.allSatisfy { $0.status == .current })
    struct Cancelled: Error {}
    let cancelled: UpdateCompletion<Void> = UpdateOperations.perform(environment: f.environment) {
      _ in throw Cancelled()
    }
    #expect(cancelled.disposition == .unchanged)
    #expect(throws: Cancelled.self) { try cancelled.result.get() }
  }

  @Test func watchAcknowledgmentRejectsUndisplayedHead() throws {
    let f = try UpdateFixture()
    try f.declare()
    let watch = SkillOperations.watchOperations()
    _ = try watch.add("fixture", environment: f.environment)
    let displayed = try #require(watch.status(environment: f.environment).first)
    let previous = try f.store.loadWatch()
    try f.advance()
    #expect(throws: (any Error).self) {
      try watch.seen(displayed, environment: f.environment)
    }
    #expect(try f.store.loadWatch() == previous)
    let current = try #require(watch.status(environment: f.environment).first)
    _ = try watch.seen(current, environment: f.environment)
    #expect(try f.store.loadWatch().sources[current.sourceID]?.seen == current.current)
  }
  @Test func discoveryRetainsExactEvidenceAndRejectsAChangedSource() throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.claudeCode])
    let declaration = try f.store.loadDeclaration()
    let before = try FileHash.folderHash(f.root)
    let discovery = try UpdateOperations.discover(declaration, environment: f.environment)
    #expect(!discovery.components.isEmpty)
    #expect(
      discovery.sourceRevisions.values.flatMap { $0 }.contains(try f.git(["rev-parse", "HEAD"])))
    #expect(try FileHash.folderHash(f.root) == before)
    #expect(discovery.readLocations.contains { $0.path == f.repo.path })
    let request = discovery.updateRequest()
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let current = try UpdateOperations.discover(declaration, environment: f.environment)
    try f.advance()
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(current.updateRequest(), environment: f.environment) {
        _ in
        Issue.record("changed discovery must fail before delivering the handle")
      }
    }
  }

  @Test func watchAcknowledgmentRejectsAnAliasRedirectEvenWithTheSameCommit() throws {
    let f = try UpdateFixture()
    try f.declare()
    let watch = SkillOperations.watchOperations()
    _ = try watch.add("fixture", environment: f.environment)
    let displayed = try #require(watch.status(environment: f.environment).first)
    let other = f.root.appendingPathComponent("another-source")
    try FileManager.default.copyItem(at: f.repo, to: other)
    var declaration = try f.store.loadDeclaration()
    declaration.sources["fixture"]?.location = other.path
    try f.store.save(declaration: declaration, ledger: f.store.loadLedger())
    let before = try Data(contentsOf: f.store.watchURL)
    #expect(throws: (any Error).self) { try watch.seen(displayed, environment: f.environment) }
    #expect(try Data(contentsOf: f.store.watchURL) == before)
  }

}

extension PublicInspectionTests {
  @Test func importedAuthoringContentUsesProductionFreezeAndInputFreshness() throws {
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("producer")
    let document = input.appendingPathComponent("apm.yml")
    let skill = input.appendingPathComponent(".apm/skills/review/SKILL.md")
    try f.write("name: example\nversion: '1.0.0'\n", to: document)
    try f.write("---\nname: review\ndescription: Review\n---\n# Review\n", to: skill)
    let before = try FileHash.folderHash(f.root)
    let proposal = try SourceImportOperations.inspect(
      format: "apmManifest", root: input, document: "apm.yml")
    #expect(!proposal.specificationStatus.isEmpty)
    #expect(proposal.diagnostics.isEmpty)
    #expect(proposal.components.count == 1)
    #expect(proposal.resources.first?.requiresStandaloneSource == true)
    #expect(try FileHash.folderHash(f.root) == before)
    let scope = try UpdateOperations.inspect(environment: f.environment)
    let request = try proposal.updateRequest(in: scope)
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installed = try UpdateOperations.inspect(environment: f.environment)
    #expect(installed.components.first?.name == "review")
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    let newProposal = try SourceImportOperations.inspect(
      format: "apmManifest", root: input, document: "apm.yml")
    let newRequest = try newProposal.updateRequest(in: installed)
    try f.write("---\nname: review\ndescription: Review\n---\n# Changed\n", to: skill)
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(newRequest, environment: f.environment) { _ in
        Issue.record("stale imported resources must fail before delivering the handle")
      }
    }
    let target = try #require(installed.deployments.first?.location)
    let bytes = try Data(contentsOf: target.appendingPathComponent("SKILL.md"))
    try FileManager.default.removeItem(at: input)
    try FileManager.default.removeItem(at: f.store.cacheDirectory)
    for deployment in installed.deployments {
      try FileManager.default.removeItem(at: deployment.location)
    }
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == bytes)
  }

  @Test func importInputChangesDuringCallbackPreventPublication() throws {
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("producer")
    let document = input.appendingPathComponent("apm.yml")
    try f.write("name: example\nversion: '1.0.0'\n", to: document)
    try f.write(
      "---\nname: review\ndescription: Review\n---\n# Review\n",
      to: input.appendingPathComponent(".apm/skills/review/SKILL.md"))
    let proposal = try SourceImportOperations.inspect(
      format: "apmManifest", root: input, document: "apm.yml")
    let request = try proposal.updateRequest(
      in: UpdateOperations.inspect(environment: f.environment))
    let result = UpdateOperations.perform(request, environment: f.environment) { update in
      try f.write("name: changed\n", to: document)
      return try update.apply()
    }
    #expect(result.disposition == .unchanged)
    #expect(throws: UpdateApplyError.self) { try result.result.get() }
    #expect(!FileManager.default.fileExists(atPath: f.store.resolvedURL.path))
  }
  @Test func importPreservesUnconvertedAndBindingDiagnostics() throws {
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("producer")
    try f.write(
      "name: example\nversion: '1.0.0'\nscripts: {start: never-run}\n",
      to: input.appendingPathComponent("apm.yml"))
    let report = try SourceImportOperations.inspect(
      format: "apmManifest", root: input, document: "apm.yml")
    #expect(!report.diagnostics.isEmpty)
    #expect(report.diagnostics.allSatisfy { !$0.document.isEmpty && !$0.message.isEmpty })
    #expect(throws: (any Error).self) {
      try report.updateRequest(in: UpdateOperations.inspect(environment: f.environment))
    }
  }

  @Test func ordinarySiblingUpdateKeepsTheWholeSharedFilePrivate() throws {
    struct Provider: RuntimeBindingProvider {
      func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
        Data("shared-canary".utf8)
      }
    }
    let f = try UpdateFixture()
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("configured-claude"), withIntermediateDirectories: true)
    try f.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "private",
          transport: .stdio(
            .init(executable: "never-run", environment: ["TOKEN": .secret("token")])),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: Provider()
    ) { try $0.apply() }
    let user = StateStore(scope: .user, environment: f.environment)
    try user.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "ordinary", transport: .stdio(.init(executable: "never-run")), agents: [.claudeCode]
        )
      ]), ledger: ResolvedLedger())
    let preview = try UpdateOperations.preview(scope: .user, environment: f.environment)
    #expect(preview.components.allSatisfy { $0.privateMaterialization })
    #expect(
      !String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains("shared-canary"))
    _ = try UpdateOperations.withPreparedUpdate(scope: .user, environment: f.environment) {
      try $0.apply()
    }
    let target = try #require(
      UpdateOperations.inspect(scope: .user, environment: f.environment).deployments.first?.location
    )
    #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self).contains("shared-canary"))
    let mode =
      try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(
      try UpdateOperations.inspect(environment: f.environment).deployments.allSatisfy {
        $0.status == .current
      })
    try FileManager.default.removeItem(at: target)
    _ = try UpdateOperations.restore(environment: f.environment, bindingProvider: Provider())
    #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self).contains("shared-canary"))
  }

}
