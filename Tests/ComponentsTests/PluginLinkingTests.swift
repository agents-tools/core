import AgentsCore
import Components
import Foundation
import Testing

@Suite("Plugin occurrence linking", .serialized)
struct PluginLinkingTests {
  private func container(_ fixture: LinkFixture, _ path: String, at root: URL) throws {
    try fixture.write("{\"name\":\"review\"}", to: path + "/.claude-plugin/plugin.json", base: root)
    try fixture.write(
      "---\ndescription: Review command\n---\nReview carefully\n",
      to: path + "/commands/review.md", base: root)
    try fixture.write(
      "---\nname: review\ndescription: Review skill\nplatforms: [macos]\n---\nBody\n",
      to: path + "/skills/review/SKILL.md", base: root)
    try fixture.write("shared support", to: path + "/shared/context.md", base: root)
    try fixture.write("#!/bin/sh\nexit 0\n", to: path + "/shared/server", base: root)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: root.appendingPathComponent(path + "/shared/server").path)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(path + "/bin"),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent(path + "/bin/server").path,
      withDestinationPath: "../shared/server")
    try fixture.write(
      "{\"mcpServers\":{\"server\":{\"command\":\"${CLAUDE_PLUGIN_ROOT}/bin/server\"}}}",
      to: path + "/.mcp.json", base: root)
  }

  private func freeze(_ fixture: LinkFixture, _ expression: String) throws -> ResolvedLedger {
    try ComponentLinker.withLinkedComponents(
      document: fixture.document(expression),
      store: fixture.store, platform: .macOS
    ) { graph, session in
      let locations = Dictionary(
        (graph.sourceSnapshots + graph.declaringSnapshots).filter {
          $0.source?.kind == .local && $0.container == nil
        }.map {
          (
            $0.snapshot.source,
            LedgerLocation(
              kind: .absolute,
              path: String($0.snapshot.source.dropFirst("local:".count)))
          )
        }, uniquingKeysWith: { first, _ in first })
      return try LedgerFreeze.freeze(
        graph, session: session,
        locations: .init(sources: locations), limits: .standard)
    }
  }

  @Test func multiParentSelectionNamespacesAndRestrictions() throws {
    let fixture = try LinkFixture()
    try container(fixture, "one", at: fixture.project)
    try container(fixture, "two", at: fixture.project)
    let expression = """
      version: 1
      defaultAgents: ["claude-code", "codex"]
      components:
        - {kind: plugin, name: first, path: one, source: ".", agents: ["claude-code"]}
        - {kind: plugin, name: repeated, path: one, source: ".", condition: {agents: []}}
        - {kind: plugin, name: second, path: two, source: ".", select: [command], exclude: [{kind: command, name: review}]}
        - {kind: plugin, name: empty, path: one, source: ".", select: []}
      """
    let graph = try fixture.link(expression)
    let parents = graph.components.filter { $0.key.kind == .plugin }
    #expect(parents.count == 4)
    #expect(parents.map { $0.origins[0].pluginExpansion!.children.count } == [3, 3, 0, 0])
    let members = graph.components.filter { $0.key.containerRoot != nil }
    #expect(members.count == 6)
    #expect(Set(members.map(\.key)).count == 3)
    #expect(members.prefix(3).allSatisfy { $0.recipients == [.claudeCode] })
    #expect(members.suffix(3).allSatisfy { $0.recipients.isEmpty })
    #expect(members.allSatisfy { !$0.origins[0].consumerEditable })
    #expect(throws: LinkError.self) { try graph.requireEditable(members[0].key) }
    let ledger = try freeze(fixture, expression)
    #expect(ledger.occurrences.count == 10)
    #expect(ledger.occurrences.filter { $0.pluginExpansion != nil }.count == 4)
    #expect(ledger.occurrences.filter { $0.pluginMember != nil }.count == 6)
    #expect(
      ledger.resources.values.allSatisfy { !$0.path.hasSuffix("plugin.json") && $0.path != "one" })
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: .standard) == ledger)
    #expect(
      ledger.occurrences.filter { $0.pluginMember != nil }.allSatisfy {
        $0.input?.format == "native/claudePluginV1@1"
      })
    let both = try fixture.link(
      """
      version: 1
      components: [{kind: plugin, name: a, path: one, source: "."}, {kind: plugin, name: b, path: two, source: "."}]
      """)
    #expect(Set(both.components.filter { $0.key.kind == .command }.map(\.key)).count == 2)
  }

  @Test func remoteChildrenAndEmptyFreezeKeepExactProducer() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(repository)
    try container(fixture, "plugins/review", at: repository)
    let first = try fixture.commit(repository, tag: "1.0.0")
    let source =
      "sources: {p: {url: \"file://localhost\(repository.path)\", requirement: {exact: \"1.0.0\"}}}"
    let expression =
      "version: 1\n" + source
      + "\ncomponents: [{kind: plugin, name: p, path: plugins/review, source: p}]"
    let ledger = try freeze(fixture, expression)
    let expansion = try #require(ledger.occurrences.first?.pluginExpansion)
    #expect(ledger.sources[expansion.source]?.revision == first)
    #expect(
      ledger.components.values.filter { $0.containerRoot != nil }.allSatisfy {
        $0.declaringSource == expansion.source && $0.source == expansion.source
      })
    let executable = try #require(ledger.resources.values.first { $0.path.hasSuffix("bin/server") })
    #expect(!executable.support.isEmpty)
    #expect(ledger.resources.values.allSatisfy { $0.kind == .git })
    let mcp = try #require(ledger.components.values.first { $0.kind == "mcpServer" })
    #expect(
      mcp.payload.object?["transport"]?.object?["run"]?.object?["executable"]?.text
        == "plugins/review/bin/server")
    #expect(
      !String(decoding: try ResolvedLedgerCodec.encode(ledger, limits: .standard), as: UTF8.self)
        .contains("agents-source-"))
    let empty = try freeze(
      fixture,
      "version: 1\n" + source
        + "\ncomponents: [{kind: plugin, name: p, path: plugins/review, source: p, select: []}]")
    let emptyExpansion = try #require(empty.occurrences.first?.pluginExpansion)
    #expect(emptyExpansion.children.isEmpty)
    #expect(empty.sources[emptyExpansion.source]?.revision == first)
    #expect(empty.resources.isEmpty)
    try FileManager.default.removeItem(at: repository)
    let decoded = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(ledger, limits: .standard), limits: .standard)
    #expect(decoded.occurrences == ledger.occurrences)
  }

  @Test func memberIdentityDoesNotInheritDeclaringParentGroup() throws {
    let fixture = try LinkFixture()
    try container(fixture, "one", at: fixture.project)
    let graph = try fixture.link(
      """
      version: 1
      groups:
        left: {components: [{kind: plugin, name: left, path: one, source: ".", select: [command]}]}
        right: {components: [{kind: plugin, name: right, path: one, source: ".", select: [command]}]}
      uses: [{group: left}, {group: right}]
      """)
    let children = graph.components.filter { $0.key.kind == .command }
    #expect(children.count == 2)
    #expect(Set(children.map(\.key)).count == 1)
    #expect(children.allSatisfy { $0.key.group == nil && $0.origins[0].reference != nil })
    #expect(Set(children.map { $0.origins[0].pluginMember!.parentOccurrence }).count == 2)
  }

  @Test func selectedMembersKeepIndependentDirectPins() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(repository)
    try container(fixture, "one", at: repository)
    let first = try fixture.commit(repository, tag: "1.0.0")
    let expression = """
      version: 1
      sources: {p: {url: "file://localhost\(repository.path)", requirement: {from: "1.0.0"}}}
      components: [{kind: skills, source: p, select: [review]}, {kind: plugin, name: p, path: one, source: p, select: [mcpServer]}]
      """
    let before = try fixture.link(expression)
    let direct = try #require(before.components.first { $0.key.kind == .skills })
    try fixture.write("new binary", to: "one/shared/server", base: repository)
    try fixture.write(
      "---\nname: review\ndescription: Changed\n---\nChanged\n",
      to: "one/skills/review/SKILL.md", base: repository)
    let second = try fixture.commit(repository, tag: "1.1.0")
    let after = try fixture.link(expression, directPins: [direct.key: try #require(direct.pin)])
    #expect(after.components.first { $0.key.kind == .skills }?.snapshot.revision == first)
    #expect(after.components.first { $0.key.kind == .mcpServer }?.snapshot.revision == second)
    #expect(!after.protectedChanges(from: before, allowing: [.skills]).isEmpty)
  }

  @Test func emptyContainerAndExactExclusionSurviveFreeze() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      "{\"name\":\"empty\"}", to: "empty/.claude-plugin/plugin.json", base: fixture.project)
    let empty = try freeze(
      fixture, "version: 1\ncomponents: [{kind: plugin, name: empty, path: empty, source: \".\"}]")
    #expect(empty.occurrences[0].pluginExpansion?.children == [])
    #expect(empty.resources.isEmpty)
    try fixture.write(
      "{\"name\":\"unicode\"}", to: "unicode/.claude-plugin/plugin.json", base: fixture.project)
    try fixture.write("Body", to: "unicode/commands/é.md", base: fixture.project)
    let base = "version: 1\ncomponents: [{kind: plugin, name: u, path: unicode, source: \".\""
    let graph = try fixture.link(base + "}]")
    let command = try #require(graph.components.first { $0.key.kind == .command })
    let name = command.key.name
    let other = name.utf8.elementsEqual("é".utf8) ? "e\u{301}" : "é"
    let kept = try fixture.link(base + ", exclude: [{kind: command, name: \"\(other)\"}]}]")
    #expect(kept.components.contains { $0.key.kind == .command })
    let excluded = try fixture.link(base + ", exclude: [{kind: command, name: \"\(name)\"}]}]")
    #expect(excluded.components.count == 1)
    let renumbered = try fixture.link(
      "version: 1\ncomponents: [{kind: ignore, name: unrelated, patterns: [temp]}, {kind: plugin, name: u, path: unicode, source: \".\"}]"
    )
    #expect(renumbered.protectedChanges(from: graph, allowing: [.ignore]).isEmpty)
  }

  @Test func unicodeSelectorsRemainDistinctWithinContainer() throws {
    let fixture = try LinkFixture()
    try fixture.write(
      "{\"name\":\"unicode\"}", to: "unicode/.claude-plugin/plugin.json", base: fixture.project)
    for (path, name) in [("first", "é"), ("second", "e\u{301}")] {
      try fixture.write(
        "---\nname: \(name)\ndescription: Agent\n---\nBody\n",
        to: "unicode/agents/" + path + ".md", base: fixture.project)
    }
    let graph = try fixture.link(
      "version: 1\ncomponents: [{kind: plugin, name: u, path: unicode, source: \".\"}]")
    let members = graph.components.filter { $0.key.kind == .subagent }
    #expect(members.count == 2)
    #expect(Set(members.map(\.key)).count == 2)
  }

  @Test func nativeModeRemainsOpaqueAndBindingBytesStayPrivate() throws {
    let fixture = try LinkFixture()
    try container(fixture, "one", at: fixture.project)
    try fixture.write(
      "{\"mcpServers\":{\"server\":{\"command\":\"server\",\"env\":{\"TOKEN\":\"CANARY-plugin-secret\"}}}}",
      to: "one/.mcp.json", base: fixture.project)
    let ledger = try freeze(
      fixture, "version: 1\ncomponents: [{kind: plugin, name: p, path: one, source: \".\"}]")
    #expect(
      !String(decoding: try ResolvedLedgerCodec.encode(ledger, limits: .standard), as: UTF8.self)
        .contains("CANARY-plugin-secret"))
    #expect(
      ledger.contentObjects.values.allSatisfy {
        !String(decoding: $0, as: UTF8.self).contains("CANARY-plugin-secret")
      })
    let opaque = try fixture.link(
      "version: 1\ncomponents: [{kind: plugin, name: p, path: one, source: \".\", mode: native, agents: [\"claude-code\"]}]"
    )
    #expect(opaque.components.count == 1)
    #expect(opaque.components[0].origins[0].pluginExpansion == nil)
    #expect(opaque.components[0].resources.count == 1)
    #expect(throws: (any Error).self) {
      _ = try fixture.link(
        "version: 1\ncomponents: [{kind: plugin, name: p, path: one, source: \".\", mode: native, agents: [\"claude-code\"], select: []}]"
      )
    }
  }

  @Test func emptyExpansionMustIdentifySelectedProducer() throws {
    let fixture = try LinkFixture()
    let declaring = fixture.root.appendingPathComponent("declaring")
    let selected = fixture.root.appendingPathComponent("selected")
    try container(fixture, "one", at: selected)
    try fixture.manifest(
      """
      version: 1
      sources: {b: {path: "\(selected.path)"}}
      exports: [bundle]
      groups: {bundle: {components: [{kind: plugin, name: empty, path: one, source: b, select: []}]}}
      """, at: declaring)
    let ledger = try freeze(
      fixture,
      """
      version: 1
      sources: {a: {path: "\(declaring.path)"}}
      uses: [{source: a, group: bundle}]
      """)
    let parent = try #require(ledger.occurrences.firstIndex { $0.pluginExpansion != nil })
    let occurrence = ledger.occurrences[parent]
    let component = try #require(ledger.components[occurrence.component])
    let expansion = try #require(occurrence.pluginExpansion)
    #expect(expansion.children.isEmpty)
    #expect(expansion.source == component.source)
    #expect(component.declaringSource != component.source)
    #expect(occurrence.dependencies.contains(component.declaringSource))
    #expect(occurrence.dependencies.contains(component.source))
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: .standard) == ledger)
    var wrongProducer = ledger
    wrongProducer.occurrences[parent].pluginExpansion!.source = component.declaringSource
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(
        ResolvedLedgerCodec.bytes(wrongProducer), limits: .standard)
    }
  }

  @Test func everyContainerArrivalNeedsItsParentRelation() throws {
    let fixture = try LinkFixture()
    try container(fixture, "one", at: fixture.project)
    let ledger = try freeze(
      fixture,
      """
      version: 1
      components:
        - {kind: ignore, name: direct, patterns: [temp]}
        - {kind: plugin, name: first, path: one, source: ".", select: [command]}
        - {kind: plugin, name: repeated, path: one, source: ".", select: [command]}
      """)
    let members = ledger.occurrences.filter { $0.pluginMember != nil }
    #expect(members.count == 2)
    #expect(Set(members.map(\.component)).count == 1)
    #expect(Set(members.map { $0.pluginMember!.parent }).count == 2)
    #expect(
      ledger.occurrences.contains {
        $0.pluginMember == nil && ledger.components[$0.component]?.containerRoot == nil
          && $0.consumerEditable
      })
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(bytes, limits: .standard) == ledger)
    for editable in [false, true] {
      var orphaned = ledger
      var orphan = try #require(members.first)
      orphan.id = (ledger.occurrences.map(\.id).max() ?? 0) + 1
      orphan.reference = nil
      orphan.pluginMember = nil
      orphan.consumerEditable = editable
      orphaned.occurrences.append(orphan)
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.decode(
          ResolvedLedgerCodec.bytes(orphaned), limits: .standard)
      }
    }
  }

  @Test func strictClosureAndByteExactNoOp() throws {
    let fixture = try LinkFixture()
    try container(fixture, "one", at: fixture.project)
    let ledger = try freeze(
      fixture,
      "version: 1\ncomponents: [{kind: plugin, name: p, path: one, source: \".\"}]")
    func refused(_ change: (inout ResolvedLedger) -> Void) {
      var value = ledger
      change(&value)
      #expect(throws: (any Error).self) {
        _ = try ResolvedLedgerCodec.encode(value, limits: .standard)
      }
    }
    refused { $0.occurrences[0].pluginExpansion!.children.removeLast() }
    refused { $0.occurrences[1].pluginMember!.parent = 9 }
    refused { $0.occurrences[1].pluginMember!.parent = 1 }
    refused { $0.occurrences[1].pluginMember!.kind = "hook" }
    refused { $0.occurrences[1].consumerEditable = true }
    refused { $0.occurrences[0].pluginExpansion!.containerRoot = "../escape" }
    refused { $0.occurrences[0].pluginExpansion!.children.reverse() }
    refused { $0.occurrences[0].recipients = [] }
    refused { $0.occurrences[0].condition.platforms = [] }
    refused {
      $0.occurrences[2].component = $0.occurrences[1].component
      $0.occurrences[2].pluginMember = $0.occurrences[1].pluginMember
    }
    refused { $0.occurrences[1].manifestPath = "elsewhere/child.md" }
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    var limits = LedgerLimits.standard
    limits.encodedBytes = encoded.count
    #expect(try ResolvedLedgerCodec.decode(encoded, limits: limits) == ledger)
    limits.encodedBytes -= 1
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(encoded, limits: limits)
    }
    var json = try #require(
      JSONSerialization.jsonObject(with: ResolvedLedgerCodec.encode(ledger, limits: .standard))
        as? [String: Any])
    var occurrences = try #require(json["occurrences"] as? [[String: Any]])
    var expansion = try #require(occurrences[0]["pluginExpansion"] as? [String: Any])
    expansion["unexpected"] = NSNull()
    occurrences[0]["pluginExpansion"] = expansion
    json["occurrences"] = occurrences
    #expect(throws: (any Error).self) {
      _ = try ResolvedLedgerCodec.decode(
        JSONSerialization.data(withJSONObject: json), limits: .standard)
    }
    var before = ResolvedLedger()
    before.sources["source"] = .init(
      kind: .local, location: .init(kind: .registered, root: "project", path: "."), revision: "é")
    var after = before
    after.sources["source"]!.revision = "e\u{301}"
    let spaced = Data(" \n".utf8) + (try ResolvedLedgerCodec.encode(before, limits: .standard))
    #expect(try ResolvedLedgerCodec.replacement(before, existing: spaced, limits: .standard) == nil)
    #expect(try ResolvedLedgerCodec.replacement(after, existing: spaced, limits: .standard) != nil)
    let key = ComponentKey(
      source: "s", root: ".", group: nil, kind: .command, name: "é", containerRoot: "é")
    let other = ComponentKey(
      source: "s", root: ".", group: nil, kind: .command, name: "e\u{301}",
      containerRoot: "e\u{301}")
    #expect(Set([key, other]).count == 2)
    #expect(
      LedgerPluginMember(parent: 0, kind: "subagent", name: "é")
        != LedgerPluginMember(parent: 0, kind: "subagent", name: "e\u{301}"))
    let input = LedgerInputProvenance(format: "native/claudePluginV1@1", adapterVersion: "1")
    #expect(
      LedgerPluginExpansion(
        source: "s", root: ".", containerRoot: "é",
        document: "é/.claude-plugin/plugin.json", input: input, children: [])
        != LedgerPluginExpansion(
          source: "s", root: ".", containerRoot: "e\u{301}",
          document: "e\u{301}/.claude-plugin/plugin.json", input: input, children: []))
  }
}
