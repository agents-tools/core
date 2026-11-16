import AgentsCore
import Components
import Foundation
import Testing

@Suite("Frozen prompts and current append references", .serialized)
struct PromptReferenceTests {
  @Test func coldReplayDoesNotReadConsumerAppend() throws {
    let fixture = try LinkFixture()
    try fixture.instruction("guide", at: fixture.project)
    let document = try fixture.document(
      "version: 1\ncomponents: [{kind: instructions, chatgpt: {daily: {sections: [{name: guide}], append: custom.md}}}]"
    )
    var ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      try LedgerFreeze.freeze(
        graph, session: session,
        locations: .init(sources: [
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
        ]), limits: .standard)
    }
    let componentID = try #require(ledger.components.keys.first)
    let component = ledger.components[componentID]!
    #expect(component.resources.count == 1)
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    ledger.lowerings = [
      .init(
        id: "prompt:daily", format: "agents/chatgpt@1", inputs: [componentID],
        resources: component.resources, deployments: [],
        layout: .init(object: ["name": .init("prompt:daily"), "sectionCount": .init(integer: 1)]),
        platform: platform, artifacts: [])
    ]
    // An escaping current append must not enter the frozen installation path.
    try fixture.write("CURRENT APPEND", to: "outside.md")
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent("custom.md"),
      withDestinationURL: fixture.root.appendingPathComponent("outside.md"))
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: ["project": fixture.project], limits: .standard)
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    ledger = try ResolvedLedgerCodec.decode(encoded, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    try LedgerReplay.withReplay(
      ledger, store: fixture.store, roots: ["project": fixture.project], limits: .standard
    ) { artifacts in
      let bytes = try #require(artifacts.first?.bytes)
      let text = String(decoding: bytes, as: UTF8.self)
      #expect(text.contains("guide"))
      #expect(!text.contains("CURRENT APPEND"))
    }
  }

  @Test func immutableProducerAppendRemainsAnExactResource() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.instruction("guide", at: producer)
    try fixture.write("FROZEN APPEND", to: "custom.md", base: producer)
    try fixture.write("CONSUMER SHADOW", to: "custom.md", base: fixture.project)
    try fixture.manifest(
      "version: 1\nexports: [g]\ngroups: {g: {components: [{kind: instructions, chatgpt: {daily: {sections: [{name: guide}], append: custom.md}}}]}}",
      at: producer)
    let document = try fixture.document(
      "version: 1\nsources: {p: {path: '\(producer.path)'}}\nuses: [{source: p, group: g}]")
    let ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      let component = try #require(graph.components.first)
      #expect(component.localAppend == nil)
      #expect(component.resources.count == 2)
      try fixture.write("LIVE PRODUCER SHADOW", to: "custom.md", base: producer)
      let append = component.resources[1]
      #expect(
        try Data(contentsOf: session.resource(snapshot: append.snapshot, path: append.path))
          == Data("FROZEN APPEND".utf8))
      return try LedgerFreeze.freeze(
        graph, session: session,
        locations: .init(sources: [
          "local:" + producer.path: .init(
            kind: .authoringRelative, root: "project", path: "../producer"),
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: "."),
        ]), limits: .standard)
    }
    let restored = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(ledger, limits: .standard), limits: .standard)
    let component = try #require(restored.components.values.first)
    #expect(component.payload.object?["localAppend"] == nil)
    #expect(component.resources.count == 2)
    let append = try #require(restored.resources[component.resources[1]])
    let object = try #require(append.entries.first?.object)
    #expect(restored.contentObjects[object] == Data("FROZEN APPEND".utf8))
  }

  @Test func codecValidatesLocalAppendLocationRatherThanReadingIt() throws {
    let fixture = try LinkFixture()
    try fixture.instruction("guide", at: fixture.project)
    let document = try fixture.document(
      "version: 1\ncomponents: [{kind: instructions, chatgpt: {daily: {sections: [{name: guide}], append: missing.md}}}]"
    )
    let ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      try LedgerFreeze.freeze(
        graph, session: session,
        locations: .init(sources: [
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
        ]), limits: .standard)
    }
    let id = try #require(ledger.components.keys.first)
    for invalid in [
      LedgerValue(object: [
        "kind": .init("registered"), "root": .init("state"), "path": .init("missing.md"),
      ]),
      LedgerValue(object: [
        "kind": .init("registered"), "root": .init("project"), "path": .init("../outside"),
      ]),
      LedgerValue(object: ["kind": .init("absolute"), "path": .init("/tmp/append")]),
      LedgerValue(object: [
        "kind": .init("registered"), "root": .init("project"), "path": .init("missing.md"),
        "fallback": .init(),
      ]),
    ] {
      var invalidLedger = ledger
      invalidLedger.components[id]!.payload.object!["localAppend"] = invalid
      #expect(throws: (any Error).self) {
        try ResolvedLedgerCodec.encode(invalidLedger, limits: .standard)
      }
    }
    #expect(
      try ResolvedLedgerCodec.decode(
        ResolvedLedgerCodec.encode(ledger, limits: .standard), limits: .standard) == ledger)
  }
}
