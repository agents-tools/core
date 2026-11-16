import AgentsCore
import AgentsManifest
import Foundation
import NativeDocuments
import Testing

@testable import Components

@Suite("Native MCP mapping and replay")
struct NativeMCPTests {
  @Test(arguments: NativeMCPScope.allCases)
  func claudeRegionsPreserveClientAndOtherScopeState(_ scope: NativeMCPScope) throws {
    try withMCP(
      [server("db", transport: stdio(), agents: ["claude-code"])],
      request: .init(surface: .claudeCode, scope: scope)
    ) { contribution, _, _ in
      let source = """
        {
          "accountSentinel" : "keep-account",
          "mcpServers": {"db": {"command":"old","args":[]}, "user-sibling" : {"command":"keep"}},
          "projects": {
            "/work/a.b": {"hasTrustDialogAccepted":false,"mcpServers":{"db":{"command":"old","args":[]}}},
            "/work/other": {"allowedTools":[],"mcpServers":{"other":{"command":"keep"}}}
          }
        }
        """
      let region = try contribution.descriptor.region(
        server: contribution.name, nativeProjectKey: "/work/a.b")
      let expectedKeys =
        scope == .local
        ? ["projects", "/work/a.b", "mcpServers", "db"] : ["mcpServers", "db"]
      #expect(region == NativeRegion(keys: expectedKeys))
      #expect(contribution.descriptor.request.scope == scope)
      #expect(contribution.descriptor.knownReaders == [.claudeCode])
      let doc = try document(source, contribution)
      let fixtureOwnedEntry = try #require(try doc.read(region))
      let value = try contribution.referenceValue()
      let changed = try doc.prepare([
        .put(region: region, expected: .owned(fixtureOwnedEntry), value: value)
      ])
      let changedText = String(decoding: changed.bytes, as: UTF8.self)
      #expect(changedText.contains(#""accountSentinel" : "keep-account""#))
      #expect(changedText.contains(#""user-sibling" : {"command":"keep"}"#))
      #expect(changedText.contains(#""hasTrustDialogAccepted":false"#))
      #expect(
        changedText.contains(
          #""/work/other": {"allowedTools":[],"mcpServers":{"other":{"command":"keep"}}}"#))
      let next = try document(changedText, contribution)
      #expect(try next.read(region)?.value == value)
      let owned = try #require(try next.read(region))
      #expect(
        try next.prepare([.put(region: region, expected: .owned(owned), value: value)]).bytes
          == changed.bytes)
      #expect(throws: NativeDocumentError.self) {
        try next.prepare([.put(region: region, expected: .absent, value: value)])
      }
      let removed = try next.prepare([.remove(region: region, expected: .owned(owned))])
      let after = try NativeDocument(bytes: removed.bytes, format: .json, budget: budget())
      #expect(try after.read(region) == nil)
      #expect(
        String(decoding: removed.bytes, as: UTF8.self).contains(
          #""accountSentinel" : "keep-account""#))
      if scope == .local {
        #expect(
          try after.read(.init(keys: ["projects", "/work/a.b", "hasTrustDialogAccepted"]))?.value
            == .boolean(false))
        #expect(throws: NativeAdapterIssue.self) {
          try contribution.descriptor.region(server: contribution.name)
        }
      }
    }
  }

  @Test(arguments: [false, true])
  func codexQuotedServerAndEnvironmentTOML(_ inline: Bool) throws {
    let name = "db.api\"quoted"
    let invocation = stdio(environment: ["NOTE": "new", "INHERITED": ["env": "INHERITED"]])
    try withMCP(
      [server(name, transport: invocation, agents: ["codex"])],
      request: .init(surface: .codexCLI, scope: .project)
    ) { contribution, _, _ in
      let source =
        inline
        ? """
        # native client sentinel
        model = "keep-model"
        mcp_servers.'db.api"quoted' = { command = "old", args = [], env = { NOTE = "before" }, env_vars = ["INHERITED"] }
        [mcp_servers.sibling]
        command = "keep-sibling" # preserve this comment
        """
        : """
        # native client sentinel
        model = "keep-model"
        [mcp_servers.'db.api"quoted']
        command = "old"
        args = []
        env_vars = ["INHERITED"]
        [mcp_servers.'db.api"quoted'.env]
        NOTE = "before"
        [mcp_servers.sibling]
        command = "keep-sibling" # preserve this comment
        """
      let region = try contribution.descriptor.region(server: contribution.name)
      #expect(region == NativeRegion(keys: ["mcp_servers", name]))
      let doc = try document(source, contribution)
      let knownOwned = try #require(try doc.read(region))
      let changed = try doc.prepare([
        .put(region: region, expected: .owned(knownOwned), value: contribution.referenceValue())
      ])
      #expect(
        String(decoding: changed.bytes, as: UTF8.self)
          == source.replacingOccurrences(of: "\"old\"", with: "\"fixture-server-never-run\"")
          .replacingOccurrences(of: "\"before\"", with: "\"new\""))
      let next = try NativeDocument(bytes: changed.bytes, format: .toml, budget: budget())
      #expect(try next.read(region)?.value == contribution.referenceValue())
      #expect(contribution.bindings.map(\.path) == [[.key("env_vars"), .index(0)]])
      #expect(contribution.bindings.map(\.binding) == [.environment("INHERITED")])
      #expect(contribution.bindings.allSatisfy { $0.reference })
    }
  }

  @Test(arguments: [false, true])
  func codexHeaderTablesAndNativeBearerReference(_ inline: Bool) throws {
    let transport: [String: Any] = [
      "kind": "streamableHTTP", "url": "https://example.invalid/mcp",
      "headers": ["X.Static": "new", "X-Token": ["env": "HTTP_TOKEN"]],
    ]
    try withMCP(
      [
        server(
          "api.v1", transport: transport, agents: ["codex"],
          native: ["codex": ["bearer_token_env_var": "BEARER_TOKEN"]])
      ],
      request: .init(surface: .codexCLI, scope: .user)
    ) { contribution, _, _ in
      let source =
        inline
        ? """
        # unmanaged prelude
        model = "keep"
        mcp_servers.'api.v1' = { url = "https://example.invalid/mcp", bearer_token_env_var = "BEARER_TOKEN", http_headers = { 'X.Static' = "old" }, env_http_headers = { X-Token = "HTTP_TOKEN" } }
        [unmanaged]
        value = "keep" # suffix
        """
        : """
        # unmanaged prelude
        model = "keep"
        [mcp_servers.'api.v1']
        url = "https://example.invalid/mcp"
        bearer_token_env_var = "BEARER_TOKEN"
        [mcp_servers.'api.v1'.http_headers]
        'X.Static' = "old"
        [mcp_servers.'api.v1'.env_http_headers]
        X-Token = "HTTP_TOKEN"
        [unmanaged]
        value = "keep" # suffix
        """
      let doc = try document(source, contribution)
      let region = try contribution.descriptor.region(server: contribution.name)
      let owned = try #require(try doc.read(region))
      let edited = try doc.prepare([
        .put(region: region, expected: .owned(owned), value: contribution.referenceValue())
      ])
      #expect(
        String(decoding: edited.bytes, as: UTF8.self)
          == source.replacingOccurrences(of: "\"old\"", with: "\"new\""))
      let fields = try #require(contribution.value.object)
      #expect(fields["env_http_headers"] == .init(object: ["X-Token": .init("HTTP_TOKEN")]))
      #expect(fields["bearer_token_env_var"] == .init("BEARER_TOKEN"))
      #expect(
        contribution.bindings.map(\.binding) == [
          .environment("HTTP_TOKEN"), .environment("BEARER_TOKEN"),
        ])
      #expect(fields["type"] == nil)
    }
  }

  @Test(arguments: [
    NativeClientSurface.claudeCode, .codexCLI, .geminiCLI, .openCodeCLI, .cursorEditor, .cursorCLI,
  ])
  func mapsRealStdioSchemasAndProductionReplay(_ surface: NativeClientSurface) throws {
    let run = stdio(arguments: ["--name", "with spaces"], environment: ["NOTE": "literal"])
    try withMCP(
      [server("typed", transport: run, agents: [surface.agent.rawValue])],
      request: .init(surface: surface, scope: .project)
    ) { contribution, ledger, fixture in
      let fields = try #require(contribution.value.object)
      let expected: LedgerValue
      if surface == .openCodeCLI {
        expected = .init(object: [
          "type": .init("local"),
          "command": .init(array: [
            .init("fixture-server-never-run"), .init("--name"), .init("with spaces"),
          ]),
          "environment": .init(object: ["NOTE": .init("literal")]),
        ])
        #expect(
          try contribution.descriptor.region(server: contribution.name)
            == NativeRegion(keys: ["mcp", "servers", "typed"]))
      } else {
        var expectedFields: [String: LedgerValue] = [
          "command": .init("fixture-server-never-run"),
          "args": .init(array: [.init("--name"), .init("with spaces")]),
          "env": .init(object: ["NOTE": .init("literal")]),
        ]
        if surface == .claudeCode || surface == .cursorEditor || surface == .cursorCLI {
          expectedFields["type"] = .init("stdio")
        }
        expected = .init(object: expectedFields)
      }
      #expect(contribution.value == expected)
      #expect(fields["enabled"] == nil)
      var candidate = ledger
      candidate.lowerings = [
        contribution.lowering(id: "mcp", artifact: "typed", platform: platform)
      ]
      candidate = try LedgerReplay.prepareLowerings(
        candidate, store: fixture.store, roots: [:], limits: .standard)
      try LedgerReplay.withReplay(candidate, store: fixture.store, roots: [:], limits: .standard) {
        output in
        #expect(output.count == 1)
        #expect(output[0].kind == .ownedValues)
        #expect(output[0].values?.object?["value"] == expected)
        #expect(output[0].bytes == nil)
      }
    }
  }

  @Test(arguments: [NativeClientSurface.claudeCode, .geminiCLI])
  func remoteTypesAndReferencesRemainDistinct(_ surface: NativeClientSurface) throws {
    for (kind, nativeType) in [("streamableHTTP", "http"), ("sse", "sse")] {
      let remote: [String: Any] = [
        "kind": kind, "url": "https://example.invalid/mcp",
        "headers": ["X-Token": ["env": "REMOTE_TOKEN"]],
      ]
      try withMCP(
        [server("remote", transport: remote, agents: [surface.agent.rawValue])],
        request: .init(surface: surface, scope: .project)
      ) { contribution, _, _ in
        #expect(
          contribution.value
            == .init(object: [
              "type": .init(nativeType), "url": .init("https://example.invalid/mcp"),
              "headers": .init(object: ["X-Token": .init("${REMOTE_TOKEN}")]),
            ]))
        #expect(contribution.bindings[0].binding == .environment("REMOTE_TOKEN"))
        #expect(contribution.bindings[0].reference)
        _ = try contribution.referenceValue()
      }
    }
  }

  @Test func openCodeRemoteProtocolIsNotSSE() throws {
    try withMCP(
      [
        server(
          "remote",
          transport: [
            "kind": "streamableHTTP", "url": "https://example.invalid/mcp",
            "headers": ["X-Token": ["env": "REMOTE_TOKEN"]],
          ], agents: ["opencode"],
          native: ["opencode": ["protocol": "legacy", "oauth": false]])
      ],
      request: .init(surface: .openCodeCLI, scope: .project)
    ) { contribution, _, _ in
      #expect(
        contribution.value
          == .init(object: [
            "type": .init("remote"), "url": .init("https://example.invalid/mcp"),
            "headers": .init(object: ["X-Token": .init("REMOTE_TOKEN", kind: .environment)]),
            "protocol": .init("legacy"), "codemode": .init(boolean: false),
            "oauth": .init(boolean: false),
          ]))
      #expect(throws: NativeAdapterIssue.self) { try contribution.referenceValue() }
    }
  }

  @Test(arguments: [false, true])
  func openCodeEnvironmentValuesRequireStagedRendering(_ remote: Bool) throws {
    let transport: [String: Any] =
      remote
      ? [
        "kind": "streamableHTTP", "url": "https://example.invalid/mcp",
        "headers": ["X-Token": ["env": "EXACT_VALUE"]],
      ]
      : stdio(environment: ["TOKEN": ["env": "EXACT_VALUE"]])
    try withMCP(
      [server("exact", transport: transport, agents: ["opencode"])],
      request: .init(surface: .openCodeCLI, scope: .project)
    ) { contribution, ledger, fixture in
      let field = remote ? "headers" : "environment"
      let key = remote ? "X-Token" : "TOKEN"
      #expect(
        contribution.value.object?[field]?.object?[key] == .init("EXACT_VALUE", kind: .environment))
      #expect(contribution.bindings.map(\.reference) == [false])
      #expect(throws: NativeAdapterIssue.self) { try contribution.referenceValue() }
      var candidate = ledger
      candidate.lowerings = [
        contribution.lowering(id: "exact", artifact: "exact", platform: platform)
      ]
      candidate = try LedgerReplay.prepareLowerings(
        candidate, store: fixture.store, roots: [:], limits: .standard)
      let restored = try ResolvedLedgerCodec.decode(
        ResolvedLedgerCodec.encode(candidate, limits: .standard), limits: .standard)
      let replayed = try MCPLayoutV1.contribution(restored.lowerings[0], ledger: restored)
      #expect(replayed.bindings == contribution.bindings)
      #expect(replayed.value == contribution.value)
      #expect(throws: NativeAdapterIssue.self) { try replayed.referenceValue() }
      var unsafeReference = restored.lowerings[0]
      unsafeReference.layout.object?["bindings"]?.array?[0].object?["reference"] = .init(
        boolean: true)
      unsafeReference.layout.object?["value"]?.object?[field]?.object?[key] = .init(
        "{env:EXACT_VALUE}")
      #expect(throws: CoreError.self) {
        try MCPLayoutV1.contribution(unsafeReference, ledger: restored)
      }
    }
  }

  @Test(arguments: [false, true])
  func equalPayloadsCannotCrossFrozenSourceOwners(_ resource: Bool) throws {
    let a = try LinkFixture()
    let b = try LinkFixture()
    var run = stdio()
    if resource {
      run["executable"] = "./server"
      for fixture in [a, b] {
        try fixture.write("same executable bytes", to: "server", base: fixture.project)
      }
    }
    let declaration: [String: Any] = [
      "version": 1, "components": [server("same", transport: run, agents: ["codex"])],
    ]
    let (_, frozenA) = try freeze(declaration, a)
    let (linkedB, _) = try freeze(declaration, b)
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(
        try #require(linkedB.first), frozen: frozenA,
        request: .init(surface: .codexCLI, scope: .project))
    }
  }

  @Test func frozenSnapshotsAndResourceProvenanceRemainExact() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(producer)
    try fixture.write("same bytes", to: "server", base: producer)
    let producerDeclaration: [String: Any] = [
      "version": 1, "exports": ["tools"],
      "groups": [
        "tools": [
          "components": [
            server(
              "same", transport: ["kind": "stdio", "executable": "./server"], agents: ["codex"])
          ]
        ]
      ],
    ]
    try fixture.write(
      String(decoding: JSONSerialization.data(withJSONObject: producerDeclaration), as: UTF8.self),
      to: ".agent/agents.yaml", base: producer)
    try fixture.commit(producer, tag: "1.0.0")
    try fixture.write("unrelated revision", to: "README.md", base: producer)
    try fixture.commit(producer, tag: "2.0.0")
    func declaration(_ version: String) -> [String: Any] {
      [
        "version": 1,
        "sources": [
          "p": [
            "url": "file://localhost" + producer.path,
            "requirement": ["exact": version],
          ]
        ], "uses": [["source": "p", "group": "tools"]],
      ]
    }
    let (linkedA, frozenA) = try freeze(declaration("1.0.0"), fixture)
    let (linkedB, frozenB) = try freeze(declaration("2.0.0"), fixture)
    let a = try #require(linkedA.first)
    let b = try #require(linkedB.first)
    #expect(a.snapshot.source == b.snapshot.source)
    #expect(a.snapshot.revision != b.snapshot.revision)
    #expect(a.payload == b.payload)
    #expect(a.resources.map(\.hash) == b.resources.map(\.hash))
    let request = NativeMCPRequest(surface: .codexCLI, scope: .project)
    _ = try NativeMCPLowering.lower(a, frozen: frozenA, request: request)
    _ = try NativeMCPLowering.lower(b, frozen: frozenB, request: request)
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(b, frozen: frozenA, request: request)
    }
    let mixedResources = LinkedComponent(
      key: a.key, declaringSnapshot: a.declaringSnapshot,
      snapshot: a.snapshot, pin: a.pin, payload: a.payload, conditions: a.conditions,
      recipients: a.recipients, chatGPT: a.chatGPT, resources: b.resources, origins: a.origins)
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(mixedResources, frozen: frozenA, request: request)
    }
  }

  @Test(arguments: ["startup_timeout_sec", "tool_timeout_sec"])
  func codexTimeoutMatchesNativeDurationRange(_ field: String) throws {
    for (value, accepted) in [
      ("0", true), ("-0.0", true), ("1e-100", true),
      ("9223372036854775807", true), ("18446744073709549568.0", true),
      ("18446744073709551615.0", false), ("18446744073709551616.0", false), ("1e100", false),
    ] {
      do {
        try withMCP(
          [
            server(
              "exact", transport: stdio(), agents: ["codex"],
              native: ["codex": [field: Double(value)!]])
          ],
          request: .init(surface: .codexCLI, scope: .project)
        ) { _, _, _ in
          #expect(accepted)
        }
      } catch let issue as NativeAdapterIssue {
        #expect(!accepted)
        #expect(issue.reason == .invalid)
        #expect(issue.request == .init(surface: .codexCLI, scope: .project))
        #expect(issue.component == "exact")
        #expect(issue.field == ["native", "codex", field])
        #expect(!issue.description.contains(value))
      }
    }
  }

  @Test func symbolicBindingsRemainReplayableWithoutMaterializedValues() throws {
    try withMCP(
      [
        server(
          "private",
          transport: stdio(environment: [
            "RENAMED": ["env": "ORIGINAL"], "TOKEN": ["secret": "credential/server"],
          ]), agents: ["codex"])
      ], request: .init(surface: .codexCLI, scope: .project)
    ) { contribution, ledger, fixture in
      #expect(
        contribution.value.object?["env"]
          == .init(object: [
            "RENAMED": .init("ORIGINAL", kind: .environment),
            "TOKEN": .init("credential/server", kind: .secret),
          ]))
      #expect(contribution.bindings.allSatisfy { !$0.reference })
      do {
        _ = try contribution.referenceValue()
        Issue.record("symbolic bindings were treated as native literal values")
      } catch let issue as NativeAdapterIssue {
        #expect(issue.reason == .integrationRequired)
        #expect(issue.field == ["env", "RENAMED"])
        #expect(!issue.description.contains("credential/server"))
      }
      var candidate = ledger
      candidate.lowerings = [
        contribution.lowering(id: "private", artifact: "private", platform: platform)
      ]
      candidate = try LedgerReplay.prepareLowerings(
        candidate, store: fixture.store, roots: [:], limits: .standard)
      let bytes = try ResolvedLedgerCodec.encode(candidate, limits: .standard)
      let restored = try ResolvedLedgerCodec.decode(bytes, limits: .standard)
      let replayed = try MCPLayoutV1.contribution(restored.lowerings[0], ledger: restored)
      #expect(replayed.bindings == contribution.bindings)
      #expect(replayed.value == contribution.value)
      #expect(replayed.resourcePlacements.isEmpty)
      try LedgerReplay.withReplay(restored, store: fixture.store, roots: [:], limits: .standard) {
        #expect($0[0].values?.object?["value"] == contribution.value)
      }
    }
  }

  @Test func coldReplayPinsLocalRouteAndRetainsIndependentAndRepeatedOwners() throws {
    let fixture = try LinkFixture()
    let item = server("same", transport: stdio(), agents: ["claude-code"])
    let declaration: [String: Any] = [
      "version": 1, "exports": ["one", "two"],
      "groups": ["one": ["components": [item]], "two": ["components": [item]]],
      "uses": [
        ["source": ".", "group": "one"], ["source": ".", "group": "two"],
        ["source": ".", "group": "one"],
      ],
    ]
    let (linked, frozen) = try freeze(declaration, fixture)
    #expect(linked.count == 3)
    #expect(frozen.ledger.components.count == 2)
    let contributions = try linked.map {
      try NativeMCPLowering.lower(
        $0, frozen: frozen, request: .init(surface: .claudeCode, scope: .local))
    }
    #expect(contributions[0].component != contributions[1].component)
    #expect(contributions[0].component == contributions[2].component)
    #expect(contributions.map(\.occurrences) == linked.map { $0.origins.map(\.occurrence) })
    var candidate = frozen.ledger
    candidate.lowerings = contributions.enumerated().map { index, contribution in
      contribution.lowering(id: "lower-\(index)", artifact: "entry-\(index)", platform: platform)
    }
    candidate = try LedgerReplay.prepareLowerings(
      candidate, store: fixture.store, roots: [:], limits: .standard)
    let encoded = try ResolvedLedgerCodec.encode(candidate, limits: .standard)
    #expect(!String(decoding: encoded, as: UTF8.self).contains(fixture.project.path))
    try FileManager.default.removeItem(at: fixture.project)
    let restored = try ResolvedLedgerCodec.decode(encoded, limits: .standard)
    try LedgerReplay.withReplay(restored, store: fixture.store, roots: [:], limits: .standard) {
      output in
      #expect(output.map(\.name) == ["entry-0", "entry-1", "entry-2"])
      #expect(
        output.map { $0.values?.object?["value"] } == contributions.map { Optional($0.value) })
    }
    for (index, lowering) in restored.lowerings.enumerated() {
      let replayed = try MCPLayoutV1.contribution(lowering, ledger: restored)
      #expect(replayed.component == contributions[index].component)
      #expect(replayed.occurrences == contributions[index].occurrences)
      #expect(replayed.descriptor.request == .init(surface: .claudeCode, scope: .local))
      #expect(
        try replayed.descriptor.region(
          server: replayed.name, nativeProjectKey: "/relocated/project")
          == NativeRegion(keys: ["projects", "/relocated/project", "mcpServers", "same"]))
    }
    var changed = restored
    changed.lowerings[0].layout.object?["scope"] = .init("project")
    #expect(throws: CoreError.self) {
      try LedgerReplay.withReplay(changed, store: fixture.store, roots: [:], limits: .standard) {
        _ in
      }
    }
    changed = restored
    changed.lowerings[0].format = "agents/claude-mcp@999"
    #expect(throws: CoreError.self) {
      try LedgerReplay.withReplay(changed, store: fixture.store, roots: [:], limits: .standard) {
        _ in
      }
    }
  }

  @Test func frozenExecutableAndDirectoryUseSymbolicPlacements() throws {
    let fixture = try LinkFixture()
    try fixture.write("#!/bin/sh\nexit 0\n", to: "bin/server", base: fixture.project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.project.appendingPathComponent("bin/server").path)
    try fixture.write("resource", to: "data/file", base: fixture.project)
    var run = stdio()
    run["executable"] = "./bin/server"
    run["workingDirectory"] = ["path": "data"]
    let (linked, frozen) = try freeze(
      [
        "version": 1, "components": [server("frozen", transport: run, agents: ["codex"])],
      ], fixture)
    let contribution = try NativeMCPLowering.lower(
      try #require(linked.first), frozen: frozen,
      request: .init(surface: .codexCLI, scope: .project))
    #expect(contribution.resourcePlacements.map(\.path) == [[.key("command")], [.key("cwd")]])
    #expect(contribution.resourcePlacements.map(\.resource) == contribution.resources)
    #expect(throws: NativeAdapterIssue.self) { try contribution.referenceValue() }
    var candidate = frozen.ledger
    candidate.lowerings = [
      contribution.lowering(id: "frozen", artifact: "frozen", platform: platform)
    ]
    candidate = try LedgerReplay.prepareLowerings(
      candidate, store: fixture.store, roots: [:], limits: .standard)
    let bytes = try ResolvedLedgerCodec.encode(candidate, limits: .standard)
    #expect(!String(decoding: bytes, as: UTF8.self).contains(fixture.project.path))
    try FileManager.default.removeItem(at: fixture.project)
    try LedgerReplay.withReplay(
      ResolvedLedgerCodec.decode(bytes, limits: .standard), store: fixture.store, roots: [:],
      limits: .standard
    ) { output in
      #expect(output[0].values?.object?["value"] == contribution.value)
      #expect(output[0].tree == nil)
    }
  }

  @Test func unsupportedUnknownAndInvalidDiagnosticsAreExact() throws {
    for surface in [NativeClientSurface.codexCLI, .openCodeCLI, .cursorEditor, .cursorCLI] {
      do {
        try withMCP(
          [
            server(
              "exact", transport: ["kind": "sse", "url": "https://example.invalid/sse"],
              agents: [surface.agent.rawValue])
          ], request: .init(surface: surface, scope: .project)
        ) { _, _, _ in Issue.record("unexpected mapping") }
        Issue.record("transport restriction was lost")
      } catch let issue as NativeAdapterIssue {
        #expect(issue.request.surface == surface)
        #expect(issue.request.scope == .project)
        #expect(issue.component == "exact")
        #expect(issue.field == ["transport", "kind"])
        #expect(
          issue.reason
            == (surface == .codexCLI || surface == .openCodeCLI ? .unsupported : .unverified))
      }
    }
    do {
      try withMCP(
        [
          server(
            "exact", transport: stdio(), agents: ["codex"],
            native: ["codex": ["futureField": "SENSITIVE_UNMANAGED_VALUE"]])
        ], request: .init(surface: .codexCLI, scope: .project)
      ) { _, _, _ in Issue.record("unknown field accepted") }
      Issue.record("unknown field was dropped")
    } catch let issue as NativeAdapterIssue {
      #expect(issue.reason == .unverified)
      #expect(issue.field == ["native", "codex", "futureField"])
      #expect(!issue.description.contains("SENSITIVE_UNMANAGED_VALUE"))
    }
    do {
      try withMCP(
        [
          server(
            "exact", transport: stdio(), agents: ["codex"],
            native: ["codex": ["startup_timeout_sec": -1]])
        ], request: .init(surface: .codexCLI, scope: .project)
      ) { _, _, _ in Issue.record("invalid timeout accepted") }
      Issue.record("invalid timeout was dropped")
    } catch let issue as NativeAdapterIssue {
      #expect(issue.reason == .invalid)
      #expect(issue.field == ["native", "codex", "startup_timeout_sec"])
    }
    #expect(throws: NativeAdapterIssue.self) {
      try CapabilityRegistry.mcp(.init(surface: .geminiCLI, scope: .local), component: "exact")
    }
    #expect(throws: NativeAdapterIssue.self) {
      try CapabilityRegistry.mcp(.init(surface: .cursorCloud, scope: .project), component: "exact")
    }
  }

  @Test func recipientProjectionPreservesTheFrozenOwnerTargeting() throws {
    let fixture = try LinkFixture()
    let (linked, ledger) = try freeze(
      [
        "version": 1,
        "components": [server("shared", transport: stdio(), agents: ["claude-code", "codex"])],
      ], fixture)
    let component = try #require(linked.first)
    for surface in [NativeClientSurface.claudeCode, .codexCLI] {
      let contribution = try NativeMCPLowering.lower(
        component, frozen: ledger, request: .init(surface: surface, scope: .project))
      #expect(contribution.recipients == [surface.agent])
      #expect(contribution.descriptor.knownReaders == [surface.agent])
      #expect(
        Set(ledger.ledger.components[contribution.component]!.recipients) == [.claudeCode, .codex])
      #expect(contribution.occurrences == component.origins.map(\.occurrence))
    }
  }

  @Test func nativeInterpolationCannotChangeLiteralIdentity() throws {
    for (surface, field, text) in [
      (NativeClientSurface.claudeCode, "env", "${CLIENT_TOKEN}"),
      (.geminiCLI, "env", "$CLIENT_TOKEN"),
      (.openCodeCLI, "environment", "{file:private.txt}"),
      (.cursorCLI, "env", "${unknown:CLIENT_TOKEN}"),
    ] {
      do {
        try withMCP(
          [
            server(
              "literal", transport: stdio(environment: ["TOKEN": text]),
              agents: [surface.agent.rawValue])
          ], request: .init(surface: surface, scope: .project)
        ) { _, _, _ in
          Issue.record("native interpolation was accepted as a portable literal")
        }
        Issue.record("literal identity was lost")
      } catch let issue as NativeAdapterIssue {
        #expect(issue.reason == .unverified)
        #expect(issue.field == [field, "TOKEN"])
        #expect(!issue.description.contains(text))
      }
    }
  }

  @Test func producerTargetingAndFrozenIdentityAreNotReinterpreted() throws {
    let fixture = try LinkFixture()
    var item = server("scoped", transport: stdio(), agents: ["claude-code"])
    item["condition"] = ["scopes": ["project"]]
    let (linked, frozen) = try freeze(["version": 1, "components": [item]], fixture)
    let component = try #require(linked.first)
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(
        component, frozen: frozen, request: .init(surface: .codexCLI, scope: .project))
    }
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(
        component, frozen: frozen, request: .init(surface: .claudeCode, scope: .user))
    }
    var changed = frozen
    changed.ledger.occurrences[0].consumerEditable = false
    #expect(throws: NativeAdapterIssue.self) {
      try NativeMCPLowering.lower(
        component, frozen: changed, request: .init(surface: .claudeCode, scope: .project))
    }
  }

  private var platform: DeclarationPlatform {
    #if os(macOS)
      .macOS
    #else
      .linux
    #endif
  }

  private func server(
    _ name: String, transport: [String: Any], agents: [String], native: [String: Any] = [:]
  ) -> [String: Any] {
    ["kind": "mcpServer", "name": name, "transport": transport, "agents": agents, "native": native]
  }

  private func stdio(arguments: [String] = [], environment: [String: Any] = [:]) -> [String: Any] {
    [
      "kind": "stdio", "executable": "fixture-server-never-run", "arguments": arguments,
      "environment": environment,
    ]
  }

  private func withMCP(
    _ components: [[String: Any]], request: NativeMCPRequest,
    _ body: (NativeMCPContribution, ResolvedLedger, LinkFixture) throws -> Void
  ) throws {
    let fixture = try LinkFixture()
    let (linked, ledger) = try freeze(["version": 1, "components": components], fixture)
    let contribution = try NativeMCPLowering.lower(
      try #require(linked.first), frozen: ledger, request: request)
    try body(contribution, ledger.ledger, fixture)
  }

  private func freeze(_ declaration: [String: Any], _ fixture: LinkFixture) throws -> (
    [LinkedComponent], LedgerFreeze.Result
  ) {
    let bytes = try JSONSerialization.data(withJSONObject: declaration, options: [.sortedKeys])
    let document = try DeclarationDocument(
      bytes: Array(bytes), identity: DocumentIdentity("consumer/agents.yaml"))
    return try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: platform
    ) { linked, session in
      let frozen = try LedgerFreeze.freezeWithSources(
        linked, session: session,
        locations: .init(sources: [
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
        ]), limits: .standard)
      return (linked.components, frozen)
    }
  }

  private func budget() -> NativeDocumentBudget {
    .init(
      limits: .init(
        storage: 32_000_000, work: 100_000_000, nodes: 100_000, depth: 128,
        uninterruptedBytes: 1_000_000))
  }

  private func document(_ text: String, _ contribution: NativeMCPContribution) throws
    -> NativeDocument
  {
    try NativeDocument(
      bytes: Data(text.utf8), format: contribution.descriptor.documentFormat, budget: budget())
  }
}
