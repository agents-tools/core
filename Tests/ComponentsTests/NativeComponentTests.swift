import AgentsManifest
import Foundation
import NativeDocuments
import Testing

@testable import AgentsCore
@testable import Components

@Suite("Concrete native component profiles")
struct NativeComponentTests {
  @Test func geminiCommandPreservesQuotedLiteralAndFrozenFileBody() throws {
    let fixture = try LinkFixture()
    let body = "Review \\\"quoted\\\" paths\nKeep exact content.\n"
    try fixture.write(body, to: "prompt.md", base: fixture.project)
    let item: [String: Any] = [
      "kind": "command", "name": "review", "description": "Review sources",
      "prompt": ["file": ["path": "prompt.md"]], "agents": ["gemini-cli"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .geminiCLI)]
    ledger = try prepared(ledger, fixture)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    let restored = try ResolvedLedgerCodec.decode(encoded, limits: .standard)
    try replay(restored, fixture) { outputs in
      let envelope = try #require(outputs[0].values?.object)
      #expect(envelope["route"]?.text == "geminiCommand")
      #expect(envelope["path"]?.text == "review.toml")
      let file = try #require(envelope["value"]?.text)
      let native = try NativeDocument(bytes: Data(file.utf8), format: .toml, budget: budget())
      #expect(try native.read(.init(keys: ["prompt"]))?.value == .string(body))
      #expect(try native.read(.init(keys: ["description"]))?.value == .string("Review sources"))
      #expect(!String(describing: envelope).contains(fixture.project.path))
    }
  }

  @Test(arguments: [NativeClientSurface.geminiCLI, .cursorEditor])
  func agentFrontmatterKeepsDescriptionAndToolSemantics(_ surface: NativeClientSurface) throws {
    let fixture = try LinkFixture()
    var item: [String: Any] = [
      "kind": "subagent", "name": "security-auditor",
      "description": "Audit: source\n---\nLiteral metadata",
      "prompt": "Inspect the source.",
      "model": "inherit", "agents": [surface.agent.rawValue],
    ]
    if surface == .geminiCLI { item["tools"] = ["read_file", "grep_search"] }
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      let envelope = try #require(output[0].values?.object)
      let text = try #require(envelope["value"]?.text)
      #expect(text.hasPrefix("---\ndescription: \"Audit: source\\n---\\nLiteral metadata\"\n"))
      #expect(text.hasSuffix("---\nInspect the source."))
      #expect(envelope["knownReaders"] == LedgerPayload.strings([surface.agent.rawValue]))
      if surface == .geminiCLI { #expect(text.contains("tools: [\"read_file\", \"grep_search\"]")) }
    }
  }

  @Test func codexRoleFreezesItsConfigAndRegistrationTogether() throws {
    let fixture = try LinkFixture()
    let item: [String: Any] = [
      "kind": "subagent", "name": "researcher", "description": "Research-focused role.",
      "prompt": "Read exact sources.\n", "model": "fixture-model", "agents": ["codex"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .codexCLI)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      let envelopes = try #require(output[0].values?.array)
      #expect(envelopes.count == 2)
      let text = try #require(envelopes[0].object?["value"]?.text)
      let doc = try NativeDocument(bytes: Data(text.utf8), format: .toml, budget: budget())
      #expect(
        try doc.read(.init(keys: ["developer_instructions"]))?.value
          == .string("Read exact sources.\n"))
      #expect(envelopes[1].object?["keys"] == LedgerPayload.strings(["agents", "researcher"]))
      #expect(
        envelopes[1].object?["value"]?.object?["config_file"]?.text == "./agents/researcher.toml")
    }
  }

  @Test func openCodeCommandAgentAndOrderedNativeToolPermissions() throws {
    let fixture = try LinkFixture()
    let components: [[String: Any]] = [
      [
        "kind": "command", "name": "review", "description": "Review sources",
        "prompt": "Review the source.", "agents": ["opencode"],
      ],
      [
        "kind": "subagent", "name": "reviewer", "description": "Review sources",
        "prompt": "Inspect source.", "model": "provider/model", "agents": ["opencode"],
      ],
      [
        "kind": "permissions", "name": "policy",
        "rules": [
          ["effect": "deny", "operation": ["tool": "read"], "pattern": "*"],
          ["effect": "allow", "operation": ["tool": "read"], "pattern": "src/**"],
          ["effect": "ask", "operation": ["tool": "read"], "pattern": "src/private/**"],
        ], "agents": ["opencode"],
      ],
    ]
    let (linked, frozen) = try freeze(components, fixture)
    var ledger = frozen.ledger
    ledger.lowerings = try linked.enumerated().map {
      try lower($0.element, frozen, surface: .openCodeCLI, id: "component-\($0.offset)")
    }
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      #expect(output[0].values?.object?["keys"] == LedgerPayload.strings(["commands", "review"]))
      #expect(output[0].values?.object?["value"]?.object?["template"]?.text == "Review the source.")
      #expect(output[1].values?.object?["value"]?.object?["mode"]?.text == "subagent")
      #expect(output[2].values?.object?["selection"]?.text == "orderedAppend")
      let rules = try #require(output[2].values?.object?["value"]?.array)
      #expect(rules.compactMap { $0.object?["effect"]?.text } == ["deny", "allow", "ask"])
      #expect(
        rules.compactMap { $0.object?["resource"]?.text } == ["*", "src/**", "src/private/**"])
      #expect(
        output.map { $0.values?.object?["occurrences"] }
          == linked.map { .init(array: $0.origins.map { .init(integer: $0.occurrence) }) })
    }
  }

  @Test(arguments: [NativeClientSurface.geminiCLI, .codexCLI])
  func nativeHookFreezesProgramAndStagedArgumentsWithoutExecuting(_ surface: NativeClientSurface)
    throws
  {
    let fixture = try LinkFixture()
    try fixture.write(
      "#!/bin/sh\n# source-owned fixture; never executed\n", to: "scripts/check",
      base: fixture.project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.project.appendingPathComponent("scripts/check").path)
    try fixture.write("data", to: "working/data", base: fixture.project)
    let item: [String: Any] = [
      "kind": "hook", "name": "check", "event": ["native": "SessionStart"],
      "run": [
        "executable": "./scripts/check",
        "arguments": ["a'b", "$(never-execute)", surface == .geminiCLI ? "plain" : "$ordinary"],
        "workingDirectory": ["path": "working"],
        "environment": ["TOKEN": ["secret": "fixture/token"]],
      ],
      "matcher": "startup", "timeoutSeconds": 7, "agents": [surface.agent.rawValue],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
    ledger = try prepared(ledger, fixture)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("private staged fixture"))
    try replay(ledger, fixture) { output in
      let envelope = try #require(output[0].values)
      let placements = Dictionary(
        uniqueKeysWithValues: frozen.ledger.components.values.first!.resources.enumerated().map {
          ($0.element, $0.offset == 0 ? "/registered/scripts/check" : "/registered/working")
        })
      let native = try NativeProgramV1.stagedValue(
        envelope,
        bindings: RuntimeBindingValues(["fixture/token": Data("private staged fixture".utf8)]),
        environment: fixture.environment, resourcePaths: placements, budget: budget(),
        codexCommandShell: .posix)
      guard case .object(let group) = native, case .array(let hooks) = group["hooks"],
        case .object(let hook) = hooks.first
      else {
        Issue.record("missing native hook group")
        return
      }
      #expect(hook["timeout"] == .integer(surface == .geminiCLI ? 7000 : 7))
      #expect(
        hook["command"]
          == .string(
            "cd -- '/registered/working' && env 'TOKEN=private staged fixture' '/registered/scripts/check' 'a'\\''b' '$(never-execute)' '"
              + (surface == .geminiCLI ? "plain" : "$ordinary") + "'"
          ))
    }
  }

  @Test func openCodeLSPPreservesSymbolicEnvAndInitialization() throws {
    let fixture = try LinkFixture()
    let item: [String: Any] = [
      "kind": "lspServer", "name": "fixture",
      "run": [
        "executable": "fixture-lsp", "arguments": ["--stdio"],
        "environment": ["TOKEN": ["env": "SOURCE"]],
      ],
      "languages": [:],
      "initializationOptions": [
        "nested": ["enabled": true], "resource": "ordinary", "program": ["setting": "retained"],
      ],
      "agents": ["opencode"],
      "native": ["opencode": ["extensions": [".fixture"]]],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .openCodeCLI)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      let envelope = try #require(output[0].values)
      let environment = RuntimeEnvironment(
        projectDirectory: fixture.project, homeDirectory: fixture.home,
        environment: ["SOURCE": "fixture value"])
      let value = try NativeProgramV1.stagedValue(
        envelope, bindings: RuntimeBindingValues([:]), environment: environment, resourcePaths: [:],
        budget: budget())
      #expect(
        value
          == .object([
            "command": .array([.string("fixture-lsp"), .string("--stdio")]),
            "env": .object(["TOKEN": .string("fixture value")]),
            "initialization": .object([
              "nested": .object(["enabled": .boolean(true)]), "resource": .string("ordinary"),
              "program": .object(["setting": .string("retained")]),
            ]),
            "extensions": .array([.string(".fixture")]),
          ]))
    }
  }

  @Test func nativePluginColdReplayKeepsManifestScriptsAndExecutableBits() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      #"{"name":"fixture-plugin","version":"1.0.0","description":"Fixture"}"#,
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    try fixture.write(
      "#!/bin/sh\n# never executed\n", to: "bundle/scripts/check", base: fixture.project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.project.appendingPathComponent("bundle/scripts/check").path)
    try fixture.write("Review source.", to: "bundle/commands/review.md", base: fixture.project)
    let item: [String: Any] = [
      "kind": "plugin", "name": "fixture-plugin", "path": "bundle", "source": ".", "mode": "native",
      "agents": ["claude-code"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .claudeCode)]
    ledger = try prepared(ledger, fixture)
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    try replay(ResolvedLedgerCodec.decode(bytes, limits: .standard), fixture) { output in
      #expect(output[0].values?.object?["route"]?.text == "claudeSkillPlugin")
      let root = try #require(output[1].tree)
      #expect(
        try String(contentsOf: root.appendingPathComponent("commands/review.md"), encoding: .utf8)
          == "Review source.")
      let attributes = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent("scripts/check").path)
      #expect((attributes[.posixPermissions] as! NSNumber).intValue & 0o111 != 0)
    }
  }

  @Test func arrayOccurrenceEvidenceRematchesAndPreservesUnmanagedSiblings() throws {
    let before =
      #"{"permissions":[{"action":"read","resource":"a","effect":"deny"}, {"action":"read","resource":"b","effect":"ask"}, {"action":"read","resource":"c","effect":"allow"}],"privateSibling":"keep"}"#
    let doc = try NativeDocument(bytes: Data(before.utf8), format: .json, budget: budget())
    let array = try #require(try doc.read(.init(keys: ["permissions"])))
    let original = array.occurrences[1]
    let retained = NativeOccurrenceEvidence(
      snapshot: try #require(original.snapshot), ordinal: try #require(original.ordinal),
      previous: original.previous, next: original.next)
    let region = NativeRegion([.key("permissions"), .occurrence(retained)])
    let knownOwned = try #require(try doc.read(region))
    let prepared = try doc.prepare([.remove(region: region, expected: .owned(knownOwned))])
    #expect(String(decoding: prepared.bytes, as: UTF8.self).contains(#""privateSibling":"keep""#))
    let changed = try NativeDocument(
      bytes: Data(
        before.replacingOccurrences(of: #""resource":"b""#, with: #""resource":"external""#).utf8),
      format: .json, budget: budget())
    #expect(throws: NativeDocumentError.self) {
      try changed.prepare([.remove(region: region, expected: .owned(knownOwned))])
    }
  }

  @Test func unsupportedAndUnverifiedRemainPreciseAndValueFree() throws {
    let fixture = try LinkFixture()
    let item: [String: Any] = [
      "kind": "command", "name": "exact", "description": "Fixture",
      "prompt": "SENSITIVE_FIXTURE", "agents": ["codex"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    do {
      _ = try lower(linked[0], frozen, surface: .codexCLI)
      Issue.record("persistent Codex command accepted")
    } catch let issue as NativeComponentIssue {
      #expect(issue.reason == .unsupported)
      #expect(issue.field == ["kind"])
      #expect(issue.component == "exact")
      #expect(!issue.description.contains("SENSITIVE_FIXTURE"))
    }
    #expect(throws: NativeComponentIssue.self) {
      try CapabilityRegistry.component(
        .init(surface: .cursorCloud, scope: .project), kind: .subagent, name: "exact")
    }
    #expect(throws: NativeComponentIssue.self) {
      try CapabilityRegistry.component(
        .init(surface: .cursorEditor, scope: .user), kind: .command, name: "exact")
    }
    #expect(throws: NativeComponentIssue.self) {
      try CapabilityRegistry.component(
        .init(surface: .codexCLI, scope: .project), kind: .permissions, name: "exact")
    }
  }

  @Test func currentIgnoreProfilesKeepOrderAndPurpose() throws {
    let fixture = try LinkFixture()
    for surface in [NativeClientSurface.geminiCLI, .cursorEditor] {
      let item: [String: Any] = [
        "kind": "ignore", "name": "private", "patterns": ["private/**", "!private/public.txt"],
        "purpose": "context", "agents": [surface.agent.rawValue],
      ]
      let (linked, frozen) = try freeze([item], fixture)
      var ledger = frozen.ledger
      ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
      ledger = try prepared(ledger, fixture)
      try replay(ledger, fixture) { output in
        #expect(output[0].values?.object?["selection"]?.text == "managedIgnore")
        #expect(
          output[0].values?.object?["value"]
            == LedgerPayload.strings(["private/**", "!private/public.txt"]))
      }
    }
  }

  @Test func profileLossAndInterpolationFailBeforePublication() throws {
    let fixture = try LinkFixture()
    let cases: [([String: Any], NativeClientSurface, [String], NativeAdapterIssue.Reason)] = [
      (
        [
          "kind": "command", "name": "exact", "description": "Fixture",
          "prompt": "$${input:literal}", "agents": ["gemini-cli"],
        ],
        .geminiCLI, ["prompt"], .unverified
      ),
      (
        [
          "kind": "command", "name": "exact", "description": "Fixture", "prompt": "$ARGUMENTS",
          "agents": ["opencode"],
        ], .openCodeCLI, ["prompt"], .unverified
      ),
      (
        [
          "kind": "command", "name": "exact", "description": "Fixture", "prompt": "  indented",
          "agents": ["opencode"],
        ], .openCodeCLI, ["prompt"], .unsupported
      ),
      (
        [
          "kind": "command", "name": "exact", "description": "Fixture",
          "prompt": "Use ${input:branch}",
          "parameters": [["name": "branch", "description": "Branch", "defaultValue": "main"]],
          "agents": ["gemini-cli"],
        ], .geminiCLI, ["parameters"], .unsupported
      ),
      (
        [
          "kind": "subagent", "name": "exact", "description": "Fixture", "prompt": "Prompt",
          "native": ["gemini-cli": ["max_turns": 1.5]], "agents": ["gemini-cli"],
        ], .geminiCLI, ["native", "gemini-cli", "max_turns"], .invalid
      ),
      (
        [
          "kind": "lspServer", "name": "exact", "run": ["executable": "fixture"],
          "languages": [".ts": "typescript"], "agents": ["opencode"],
        ], .openCodeCLI, ["languages"], .unverified
      ),
    ]
    for (item, surface, field, reason) in cases {
      let (linked, frozen) = try freeze([item], fixture)
      var ledger = frozen.ledger
      ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
      do {
        _ = try prepared(ledger, fixture)
        Issue.record("unrepresentable native profile accepted")
      } catch let issue as NativeComponentIssue {
        #expect(issue.field == field)
        #expect(issue.reason == reason)
        #expect(issue.component == "exact")
      }
    }
  }

  @Test func cursorProjectCommandAndGeminiNativeExtensionHaveClosedRoutes() throws {
    let fixture = try LinkFixture()
    let command: [String: Any] = [
      "kind": "command", "name": "review", "description": "", "prompt": "Review source.\n",
      "agents": ["cursor"],
    ]
    let (linked, frozen) = try freeze([command], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .cursorEditor)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      #expect(output[0].values?.object?["value"]?.text == "Review source.\n")
      #expect(output[0].values?.object?["route"]?.text == "cursorCommand")
    }
    try fixture.write(
      #"{"name":"extension-fixture","version":"1.0.0"}"#, to: "extension/gemini-extension.json",
      base: StateStore(scope: .user, environment: fixture.environment).directory)
    try fixture.write(
      #"prompt = "Review source.""# + "\n", to: "extension/commands/review.toml",
      base: StateStore(scope: .user, environment: fixture.environment).directory)
    let plugin: [String: Any] = [
      "kind": "plugin", "name": "extension-fixture", "path": "extension", "source": ".",
      "mode": "native", "agents": ["gemini-cli"],
    ]
    let (plugins, pluginFrozen) = try freeze([plugin], fixture, scope: .user)
    var pluginLedger = pluginFrozen.ledger
    pluginLedger.lowerings = [
      try NativeComponentLowering.lower(
        plugins[0], frozen: pluginFrozen,
        request: .init(surface: .geminiCLI, scope: .user), id: "extension", platform: platform)
    ]
    pluginLedger = try prepared(pluginLedger, fixture)
    try replay(pluginLedger, fixture) { output in
      #expect(output[0].values?.object?["route"]?.text == "geminiExtension")
      #expect(output[0].values?.object?["scope"]?.text == "user")
      let root = try #require(output[1].tree)
      let bytes = try Data(contentsOf: root.appendingPathComponent("commands/review.toml"))
      let native = try NativeDocument(bytes: bytes, format: .toml, budget: budget())
      #expect(try native.read(.init(keys: ["prompt"]))?.value == .string("Review source."))
    }
  }

  @Test func sourceDerivedNativeRejectionsAndLockedOutputBudget() throws {
    let fixture = try LinkFixture()
    let cases: [([String: Any], NativeClientSurface, [String])] = [
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "SessionEnd"], "timeoutSeconds": 4,
          "run": ["executable": "fixture"], "agents": ["codex"],
        ], .codexCLI, ["timeoutSeconds"]
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "Stop"], "matcher": "ignored",
          "run": ["executable": "fixture"], "agents": ["codex"],
        ], .codexCLI, ["matcher"]
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "SessionStart"],
          "run": ["executable": "fixture", "arguments": ["$ordinary"]], "agents": ["gemini-cli"],
        ],
        .geminiCLI, ["run", "arguments", "0"]
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": "beforeTool", "run": ["executable": "fixture"],
          "agents": ["gemini-cli"],
        ], .geminiCLI, ["event"]
      ),
      (
        [
          "kind": "subagent", "name": "exact", "description": "Description", "prompt": "Prompt",
          "tools": ["not_a_native_tool"], "agents": ["gemini-cli"],
        ], .geminiCLI, ["tools", "0"]
      ),
      (
        [
          "kind": "subagent", "name": "exact", "description": "Description",
          "prompt": "Prompt\u{FEFF}",
          "agents": ["gemini-cli"],
        ], .geminiCLI, ["prompt"]
      ),
    ]
    for (item, surface, field) in cases {
      let (linked, frozen) = try freeze([item], fixture)
      var ledger = frozen.ledger
      ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
      do {
        _ = try prepared(ledger, fixture)
        Issue.record("native loss was accepted")
      } catch let issue as NativeComponentIssue { #expect(issue.field == field) }
    }
    let item: [String: Any] = [
      "kind": "command", "name": "budget", "description": "Description", "prompt": "Body",
      "agents": ["gemini-cli"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    let lowering = try lower(linked[0], frozen, surface: .geminiCLI)
    var limits = LedgerLimits.standard
    limits.resourceBytes = 1
    let render = try #require(NativeComponentLayoutsV1.renderers(limits: limits)[lowering.format])
    #expect(throws: NativeComponentIssue.self) { try render(lowering, frozen.ledger, [:]) }
    var ledger = frozen.ledger
    ledger.lowerings = [lowering]
    ledger = try prepared(ledger, fixture)
    ledger.lowerings[0].format = "agents/gemini-components@999"
    #expect(throws: CoreError.self) { try replay(ledger, fixture) { _ in } }
  }

  @Test func coalescedConditionsKeepInactiveOriginsAndSelectTheActiveOccurrence() throws {
    let fixture = try LinkFixture()
    let base: [String: Any] = [
      "kind": "permissions", "name": "same", "agents": ["opencode"],
      "rules": [["effect": "allow", "operation": ["tool": "read"], "pattern": "src/**"]],
    ]
    var project = base
    project["condition"] = ["scopes": ["project"], "platforms": [platform.rawValue]]
    var user = base
    user["condition"] = ["scopes": ["user"], "platforms": [platform.rawValue]]
    let (linked, frozen) = try freeze([project, user], fixture)
    #expect(linked.count == 1)
    #expect(linked[0].origins.count == 2)
    #expect(frozen.ledger.occurrences.count == 2)
    #expect(frozen.ledger.components.values.first?.conditions.count == 2)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .openCodeCLI)]
    let otherPlatform: DeclarationPlatform = platform == .macOS ? .linux : .macOS
    do {
      _ = try NativeComponentLowering.lower(
        linked[0], frozen: frozen, request: .init(surface: .openCodeCLI, scope: .project),
        id: "wrong-platform", platform: otherPlatform)
      Issue.record("accepted an output platform excluded by its frozen occurrence")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["platform"])
      #expect(issue.reason == .invalid)
    }
    var mismatched = ledger.lowerings[0]
    mismatched.platform = otherPlatform.rawValue
    let renderer = try #require(
      NativeComponentLayoutsV1.renderers(limits: .standard)[mismatched.format])
    #expect(throws: CoreError.self) { try renderer(mismatched, ledger, [:]) }
    #expect(
      ledger.lowerings[0].layout.object?["occurrences"]
        == .init(array: [.init(integer: linked[0].origins[0].occurrence)]))
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      #expect(
        output[0].values?.object?["occurrences"]
          == .init(array: [.init(integer: linked[0].origins[0].occurrence)]))
    }
    #expect(ledger.occurrences.count == 2)
  }

  @Test func claudeFilesUseTheirDistinctFrontmatterContracts() throws {
    let fixture = try LinkFixture()
    let items: [[String: Any]] = [
      [
        "kind": "command", "name": "review", "description": "Review sources",
        "prompt": "Keep exact text.\n",
        "agents": ["claude-code"],
        "native": ["claude-code": ["disable-model-invocation": true, "allowed-tools": ["Read"]]],
      ],
      [
        "kind": "subagent", "name": "reviewer", "description": "Audit: sources",
        "prompt": "Review source.",
        "tools": ["Read", "Bash"], "model": "inherit", "agents": ["claude-code"],
        "native": [
          "claude-code": [
            "disallowedTools": ["Bash"], "maxTurns": 5, "permissionMode": "plan",
            "background": false,
          ]
        ],
      ],
    ]
    let (linked, frozen) = try freeze(items, fixture)
    var ledger = frozen.ledger
    ledger.lowerings = try linked.enumerated().map {
      try lower($0.element, frozen, surface: .claudeCode, id: "file-\($0.offset)")
    }
    #expect(ledger.lowerings.allSatisfy { $0.format == "agents/claude-components@2" })
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      let command = try #require(output[0].values?.object?["value"]?.text)
      #expect(command.contains("disable-model-invocation: true"))
      #expect(command.hasSuffix("---\nKeep exact text.\n"))
      #expect(!command.contains("\nname:"))
      let agent = try #require(output[1].values?.object?["value"]?.text)
      #expect(agent.contains("disallowedTools: [\"Bash\"]"))
      #expect(agent.contains("maxTurns: 5"))
      #expect(agent.contains("permissionMode: \"plan\""))
      #expect(output[0].values?.object?["route"]?.text == "claudeCommand")
      #expect(output[1].values?.object?["route"]?.text == "claudeAgent")
      #expect(
        output[1].values?.object?["knownReaders"]
          == LedgerPayload.strings(["claude-code", "cursor"]))
      #expect(output[1].values?.object?["recipients"] == LedgerPayload.strings(["claude-code"]))
    }
  }

  @Test(arguments: [NativeClientSurface.claudeCode, .cursorEditor, .cursorCLI, .cursorCloud])
  func documentedNativeHooksKeepShapesAndPrivateArguments(_ surface: NativeClientSurface) throws {
    let fixture = try LinkFixture()
    let item: [String: Any] = [
      "kind": "hook", "name": "guard",
      "event": ["native": surface == .claudeCode ? "PreToolUse" : "beforeShellExecution"],
      "run": [
        "executable": "fixture-hook", "arguments": ["a'b", "$(never-execute)"],
        "environment": ["TOKEN": ["secret": "fixture/hook"]],
      ],
      "matcher": surface == .claudeCode ? "Bash|Edit" : "curl|wget", "timeoutSeconds": 9,
      "agents": [surface.agent.rawValue],
      "native": [
        surface.agent.rawValue: surface == .claudeCode
          ? ["onFailure": "block"] : ["failClosed": true]
      ],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
    ledger = try prepared(ledger, fixture)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("staged hook value"))
    try replay(ledger, fixture) { output in
      let envelope = try #require(output[0].values)
      if surface == .cursorEditor {
        #expect(envelope.object?["rootRequirements"]?.object?["version"]?.integer == 1)
        #expect(envelope.object?["value"]?.object?["matcher"]?.text == "curl|wget")
        #expect(throws: NativeComponentIssue.self) {
          try NativeProgramV1.stagedValue(
            envelope, bindings: .init([:]), environment: fixture.environment, resourcePaths: [:],
            budget: budget())
        }
      }
      let native = try NativeProgramV1.stagedValue(
        envelope, bindings: .init(["fixture/hook": Data("staged hook value".utf8)]),
        environment: fixture.environment, resourcePaths: [:], budget: budget(),
        cursorCommandShell: .posix)
      guard case .object(let object) = native else {
        Issue.record("missing native hook")
        return
      }
      let handler: [String: NativeValue]
      if surface == .claudeCode {
        #expect(
          envelope.object?["knownReaders"] == LedgerPayload.strings(["claude-code", "cursor"]))
        #expect(envelope.object?["recipients"] == LedgerPayload.strings(["claude-code"]))
        #expect(object["matcher"] == .string("Bash|Edit"))
        guard case .array(let handlers) = object["hooks"], case .object(let first) = handlers.first
        else {
          Issue.record("missing Claude group")
          return
        }
        handler = first
        #expect(handler["onFailure"] == .string("block"))
      } else {
        handler = object
        #expect(handler["failClosed"] == .boolean(true))
      }
      #expect(handler["timeout"] == .integer(9))
      #expect(
        handler["command"]
          == .string("env 'TOKEN=staged hook value' 'fixture-hook' 'a'\\''b' '$(never-execute)'"))
    }
  }

  @Test func claudeLSPFreezesGeneratedManifestAndPrivateSlots() throws {
    let fixture = try LinkFixture()
    try fixture.write("#!/bin/sh\n# never executed\n", to: "bin/server", base: fixture.project)
    let item: [String: Any] = [
      "kind": "lspServer", "name": "fixture-lsp",
      "run": [
        "executable": "./bin/server", "arguments": ["--stdio"],
        "environment": ["TOKEN": ["secret": "fixture/lsp"]],
      ],
      "languages": [".fixture": "fixture"],
      "initializationOptions": ["resource": "ordinary", "program": ["setting": true]],
      "agents": ["claude-code"],
      "native": [
        "claude-code": [
          "transport": "socket", "startupTimeout": 1000, "shutdownTimeout": 2000,
          "requestTimeout": 3000, "restartOnCrash": false, "maxRestarts": 0, "diagnostics": false,
          "settings": ["literal": "${ordinary}"], "workspaceFolder": "./workspace",
        ]
      ],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .claudeCode)]
    ledger = try prepared(ledger, fixture)
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    try replay(ResolvedLedgerCodec.decode(bytes, limits: .standard), fixture) { output in
      let envelope = try #require(output[0].values)
      #expect(envelope.object?["selection"]?.text == "generatedPlugin")
      #expect(envelope.object?["route"]?.text == "claudeSkillPlugin")
      let id = try #require(frozen.ledger.components.values.first?.resources.first)
      let materialized = try NativeProgramV1.stagedValue(
        envelope, bindings: .init(["fixture/lsp": Data("staged LSP value".utf8)]),
        environment: fixture.environment,
        resourcePaths: [id: "/registered/bin/server"], budget: budget())
      guard case .object(let files) = materialized,
        case .object(let manifest) = files[".claude-plugin/plugin.json"],
        case .object(let servers) = manifest["lspServers"],
        case .object(let config) = servers["fixture-lsp"]
      else {
        Issue.record("missing generated native manifest")
        return
      }
      #expect(config["command"] == .string("/registered/bin/server"))
      #expect(config["transport"] == .string("socket"))
      #expect(config["diagnostics"] == .boolean(false))
      #expect(config["requestTimeout"] == .integer(3000))
      #expect(config["settings"] == .object(["literal": .string("${ordinary}")]))
      #expect(
        config["initializationOptions"]
          == .object([
            "resource": .string("ordinary"), "program": .object(["setting": .boolean(true)]),
          ]))
      #expect(config["env"] == .object(["TOKEN": .string("staged LSP value")]))
      for invalid in [Data([0xff]), Data([0]), Data("${CLAUDE_PLUGIN_ROOT}".utf8)] {
        do {
          _ = try NativeProgramV1.stagedValue(
            envelope, bindings: .init(["fixture/lsp": invalid]), environment: fixture.environment,
            resourcePaths: [id: "/registered/bin/server"], budget: budget())
          Issue.record("accepted a nonliteral staged native value")
        } catch let issue as NativeComponentIssue {
          #expect(
            issue.field == [
              ".claude-plugin/plugin.json", "lspServers", "fixture-lsp", "env", "TOKEN",
            ])
          #expect(!issue.description.contains("${CLAUDE_PLUGIN_ROOT}"))
        }
      }
    }
    #expect(!String(decoding: bytes, as: UTF8.self).contains("staged LSP value"))
  }

  @Test func claudeExplicitNativePolicyKeepsCategoryPrecedence() throws {
    let fixture = try LinkFixture()
    let item: [String: Any] = [
      "kind": "permissions", "name": "native-policy", "rules": [], "agents": ["claude-code"],
      "native": [
        "claude-code": [
          "allow": ["Bash(git *)"], "ask": ["Edit"], "deny": ["Read(./secret/**)"],
          "defaultMode": "plan",
        ]
      ],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .claudeCode)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      #expect(output[0].values?.object?["selection"]?.text == "nativePolicy")
      let policy = try #require(output[0].values?.object?["value"]?.object)
      #expect(policy["deny"] == LedgerPayload.strings(["Read(./secret/**)"]))
      #expect(policy["allow"] == LedgerPayload.strings(["Bash(git *)"]))
    }
  }

  @Test func documentedIgnoredAndUnverifiedHookCombinationsAreDiagnosed() throws {
    let fixture = try LinkFixture()
    let cases: [([String: Any], NativeClientSurface, [String], NativeAdapterIssue.Reason)] = [
      (
        [
          "kind": "subagent", "name": "exact", "description": "Fixture", "prompt": "Prompt",
          "agents": ["claude-code"], "native": ["claude-code": ["max_turns": 2]],
        ], .claudeCode, ["native", "claude-code", "max_turns"], .unverified
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "Stop"],
          "run": ["executable": "fixture"], "matcher": "Bash", "agents": ["claude-code"],
        ], .claudeCode, ["matcher"], .unsupported
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "PreToolUse"],
          "run": ["executable": "fixture"], "timeoutSeconds": 4,
          "native": ["claude-code": ["async": true]], "agents": ["claude-code"],
        ], .claudeCode, ["timeoutSeconds"], .unsupported
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "sessionStart"],
          "run": ["executable": "fixture"], "native": ["cursor": ["failClosed": true]],
          "agents": ["cursor"],
        ], .cursorEditor, ["native", "cursor", "failClosed"], .unsupported
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "preToolUse"],
          "run": ["executable": "fixture"], "native": ["cursor": ["loop_limit": 3]],
          "agents": ["cursor"],
        ], .cursorEditor, ["native", "cursor", "loop_limit"], .unsupported
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "sessionStart"],
          "run": ["executable": "fixture"], "agents": ["cursor"],
        ], .cursorCloud, ["event"], .unsupported
      ),
      (
        [
          "kind": "permissions", "name": "exact",
          "rules": [
            ["effect": "deny", "operation": ["tool": "Read"], "pattern": "*"],
            ["effect": "allow", "operation": ["tool": "Read"], "pattern": "src/**"],
          ], "agents": ["claude-code"],
        ], .claudeCode, ["rules"], .unverified
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "beforeTabFileRead"],
          "run": ["executable": "fixture"], "agents": ["cursor"],
        ], .cursorCLI, ["event"], .unsupported
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "beforeMCPExecution"],
          "run": ["executable": "fixture"], "matcher": "native-server", "agents": ["cursor"],
        ], .cursorEditor, ["matcher"], .unverified
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "PreToolUse"],
          "run": ["executable": "fixture"], "matcher": "[", "agents": ["claude-code"],
        ], .claudeCode, ["matcher"], .unverified
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": "beforeTool", "run": ["executable": "fixture"],
          "agents": ["claude-code"],
        ], .claudeCode, ["event"], .unverified
      ),
      (
        [
          "kind": "hook", "name": "exact", "event": ["native": "preToolUse"],
          "run": ["executable": "fixture"], "native": ["cursor": ["type": "prompt"]],
          "agents": ["cursor"],
        ], .cursorEditor, ["native", "cursor", "type"], .unsupported
      ),
    ]
    for (item, surface, field, reason) in cases {
      let (linked, frozen) = try freeze([item], fixture)
      var ledger = frozen.ledger
      ledger.lowerings = [try lower(linked[0], frozen, surface: surface)]
      do {
        _ = try prepared(ledger, fixture)
        Issue.record("accepted a lost native intent")
      } catch let issue as NativeComponentIssue {
        #expect(issue.field == field)
        #expect(issue.reason == reason)
      }
    }
  }

  @Test func nativeManifestFieldsPreserveFrozenChildrenAndColdV1Replay() throws {
    let fixture = try LinkFixture()
    let manifest: [String: Any] = [
      "name": "native-fields", "version": "build-label", "author": ["name": "Fixture"],
      "commands": [
        "about": ["content": "Review source.", "argumentHint": "[file]", "allowedTools": ["Read"]]
      ],
      "agents": ["./agents/reviewer.md"], "skills": ["./skills"],
      "userConfig": [
        "token": [
          "type": "string", "title": "Token", "description": "Native client-owned token",
          "sensitive": true,
        ],
        "tone": [
          "type": "string", "title": "Tone", "description": "Picker",
          "options": ["neutral", "warm"], "required": true,
        ],
      ],
      "hooks": ["Stop": [["hooks": [["type": "prompt", "prompt": "Review $ARGUMENTS"]]]]],
      "mcpServers": [
        "fixture": [
          "type": "stdio", "command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/server.js"],
        ]
      ],
      "lspServers": [
        "fixture": [
          "command": "fixture-lsp", "extensionToLanguage": [".fixture": "fixture"],
          "transport": "socket", "diagnostics": false,
        ]
      ],
    ]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self),
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    try fixture.write(
      "---\nname: reviewer\ndescription: Fixture\n---\nReview source.",
      to: "bundle/agents/reviewer.md", base: fixture.project)
    try fixture.write("# Fixture", to: "bundle/skills/fixture/SKILL.md", base: fixture.project)
    try fixture.write("Default command.", to: "bundle/commands/default.md", base: fixture.project)
    let item: [String: Any] = [
      "kind": "plugin", "name": "native-fields", "path": "bundle", "source": ".", "mode": "native",
      "agents": ["claude-code"],
    ]
    let (linked, frozen) = try freeze([item], fixture)
    var ledger = frozen.ledger
    ledger.lowerings = [try lower(linked[0], frozen, surface: .claudeCode)]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      let root = try #require(output[1].tree)
      let bytes = try Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))
      let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      #expect(object["version"] as? String == "build-label")
      #expect(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("commands/default.md").path))
      #expect(object["commands"] is [String: Any])
    }
    var invalid = manifest
    invalid["agents"] = ["agents/reviewer.md"]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self),
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    let (badLinked, badFrozen) = try freeze([item], fixture)
    var bad = badFrozen.ledger
    bad.lowerings = [try lower(badLinked[0], badFrozen, surface: .claudeCode)]
    do {
      _ = try prepared(bad, fixture)
      Issue.record("accepted a native path without its required prefix")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["manifest", "agents", "0"])
      #expect(issue.reason == .invalid)
    }
    invalid = manifest
    invalid["hooks"] = [
      "PermissionRequest": [["hooks": [["type": "agent", "prompt": "Review request"]]]]
    ]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self),
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    let (skippedLinked, skippedFrozen) = try freeze([item], fixture)
    var skipped = skippedFrozen.ledger
    skipped.lowerings = [try lower(skippedLinked[0], skippedFrozen, surface: .claudeCode)]
    do {
      _ = try prepared(skipped, fixture)
      Issue.record("accepted a handler type the native event skips")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["manifest", "hooks", "PermissionRequest", "type"])
      #expect(issue.reason == .unsupported)
    }
    invalid["hooks"] = [
      "Stop": [["hooks": [["type": "command", "command": "fixture", "onFailure": "block"]]]]
    ]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self),
      to: "bundle/.claude-plugin/plugin.json", base: fixture.project)
    let (ignoredLinked, ignoredFrozen) = try freeze([item], fixture)
    var ignored = ignoredFrozen.ledger
    ignored.lowerings = [try lower(ignoredLinked[0], ignoredFrozen, surface: .claudeCode)]
    do {
      _ = try prepared(ignored, fixture)
      Issue.record("accepted a native failure policy with no effect")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["manifest", "hooks", "Stop", "onFailure"])
      #expect(issue.reason == .unsupported)
    }
    // Revision 1 uses its frozen metadata-only validator and continues to replay valid bundles.
    try fixture.write(
      #"{"name":"native-fields","version":"1.0.0"}"#, to: "simple/.claude-plugin/plugin.json",
      base: fixture.project)
    var simple = item
    simple["path"] = "simple"
    let (oldLinked, oldFrozen) = try freeze([simple], fixture)
    var old = oldFrozen.ledger
    var lowering = try lower(oldLinked[0], oldFrozen, surface: .claudeCode)
    lowering.format = "agents/claude-components@1"
    old.lowerings = [lowering]
    old = try prepared(old, fixture)
    let locked = try ResolvedLedgerCodec.encode(old, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    try replay(ResolvedLedgerCodec.decode(locked, limits: .standard), fixture) { output in
      #expect(output.count == 2)
      #expect(output[0].values?.object?["route"]?.text == "claudeSkillPlugin")
    }
  }

  @Test func cursorManifestUsesSelectedPathsAndCommandOnlyPluginHooks() throws {
    let fixture = try LinkFixture()
    let base = StateStore(scope: .user, environment: fixture.environment).directory
    let manifest: [String: Any] = [
      "name": "cursor-fields", "version": "1.2.3",
      "author": ["name": "Fixture", "email": "fixture@example.test"],
      "commands": "./commands", "rules": "./rules", "agents": "./agents", "skills": "./skills",
      "hooks": "./config/hooks.json", "mcpServers": ["./config/mcp.json"],
      "variables": [
        "type": "object", "properties": ["TOKEN": ["type": "string", "title": "Token"]],
        "required": ["TOKEN"],
      ],
    ]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self),
      to: "bundle/.cursor-plugin/plugin.json", base: base)
    for path in [
      "commands/check.md", "rules/check.mdc", "agents/check.md", "skills/check/SKILL.md",
    ] {
      try fixture.write("Fixture source.", to: "bundle/" + path, base: base)
    }
    try fixture.write(
      #"{"hooks":{"beforeShellExecution":[{"command":"./scripts/check.sh","matcher":"curl|wget","failClosed":true}]}}"#,
      to: "bundle/config/hooks.json", base: base)
    try fixture.write(
      #"{"mcpServers":{"fixture":{"command":"node","args":["${CURSOR_PLUGIN_ROOT}/server.js"],"cwd":"${CURSOR_PLUGIN_ROOT}"}}}"#,
      to: "bundle/config/mcp.json", base: base)
    // An explicit Cursor hooks path replaces this default discovery file.
    try fixture.write(
      #"{"hooks":{"stop":[{"type":"prompt","command":"not-selected"}]}}"#,
      to: "bundle/hooks/hooks.json", base: base)
    let item: [String: Any] = [
      "kind": "plugin", "name": "cursor-fields", "path": "bundle", "source": ".", "mode": "native",
      "agents": ["cursor"],
    ]
    let (linked, frozen) = try freeze([item], fixture, scope: .user)
    var ledger = frozen.ledger
    ledger.lowerings = [
      try NativeComponentLowering.lower(
        linked[0], frozen: frozen, request: .init(surface: .cursorEditor, scope: .user),
        id: "cursor-plugin", platform: platform)
    ]
    ledger = try prepared(ledger, fixture)
    try replay(ledger, fixture) { output in
      #expect(output[0].values?.object?["route"]?.text == "cursorLocalPlugin")
      let tree = try #require(output[1].tree)
      #expect(
        try String(contentsOf: tree.appendingPathComponent("config/hooks.json"), encoding: .utf8)
          .contains("failClosed"))
      #expect(
        try String(contentsOf: tree.appendingPathComponent("hooks/hooks.json"), encoding: .utf8)
          .contains("not-selected"))
    }
    var changed = manifest
    changed["hooks"] = "./hooks/hooks.json"
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: changed), as: UTF8.self),
      to: "bundle/.cursor-plugin/plugin.json", base: base)
    let (badLinked, badFrozen) = try freeze([item], fixture, scope: .user)
    var bad = badFrozen.ledger
    bad.lowerings = [
      try NativeComponentLowering.lower(
        badLinked[0], frozen: badFrozen, request: .init(surface: .cursorEditor, scope: .user),
        id: "cursor-plugin", platform: platform)
    ]
    do {
      _ = try prepared(bad, fixture)
      Issue.record("accepted a prompt handler in a Cursor plugin")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["manifest", "hooks", "stop", "type"])
      #expect(issue.reason == .unsupported)
    }
    changed["hooks"] = ["hooks": ["stop": [["command": "fixture"]]]]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: changed), as: UTF8.self),
      to: "bundle/.cursor-plugin/plugin.json", base: base)
    let (inlineLinked, inlineFrozen) = try freeze([item], fixture, scope: .user)
    var inline = inlineFrozen.ledger
    inline.lowerings = [
      try NativeComponentLowering.lower(
        inlineLinked[0], frozen: inlineFrozen, request: .init(surface: .cursorEditor, scope: .user),
        id: "cursor-plugin", platform: platform)
    ]
    do {
      _ = try prepared(inline, fixture)
      Issue.record("guessed an inline Cursor wrapper")
    } catch let issue as NativeComponentIssue {
      #expect(issue.field == ["manifest", "hooks"])
      #expect(issue.reason == .unverified)
    }
  }

  private var platform: DeclarationPlatform {
    #if os(macOS)
      .macOS
    #else
      .linux
    #endif
  }

  private func lower(
    _ linked: LinkedComponent, _ frozen: LedgerFreeze.Result,
    surface: NativeClientSurface, id: String = "native"
  ) throws -> LockedLowering {
    try NativeComponentLowering.lower(
      linked, frozen: frozen,
      request: .init(surface: surface, scope: .project), id: id, platform: platform)
  }
  private func freeze(
    _ items: [[String: Any]], _ fixture: LinkFixture, scope: InstallScope = .project
  ) throws -> (
    [LinkedComponent], LedgerFreeze.Result
  ) {
    let bytes = try JSONSerialization.data(
      withJSONObject: ["version": 1, "components": items], options: [.sortedKeys])
    let document = try DeclarationDocument(
      bytes: Array(bytes), identity: .init("consumer/agents.yaml"))
    let store = StateStore(scope: scope, environment: fixture.environment)
    let packageRoot = scope == .project ? fixture.project : store.directory
    return try ComponentLinker.withLinkedComponents(
      document: document, store: store,
      platform: platform
    ) { graph, session in
      (
        graph.components,
        try LedgerFreeze.freezeWithSources(
          graph, session: session,
          locations: .init(sources: [
            "local:" + packageRoot.path: .init(
              kind: .registered, root: scope == .project ? "project" : "userState", path: ".")
          ]), limits: .standard)
      )
    }
  }
  private func prepared(_ ledger: ResolvedLedger, _ fixture: LinkFixture) throws -> ResolvedLedger {
    try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard,
      renderers: NativeComponentLayoutsV1.renderers(limits: .standard))
  }
  private func replay(
    _ ledger: ResolvedLedger, _ fixture: LinkFixture, _ body: ([ReplayedArtifact]) throws -> Void
  ) throws {
    try LedgerReplay.withReplay(
      ledger, store: fixture.store, roots: [:], limits: .standard,
      renderers: NativeComponentLayoutsV1.renderers(limits: .standard), body)
  }
  private func budget() -> NativeDocumentBudget {
    .init(
      limits: .init(
        storage: 32_000_000, work: 100_000_000, nodes: 100_000, depth: 128,
        uninterruptedBytes: 1_000_000))
  }
}
