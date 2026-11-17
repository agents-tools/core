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

  @Test func preservedMCPDocumentsClassifyExcludedAndReplacedBindings() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "settings.json",
      #"{"mcpServers":{"clean":{"command":"tool"},"private":{"command":"tool","env":{"CUSTOM":"EXCLUDED_SECRET"}}}}"#
    )
    var input = fixture.input(.claudeSettingsV1, "settings.json")
    input.selection = ["clean"]
    let before = try fixture.hash()
    let selected = try SourceImport.preview(input)
    #expect(selected.components.count == 1)
    #expect(selected.bindings.contains { $0.location.pointer.contains("member[1]/env") })
    #expect(selected.resources.allSatisfy { $0.requiresBindingRewrite && $0.observedHash == nil })
    #expect(!String(reflecting: selected).contains("EXCLUDED_SECRET"))
    #expect(try fixture.hash() == before)
    #expect(selected.components.first?.member?.selector == .mcpServer(name: "clean"))
    try fixture.write(
      "settings.json",
      #"{"mcpServers":{"clean":{"command":"tool","env":{}},"private":{"command":"tool","env":{"CUSTOM":"${OPTIONAL_TOKEN}"}}}}"#
    )
    let symbolic = try SourceImport.preview(input)
    #expect(symbolic.components.count == 1)
    #expect(symbolic.bindings.isEmpty)
    #expect(symbolic.resources.allSatisfy { !$0.requiresBindingRewrite && $0.observedHash != nil })
    try fixture.write(
      "settings.json",
      #"{"mcpServers":{"clean":{"command":"tool"},"private":{"command":"tool","env_http_headers":{"CUSTOM":"EXCLUDED_HEADER_SECRET"}}}}"#
    )
    let foreignField = try SourceImport.preview(input)
    #expect(!foreignField.bindings.isEmpty)
    #expect(
      foreignField.resources.allSatisfy { $0.requiresBindingRewrite && $0.observedHash == nil })
    #expect(!String(reflecting: foreignField).contains("EXCLUDED_HEADER_SECRET"))

    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","mcpServers":{"same":{"command":"winning-tool"}}}"#)
    try fixture.write(
      "bundle/.mcp.json",
      #"{"mcpServers":{"same":{"command":"old-tool","env":{"CUSTOM":"REPLACED_SECRET"}}}}"#)
    let bundleBefore = try fixture.hash()
    let replaced = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(replaced.components.count == 1)
    #expect(replaced.bindings.contains { $0.location.document == "bundle/.mcp.json" })
    #expect(
      replaced.resources.contains {
        $0.path == ".mcp.json" && $0.requiresBindingRewrite && $0.observedHash == nil
      })
    #expect(!String(reflecting: replaced).contains("REPLACED_SECRET"))
    #expect(try fixture.hash() == bundleBefore)
  }

  @Test func rootRelativeExecutablesRemainResourcesAcrossNativeKinds() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      ".claude-plugin/plugin.json",
      #"{"name":"bundle","mcpServers":{"mcp":{"command":"./server"}},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"./server"}]}]}}"#
    )
    try fixture.write(
      ".lsp.json",
      #"{"lsp":{"command":"${CLAUDE_PLUGIN_ROOT}/server","extensionToLanguage":{".x":"x"}}}"#)
    try fixture.write("server", "#!/bin/sh\nexit 0\n", executable: true)
    let before = try fixture.hash()
    let result = try SourceImport.preview(
      fixture.input(.claudePluginV1, ".claude-plugin/plugin.json"))
    var executables: [String] = []
    for item in result.components {
      switch item.declaration {
      case .mcpServer(_, .stdio(let run), _, _, _), .hook(_, _, let run, _, _, _, _, _),
        .lspServer(_, let run, _, _, _, _, _):
        executables.append(run.executable)
      default: Issue.record("Unexpected member")
      }
    }
    #expect(executables == ["./server", "./server", "./server"])
    #expect(result.resources.contains { $0.path == "server" && $0.executableFlags["."] == true })
    #expect(try fixture.hash() == before)
  }

  @Test func lspBindingsKeepOriginalMapCoordinatesThroughPrecedence() throws {
    let fixture = try NativeImportFixture()
    try fixture.write("bundle/.claude-plugin/plugin.json", #"{"name":"bundle"}"#)
    try fixture.write(
      "bundle/.lsp.json",
      """
      {"a":{"command":"a-lsp","extensionToLanguage":{".a":"a"},"env":{"CUSTOM":"LSP_A_SECRET"}},
      "b":{"command":"b-lsp","extensionToLanguage":{".b":"b"},"env":{"CUSTOM":"LSP_B_SECRET"}}}
      """)
    func keys(_ result: SourceImportProposal) -> [String] {
      result.components.compactMap {
        if case .lspServer(_, let run, _, _, _, _, _) = $0.declaration,
          case .secret(let key) = run.environment["CUSTOM"]
        {
          return key
        }
        return nil
      }
    }
    let original = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(Set(keys(original)).count == 2)
    #expect(Set(original.components.map(\.origin.pointer)) == ["/member[0]", "/member[1]"])
    #expect(Set(original.components.compactMap { $0.origin.span?.line }) == [1, 2])
    try fixture.write(
      "bundle/.claude-plugin/plugin.json", #"{"name":"bundle","lspServers":"./override.json"}"#)
    try fixture.write(
      "bundle/override.json",
      #"{"a":{"command":"new-lsp","extensionToLanguage":{".a":"a"},"env":{"CUSTOM":"NEW_LSP_SECRET"}}}"#
    )
    let replaced = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(Set(keys(replaced)).count == 2)
    #expect(Set(replaced.bindings.compactMap(\.key)).count == 3)
    #expect(
      replaced.components.contains {
        $0.origin.document == "bundle/.lsp.json" && $0.origin.pointer == "/member[1]"
      })
    #expect(
      replaced.components.contains {
        $0.origin.document == "bundle/override.json" && $0.origin.pointer == "/member[0]"
          && $0.origin.span != nil
      })
    #expect(
      replaced.resources.filter { $0.path == ".lsp.json" || $0.path == "override.json" }.allSatisfy
      { $0.requiresBindingRewrite && $0.observedHash == nil })
    #expect(!String(reflecting: replaced).contains("LSP_B_SECRET"))
  }

  @Test func openCodeExplicitOAuthDisableSurvivesTypedImport() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "opencode.jsonc",
      #"{"mcp":{"servers":{"review":{"type":"remote","url":"https://example.test/mcp","oauth":false}}}}"#
    )
    let result = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.jsonc"))
    guard
      case .mcpServer(_, .streamableHTTP, _, _, let native) = result.components.first?.declaration
    else {
      Issue.record("Expected remote MCP")
      return
    }
    #expect(native[AgentID.opencode.rawValue]?["oauth"] == .boolean(false))
    #expect(result.diagnostics.isEmpty)
  }

  @Test func nativeConfigurationMemberSelectionHonorsEmptyAndNarrowNames() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "opencode.jsonc",
      #"{"commands":{"other":{"template":"Other"},"selected":{"template":"Selected"}},"agents":{"other":{"system":"Other","mode":"subagent"},"selected":{"system":"Selected","mode":"subagent"}}}"#
    )
    try fixture.write(
      "config.toml",
      "[agents.other]\ndescription='Other'\nconfig_file='other.toml'\n[agents.selected]\ndescription='Selected'\nconfig_file='selected.toml'\n"
    )
    try fixture.write("other.toml", "developer_instructions='Other'\n")
    try fixture.write("selected.toml", "developer_instructions='Selected'\n")
    let selections: [Set<String>?] = [nil, [], ["selected"]]
    for selection in selections {
      var openCode = fixture.input(.openCodeConfigV2, "opencode.jsonc")
      var codex = fixture.input(.codexConfigV1, "config.toml")
      openCode.selection = selection
      codex.selection = selection
      let a = try SourceImport.preview(openCode)
      let b = try SourceImport.preview(codex)
      #expect(a.components.count == (selection == nil ? 4 : selection!.isEmpty ? 0 : 2))
      #expect(b.components.count == (selection == nil ? 2 : selection!.isEmpty ? 0 : 1))
      if selection == ["selected"] {
        #expect(
          a.components.compactMap { $0.member?.selector } == [
            .command(name: "selected"), .subagent(name: "selected"),
          ])
        #expect(b.components.first?.member?.selector == .subagent(name: "selected"))
      }
    }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("other.toml"))
    var narrow = fixture.input(.codexConfigV1, "config.toml")
    narrow.selection = ["selected"]
    #expect(try SourceImport.preview(narrow).components.count == 1)
  }

  @Test func sharedMarkdownFieldsKeepNativeIntentAndActualRegistrationContext() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "auditor.md",
      "---\nname: auditor\ndescription: Inspect source\npermissionMode: plan\nmaxTurns: 3\n---\nInspect carefully.\n"
    )
    let standalone = try SourceImport.preview(fixture.input(.claudeAgentV1, "auditor.md"))
    guard case .subagent(_, _, _, _, _, _, _, let native) = standalone.components.first?.declaration
    else {
      Issue.record("Expected standalone agent")
      return
    }
    #expect(native[AgentID.claudeCode.rawValue]?["permissionMode"] == .string("plan"))
    #expect(native[AgentID.claudeCode.rawValue]?["maxTurns"] == .integer(3))
    try fixture.write("bundle/.claude-plugin/plugin.json", #"{"name":"bundle"}"#)
    try fixture.write(
      "bundle/agents/auditor.md",
      "---\nname: auditor\ndescription: Inspect source\npermissionMode: plan\n---\nInspect.\n")
    let plugin = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(!plugin.components.contains { $0.declaration.kind == .subagent })
    #expect(
      plugin.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "bundle/agents/auditor.md"
          && $0.location.span?.line == 4
      })
    try fixture.write(
      "review.md",
      "---\ncontext: fork\nagent: auditor\nbackground: true\nmodel: sonnet\n---\nReview.\n")
    let command = try SourceImport.preview(fixture.input(.claudeCommandV1, "review.md"))
    guard case .command(_, _, _, _, _, _, let fields) = command.components.first?.declaration else {
      Issue.record("Expected native command")
      return
    }
    #expect(fields[AgentID.claudeCode.rawValue]?["context"] == .string("fork"))
    #expect(fields[AgentID.claudeCode.rawValue]?["model"] == .string("sonnet"))
    try fixture.write("review.md", "---\nbackground: true\n---\nReview.\n")
    let refused = try SourceImport.preview(fixture.input(.claudeCommandV1, "review.md"))
    #expect(refused.components.isEmpty)
    #expect(
      refused.diagnostics.contains { $0.code == .unconverted && $0.location.span?.line == 2 })
    try fixture.write(
      "review.md", "---\nzzzUnknown: value\ndescription: Review\naaaUnknown: value\n---\nReview.\n")
    let unknown = try SourceImport.preview(fixture.input(.claudeCommandV1, "review.md"))
    #expect(unknown.components.isEmpty)
    #expect(unknown.diagnostics.contains { $0.code == .unconverted && $0.location.span?.line == 4 })
    try fixture.write("review.md", "---\nzzz: 3.5\ndescription: Review\n---\nReview.\n")
    let decimalUnknown = try SourceImport.preview(fixture.input(.claudeCommandV1, "review.md"))
    #expect(decimalUnknown.components.isEmpty)
    #expect(
      decimalUnknown.diagnostics.contains { $0.code == .unconverted && $0.location.span?.line == 2 }
    )
    let cursorBody = "---\nnot-frontmatter: [this is prompt text\n---\nKeep all bytes.\n"
    try fixture.write("review.md", cursorBody)
    let cursor = try SourceImport.preview(fixture.input(.cursorCommandV1, "review.md"))
    guard case .command(_, _, .literal(let body), _, _, _, _) = cursor.components.first?.declaration
    else {
      Issue.record("Expected plain Cursor prompt")
      return
    }
    #expect(body == cursorBody)
  }

  @Test func sharedLSPFieldsPreserveExtrasBindingsAndRefuseAbsentPrograms() throws {
    let fixture = try NativeImportFixture()
    try fixture.write("bundle/.claude-plugin/plugin.json", #"{"name":"bundle"}"#)
    try fixture.write(
      "bundle/.lsp.json",
      #"{"source":{"command":"${CLAUDE_PLUGIN_ROOT}/server","extensionToLanguage":{".s":"source"},"transport":"socket","workspaceFolder":"workspace","requestTimeout":4,"settings":{"nested":[true,7]},"initializationOptions":{"feature":true},"env":{"TOKEN":"SHARED_SECRET_CANARY"}}}"#
    )
    try fixture.write("bundle/server", "#!/bin/sh\nexit 0\n", executable: true)
    let before = try fixture.hash()
    let result = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    guard
      case .lspServer(_, let run, _, let options, _, _, let native) = result.components.first?
        .declaration
    else {
      Issue.record("Expected native LSP")
      return
    }
    #expect(run.executable == "./server")
    #expect(run.workingDirectory == nil)
    #expect(options == ["feature": .boolean(true)])
    #expect(native[AgentID.claudeCode.rawValue]?["workspaceFolder"] == .string("workspace"))
    #expect(
      native[AgentID.claudeCode.rawValue]?["settings"]
        == .object(["nested": .array([.boolean(true), .integer(7)])]))
    #expect(!String(reflecting: result).contains("SHARED_SECRET_CANARY"))
    #expect(
      result.resources.contains {
        $0.path == ".lsp.json" && $0.requiresBindingRewrite && $0.observedHash == nil
      })
    #expect(try fixture.hash() == before)
    try fixture.write(
      "opencode.json",
      #"{"lsp":{"builtin":{"disabled":true},"empty":{"command":[]},"valid":{"command":["source-lsp"],"initialization":{"feature":true}}}}"#
    )
    let open = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.json"))
    #expect(open.components.map(\.member?.selector) == [.lspServer(name: "valid")])
    #expect(open.diagnostics.filter { $0.code == .unconverted }.count == 2)
    try fixture.write(
      "bundle/.lsp.json",
      #"{"source":{"command":"server","extensionToLanguage":{".s":"source"},"requestTimeout":0}}"#)
    let invalid = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(invalid.components.isEmpty)
    #expect(
      invalid.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == "bundle/.lsp.json"
          && $0.location.pointer == "/member[0]/member[2]" && $0.location.span != nil
      })
    try fixture.write("opencode.json", #"{"lsp":{"source":{"command":17}}}"#)
    let wrapped = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.json"))
    #expect(wrapped.components.isEmpty)
    #expect(
      wrapped.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == "opencode.json"
          && $0.location.pointer == "/member[0]/member[0]/member[0]"
      })
  }

  @Test func sharedPluginDefaultsReplaceClaudeCommandsAgentsAndValidateRealDocuments() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","commands":"./chosen/review.md","agents":"./chosen/auditor.md"}"#)
    try fixture.write("bundle/commands/ignored.md", "Ignored default\n")
    try fixture.write(
      "bundle/agents/ignored.md", "---\nname: ignored\ndescription: Ignored\n---\nIgnored default\n"
    )
    try fixture.write("bundle/chosen/review.md", "Chosen command\n")
    try fixture.write(
      "bundle/chosen/auditor.md", "---\nname: auditor\ndescription: Inspect\n---\nChosen agent\n")
    try fixture.write("bundle/hooks/hooks.json", #"{"hooks":{"invented":[]}}"#)
    let input = fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json")
    let invalidDefault = try SourceImport.preview(input)
    #expect(
      invalidDefault.components.map(\.member?.selector) == [
        .command(name: "review"), .subagent(name: "auditor"),
      ])
    #expect(
      invalidDefault.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "bundle/hooks/hooks.json"
      })
    try fixture.write("bundle/hooks/hooks.json", #"{"hooks":{}}"#)
    let valid = try SourceImport.preview(input)
    #expect(valid.diagnostics.isEmpty)
    try fixture.write(
      "bundle/.claude-plugin/plugin.json", #"{"name":"bundle","agents":"./chosen"}"#)
    let wrongKind = try SourceImport.preview(input)
    #expect(
      wrongKind.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == input.document
      })
  }

  @Test func nativeSensitiveDefaultsRequireBindingsBeforeManifestPreservation() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","userConfig":{"access":{"type":"string","title":"Access","description":"Local binding","sensitive":true,"default":"USER_CONFIG_SECRET_CANARY"}}}"#
    )
    let result = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(!result.bindings.isEmpty)
    #expect(!String(reflecting: result).contains("USER_CONFIG_SECRET_CANARY"))
    #expect(
      result.resources.contains {
        $0.path == ".claude-plugin/plugin.json" && $0.requiresBindingRewrite
          && $0.observedHash == nil
      })
  }

  @Test(arguments: [false, true])
  func multiplePluginConfigurationInputsKeepExactFailureDocument(_ firstInvalid: Bool) throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","mcpServers":["./first.json","./second.json"]}"#)
    let invalid = "{\n  \"mcpServers\": {\n    \"same\": {\n      \"command\": 17\n    }\n  }\n}"
    let valid = #"{"mcpServers":{"same":{"command":"tool"}}}"#
    try fixture.write("bundle/first.json", firstInvalid ? invalid : valid)
    try fixture.write("bundle/second.json", firstInvalid ? valid : invalid)
    let before = try fixture.hash()
    let result = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(result.components.count == (firstInvalid ? 1 : 0))
    let invalidDocument = firstInvalid ? "bundle/first.json" : "bundle/second.json"
    #expect(
      result.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == invalidDocument
          && $0.location.pointer == "/member[0]/member[0]/member[0]"
          && $0.location.span?.line == 4
      })
    #expect(
      !result.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document != invalidDocument
      })
    #expect(try fixture.hash() == before)
  }

  @Test func overlappingPreservationResourcesUseCompleteBindingClassification() throws {
    let fixture = try NativeImportFixture()
    try fixture.write(
      "opencode.jsonc",
      #"{"mcp":{"servers":{"clean":{"type":"local","command":["tool"],"cwd":"."}}},"lsp":{"language":{"command":["language-server"],"env":{"TOKEN":"LATE_LITERAL_CANARY"}}}}"#
    )
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(.openCodeConfigV2, "opencode.jsonc"))
    #expect(result.components.count == 2)
    let directory = try #require(result.resources.first { $0.path == "." })
    #expect(directory.requiresBindingRewrite)
    #expect(directory.observedHash == nil)
    #expect(!String(reflecting: result).contains("LATE_LITERAL_CANARY"))
    #expect(try fixture.hash() == before)

    try fixture.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","lspServers":"./skills/audit/language.json"}"#)
    try fixture.write(
      "bundle/skills/audit/SKILL.md", "---\nname: audit\ndescription: Audit\n---\nBody\n")
    try fixture.write(
      "bundle/skills/audit/language.json",
      #"{"language":{"command":"language-server","extensionToLanguage":{".x":"x"},"env":{"TOKEN":"LATE_SKILL_CANARY"}}}"#
    )
    let bundleBefore = try fixture.hash()
    let bundle = try SourceImport.preview(
      fixture.input(.claudePluginV1, "bundle/.claude-plugin/plugin.json"))
    #expect(bundle.components.contains { $0.declaration.kind == .skills })
    let skill = try #require(bundle.resources.first { $0.kind == .skills })
    #expect(skill.requiresBindingRewrite)
    #expect(skill.observedHash == nil)
    #expect(!String(reflecting: bundle).contains("LATE_SKILL_CANARY"))
    #expect(try fixture.hash() == bundleBefore)
  }

  @Test(arguments: [SourceImportProfile.openCodeCommandV2, .openCodeAgentV2])
  func openCodeMarkdownRejectsInvalidDescriptionAtOriginalField(_ profile: SourceImportProfile)
    throws
  {
    let fixture = try NativeImportFixture()
    try fixture.write("review.md", "---\ndescription: [invalid]\n---\nBody\n")
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(profile, "review.md"))
    #expect(result.components.isEmpty)
    #expect(
      result.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == "review.md"
          && $0.location.span?.line == 2
      })
    #expect(try fixture.hash() == before)
    try fixture.write("review.md", "---\ndescription: Review\n---\nBody\n")
    let valid = try SourceImport.preview(fixture.input(profile, "review.md"))
    #expect(valid.components.count == 1)
    #expect(valid.diagnostics.isEmpty)
  }

  @Test func geminiExtensionHooksRemainVisibleAndPrivatelyPreserved() throws {
    let fixture = try NativeImportFixture()
    try fixture.write("bundle/gemini-extension.json", #"{"name":"bundle","version":"1"}"#)
    try fixture.write(
      "bundle/commands/review.toml", "description='Review'\nprompt='Review changes'\n")
    try fixture.write(
      "bundle/hooks/hooks.json",
      #"{"hooks":{"BeforeTool":[{"hooks":[{"type":"command","command":"./check","token":"HOOK_LITERAL_CANARY"}]}]}}"#
    )
    let before = try fixture.hash()
    let result = try SourceImport.preview(
      fixture.input(.geminiExtensionV1, "bundle/gemini-extension.json"))
    #expect(result.components.count == 1)
    #expect(result.components.first?.declaration.kind == .command)
    #expect(
      result.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "bundle/hooks/hooks.json"
      })
    #expect(result.bindings.contains { $0.location.document == "bundle/hooks/hooks.json" })
    let hooks = try #require(result.resources.first { $0.path == "hooks/hooks.json" })
    #expect(hooks.requiresBindingRewrite && hooks.observedHash == nil)
    #expect(!String(reflecting: result).contains("HOOK_LITERAL_CANARY"))
    #expect(try fixture.hash() == before)
  }

  @Test func nativeMemberCoordinatesPreserveExactUTF8Selectors() throws {
    let fixture = try NativeImportFixture()
    try fixture.write("unicode/.claude-plugin/plugin.json", #"{"name":"unicode"}"#)
    for (path, name) in [("first", "\u{e9}"), ("second", "e\u{301}")] {
      try fixture.write(
        "unicode/agents/" + path + ".md",
        "---\nname: \(name)\ndescription: Agent\n---\nBody\n")
    }
    let result = try SourceImport.preview(
      fixture.input(.claudePluginV1, "unicode/.claude-plugin/plugin.json"))
    #expect(result.components.count == 2)
    let members = result.components.compactMap(\.member)
    #expect(members.count == 2)
    #expect(members.first != members.last)
    #expect(!result.diagnostics.contains { $0.code == .ambiguousSource })
    let first = try #require(members.first)
    #expect(first == first)
    try fixture.write(
      "unicode/agents/second.md", "---\nname: \u{e9}\ndescription: Agent\n---\nBody\n")
    let duplicate = try SourceImport.preview(
      fixture.input(.claudePluginV1, "unicode/.claude-plugin/plugin.json"))
    #expect(duplicate.components.isEmpty)
    #expect(duplicate.diagnostics.contains { $0.code == .ambiguousSource })
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
