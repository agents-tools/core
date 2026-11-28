import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation
import StateTestSupport
import Synchronization
import Testing

@testable import AgentsUpdates

@Suite("Ledger lifecycle composition")
struct LifecycleCompositionTests {
  @Test(arguments: [InstallMode.copy, .link])
  func exactColdRestoreKeepsFrozenOwnInstructionsAndSkillResources(_ mode: InstallMode) throws {
    let fixture = try UpdateFixture()
    let source = fixture.root.appendingPathComponent("local-skills")
    try fixture.write(
      "---\nname: frozen\ndescription: Frozen\n---\nOriginal skill\n",
      to: source.appendingPathComponent("frozen/SKILL.md"))
    let script = source.appendingPathComponent("frozen/run")
    try fixture.write("#!/bin/sh\nexit 0\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try fixture.write(
      "---\ndescription: Frozen\n---\n# Frozen\n\nOriginal instructions\n",
      to: fixture.root.appendingPathComponent(".agent/instructions/frozen.md"))
    try fixture.store.save(
      declaration: Declaration(
        sources: ["local": .init(kind: .local, location: source.path)],
        skills: ["local": .init(select: .all, agents: [.claudeCode], mode: mode)],
        instructions: .init(agents: [.codex], sections: ["frozen"])), ledger: ResolvedLedger())
    _ = try fixture.apply()
    let instruction = try fixture.bytes(fixture.instruction())
    let skill = try fixture.bytes(
      fixture.target(.claudeCode).deletingLastPathComponent().appendingPathComponent(
        "frozen/SKILL.md"))
    let cold = fixture.root.appendingPathComponent("cold")
    var environment = fixture.environment
    environment.projectDirectory = cold
    let store = StateStore(scope: .project, environment: environment)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try fixture.bytes(fixture.store.declarationURL).write(to: store.declarationURL)
    let locked = try fixture.bytes(fixture.store.resolvedURL)
    try locked.write(to: store.resolvedURL)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(
      at: fixture.root.appendingPathComponent(".agent/instructions"))
    _ = try UpdateOperations.restore(environment: environment)
    #expect(try Data(contentsOf: cold.appendingPathComponent("AGENTS.md")) == instruction)
    let restored = cold.appendingPathComponent(".claude/skills/frozen")
    #expect(try Data(contentsOf: restored.appendingPathComponent("SKILL.md")) == skill)
    let flags =
      try FileManager.default.attributesOfItem(atPath: restored.appendingPathComponent("run").path)[
        .posixPermissions] as? NSNumber
    #expect((flags?.intValue ?? 0) & 0o111 != 0)
    #expect(try Data(contentsOf: store.resolvedURL) == locked)
    #expect(
      try store.loadResolved().skills["frozen"]?.installs == [AgentID.claudeCode.rawValue: mode])
  }

  @Test func purePreviewAndStableFingerprintUseNoPersistentSourceWrites() throws {
    let fixture = try UpdateFixture()
    try fixture.declare(agents: [.claudeCode])
    let before = try FileHash.folderHash(fixture.root)
    let first = try fixture.preview()
    let second = try fixture.preview()
    #expect(first.displayedFingerprint == second.displayedFingerprint)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
    _ = try fixture.apply()
    let installed = try FileHash.folderHash(fixture.root)
    let request = UpdateRequest(operation: .restore)
    let a = try UpdateOperations.preview(request, environment: fixture.environment)
    let b = try UpdateOperations.preview(request, environment: fixture.environment)
    #expect(a.displayedFingerprint == b.displayedFingerprint)
    #expect(try FileHash.folderHash(fixture.root) == installed)
    #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) is [String: Any])
  }

  @Test func directSkillPinUpdatePreservesRecordedInstructionPinAndLastRemovalRetention() throws {
    let fixture = try UpdateFixture()
    try fixture.install(agents: [.claudeCode])
    let old = try fixture.store.loadResolved()
    let bytes = try fixture.bytes(fixture.instruction(.claudeCode))
    try fixture.advance()
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let updated = try fixture.store.loadResolved()
    #expect(updated.skills["demo"]?.revision != old.skills["demo"]?.revision)
    #expect(updated.instructions == old.instructions)
    #expect(try fixture.bytes(fixture.instruction(.claudeCode)) == bytes)
    _ = try SkillOperations.watchOperations().add("fixture", environment: fixture.environment)
    _ = try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    #expect(try SkillOperations.listManaged(environment: fixture.environment).isEmpty)
    #expect(try fixture.store.loadResolved().instructions == old.instructions)
    #expect(try fixture.bytes(fixture.instruction(.claudeCode)) == bytes)
    _ = try SkillOperations.watchOperations().status(environment: fixture.environment)
    _ = try SkillOperations.doctor(environment: fixture.environment)
    _ = try InstructionOperations.doctor(environment: fixture.environment)
    _ = try InstructionOperations.renderChatGPT(prompt: "weekly", environment: fixture.environment)
    _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
  }

  @Test func nativeSiblingsStayPrivateAndEqualUnmanagedValuesAreNotAdopted() throws {
    let fixture = try UpdateFixture()
    let declaration = Declaration(components: [
      .mcpServer(
        name: "server", transport: .stdio(.init(executable: "fixture-server")),
        agents: [.claudeCode])
    ])
    try fixture.store.save(declaration: declaration, ledger: ResolvedLedger())
    let native = fixture.root.appendingPathComponent(".mcp.json")
    try fixture.write("{\"unmanaged\":{\"secret\":\"private sibling sentinel\"}}\n", to: native)
    let report = try fixture.preview()
    #expect(
      !String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains(
        "private sibling sentinel"))
    _ = try fixture.apply()
    let owned = try fixture.bytes(native)
    #expect(String(decoding: owned, as: UTF8.self).contains("private sibling sentinel"))
    let original = try fixture.preview().displayedFingerprint
    try fixture.write(
      String(decoding: owned, as: UTF8.self).replacingOccurrences(
        of: "private sibling sentinel", with: "rotated private sibling"), to: native)
    #expect(try fixture.preview().displayedFingerprint == original)
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { prepared in
      try fixture.write(String(decoding: owned, as: UTF8.self), to: native)
      #expect(throws: UpdateApplyError.self) { try prepared.apply() }
    }
    try FileManager.default.removeItem(at: fixture.store.resolvedURL)
    let before = try FileHash.folderHash(fixture.root)
    #expect(throws: (any Error).self) { try fixture.preview() }
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func combinedFaultRollsBackSkillInstructionAndNativeOwnedKey() throws {
    let fixture = try UpdateFixture()
    try fixture.declare(agents: [.claudeCode])
    var declaration = try fixture.store.loadDeclaration()
    declaration.components.append(
      .mcpServer(
        name: "server", transport: .stdio(.init(executable: "before")), agents: [.claudeCode]))
    try fixture.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try fixture.apply()
    let native = fixture.root.appendingPathComponent(".mcp.json")
    let oldNative = try fixture.bytes(native)
    let before = try fixture.snapshot()
    try fixture.advance()
    declaration.components[declaration.components.count - 1] = .mcpServer(
      name: "server", transport: .stdio(.init(executable: "after")), agents: [.claudeCode])
    try fixture.store.save(declaration: declaration, ledger: fixture.store.loadLedger())
    let state = try fixture.snapshot()
    struct Interrupted: Error {}
    var interrupted = false
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { _ in
          if !interrupted, (try? fixture.bytes(native)) != oldNative {
            interrupted = true
            throw Interrupted()
          }
        }, { try $0.apply() })
    }
    #expect(interrupted)
    #expect(try fixture.snapshot() == state)
    #expect(try fixture.bytes(native) == oldNative)
    #expect(
      before[fixture.instruction(.claudeCode).path] == state[fixture.instruction(.claudeCode).path])
    _ = try fixture.apply()
    #expect(try fixture.bytes(native) != oldNative)
  }
}

private final class FixtureBindings: RuntimeBindingProvider {
  private let state = Mutex((calls: 0, value: "private literal sentinel"))
  var calls: Int { state.withLock { $0.calls } }
  var value: String {
    get { state.withLock { $0.value } }
    set { state.withLock { $0.value = newValue } }
  }
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    state.withLock {
      $0.calls += 1
      return Data($0.value.utf8)
    }
  }
}

extension LifecycleCompositionTests {
  @Test func literalBindingsStayInsidePrivateStagingAndDoNotChangeDisplayIdentity() throws {
    let fixture = try UpdateFixture()
    try fixture.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "bound",
          transport: .stdio(
            .init(executable: "fixture-server", environment: ["TOKEN": .secret("fixture-token")])),
          agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    var environment = fixture.environment
    environment.environment["CLAUDE_CONFIG_DIR"] = nil
    let provider = FixtureBindings()
    let request = UpdateRequest()
    try UpdateOperations.prepare(
      request, scope: .project, environment: environment, checkpoint: { _ in },
      provider: provider,
      { prepared in
        #expect(provider.calls == 0)
        let json = String(decoding: try JSONEncoder().encode(prepared.report), as: UTF8.self)
        #expect(!json.contains(provider.value))
        _ = try prepared.apply()
      })
    #expect(provider.calls == 1)
    let native = environment.homeDirectory.appendingPathComponent(".claude.json")
    #expect(String(decoding: try fixture.bytes(native), as: UTF8.self).contains(provider.value))
    #expect(
      !String(decoding: try fixture.bytes(fixture.store.resolvedURL), as: UTF8.self).contains(
        provider.value))
    let a = try UpdateOperations.preview(environment: environment).displayedFingerprint
    provider.value = "rotated private literal"
    try UpdateOperations.prepare(
      request, scope: .project, environment: environment, checkpoint: { _ in },
      provider: provider,
      { prepared in
        #expect(prepared.report.displayedFingerprint == a)
        #expect(provider.calls == 1)
        _ = try prepared.apply()
      })
    #expect(provider.calls == 2)
    #expect(try UpdateOperations.preview(environment: environment).displayedFingerprint == a)
    let mode =
      try FileManager.default.attributesOfItem(atPath: native.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
  }

  @Test(arguments: [false, true])
  func producerOwnedSkillCannotBeRemovedAndChangedProtectedGroupRequiresCombinedUpdate(
    nonCanonical: Bool
  ) throws {
    let fixture = try UpdateFixture()
    if nonCanonical {
      try fixture.write(
        "---\nname: Demo Skill\ndescription: Producer skill\n---\nOriginal\n",
        to: fixture.repo.appendingPathComponent("skills/demo/SKILL.md"))
    }
    try fixture.write(
      """
      version: 1
      components: []
      groups:
        skills:
          components: [{kind: skills, source: ., select: all, mode: copy, agents: [claude-code]}]
        tools:
          components: [{kind: mcpServer, name: server, transport: {kind: stdio, executable: before}, agents: [claude-code]}]
      exports: [skills, tools]
      """, to: fixture.repo.appendingPathComponent(".agent/agents.yaml"))
    try fixture.commit()
    try fixture.write(
      """
      version: 1
      sources:
        producer: {path: \(fixture.repo.path)}
      uses:
        - {source: producer, group: skills}
        - {source: producer, group: tools}
      """, to: fixture.store.declarationURL)
    _ = try fixture.apply()
    let before = try fixture.snapshot()
    #expect {
      try SkillOperations.remove(
        skillNames: [nonCanonical ? "demo-skill" : "demo"], environment: fixture.environment)
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("notEditableHere") && reason.contains(fixture.repo.path)
        && reason.contains("#skills")
    }
    #expect(try fixture.snapshot() == before)
    let manifest = fixture.repo.appendingPathComponent(".agent/agents.yaml")
    let changed = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(
      of: "executable: before", with: "executable: after")
    try fixture.write(changed, to: manifest)
    try fixture.writeSource("new producer skill")
    try fixture.commit()
    do {
      _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
      Issue.record("protected producer group was changed by skill-only update")
    } catch let error as CoreError {
      #expect(error.description.contains("requiresCombinedUpdate"))
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func completeYAMLEditPreservesUnusedIntentAndChangesItsDisplayIdentity() throws {
    let fixture = try UpdateFixture()
    try fixture.write(
      """
      # retained preamble
      version: 1
      components:
        - {kind: mcpServer, name: inactive, transport: {kind: stdio, executable: fixture}, agents: [], native: {claude-code: {value: !!float 1.00}}}
      groups:
        unused:
          components: [{kind: ignore, name: unused, patterns: [build], condition: {platforms: []}}]
      """, to: fixture.store.declarationURL)
    let before = try fixture.bytes(fixture.store.declarationURL)
    let a = try fixture.preview().displayedFingerprint
    let document = try #require(try fixture.store.loadManifest())
    let request = UpdateRequest(
      operation: .edit([.setDefaultAgents([.claudeCode])]),
      expectedDeclarationDigest: document.digest)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
      try $0.apply()
    }
    let after = try fixture.bytes(fixture.store.declarationURL)
    let text = String(decoding: after, as: UTF8.self)
    #expect(text.contains("# retained preamble") && text.contains("!!float 1.00"))
    #expect(text.contains("unused:") && text.contains("platforms: []"))
    #expect(after != before)
    #expect(try fixture.preview().displayedFingerprint != a)
    #expect(try fixture.store.loadDeclaration().groups.count == 1)
  }
}

extension LifecycleCompositionTests {
  @Test func nonGitSeparateGroupsSharingAProducerProtectActualNativeSemantics() throws {
    let fixture = try UpdateFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.write(
      "---\nname: demo\ndescription: Local\n---\nBefore\n",
      to: producer.appendingPathComponent("skills/demo/SKILL.md"))
    try fixture.write(
      """
      version: 1
      groups:
        skills:
          components: [{kind: skills, source: ., select: [demo], mode: copy, agents: [claude-code]}]
        tools:
          components: [{kind: mcpServer, name: stable, transport: {kind: stdio, executable: fixture-server}, agents: [claude-code]}]
      exports: [skills, tools]
      """, to: producer.appendingPathComponent(".agent/agents.yaml"))
    try fixture.write(
      """
      version: 1
      sources: {producer: {path: \(producer.path)}}
      uses: [{source: producer, group: skills}, {source: producer, group: tools}]
      """, to: fixture.store.declarationURL)
    _ = try fixture.apply()
    let native = fixture.root.appendingPathComponent(".mcp.json")
    let bytes = try fixture.bytes(native)
    try fixture.write(
      "---\nname: demo\ndescription: Local\n---\nAfter\n",
      to: producer.appendingPathComponent("skills/demo/SKILL.md"))
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.bytes(native) == bytes)
    #expect(
      String(
        decoding: try fixture.bytes(fixture.target(.claudeCode).appendingPathComponent("SKILL.md")),
        as: UTF8.self
      ).contains("After"))
  }
}

extension LifecycleCompositionTests {
  @Test func sameSkillNameFromDisjointSourcesKeepsSeparatePublicInventoryAndReport() throws {
    let fixture = try UpdateFixture()
    let second = fixture.root.appendingPathComponent("second")
    try fixture.write(
      "---\nname: demo\ndescription: Other\n---\nSecond\n",
      to: second.appendingPathComponent("skills/demo/SKILL.md"))
    try fixture.store.save(
      declaration: Declaration(
        sources: [
          "first": .init(kind: .local, location: fixture.repo.path),
          "second": .init(kind: .local, location: second.path),
        ],
        components: [
          .skills(source: "first", .init(select: .all, agents: [.codex], mode: .copy)),
          .skills(source: "second", .init(select: .all, agents: [.claudeCode], mode: .copy)),
        ]), ledger: ResolvedLedger())
    let report = try fixture.preview()
    #expect(report.skills.count == 2)
    #expect(Set(report.skills.map(\.sourceIdentity)).count == 2)
    _ = try fixture.apply()
    let inventory = try SkillOperations.listManaged(environment: fixture.environment)
    #expect(Set(inventory.compactMap(\.sourceIdentity)).count == 2)
    #expect(Set(inventory.map(\.agent)) == [.codex, .claudeCode])
    #expect(
      try fixture.store.loadLedger().components.values.filter { $0.kind == "skills" }.count == 2)
  }
}

extension LifecycleCompositionTests {
  @Test func forwardingSiblingsStayPrivateWhileFreshnessRemainsStrict() throws {
    let fixture = try UpdateFixture()
    try fixture.declare(agents: [.claudeCode])
    let file = fixture.root.appendingPathComponent("CLAUDE.md")
    try fixture.write("# Private sibling sentinel\n", to: file)
    let report = try fixture.preview()
    let decoded = try JSONDecoder().decode(
      CombinedUpdateReport.self, from: JSONEncoder().encode(report))
    let forwarding = try #require(
      decoded.instructions.outputs.first { $0.fileURL?.path == file.path })
    #expect(forwarding.content == Data(ClaudeForwarding.renderBlock(for: .root).utf8))
    _ = try fixture.apply()
    let before = try fixture.bytes(file)
    let fingerprint = try fixture.preview().displayedFingerprint
    try fixture.write(
      String(decoding: before, as: UTF8.self).replacingOccurrences(
        of: "Private sibling sentinel", with: "Rotated sibling"), to: file)
    #expect(try fixture.preview().displayedFingerprint == fingerprint)
    try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      try before.write(to: file)
      #expect(throws: UpdateApplyError.self) { try update.apply() }
    }
    #expect(try fixture.bytes(file) == before)
  }
}

extension LifecycleCompositionTests {
  @Test func unusedDeclarationEditsInvalidateASelectedSkillPreparation() throws {
    let fixture = try UpdateFixture()
    try fixture.install(agents: [.codex])
    let authored =
      String(decoding: try fixture.bytes(fixture.store.declarationURL), as: UTF8.self)
      + "\ngroups:\n  unused: {components: [{kind: ignore, name: draft, patterns: [build]}]}\n"
    try fixture.write(authored, to: fixture.store.declarationURL)
    try fixture.advance()
    let ledger = try fixture.bytes(fixture.store.resolvedURL)
    let target = try FileHash.folderHash(fixture.target())
    var edited = Data()
    try UpdateOperations.withPreparedUpdate(
      UpdateRequest(kinds: [.skills]), environment: fixture.environment
    ) { prepared in
      edited = Data(
        authored.replacingOccurrences(of: "patterns: [build]", with: "patterns: [cache]").utf8)
      try edited.write(to: fixture.store.declarationURL)
      #expect { try prepared.apply() } throws: { error in
        guard let failure = error as? UpdateApplyError,
          case .unchanged = failure.disposition,
          case CoreError.invalidState(let reason) = failure.underlyingError
        else { return false }
        return reason.contains("changed during preparation")
      }
    }
    #expect(try fixture.bytes(fixture.store.declarationURL) == edited)
    #expect(try fixture.bytes(fixture.store.resolvedURL) == ledger)
    #expect(try FileHash.folderHash(fixture.target()) == target)
    #expect(try fixture.store.loadDeclaration().groups.count == 1)
    #expect(try fixture.store.loadLedger().version == 2)
  }
}
