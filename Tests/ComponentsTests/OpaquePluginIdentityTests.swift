import AgentsManifest
import Foundation
import Testing

@testable import AgentsCore
@testable import Components

@Suite("Opaque native plugin producer identity")
struct OpaquePluginIdentityTests {
  private var platform: DeclarationPlatform {
    #if os(macOS)
      .macOS
    #else
      .linux
    #endif
  }

  @Test(arguments: [false, true])
  func declaringNamespaceAndSelectedProducerPairThroughColdReplay(_ separateProducer: Bool) throws {
    let fixture = try LinkFixture()
    let producer =
      separateProducer ? fixture.root.appendingPathComponent("producer") : fixture.project
    let manifest = #"{"name":"demo-plugin","version":"1.0.0"}"#
    try fixture.write(manifest, to: "demo-plugin/.claude-plugin/plugin.json", base: producer)
    try fixture.write("#!/bin/sh\n# frozen only\n", to: "demo-plugin/bin/check", base: producer)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: producer.appendingPathComponent("demo-plugin/bin/check").path)
    try FileManager.default.createSymbolicLink(
      atPath: producer.appendingPathComponent("demo-plugin/current").path,
      withDestinationPath: "bin/check")
    let input: [String: Any] = [
      "version": 1, "sources": ["producer": ["path": producer.path]],
      "components": [
        [
          "kind": "plugin", "name": "demo-plugin", "path": "demo-plugin",
          "source": "producer", "mode": "native", "agents": ["claude-code"],
        ]
      ],
    ]
    let document = try DeclarationDocument(
      bytes: Array(JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])),
      identity: .init("consumer/agents.yaml"))
    let (linked, frozen) = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: platform
    ) { graph, session in
      let locations = Dictionary(
        (graph.sourceSnapshots + graph.declaringSnapshots).map {
          (
            $0.snapshot.source,
            LedgerLocation(
              kind: .absolute, path: String($0.snapshot.source.dropFirst("local:".count)))
          )
        }, uniquingKeysWith: { first, _ in first })
      return (
        try #require(graph.components.first),
        try LedgerFreeze.freezeWithSources(
          graph, session: session, locations: .init(sources: locations), limits: .standard)
      )
    }
    let lowering = try NativeComponentLowering.lower(
      linked, frozen: frozen,
      request: .init(surface: .claudeCode, scope: .project), id: "opaque", platform: platform)
    let record = try #require(frozen.ledger.components[lowering.inputs[0]])
    #expect(linked.key.source == linked.declaringSnapshot.source)
    #expect(record.declaringSource == frozen.sources[linked.declaringSnapshot])
    #expect(record.source == frozen.sources[linked.snapshot])
    #expect((linked.declaringSnapshot.source != linked.snapshot.source) == separateProducer)
    let resource = try #require(record.resources.first)
    #expect(frozen.ledger.resources[resource]?.source == record.source)
    var corrupt = frozen
    corrupt.ledger.resources[resource]!.source = "missing-selected-producer"
    #expect(throws: NativeComponentIssue.self) {
      try NativeComponentLowering.lower(
        linked, frozen: corrupt,
        request: .init(surface: .claudeCode, scope: .project), id: "invalid", platform: platform)
    }
    var ledger = frozen.ledger
    ledger.lowerings = [lowering]
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard)
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: producer.appendingPathComponent("demo-plugin"))
    let restored = try ResolvedLedgerCodec.decode(bytes, limits: .standard)
    try LedgerReplay.withReplay(restored, store: fixture.store, roots: [:], limits: .standard) {
      artifacts in
      let contribution = try NativeComponentLayoutsV1.contribution(
        restored.lowerings[0], ledger: restored,
        artifacts: artifacts, limits: .standard)
      #expect(contribution.occurrences == linked.origins.map(\.occurrence))
      guard
        case .nativePlugin(let directory, let selected, let entry) = contribution.outputs[0].content
      else {
        Issue.record("missing opaque native contribution")
        return
      }
      #expect(
        directory == "demo-plugin" && selected == resource && entry == ".claude-plugin/plugin.json")
      let root = try #require(artifacts[1].tree)
      #expect(
        try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8) == manifest)
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appendingPathComponent("current").path) == "bin/check")
      let mode =
        try FileManager.default.attributesOfItem(
          atPath: root.appendingPathComponent("bin/check").path)[.posixPermissions] as? NSNumber
      #expect(mode.map { $0.intValue & 0o111 != 0 } == true)
    }
  }
}
