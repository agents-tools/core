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
