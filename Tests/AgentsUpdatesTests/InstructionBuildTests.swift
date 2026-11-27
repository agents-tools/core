import AgentsCore
import AgentsInstructions
import AgentsUpdates
import Foundation
import Testing

struct InstructionBuildTests {
  @Test func outputPreviewSkipsUnrelatedNativePluginMembers() throws {
    let fixture = try UpdateFixture()
    try fixture.write(
      #"{"name":"review"}"#,
      to: fixture.root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
    try fixture.write(
      "# Invalid sample\n", to: fixture.root.appendingPathComponent("plugin/skills/broken/SKILL.md")
    )
    try fixture.write(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - {kind: plugin, name: review, path: plugin, source: ".", mode: components}
        - kind: instructions
          sections: [{name: rules, source: fixture, recipients: [codex, chatgpt-app]}]
      """, to: fixture.store.declarationURL)
    let before = try fixture.snapshot()
    let outputs = try InstructionOperations.previewOutputs(environment: fixture.environment)
      .instructions.outputs
    #expect(Set(outputs.map(\.recipient)) == [.local(.codex), .chatGPTApp])
    let copy = try #require(outputs.first { $0.recipient == .chatGPTApp })
    #expect(copy.content == Data("# Rules\n\nold\n".utf8))
    #expect {
      try InstructionOperations.previewCompilation(environment: fixture.environment)
    } throws: { error in
      String(describing: error).contains("native plugin invalidInput")
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func namedSkillsValidateOnlyTheirOwnRetainedRevision() throws {
    let fixture = try UpdateFixture()
    let a = fixture.repo.appendingPathComponent("skills/a/SKILL.md")
    let b = fixture.repo.appendingPathComponent("skills/b/SKILL.md")
    let oldA = "---\nname: a\ndescription: A\n---\nOld A\n"
    let newB = "---\nname: b\ndescription: B\n---\nNew B\n"
    try fixture.write(oldA, to: a)
    try fixture.write("# Malformed old B\n", to: b)
    try fixture.commit()
    let old = try fixture.git(["rev-parse", "HEAD"])
    func declaration(_ names: [String]) -> Declaration {
      Declaration(
        sources: ["fixture": .init(kind: .local, location: fixture.repo.path)],
        skills: ["fixture": .init(select: .names(names), agents: [.codex], mode: .copy)])
    }
    func apply(_ names: [String]) throws {
      let request = UpdateRequest(operation: .declaration(declaration(names)))
      _ = try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
        try $0.apply()
      }
    }
    try apply(["a"])
    try fixture.write("# Malformed new A\n", to: a)
    try fixture.write(newB, to: b)
    try fixture.commit()
    let latest = try fixture.git(["rev-parse", "HEAD"])
    try apply(["a", "b"])
    let skills = try fixture.store.loadResolved().skills
    #expect(skills["a"]?.revision == old)
    #expect(skills["b"]?.revision == latest)
    let targets = fixture.target().deletingLastPathComponent()
    #expect(try fixture.bytes(targets.appendingPathComponent("a/SKILL.md")) == Data(oldA.utf8))
    #expect(try fixture.bytes(targets.appendingPathComponent("b/SKILL.md")) == Data(newB.utf8))
    let before = try fixture.snapshot()
    _ = try InstructionOperations.previewCompilation(environment: fixture.environment)
    #expect(try fixture.snapshot() == before)
  }

  @Test func compilationWithNamedSkillsIgnoresUnselectedMalformedSamples() throws {
    let fixture = try UpdateFixture(scope: .user)
    let sample = "scripts/skill-format-check/tests/missing-fields/SKILL.md"
    try fixture.write("# Invalid sample\n", to: fixture.repo.appendingPathComponent(sample))
    try fixture.commit()
    let yaml = """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - kind: skills
          source: fixture
          path: skills
          select: [demo]
          agents: [codex]
        - kind: instructions
          sections: [{name: rules, source: fixture, recipients: [codex, chatgpt-app]}]
      """
    try fixture.write(yaml, to: fixture.store.declarationURL)
    let installed = try fixture.apply().report.instructions.outputs
    try fixture.write(
      yaml.replacingOccurrences(of: "    path: skills\n", with: ""),
      to: fixture.store.declarationURL)
    let before = try fixture.snapshot()

    let compile = try InstructionOperations.previewCompilation(
      scope: .user, environment: fixture.environment)
    #expect(compile.report.instructions.outputs == installed)
    #expect(compile.report.skills.isEmpty)
    #expect(try fixture.snapshot() == before)

    try fixture.write(
      yaml.replacingOccurrences(of: "    path: skills\n", with: "")
        .replacingOccurrences(of: "select: [demo]", with: "select: [missing-fields]"),
      to: fixture.store.declarationURL)
    let malformedSelection = try fixture.snapshot()
    let outputs = try InstructionOperations.previewOutputs(
      scope: .user, environment: fixture.environment)
    #expect(outputs.instructions.outputs == installed)
    #expect(outputs.skills.isEmpty && outputs.components.isEmpty)
    #expect(try fixture.snapshot() == malformedSelection)
    #expect {
      try InstructionOperations.previewCompilation(scope: .user, environment: fixture.environment)
    } throws: { error in
      String(describing: error).contains(sample)
    }
    #expect(try fixture.snapshot() == malformedSelection)
  }

  @Test(arguments: ["missing-fields", "broken-by-name", "all"])
  func selectedMalformedSkillsReportTheirSourceRelativePaths(_ selection: String) throws {
    let fixture = try UpdateFixture()
    let leaf = selection == "broken-by-name" ? "different-directory" : "missing-fields"
    let sample = "scripts/skill-format-check/tests/\(leaf)/SKILL.md"
    try fixture.write(
      selection == "broken-by-name" ? "---\nname: broken-by-name\n---\n# Invalid\n" : "# Invalid\n",
      to: fixture.repo.appendingPathComponent(sample))
    try fixture.commit()
    try fixture.write(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - kind: skills
          source: fixture
          select: \(selection == "all" ? "all" : "[\(selection)]")
          agents: [codex]
      """, to: fixture.store.declarationURL)
    let before = try fixture.snapshot()
    #expect {
      try fixture.preview()
    } throws: { error in
      String(describing: error).contains(sample)
        && String(describing: error).contains("requires name and description")
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func previewsAndAppliesTheSameCandidateBytes() throws {
    let fixture = try UpdateFixture()
    let shared = fixture.instruction()
    let forwarding = fixture.root.appendingPathComponent("CLAUDE.md")
    let original = "Custom Claude content.\n"
    try fixture.write(original, to: forwarding)
    try fixture.write(
      "---\ndescription: Own section\n---\n# Own section\n\nProject content.\n",
      to: fixture.root.appendingPathComponent(".agent/instructions/rules.md"))
    let yaml = """
      version: 1
      defaultAgents: [codex, claude-code]
      sources:
        team/rules: {path: ./source}
      components:
        - {kind: skills, source: team/rules, select: [demo], agents: [codex], mode: copy}
        - kind: instructions
          sections:
            - {name: rules, source: team/rules, recipients: [chatgpt-app, gemini-app]}
            - {name: rules, recipients: [codex, claude-code, chatgpt-app]}
            - {name: rules, source: team/rules, recipients: [gemini-app], condition: {scopes: [user]}}
          chatgpt:
            weekly:
              sections: [{name: rules, source: team/rules}]
      """
    let request = UpdateRequest(
      declarationYAML: Data(yaml.utf8), expectedDeclarationDigest: "absent")
    let preview = try UpdateOperations.preview(request, environment: fixture.environment)
    let outputs = preview.instructions.outputs
    #expect(outputs.count == 5)
    #expect(Set(outputs.map(\.id)).count == 5)
    let chatGPT = try #require(outputs.first { $0.recipient == .chatGPTApp })
    let gemini = try #require(outputs.first { $0.recipient == .geminiApp })
    #expect(chatGPT.fileURL == nil && gemini.fileURL == nil)
    #expect(
      String(decoding: chatGPT.content, as: UTF8.self)
        == "# Rules\n\nold\n\n# Own section\n\nProject content.\n")
    #expect(String(decoding: gemini.content, as: UTF8.self) == "# Rules\n\nold\n")
    let local = outputs.filter { $0.fileURL?.path == shared.path }
    #expect(Set(local.map(\.recipient)) == [.local(.codex), .local(.claudeCode)])
    #expect(Set(local.map(\.content)).count == 1)
    #expect(local.allSatisfy { !String(decoding: $0.content, as: UTF8.self).contains("old") })
    let claude = try #require(outputs.first { $0.fileURL?.path == forwarding.path })
    #expect(String(decoding: claude.content, as: UTF8.self).hasSuffix(original))
    #expect(String(decoding: claude.content, as: UTF8.self).contains("@AGENTS.md"))
    #expect(!FileManager.default.fileExists(atPath: shared.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    #expect(try fixture.bytes(forwarding) == Data(original.utf8))

    let applied = try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment)
    {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(applied.report.instructions.outputs == outputs)
    for output in outputs {
      if let file = output.fileURL { #expect(try fixture.bytes(file) == output.content) }
    }
    let unchanged = try fixture.preview().instructions
    #expect(!unchanged.hasChanges)
    #expect(unchanged.outputs == outputs)
    let prompt = try InstructionOperations.renderChatGPT(
      prompt: "weekly", environment: fixture.environment)
    #expect(prompt == gemini.content)

    func inspectedUnits() throws -> [ComponentInspection] {
      try UpdateOperations.inspect(environment: fixture.environment).components.filter {
        $0.kind == .instructions
      }
    }
    let units = try inspectedUnits()
    #expect(units.count == 4)
    let mixed = try #require(units.first { !$0.recipients.isEmpty })
    #expect(mixed.copyRecipients == [.chatGPTApp])
    let copyOnly = try #require(units.first { $0.copyRecipients.count == 2 })
    #expect(copyOnly.recipients.isEmpty && copyOnly.copyRecipients == [.chatGPTApp, .geminiApp])
    #expect(
      units.filter { $0.chatGPT || $0.conditions.contains { $0.scopes == [.user] } }
        .allSatisfy { $0.copyRecipients.isEmpty })

    try FileManager.default.removeItem(at: fixture.target())
    let partial = UpdateRequest(kinds: [.skills])
    let repaired = try UpdateOperations.withPreparedUpdate(
      partial, environment: fixture.environment
    ) {
      try $0.apply()
    }
    #expect(repaired.report.instructions.outputs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.target().path))
    #expect(try inspectedUnits().map(\.copyRecipients) == units.map(\.copyRecipients))
  }

  @Test func addingLocalsPreservesExplicitRecipientsAndDistinctOccurrences() throws {
    let fixture = try UpdateFixture(scope: .user)
    try fixture.write(
      "---\ndescription: Other.\n---\n# Other rules\n\nOther source content.\n",
      to: fixture.repo.appendingPathComponent("other/instructions/rules.md"))
    try fixture.commit()
    try fixture.write(
      """
      version: 1
      defaultAgents: [codex]
      sources:
        team/rules: {path: ./source}
        team/other: {path: ./source, subpath: other}
      components:
        - kind: instructions
          sections:
            - {name: rules, source: team/rules, recipients: [gemini-cli, gemini-app], condition: {scopes: [project]}}
            - {name: rules, source: team/rules, recipients: [codex, chatgpt-app], condition: {scopes: [user]}}
            - {name: rules, source: team/other, recipients: [gemini-app]}
      """, to: fixture.store.declarationURL)
    let baseline = try fixture.apply().report.instructions.outputs
    let original = try fixture.store.loadDeclaration()
    let snapshot = try fixture.snapshot()
    #expect(throws: CoreError.self) {
      try InstructionOperations.add(
        .init(
          source: fixture.repo.path, alias: "team/other", scope: .user,
          environment: fixture.environment))
    }

    func add(_ agents: [AgentID]? = nil) throws -> InstructionUpdateReport {
      let result = try InstructionOperations.add(
        .init(
          source: fixture.repo.path, names: ["rules"], agents: agents, scope: .user,
          environment: fixture.environment))
      return try #require(result.result)
    }
    #expect(try !add().hasChanges)
    #expect(try fixture.snapshot() == snapshot)

    let added = try add([.geminiCLI, .codex])
    let before = try #require(try original.instructions)
    let after = try #require(try fixture.store.loadDeclaration().instructions)
    #expect(after.sectionReferences.map(\.reference) == before.sectionReferences.map(\.reference))
    #expect(after.sectionReferences[0] == before.sectionReferences[0])
    #expect(after.sectionReferences[2] == before.sectionReferences[2])
    #expect(after.sectionReferences[1].condition == before.sectionReferences[1].condition)
    #expect(
      after.sectionReferences[1].recipients == [.local(.codex), .chatGPTApp, .local(.geminiCLI)])
    #expect(added.outputs.filter { $0.recipient != .local(.geminiCLI) } == baseline)
    let gemini = try #require(added.outputs.first { $0.recipient == .local(.geminiCLI) })
    #expect(try fixture.bytes(fixture.instruction(.geminiCLI)) == gemini.content)

    let updated = try fixture.snapshot()
    #expect(try !add([.geminiCLI, .codex]).hasChanges)
    #expect(try fixture.snapshot() == updated)
  }

  @Test func copyOnlyBuildUsesItsScopeAndReplaysWithoutDeployments() throws {
    let fixture = try UpdateFixture(scope: .user)
    try fixture.write(
      "---\ndescription: Project section\n---\n# Project section\n",
      to: fixture.root.appendingPathComponent(".agent/instructions/separate.md"))
    let project = StateStore(scope: .project, environment: fixture.environment)
    try fixture.write(
      """
      version: 1
      components:
        - kind: instructions
          sections: [{name: separate, recipients: [chatgpt-app]}]
      """, to: project.declarationURL)
    let user = """
      version: 1
      defaultAgents: [codex, claude-code]
      sources:
        team/rules: {path: ./source}
      components:
        - kind: instructions
          sections:
            - {name: rules, source: team/rules, recipients: [chatgpt-app]}
      """
    try fixture.write(user, to: fixture.store.declarationURL)
    let preview = try fixture.preview().instructions
    let output = try #require(preview.outputs.first)
    #expect(preview.outputs.count == 1)
    #expect(preview.hasChanges && preview.targets.isEmpty)
    #expect(output.recipient == .chatGPTApp && output.fileURL == nil)
    #expect(String(decoding: output.content, as: UTF8.self) == "# Rules\n\nold\n")

    let lock = fixture.store.resolvedURL
    #expect(!FileManager.default.fileExists(atPath: lock.path))
    #expect(try fixture.apply().report.instructions.outputs == preview.outputs)
    #expect(try fixture.store.loadResolved().instructions.targets.isEmpty)
    let before = try fixture.bytes(lock)
    try fixture.advance()
    let restored = try InstructionOperations.installResolvedReport(
      scope: .user, environment: fixture.environment)
    #expect(restored.outputs == preview.outputs)
    #expect(restored.targets.isEmpty && !restored.hasChanges)
    #expect(try fixture.bytes(lock) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.instruction().path))
  }

  @Test func addingLocalsKeepsPlatformSpecificRoutesDisjoint() throws {
    let fixture = try UpdateFixture(scope: .user)
    #if os(macOS)
      let current = DeclarationPlatform.macOS
      let other = DeclarationPlatform.linux
    #else
      let current = DeclarationPlatform.linux
      let other = DeclarationPlatform.macOS
    #endif
    try fixture.write(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - kind: instructions
          sections:
            - {name: rules, source: fixture, recipients: [codex, chatgpt-app]}
            - {name: rules, source: fixture, recipients: [gemini-cli], condition: {platforms: [\(other.rawValue)]}}
      """, to: fixture.store.declarationURL)
    _ = try fixture.apply()
    let original = try #require(try fixture.store.loadDeclaration().instructions)
    let options = InstructionAddOptions(
      source: "fixture", agents: [.geminiCLI], scope: .user, environment: fixture.environment)
    let added = try InstructionOperations.add(options)
    #expect(added.result?.outputs.contains { $0.recipient == .local(.geminiCLI) } == true)
    let selections = try fixture.store.loadDeclaration().components.compactMap {
      component -> InstructionsDeclaration? in
      if case .instructions(let selection) = component { return selection }
      return nil
    }
    #expect(selections.first == original)
    let fallback = try #require(selections.last?.sectionReferences.last)
    #expect(fallback.condition == DeclarationCondition(scopes: [.user], platforms: [current]))
    #expect(try InstructionOperations.add(options).result?.hasChanges == false)
  }

  @Test func addingLocalsUsesOnlyEffectiveRecipientsOfActiveNestedGroups() throws {
    let fixture = try UpdateFixture(scope: .user)
    try fixture.write(
      "---\ndescription: Extra rules\n---\n# Extra rules\n",
      to: fixture.repo.appendingPathComponent("instructions/extra.md"))
    try fixture.commit()
    try fixture.write(
      """
      version: 1
      defaultAgents: [codex]
      sources: {team/rules: {path: ./source}}
      groups:
        leaf:
          components:
            - kind: instructions
              sections: [{name: rules, source: team/rules, recipients: [codex, gemini-cli, chatgpt-app]}]
        nested:
          uses: [{group: leaf, condition: {agents: [codex]}}]
        inactive:
          components:
            - kind: instructions
              sections: [{name: rules, source: team/rules, recipients: [gemini-cli]}]
        unused:
          components:
            - kind: instructions
              sections: [{name: rules, source: team/rules, recipients: [gemini-cli]}]
        unrelated:
          components:
            - kind: instructions
              sections: [{name: extra, source: team/rules, recipients: [opencode]}]
      uses: [{group: nested}, {group: inactive, condition: {scopes: [project]}}, {group: unrelated}]
      """, to: fixture.store.declarationURL)
    let outputs = try fixture.apply().report.instructions.outputs
    let copy = try #require(outputs.first { $0.recipient == .chatGPTApp })
    let codex = try fixture.bytes(fixture.instruction())
    let original = try fixture.store.loadDeclaration()
    let unrelated = fixture.instruction(.opencode)
    try FileManager.default.removeItem(at: unrelated)
    let before = try fixture.snapshot()

    func add(_ agents: [AgentID]) throws -> InstructionUpdateReport {
      let outcome = try InstructionOperations.add(
        .init(
          source: "team/rules", names: ["rules"], agents: agents, scope: .user,
          environment: fixture.environment))
      return try #require(outcome.result)
    }
    #expect(try !add([.codex]).hasChanges)
    #expect(try fixture.snapshot() == before)

    let added = try add([.codex, .geminiCLI])
    let declaration = try fixture.store.loadDeclaration()
    #expect(declaration.groups == original.groups && declaration.uses == original.uses)
    let instructions = try #require(try declaration.instructions)
    #expect(instructions.agents == [.geminiCLI])
    #expect(instructions.sectionReferences.map(\.reference) == ["team/rules:rules"])
    #expect(added.outputs.first { $0.recipient == .chatGPTApp } == copy)
    #expect(try fixture.bytes(fixture.instruction(.geminiCLI)) == codex)
    #expect(try fixture.bytes(fixture.instruction()) == codex)
    #expect(!FileManager.default.fileExists(atPath: unrelated.path))
    let updated = try fixture.snapshot()
    #expect(try !add([.codex, .geminiCLI]).hasChanges)
    #expect(try fixture.snapshot() == updated)
  }

  @Test func olderReportsDecodeWithoutBuildOutputs() throws {
    let json = """
      {"sections":[],"targets":[],"changedPrompts":[],"lockMissing":false,"hasChanges":false}
      """
    let decoded = try JSONDecoder().decode(InstructionUpdateReport.self, from: Data(json.utf8))
    #expect(decoded.outputs.isEmpty)
  }

  @Test func addingLocalCanReuseTheGroupsExactSharedTarget() throws {
    let fixture = try UpdateFixture()
    try fixture.write(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      groups:
        shared:
          components:
            - kind: instructions
              sections: [{name: rules, source: fixture, recipients: [codex, chatgpt-app]}]
      uses: [{group: shared}]
      """, to: fixture.store.declarationURL)
    let file = fixture.instruction()
    let declaration = try fixture.bytes(fixture.store.declarationURL)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let codex = InstructionAddOptions(
      source: "fixture", names: ["rules"], agents: [.codex], environment: fixture.environment)
    let initial = try #require(try InstructionOperations.add(codex).result)
    #expect(initial.hasChanges)
    #expect(FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    #expect(initial.targets.map(\.afterAgents) == [[.codex]])
    #expect(Set(initial.outputs.map(\.recipient)) == [.local(.codex), .chatGPTApp])
    #expect(try fixture.bytes(fixture.store.declarationURL) == declaration)
    let before = try fixture.bytes(file)
    #expect(initial.outputs.first { $0.recipient == .local(.codex) }?.content == before)
    let applied = try fixture.snapshot()
    #expect(try InstructionOperations.add(codex).result?.hasChanges == false)
    #expect(try fixture.snapshot() == applied)

    let options = InstructionAddOptions(
      source: "fixture", agents: [.codex, .claudeCode], environment: fixture.environment)
    let added = try InstructionOperations.add(options)
    #expect(added.result?.targets.first { $0.url == file }?.afterAgents == [.claudeCode, .codex])
    #expect(try fixture.bytes(file) == before)
    let mapping = InstructionOperations.export(
      projectRoots: [fixture.root], environment: fixture.environment)
    #expect(
      mapping.first { $0.scope == .project }?.targets.first?.sections.map(\.name) == ["rules"])
    #expect(try InstructionOperations.add(options).result?.hasChanges == false)
  }

  @Test func readdingAnExportedGroupsSourceLeavesBothDeclarationsIntact() throws {
    let fixture = try UpdateFixture(scope: .user)
    let producer = try UpdateFixture()
    let producerManifest = producer.repo.appendingPathComponent(".agent/agents.yaml")
    try producer.write(
      """
      version: 1
      sources: {payload: {path: "\(fixture.repo.path)"}}
      exports: [rules]
      groups:
        rules:
          components:
            - kind: instructions
              sections: [{name: rules, source: payload, recipients: [codex, chatgpt-app]}]
      """, to: producerManifest)
    try producer.commit()
    try fixture.write(
      """
      version: 1
      sources: {producer: {path: "\(producer.repo.path)"}}
      uses: [{group: rules, source: producer}]
      """, to: fixture.store.declarationURL)
    _ = try fixture.apply()
    let before = try fixture.snapshot()
    let upstream = try producer.bytes(producerManifest)
    let result = try InstructionOperations.add(
      .init(
        source: fixture.repo.path, agents: [.codex], scope: .user,
        environment: fixture.environment))
    #expect(result.result?.hasChanges == false)
    #expect(try fixture.snapshot() == before)
    #expect(try producer.bytes(producerManifest) == upstream)
  }
}
