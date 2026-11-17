import AgentsCore
import AgentsManifest
import Components
import Foundation
import StateTestSupport
import Testing

@Suite("Ledger reconstruction")
struct LedgerReplayTests {
  @Test func coldSubprocessReconstructsFrozenBResult() throws {
    let fixture = try LinkFixture()
    let project = fixture.project
    try fixture.write("#!/bin/sh\nexit 0\n", to: "bin/server", base: project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: project.appendingPathComponent("bin/server").path)
    try fixture.write("# Frozen prompt\n", to: "prompts/task.md", base: project)
    try fixture.write("vendor bytes\n", to: "vendor/data", base: project)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("vendor/empty"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: project.appendingPathComponent("vendor/alias").path, withDestinationPath: "data")
    try fixture.manifest(
      """
      version: 1
      components: [{"kind": "mcpServer", "name": "server", "transport": {"kind": "stdio", "executable": "./bin/server"}}, {"kind": "command", "name": "task", "description": "Task", "prompt": {"file": {"path": "prompts/task.md"}}}, {"kind": "plugin", "name": "vendor", "path": "vendor", "source": ".", "mode": "native", "agents": ["claude-code"]}]
      """, at: project)
    try run("ledger-freeze", root: project)
    let ledger = try fixture.store.loadLedger(limits: .standard)
    #expect(!ledger.contentObjects.isEmpty)
    let locked = try Data(contentsOf: fixture.store.resolvedURL)
    let expected = try #require(ledger.lowerings.first).artifacts
    let cold = fixture.root.appendingPathComponent("cold")
    try FileManager.default.createDirectory(
      at: cold.appendingPathComponent(".agent"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: fixture.store.declarationURL, to: cold.appendingPathComponent(".agent/agents.yaml"))
    try locked.write(to: cold.appendingPathComponent(".agent/agents.resolved"))
    try FileManager.default.removeItem(at: project)
    try run("ledger-replay", root: cold)
    let actual = try JSONDecoder().decode(
      [LedgerArtifactDigest].self,
      from: Data(contentsOf: cold.appendingPathComponent("replay-summary.json")))
    #expect(actual == expected)
    #expect(try Data(contentsOf: cold.appendingPathComponent(".agent/agents.resolved")) == locked)
    #expect(
      !FileManager.default.fileExists(atPath: cold.appendingPathComponent(".agent/cache").path))
    let tree = cold.appendingPathComponent("probe-bundle")
    #expect(
      FileManager.default.fileExists(atPath: tree.appendingPathComponent("resource-2/empty").path))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: tree.appendingPathComponent("resource-2/alias").path) == "data")
    let flags = try FileManager.default.attributesOfItem(
      atPath: tree.appendingPathComponent("resource-0").path)
    #expect(((flags[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0)
  }

  @Test func freezeRejectsMutationAndMissingLocations() throws {
    let fixture = try LinkFixture()
    try fixture.write("before", to: "prompt.md", base: fixture.project)
    let document = try fixture.document(
      "version: 1\ncomponents: [{\"kind\": \"command\", \"name\": \"task\", \"description\": \"Task\", \"prompt\": {\"file\": {\"path\": \"prompt.md\"}}}]\n"
    )
    try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      #expect(throws: (any Error).self) {
        _ = try LedgerFreeze.freeze(
          graph, session: session, locations: .init(sources: [:]), limits: .standard)
      }
      try fixture.write("changed", to: "prompt.md", base: fixture.project)
      #expect(throws: (any Error).self) {
        _ = try LedgerFreeze.freeze(
          graph, session: session,
          locations: .init(sources: [
            "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
          ]), limits: .standard)
      }
    }
  }

  private func run(_ action: String, root: URL) throws {
    var directory = Bundle(for: LedgerTestBundle.self).bundleURL
    while directory.path != "/",
      !FileManager.default.isExecutableFile(
        atPath: directory.appendingPathComponent("StateTestProcess").path)
    {
      directory.deleteLastPathComponent()
    }
    let child = Process()
    child.executableURL = directory.appendingPathComponent("StateTestProcess")
    child.arguments = [root.path, action]
    child.environment = ProcessInfo.processInfo.environment
    try child.run()
    defer { if child.isRunning { try? ProcessWait.terminate(child) } }
    try ProcessWait.exit(child, root: root)
    try #require(child.terminationStatus == 0)
  }
}
private final class LedgerTestBundle: NSObject {}

@Suite("Ledger replay failure boundaries")
struct LedgerReplayFailureTests {
  @Test func formatAndHashRejectWithoutFallbackAndCleanup() throws {
    let fixture = try LinkFixture()
    var ledger = ResolvedLedger()
    ledger.sources["root"] = LedgerSource(
      kind: .local, location: .init(kind: .registered, root: "project", path: "."), revision: "live"
    )
    try fixture.write("frozen", to: "file", base: fixture.project)
    let input = try LedgerResources.capture(
      fixture.project.appendingPathComponent("file"), embed: true, limits: .standard)
    ledger.contentObjects = input.objects
    ledger.resources["file"] = LedgerResource(
      kind: .embedded, source: "root", path: "file", hash: input.hash, entries: input.entries)
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    ledger.lowerings = [
      LockedLowering(
        id: "test", format: "test/frozen@1", inputs: [], resources: ["file"], deployments: [],
        layout: .init(), platform: platform, artifacts: [])
    ]
    var borrowed: URL?
    let renderer: LedgerRenderer = { _, _, resources in
      borrowed = resources["file"]
      return [
        ReplayedArtifact(name: "file", kind: .file, bytes: try Data(contentsOf: resources["file"]!))
      ]
    }
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store,
      roots: ["project": fixture.project], limits: .standard, renderers: ["test/frozen@1": renderer]
    )
    #expect(borrowed.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(throws: (any Error).self) {
      try LedgerReplay.withReplay(ledger, store: fixture.store, roots: [:], limits: .standard) {
        _ in
      }
    }
    let changed: LedgerRenderer = { _, _, _ in
      [.init(name: "file", kind: .file, bytes: Data("new output".utf8))]
    }
    #expect(throws: (any Error).self) {
      try LedgerReplay.withReplay(
        ledger, store: fixture.store, roots: [:], limits: .standard,
        renderers: ["test/frozen@1": changed]
      ) { _ in }
    }
    let cancelled: LedgerRenderer = { _, _, resources in
      borrowed = resources["file"]
      throw CancellationError()
    }
    #expect(throws: CancellationError.self) {
      try LedgerReplay.withReplay(
        ledger, store: fixture.store, roots: [:], limits: .standard,
        renderers: ["test/frozen@1": cancelled]
      ) { _ in }
    }
    #expect(borrowed.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    try LedgerReplay.withReplay(
      ledger, store: fixture.store, roots: [:], limits: .standard,
      renderers: ["test/frozen@1": renderer]
    ) { #expect($0.count == 1) }
    ledger.resources["file"]?.hash = "sha256:" + String(repeating: "0", count: 64)
    #expect(throws: (any Error).self) {
      try LedgerReplay.withReplay(
        ledger, store: fixture.store, roots: [:], limits: .standard,
        renderers: ["test/frozen@1": renderer]
      ) { _ in }
    }
  }
}

@Suite("Ledger resource closure")
struct LedgerResourceClosureTests {
  @Test func freezesSourceContainedLinksOutsideSelectedSubtree() throws {
    let fixture = try LinkFixture()
    try fixture.write("outside selected subtree", to: "shared/text", base: fixture.project)
    try FileManager.default.createDirectory(
      at: fixture.project.appendingPathComponent("vendor"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.project.appendingPathComponent("vendor/reference").path,
      withDestinationPath: "../shared/text")
    let document = try fixture.document(
      "version: 1\ncomponents: [{\"kind\": \"plugin\", \"name\": \"vendor\", \"path\": \"vendor\", \"source\": \".\", \"mode\": \"native\", \"agents\": [\"claude-code\"]}]\n"
    )
    var ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { linked, session in
      try LedgerFreeze.freeze(
        linked, session: session,
        locations: .init(sources: [
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
        ]), limits: .standard)
    }
    let resource = try #require(ledger.resources.keys.first)
    #expect(!ledger.resources[resource]!.support.isEmpty)
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    ledger.lowerings = [
      .init(
        id: "closure", format: "test/closure@1", inputs: [], resources: [resource], deployments: [],
        layout: .init(), platform: platform, artifacts: [])
    ]
    let renderer: LedgerRenderer = { _, _, resources in
      [
        .init(
          name: "linked", kind: .file,
          bytes: try Data(contentsOf: resources[resource]!.appendingPathComponent("reference")))
      ]
    }
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: [:], limits: .standard,
      renderers: ["test/closure@1": renderer])
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    try FileManager.default.removeItem(at: fixture.project)
    let cold = fixture.root.appendingPathComponent("cold")
    try FileManager.default.createDirectory(at: cold, withIntermediateDirectories: true)
    let coldStore = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: cold, homeDirectory: fixture.home, environment: [:]))
    try LedgerReplay.withReplay(
      ResolvedLedgerCodec.decode(bytes, limits: .standard), store: coldStore,
      roots: [:], limits: .standard, renderers: ["test/closure@1": renderer]
    ) { artifacts in
      #expect(artifacts[0].bytes == Data("outside selected subtree".utf8))
    }
  }
}

@Suite("Ledger exact Git inputs")
struct LedgerExactGitTests {
  @Test func changedProducerAndBranchDoNotReselectLockedInput() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.initialize(producer)
    try fixture.write("original", to: "prompt.md", base: producer)
    try fixture.manifest(
      """
      version: 1
      exports: ["task"]
      groups: {"task": {"components": [{"kind": "command", "name": "task", "description": "Task", "prompt": {"file": {"path": "prompt.md"}}}]}}
      """, at: producer)
    let original = try fixture.commit(producer)
    let document = try fixture.document(
      """
      version: 1
      sources: {"producer": {"path": "../producer", "requirement": {"branch": "main"}}}
      uses: [{"source": "producer", "group": "task"}]
      """)
    var ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { linked, session in
      try LedgerFreeze.freeze(
        linked, session: session,
        locations: .init(sources: [
          "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: "."),
          "local:" + producer.path: .init(
            kind: .authoringRelative, root: "project", path: "../producer"),
        ]), limits: .standard)
    }
    #expect(ledger.groups.first?.manifestHash.hasPrefix("sha256:") == true)
    #expect(ledger.sources.values.contains { $0.revision == original })
    try fixture.write("changed", to: "prompt.md", base: producer)
    try fixture.write("invalid producer manifest", to: ".agent/agents.yaml", base: producer)
    _ = try fixture.commit(producer)
    let resource = try #require(ledger.resources.keys.first)
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    ledger.lowerings = [
      .init(
        id: "exact", format: "test/exact@1", inputs: [], resources: [resource], deployments: [],
        layout: .init(), platform: platform, artifacts: [])
    ]
    let renderer: LedgerRenderer = { _, _, resources in
      let bytes = try Data(contentsOf: resources[resource]!)
      guard bytes == Data("original".utf8) else {
        throw CoreError.invalidState("mutable input selected")
      }
      return [.init(name: "original", kind: .file, bytes: bytes)]
    }
    let roots = ["project": fixture.project]
    ledger = try LedgerReplay.prepareLowerings(
      ledger, store: fixture.store, roots: roots, limits: .standard,
      renderers: ["test/exact@1": renderer])
    try LedgerReplay.withReplay(
      ledger, store: fixture.store, roots: roots, limits: .standard,
      renderers: ["test/exact@1": renderer]
    ) { #expect($0[0].bytes == Data("original".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }
}
