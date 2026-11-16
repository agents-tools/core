import AgentsCore
import Components
import Foundation
import Testing

struct ImportNativeTests {
  @Test(arguments: [
    SourceImportProfile.claudeSettingsV1, .codexConfigV1, .cursorMCPV1, .geminiSettingsV1,
    .openCodeConfigV2,
  ])
  func fiveNativeMCPProfilesKeepArgvBindingsAndOriginalLocations(_ profile: SourceImportProfile)
    throws
  {
    let fixture = try NativeImportFixture()
    let file: String
    let text: String
    switch profile {
    case .codexConfigV1:
      file = "config.toml"
      text =
        "[mcp_servers.review]\ncommand='review-server'\nargs=['--read-only']\nenv_vars=['PUBLIC_TOKEN']\n[mcp_servers.review.env]\nTOKEN='NATIVE_SECRET_CANARY'\n"
    case .openCodeConfigV2:
      file = "opencode.jsonc"
      text =
        #"{"mcp":{"servers":{"review":{"type":"local","command":["review-server","--read-only"],"environment":{"TOKEN":"NATIVE_SECRET_CANARY"}}}}}"#
    default:
      file = "settings.json"
      text =
        #"{"mcpServers":{"review":{"command":"review-server","args":["--read-only"],"env":{"TOKEN":"NATIVE_SECRET_CANARY"}}}}"#
    }
    try fixture.write(file, text)
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(profile, file))
    let item = try #require(result.components.first)
    guard case .mcpServer(let name, .stdio(let run), let agents, _, _) = item.declaration else {
      Issue.record("Expected typed stdio member")
      return
    }
    #expect(name == "review")
    #expect(run.executable == "review-server")
    #expect(run.arguments == ["--read-only"])
    #expect(agents?.count == 1)
    if case .secret(let key) = run.environment["TOKEN"] {
      #expect(result.bindings.contains { $0.key == key })
    } else {
      Issue.record("Literal credential must be symbolic")
    }
    if profile == .codexConfigV1 {
      #expect(run.environment["PUBLIC_TOKEN"] == .environment("PUBLIC_TOKEN"))
    }
    #expect(item.member?.selector == .mcpServer(name: "review"))
    #expect(item.member?.containerRoot == ".")
    #expect(item.origin.document == file)
    #expect(item.origin.span?.start != nil)
    #expect(result.resources.last?.requiresBindingRewrite == true)
    #expect(result.resources.last?.observedHash == nil)
    #expect(!String(reflecting: result).contains("NATIVE_SECRET_CANARY"))
    #expect(try fixture.hash() == before)
  }

  @Test func nativeProfileProvenanceUsesUpstreamSourcesAndHonestDocumentationStatus() {
    #expect(
      SourceImportProfile.codexConfigV1.producerRevision
        == "092d3acd6bec3e3a14bdc7e7a2810ab628ab759d")
    #expect(
      SourceImportProfile.geminiExtensionV1.producerRevision
        == "5a5c7180ff3f0a02511f54b54db7f228d4982a30")
    #expect(
      SourceImportProfile.openCodeConfigV2.producerRevision
        == "fedc6f208aa2bd54c1019227214568083f6380ad")
    for profile in [
      SourceImportProfile.claudeSettingsV1, .claudePluginV1, .claudeMarketplaceV1,
      .claudeCommandV1, .claudeAgentV1, .cursorMCPV1, .cursorPluginV1, .cursorCommandV1,
      .cursorAgentV1, .cursorIgnoreV1,
    ] {
      #expect(profile.producerRevision == nil)
      #expect(profile.specificationStatus.contains("Documented"))
      #expect(profile.specificationStatus.contains("upstream source revision unavailable"))
    }
  }

  @Test func claudeContainerPreservesTypedChildrenRootsExecutableClosureAndSecrets() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"review-bundle","version":"1","mcpServers":{"review":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/server","env":{"TOKEN":"NATIVE_SECRET_CANARY"}}}}"#
    )
    try fixture.write("bundle/bin/server", "#!/bin/sh\nexit 0\n", executable: true)
    try fixture.write(
      "bundle/commands/check.md", "---\ndescription: Check changes\n---\nReview the change.\n")
    try fixture.write(
      "bundle/agents/reviewer.md",
      "---\nname: reviewer\ndescription: Review changes\n---\nReview carefully.\n")
    try fixture.write(
      "bundle/skills/audit/SKILL.md", "---\nname: audit\ndescription: Audit changes\n---\nAudit.\n")
    try fixture.write(
      "bundle/.lsp.json",
      #"{"swift":{"command":"swift-lsp","extensionToLanguage":{".swift":"swift"}}}"#)
    try fixture.write(
      "bundle/hooks/hooks.json",
      #"{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"./bin/server"}]}]}}"#
    )
    var input = fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json")
    input.selection = []  // Member all/none is B's operation, not container parsing.
    let before = try fixture.hash()
    let result = try SourceImport.preview(input)
    #expect(
      Set(result.components.map(\.declaration.kind)) == [
        .command, .subagent, .skills, .mcpServer, .lspServer, .hook,
      ])
    #expect(result.components.allSatisfy { $0.member?.containerRoot == "bundle" })
    #expect(
      result.components.first { $0.declaration.kind == .command }?.origin.document
        == "bundle/commands/check.md")
    #expect(
      result.components.first { $0.declaration.kind == .lspServer }?.origin.document
        == "bundle/.lsp.json")
    #expect(
      result.resources.contains {
        $0.path == "bin/server" && $0.executableFlags["."] == true && $0.requiresStandaloneSource
      })
    #expect(!result.resources.contains { $0.sourceAlias == "native-input" && $0.path == "." })
    #expect(
      result.resources.first { $0.path == ".claude-plugin/plugin.json" }?.requiresBindingRewrite
        == true)
    #expect(!String(reflecting: result).contains("NATIVE_SECRET_CANARY"))
    #expect(try fixture.hash() == before)
  }

  @Test func cursorReplacementAndGeminiCommandNamespaceKeepProducerMeaning() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "cursor/.cursor-plugin/plugin.json", #"{"name":"review","commands":"custom"}"#)
    try fixture.write("cursor/commands/ignored.md", "Default must not be selected\n")
    try fixture.write("cursor/custom/selected.txt", "Selected prompt\n")
    let cursor = try SourceImport.preview(
      fixture.input(.cursorPluginV1, "cursor/.cursor-plugin/plugin.json"))
    #expect(cursor.components.map(\.member?.selector) == [.command(name: "selected")])
    try fixture.write("extension/gemini-extension.json", #"{"name":"review","version":"1"}"#)
    try fixture.write(
      "extension/commands/gcs/sync.toml", "description='Sync'\nprompt='Sync {{args}}'\n")
    let gemini = try SourceImport.preview(
      fixture.input(.geminiExtensionV1, "extension/gemini-extension.json"))
    #expect(gemini.components.first?.member?.selector == .command(name: "gcs/sync"))
    #expect(gemini.components.first?.origin.document == "extension/commands/gcs/sync.toml")
  }

  @Test func codexRoleRelativeFileAndOpenCodeOrderedPolicyBecomeTypedIntent() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "codex/config.toml",
      "[agents.review]\ndescription='Review'\nconfig_file='./roles/review.toml'\n")
    try fixture.write(
      "codex/roles/review.toml", "developer_instructions='Review carefully'\nmodel='model-id'\n")
    let codex = try SourceImport.preview(fixture.input(.codexConfigV1, "codex/config.toml"))
    #expect(codex.components.first?.origin.document == "codex/roles/review.toml")
    #expect(codex.resources.contains { $0.path == "codex/roles/review.toml" })
    try fixture.write(
      "opencode.jsonc",
      #"{"commands":{"review":{"description":"Review","template":"Review $ARGUMENTS"}},"agents":{"reviewer":{"description":"Reviewer","mode":"subagent","system":"Review","model":"provider/model"}},"permissions":[{"action":"read","resource":"*","effect":"deny"},{"action":"read","resource":"safe/*","effect":"allow"}]}"#
    )
    let opencode = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.jsonc"))
    #expect(
      Set(opencode.components.map(\.declaration.kind)) == [.command, .subagent, .permissions])
    guard case .permissions(_, let rules, _, _, _) = opencode.components.last?.declaration else {
      Issue.record("Expected native ordered policy")
      return
    }
    #expect(rules == [.deny(.tool("read"), "*"), .allow(.tool("read"), "safe/*")])
  }

  @Test func selectedCatalogCoordinatesKeepExactPinsAndNeverExecuteCommandSources() throws {
    let fixture = try NativeImportFixture()
    let commit = String(repeating: "a", count: 40)
    try fixture.write(
      "catalog/.claude-plugin/marketplace.json",
      """
      {"name":"catalog","owner":{"name":"owner"},"plugins":[
        {"name":"pinned","source":{"source":"github","repo":"acme/review","ref":"main","sha":"\(commit)"}},
        {"name":"mutable","source":{"source":"url","url":"https://example.test/repo.git","ref":"main"}},
        {"name":"command","source":{"source":"command","command":"touch SHOULD_NOT_EXIST"}}]}
      """)
    var input = fixture.input(.claudeMarketplaceV1, "catalog/.claude-plugin/marketplace.json")
    let unselected = try SourceImport.preview(input)
    #expect(unselected.sources.isEmpty)
    input.selection = ["pinned", "mutable", "command"]
    let before = try fixture.hash()
    let result = try SourceImport.preview(input)
    #expect(result.sources.map(\.pin.commit) == [commit, nil])
    #expect(result.sources.first?.declaration?.requirement == .revision(commit))
    #expect(result.sources.first?.requestedRef == "main")
    #expect(result.diagnostics.contains { $0.code == .incompletePin })
    #expect(result.diagnostics.contains { $0.code == .unconverted })
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    #expect(try fixture.hash() == before)
  }

  @Test func nativeRefusalsAreLocatedValueFreeAndPreserveAllInputBytes() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "settings.json",
      #"{"mcpServers":{"bad":{"command":"tool","args":["--token=NATIVE_SECRET_CANARY"]}},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo a | sed b"}]}]},"future":{"token":"NATIVE_SECRET_CANARY"}}"#
    )
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(.claudeSettingsV1, "settings.json"))
    #expect(result.components.isEmpty)
    #expect(!result.bindings.isEmpty)
    #expect(
      result.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "settings.json"
      })
    #expect(!String(reflecting: result).contains("NATIVE_SECRET_CANARY"))
    #expect(try fixture.hash() == before)
    try fixture.write("duplicate.json", #"{"mcpServers":{},"mcpServers":{}}"#)
    let duplicate = try SourceImport.preview(fixture.input(.claudeSettingsV1, "duplicate.json"))
    #expect(duplicate.components.isEmpty)
    #expect(duplicate.diagnostics.last?.code == .invalidInput)
    try fixture.write(
      "bundle/.claude-plugin/plugin.json", #"{"name":"bundle","commands":"./../outside"}"#)
    let traversal = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(traversal.diagnostics.last?.code == .unsafePath)
    var limits = SourceImportLimits()
    limits.documentBytes = 8
    #expect(
      try SourceImport.preview(fixture.input(.claudeSettingsV1, "settings.json"), limits: limits)
        .components.isEmpty)
  }

  @Test func nativeIgnoreAndCatalogSubdirectoryPreserveFormatCoordinates() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(".geminiignore", "build/\n!important.txt\n")
    let ignored = try SourceImport.preview(fixture.input(.geminiIgnoreV1, ".geminiignore"))
    guard case .ignore(_, let patterns, _, _, _, _) = ignored.components.first?.declaration else {
      Issue.record("Expected context exclusion patterns")
      return
    }
    #expect(patterns == ["build/", "!important.txt"])
    let commit = String(repeating: "b", count: 40)
    try fixture.write(
      ".claude-plugin/marketplace.json",
      """
      {"name":"catalog","owner":{"name":"owner"},"plugins":[
      {"name":"nested","source":{"source":"git-subdir","url":"https://example.test/repo.git","path":"plugins/review","sha":"\(commit)"}}]}
      """)
    var input = fixture.input(.claudeMarketplaceV1, ".claude-plugin/marketplace.json")
    input.selection = ["nested"]
    let result = try SourceImport.preview(input)
    #expect(result.sources.first?.declaration?.path == "plugins/review")
    #expect(result.sources.first?.pin.commit == commit)
    guard case .plugin(_, let path, _, _, _, _, _, _, _) = result.components.first?.declaration
    else {
      Issue.record("Expected selected catalog plugin")
      return
    }
    #expect(path == ".")
  }

  @Test func optionalNativeDescriptionsAndReferencedUnknownFieldsStayVisible() throws {
    let fixture = try NativeImportFixture()
    try fixture.write("command.toml", "prompt='Review {{args}}'\n")
    let command = try SourceImport.preview(fixture.input(.geminiCommandV1, "command.toml"))
    #expect(command.components.count == 1)
    try fixture.write("opencode.jsonc", #"{"commands":{"review":{"template":"Review"}}}"#)
    let opencode = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.jsonc"))
    #expect(opencode.components.count == 1)
    try fixture.write("bundle/.claude-plugin/plugin.json", #"{"name":"bundle"}"#)
    try fixture.write(
      "bundle/.mcp.json", #"{"mcpServers":{},"future":{"token":"NATIVE_SECRET_CANARY"}}"#)
    let bundle = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(
      bundle.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "bundle/.mcp.json"
      })
    #expect(!bundle.bindings.isEmpty)
    #expect(bundle.resources.contains { $0.path == ".mcp.json" && $0.requiresBindingRewrite })
    #expect(!String(reflecting: bundle).contains("NATIVE_SECRET_CANARY"))
  }

  @Test func missingExplicitContainerMembersAreLocatedWhileOptionalDefaultsStayOptional() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "bundle/.cursor-plugin/plugin.json", #"{"name":"bundle","commands":"missing"}"#)
    let missing = try SourceImport.preview(
      fixture.input(.cursorPluginV1, "bundle/.cursor-plugin/plugin.json"))
    #expect(missing.components.isEmpty)
    #expect(
      missing.diagnostics.contains {
        $0.code == .missingResource && $0.location.document == "bundle/.cursor-plugin/plugin.json"
          && $0.location.pointer == "/commands" && $0.location.span != nil
      })
    try fixture.write("bundle/.cursor-plugin/plugin.json", #"{"name":"bundle"}"#)
    let defaults = try SourceImport.preview(
      fixture.input(.cursorPluginV1, "bundle/.cursor-plugin/plugin.json"))
    #expect(!defaults.diagnostics.contains { $0.code == .missingResource })
  }

  @Test func typedMembersStayStableWhenCallerMovesTheInputRoot() throws {
    let one = try NativeImportFixture()
    let two = try NativeImportFixture()
    for fixture in [one, two] {
      try fixture.write("bundle/.cursor-plugin/plugin.json", #"{"name":"bundle"}"#)
      try fixture.write("bundle/commands/review.md", "Review\n")
    }
    let a = try SourceImport.preview(
      one.input(.cursorPluginV1, "bundle/.cursor-plugin/plugin.json"))
    let b = try SourceImport.preview(
      two.input(.cursorPluginV1, "bundle/.cursor-plugin/plugin.json"))
    #expect(a.components.map(\.member) == b.components.map(\.member))
    #expect(a.components.map(\.origin) == b.components.map(\.origin))
    #expect(a.resources.map(\.observedHash) == b.resources.map(\.observedHash))
  }
}

private final class NativeImportFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-import-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
  func write(_ path: String, _ text: String, executable: Bool = false) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
  }
  func input(_ profile: SourceImportProfile, _ path: String) -> SourceImportInput {
    .init(profile: profile, root: root, document: path)
  }
  func hash() throws -> String { try FileHash.folderHash(root) }
}
