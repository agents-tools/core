import AgentsCore
import Foundation
import Testing

@testable import AgentsUpdates
@testable import Components

struct SourceImportSelectionTests {
  @Test func oneProducerKeyShowsEveryFamilyAndFixedContributions() throws {
    let f = try ImportSelectionFixture()
    let text =
      #"{"mcp":{"servers":{"same":{"type":"local","command":["never-run"]}}},"commands":{"same":{"template":"Review"},"other":{"template":"Other"}},"agents":{"same":{"system":"Review","mode":"subagent"}},"lsp":{"fixed":{"command":["never-run"]}}}"#
    try f.write("opencode.json", text)
    let before = try FileHash.folderHash(f.root)
    let report = try SourceImportOperations.inspect(
      format: "openCodeConfigV2", root: f.root, document: "opencode.json")
    let shared = try #require(report.availableChoices.first { $0.effects.components.count == 3 })
    #expect(
      Set(shared.effects.components.map(\.declaration.kind)) == [.mcpServer, .command, .subagent])
    #expect(report.fixedEffects.components.map(\.declaration.kind) == [.lspServer])
    let selected = try report.resolving(choices: [shared.id])
    #expect(selected.components.count == 4)
    let empty = try report.resolving(choices: [])
    #expect(empty.components.map(\.declaration.kind) == [.lspServer])
    #expect(throws: (any Error).self) { try selected.resolving(choices: [shared.id]) }
    #expect(try FileHash.folderHash(f.root) == before)
    try f.write("opencode.json", "{}")
    #expect(throws: (any Error).self) { try report.resolving(choices: [shared.id]) }
  }

  @Test func linkedSkillSupportingBytesInvalidateResolution() throws {
    let f = try ImportSelectionFixture()
    try f.write("bundle/.claude-plugin/plugin.json", #"{"name":"producer"}"#)
    try f.write(
      "bundle/skills/helper/SKILL.md", "---\nname: helper\ndescription: Helper\n---\nBody\n")
    try f.write("bundle/shared/tool.txt", "Original support\n")
    try FileManager.default.createSymbolicLink(
      atPath: f.root.appendingPathComponent("bundle/skills/helper/reference.txt").path,
      withDestinationPath: "../../shared/tool.txt")
    let report = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    #expect(report.diagnostics.isEmpty)
    let support = try #require(report.resources.first { $0.path == "shared/tool.txt" })
    #expect(support.hash == nil && !support.requiresBindingRewrite)
    try f.write("bundle/shared/tool.txt", "Modified support\n")
    #expect(throws: (any Error).self) { try report.resolving() }
    let refreshed = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    #expect(try refreshed.resolving().diagnostics.isEmpty)
  }

  @Test func supportingBytesInvalidateCapturedRequestPreparation() throws {
    let f = try ImportSelectionFixture()
    try f.write("bundle/.claude-plugin/plugin.json", #"{"name":"producer"}"#)
    try f.write(
      "bundle/commands/review.md",
      "---\ndescription: Review\n---\nUse [support](../shared/tool.txt).\n")
    try f.write("bundle/shared/tool.txt", "Original support\n")
    let environment = RuntimeEnvironment(
      projectDirectory: f.root, homeDirectory: f.root, environment: [:])
    let scope = try UpdateOperations.inspect(environment: environment)
    let report = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    #expect(report.diagnostics.isEmpty)
    let request = try report.updateRequest(in: scope)
    try f.write("bundle/shared/tool.txt", "Modified support\n")
    #expect(throws: (any Error).self) { try report.resolving() }
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(request, environment: environment) { _ in
        Issue.record("Stale supporting content must not reach the prepared handle")
      }
    }
    let refreshed = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    let freshRequest = try refreshed.updateRequest(in: scope)
    _ = try UpdateOperations.preview(freshRequest, environment: environment)
  }

  @Test func literalSupportingBytesRemainPrivateAndFreshAfterSymbolicResolution() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"producer","lspServers":"./shared/language.json"}"#)
    try f.write(
      "bundle/skills/helper/SKILL.md", "---\nname: helper\ndescription: Helper\n---\nBody\n")
    let original =
      #"{"review":{"command":"never-run","extensionToLanguage":{".txt":"text"},"env":{"TOKEN":"PRIVATE_SUPPORT_A"}}}"#
    try f.write("bundle/shared/language.json", original)
    try FileManager.default.createSymbolicLink(
      atPath: f.root.appendingPathComponent("bundle/skills/helper/reference.txt").path,
      withDestinationPath: "../../shared/language.json")
    let report = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    let slot = try #require(report.requiredInputs.first { $0.kind == .bindingReference })
    let resolved = try report.resolving(inputs: [
      .init(id: slot.id, value: .binding(.environment("SUPPORT_TOKEN")))
    ])
    #expect(resolved.bindings.isEmpty)
    let preserved = resolved.resources.filter {
      $0.path == "skills/helper" || $0.path == "shared/language.json"
    }
    #expect(!preserved.isEmpty)
    #expect(preserved.allSatisfy { $0.hash == nil && $0.requiresBindingRewrite })
    #expect(!String(reflecting: resolved).contains("PRIVATE_SUPPORT_A"))
    let environment = RuntimeEnvironment(
      projectDirectory: f.root, homeDirectory: f.root, environment: [:])
    let scope = try UpdateOperations.inspect(environment: environment)
    #expect(throws: (any Error).self) { try resolved.updateRequest(in: scope) }
    try f.write(
      "bundle/shared/language.json",
      original.replacingOccurrences(of: "PRIVATE_SUPPORT_A", with: "PRIVATE_SUPPORT_B"))
    #expect(throws: (any Error).self) { try report.resolving() }
    #expect(throws: (any Error).self) { try resolved.resolving() }
    let refreshed = try SourceImportOperations.inspect(
      format: "claudePluginV1", root: f.root, document: "bundle/.claude-plugin/plugin.json")
    #expect(!refreshed.bindings.isEmpty)
    #expect(!String(reflecting: refreshed).contains("PRIVATE_SUPPORT_B"))
    #expect(
      refreshed.resources.filter { $0.path == "skills/helper" }.allSatisfy {
        $0.hash == nil && $0.requiresBindingRewrite
      })
  }

  @Test func resolvedCanonicalBindingCannotAdmitRawPreservedBytes() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "settings.json",
      #"{"mcpServers":{"review":{"command":"never-run","env":{"TOKEN":"PRIVATE_INPUT_CANARY"}}}}"#)
    let initial = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: f.root, document: "settings.json")
    let slot = try #require(initial.requiredInputs.first { $0.kind == .bindingReference })
    let resolved = try initial.resolving(inputs: [
      .init(id: slot.id, value: .binding(.environment("REVIEW_TOKEN")))
    ])
    #expect(resolved.bindings.isEmpty)
    #expect(resolved.diagnostics.isEmpty)
    #expect(resolved.resources.allSatisfy { $0.requiresBindingRewrite && $0.hash == nil })
    guard case .mcpServer(_, .stdio(let run), _, _, _, _) = resolved.components.first?.declaration
    else {
      Issue.record("Expected canonical MCP transport")
      return
    }
    #expect(run.environment["TOKEN"] == .environment("REVIEW_TOKEN"))
    #expect(!String(reflecting: resolved).contains("PRIVATE_INPUT_CANARY"))
    let environment = RuntimeEnvironment(
      projectDirectory: f.root, homeDirectory: f.root, environment: [:])
    let store = StateStore(scope: .project, environment: environment)
    try store.save(declaration: Declaration(), ledger: ResolvedLedger())
    let scope = try UpdateOperations.inspect(environment: environment)
    #expect(throws: (any Error).self) { try resolved.updateRequest(in: scope) }

    var input = SourceImportInput(
      profile: .claudeSettingsV1, root: f.root, document: "settings.json")
    let raw = try SourceImport.preview(input)
    let key = try #require(raw.bindings.first(where: \.canonicalSlot)?.key)
    input.bindingReferences[key] = .secret("local-review-token")
    let proposal = try SourceImport.preview(input)
    var enumeration = input
    enumeration.enumerateChoices = true
    let document = f.root.appendingPathComponent("settings.json")
    let preparation = try ImportPreparation(
      input: input, proposal: proposal,
      catalog: try SourceImport.preview(enumeration),
      locations: [document])
    #expect(throws: (any Error).self) { try preparation.capture() }
    #expect(try preparation.capture(admitConversion: false).count == 1)
    let reinspected = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: f.root, document: "settings.json")
    #expect(!reinspected.bindings.isEmpty)
    #expect(reinspected.resources.allSatisfy { $0.requiresBindingRewrite })
  }

  @Test func excludedCredentialsRemainBlockedAndCannotReceiveFakeSlotHandles() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "settings.json",
      #"{"mcpServers":{"clean":{"command":"never-run"},"private":{"command":"never-run","env":{"TOKEN":"EXCLUDED_INPUT_CANARY"}}}}"#
    )
    let report = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: f.root,
      document: "settings.json", selection: ["clean"])
    #expect(report.components.count == 1)
    #expect(!report.bindings.isEmpty)
    #expect(report.bindings.allSatisfy { !$0.canResolveCanonicalSlot })
    #expect(!report.requiredInputs.contains { $0.kind == .bindingReference })
    #expect(report.resources.allSatisfy { $0.requiresBindingRewrite && $0.hash == nil })
    #expect(!String(reflecting: report).contains("EXCLUDED_INPUT_CANARY"))
  }

  @Test func originalSymbolicBindingsDoNotInventRawCredentialRewrite() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "settings.json",
      #"{"mcpServers":{"review":{"command":"never-run","env":{"TOKEN":"${REVIEW_TOKEN}"}}}}"#)
    let original = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: f.root, document: "settings.json")
    let slot = try #require(original.requiredInputs.first { $0.kind == .bindingReference })
    #expect(original.resources.allSatisfy { !$0.requiresBindingRewrite && $0.hash != nil })
    let resolved = try original.resolving(inputs: [
      .init(id: slot.id, value: .binding(.environment("REVIEW_TOKEN")))
    ])
    #expect(resolved.bindings.isEmpty)
    #expect(resolved.resources.allSatisfy { !$0.requiresBindingRewrite && $0.hash != nil })
  }

  @Test func failedNativeConversionDoesNotOfferAnUnusedCanonicalBindingSlot() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "settings.json",
      #"{"mcpServers":{"bad":{"command":"./missing-server","env":{"TOKEN":"FAILED_MEMBER_CANARY"}}}}"#
    )
    let report = try SourceImportOperations.inspect(
      format: "claudeSettingsV1", root: f.root, document: "settings.json")
    #expect(report.components.isEmpty)
    #expect(!report.bindings.isEmpty)
    #expect(report.bindings.allSatisfy { !$0.canResolveCanonicalSlot })
    #expect(!report.requiredInputs.contains { $0.kind == .bindingReference })
    #expect(!String(reflecting: report).contains("FAILED_MEMBER_CANARY"))
  }

  @Test func overlappingResourceAdmissionSurvivesCanonicalResolution() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "opencode.json",
      #"{"mcp":{"servers":{"clean":{"type":"local","command":["never-run"],"cwd":"."}}},"lsp":{"fixed":{"command":["never-run"],"env":{"TOKEN":"OVERLAP_CANARY"}}}}"#
    )
    let initial = try SourceImportOperations.inspect(
      format: "openCodeConfigV2", root: f.root, document: "opencode.json")
    let slot = try #require(initial.requiredInputs.first { $0.kind == .bindingReference })
    let resolved = try initial.resolving(inputs: [
      .init(id: slot.id, value: .binding(.secret("local-token")))
    ])
    #expect(resolved.bindings.isEmpty)
    #expect(resolved.diagnostics.isEmpty)
    let root = try #require(resolved.resources.first { $0.path == "." })
    #expect(root.requiresBindingRewrite && root.hash == nil)
    #expect(!String(reflecting: resolved).contains("OVERLAP_CANARY"))
  }

  @Test func sourceHandlesRerunTheOwningLockAdapter() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "lock.json",
      "{\"lockfileVersion\":1,\"sources\":{\"acme/repo\":{\"resolvedRef\":\""
        + String(repeating: "a", count: 40) + "\",\"skillsPath\":\"skills\",\"skills\":{}}}}")
    let initial = try SourceImportOperations.inspect(
      format: "rulesyncSourcesV1", root: f.root, document: "lock.json")
    let source = try #require(initial.requiredInputs.first { $0.kind == .sourceCoordinates })
    let resolved = try initial.resolving(inputs: [
      .init(
        id: source.id,
        value: .source(.init(kind: .git, location: "https://example.invalid/acme/repo")))
    ])
    #expect(resolved.requiredInputs.isEmpty)
    #expect(resolved.diagnostics.isEmpty)
    #expect(resolved.sources.first?.commit == String(repeating: "a", count: 40))
    #expect(throws: (any Error).self) {
      try resolved.resolving(inputs: [.init(id: source.id, value: .content(path: "."))])
    }
  }

  @Test func explicitContentAndMarketplaceChoicesRerunTheirOwnAdmission() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "skills/review/SKILL.md", "---\nname: review\ndescription: Review\n---\nReview\n")
    let capture = try ImportSkillContent.read(
      "skills/review", input: .init(profile: .vercelProjectV2, root: f.root, document: "lock.json"),
      limits: .init())
    let hash = ImportSkillContent.vercelHash(capture)
    try f.write(
      "lock.json",
      "{\"version\":2,\"skills\":{\"review\":{\"source\":\"acme/repo\",\"sourceType\":\"github\",\"computedHash\":\""
        + hash + "\"}}}")
    let initial = try SourceImportOperations.inspect(
      format: "vercelProjectV2", root: f.root, document: "lock.json")
    let content = try #require(initial.requiredInputs.first { $0.kind == .explicitContent })
    #expect(throws: (any Error).self) {
      try initial.resolving(inputs: [.init(id: content.id, value: .content(path: "../escape"))])
    }
    let missing = try initial.resolving(inputs: [
      .init(id: content.id, value: .content(path: "absent"))
    ])
    #expect(missing.requiredInputs.contains { $0.kind == .explicitContent })
    let captured = try initial.resolving(inputs: [
      .init(id: content.id, value: .content(path: "skills/review"))
    ])
    #expect(!captured.requiredInputs.contains { $0.kind == .explicitContent })
    #expect(captured.resources.contains { $0.hash != nil && $0.requiresStandaloneSource })
    #expect(captured.sources.allSatisfy { $0.commit == nil })
    #expect(captured.diagnostics.contains { $0.code == "incompletePin" })

    try f.write(
      ".claude-plugin/marketplace.json",
      #"{"name":"market","owner":{"name":"Owner"},"plugins":[{"name":"review","source":{"source":"github","repo":"acme/repo","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}"#
    )
    let catalog = try SourceImportOperations.inspect(
      format: "claudeMarketplaceV1", root: f.root, document: ".claude-plugin/marketplace.json")
    #expect(catalog.sources.isEmpty)
    #expect(!catalog.diagnostics.isEmpty)
    let choice = try #require(catalog.availableChoices.first)
    #expect(choice.effects.sources.count == 1)
    let selected = try catalog.resolving(choices: [choice.id])
    #expect(selected.sources.count == 1)
    #expect(selected.sources.first?.commit == String(repeating: "a", count: 40))
    let empty = try catalog.resolving(choices: [])
    #expect(empty.sources.isEmpty)
  }

  @Test func ordinalChoicesAndUnfilteredContainersKeepTheirOwnSemantics() throws {
    let f = try ImportSelectionFixture()
    try f.write(
      "apm.yml",
      "name: example\nversion: '1.0.0'\ndependencies:\n  apm: [acme/one]\ndevDependencies:\n  apm: [acme/two]\n"
    )
    let yaml = try SourceImportOperations.inspect(
      format: "apmManifest", root: f.root, document: "apm.yml")
    #expect(yaml.availableChoices.count == 1)
    #expect(yaml.availableChoices.first?.locations.count == 2)
    #expect(yaml.availableChoices.first?.effects.sources.count == 2)
    let empty = try yaml.resolving(choices: [])
    #expect(empty.sources.isEmpty)
    try f.write("bundle/.cursor-plugin/plugin.json", #"{"name":"bundle"}"#)
    try f.write("bundle/commands/review.md", "Review")
    let container = try SourceImportOperations.inspect(
      format: "cursorPluginV1", root: f.root, document: "bundle/.cursor-plugin/plugin.json")
    #expect(container.availableChoices.isEmpty)
    #expect(container.fixedEffects.components.count == 1)
    #expect(try container.resolving(choices: []).components.count == 1)
  }
}

private final class ImportSelectionFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "import-selection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}
