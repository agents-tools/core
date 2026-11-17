import AgentsCore
import AgentsManifest
import Components
import Foundation
import Testing

@testable import AgentsUpdates

private struct ManagedMCPFixture {
  let fixture: MCPFacadeFixture
  let store: StateStore
  let producer: URL
  var ledger: ResolvedLedger

  init(remote: Bool) throws {
    fixture = try MCPFacadeFixture()
    store = StateStore(scope: .project, environment: fixture.environment)
    producer = fixture.root.appendingPathComponent("producer")
    let fm = FileManager.default
    try fm.createDirectory(
      at: producer.appendingPathComponent(".agent"), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: producer.appendingPathComponent("cwd"), withIntermediateDirectories: true)
    try fm.copyItem(at: MCPFacadeFixture.executable, to: producer.appendingPathComponent("tool"))
    try fm.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: producer.appendingPathComponent("tool").path)
    try Data("fixed support".utf8).write(to: producer.appendingPathComponent("cwd/support"))
    try Data(
      """
      version: 1
      groups:
        tools:
          components:
            - kind: mcpServer
              name: selected
              transport:
                kind: stdio
                executable: ./tool
                arguments: [managed, \(fixture.observation.path)]
                workingDirectory: {path: cwd}
                environment: {TOKEN: {secret: wanted}}
              agents: []
      exports: [tools]
      """.utf8
    ).write(to: producer.appendingPathComponent(".agent/agents.yaml"))
    let bytes = Data(
      """
      version: 1
      sources: {producer: {path: \(producer.path)}}
      uses: [{source: producer, group: tools}]
      """.utf8)
    try bytes.write(to: store.declarationURL)
    let document = try DeclarationDocument(
      bytes: Array(bytes), identity: DocumentIdentity(store.declarationURL.path))
    let declaration = try ManifestProjection.declaration(
      of: document, environment: fixture.environment)
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    let selectedStore = store
    ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: selectedStore, platform: platform
    ) { linked, session in
      try LedgerFreeze.freeze(
        linked, session: session,
        locations: .init(
          sources: UpdatePlan.sourceLocations(
            linked, declaration: declaration, store: selectedStore)), limits: .standard)
    }
    if remote {
      let id = try #require(ledger.groups.first?.source)
      let revision = String(repeating: "a", count: 40)
      ledger.sources[id] = .init(
        kind: .git, transport: "https://fixture.invalid/producer.git", revision: revision)
      let root = SourceCache(store: store).materializedURL(
        sourceID: try ledger.sourceIdentity(id, roots: store.ledgerRoots), revision: revision)
      try fm.createDirectory(
        at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: producer, to: root)
      for key in ledger.resources.keys {
        ledger.resources[key]!.kind = .git
        ledger.resources[key]!.entries = ledger.resources[key]!.entries.map {
          var e = $0
          e.object = nil
          return e
        }
        ledger.resources[key]!.support = ledger.resources[key]!.support.map {
          var e = $0
          e.object = nil
          return e
        }
      }
      ledger.contentObjects = [:]
    }
    try ResolvedLedgerCodec.encode(ledger, limits: .standard).write(to: store.resolvedURL)
  }
  func save(_ value: ResolvedLedger) throws {
    try ResolvedLedgerCodec.encode(value, limits: .standard).write(to: store.resolvedURL)
  }
  func inspection() throws -> ComponentInspection {
    try #require(UpdateOperations.inspect(environment: fixture.environment).components.first)
  }
}

@Suite(.serialized) struct MCPManagedSelectionTests {
  @Test(arguments: [false, true])
  func exactGroupSelectionOwnsResourcesAcrossSourceLossAndConcurrentTests(_ remote: Bool)
    async throws
  {
    let f = try ManagedMCPFixture(remote: remote)
    let selected = try f.inspection()
    #expect(selected.group == "tools" && selected.kind == .mcpServer)
    #expect(
      remote ? selected.source == "fixture.invalid/producer" : selected.source.hasPrefix("local:"))
    let before = try FileHash.folderHash(f.store.directory)
    if remote { try FileManager.default.removeItem(at: f.producer) }
    let snapshot = try MCPConnectionOperations.snapshot(
      selection: selected.occurrences[0].selection, scope: .project,
      environment: f.fixture.environment)
    let description = MCPConnectionOperations.describe(snapshot)
    #expect(description.executable == "tool" && description.executableIsCaptured)
    #expect(description.workingDirectory == "cwd" && description.workingDirectoryIsCaptured)
    #expect(snapshot.readLocations.contains(f.store.declarationURL))
    #expect(snapshot.readLocations.contains(f.store.resolvedURL))
    #expect(snapshot.readLocations.contains(f.store.watchURL))
    #expect(description.readLocations == snapshot.readLocations)
    #expect(!snapshot.readLocations.contains { $0.path.contains("agents-mcp-capture-") })
    let spy = MCPBindingSpy(["wanted": Data("provider-canary".utf8)])
    #expect(MCPConnectionOperations.describe(snapshot).requiredBindings == ["wanted"])
    #expect(spy.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.fixture.observation.path).isEmpty)
    #expect(try FileHash.folderHash(f.store.directory) == before)
    if !remote { try FileManager.default.removeItem(at: f.producer) }
    if remote { try FileManager.default.removeItem(at: f.store.cacheDirectory) }
    let environment = f.fixture.environment
    async let first = MCPConnectionOperations.test(
      snapshot, environment: environment, bindings: spy)
    async let second = MCPConnectionOperations.test(
      snapshot, environment: environment, bindings: spy)
    let results = await [first, second]
    #expect(results.allSatisfy { $0.outcome == .discovered && $0.cleanupComplete })
    #expect(spy.calls == ["wanted", "wanted"])
    let children = try FileManager.default.contentsOfDirectory(
      at: f.fixture.observation, includingPropertiesForKeys: nil)
    #expect(children.count == 2)
    var directories = Set<String>()
    for child in children {
      let pid = try #require(
        Int32(String(contentsOf: child.appendingPathComponent("pid"), encoding: .utf8)))
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
      let wire = try String(contentsOf: child.appendingPathComponent("wire.jsonl"), encoding: .utf8)
      let startup = try #require(wire.split(separator: "\n").first)
      let record = try #require(
        JSONSerialization.jsonObject(with: Data(startup.utf8)) as? [String: Any])
      let cwd = try #require(record["cwd"] as? String)
      directories.insert(cwd)
      #expect(!FileManager.default.fileExists(atPath: cwd))
    }
    #expect(directories.count == 2)
  }

  @Test func staleWrongKindOccurrenceAndAmbiguousSelectionsRefusePreparation() throws {
    let f = try ManagedMCPFixture(remote: false)
    let selected = try f.inspection()
    let environment = f.fixture.environment
    let wrong = ComponentSelection(
      identity: selected.selection.identity, occurrence: 99999,
      generation: selected.selection.generation)
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: wrong, scope: .project, environment: environment)
    }
    let unknown = ComponentSelection(
      identity: "not-the-selected-source", occurrence: nil,
      generation: selected.selection.generation)
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: unknown, scope: .project, environment: environment)
    }
    var ledger = f.ledger
    let key = try #require(ledger.components.keys.first)
    ledger.components[key]!.kind = "ignore"
    try f.save(ledger)
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: selected.selection, scope: .project, environment: environment)
    }
    let wrongKind = try f.inspection().selection
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: wrongKind, scope: .project, environment: environment)
    }
    try f.save(f.ledger)
    var declaration = try Data(contentsOf: f.store.declarationURL)
    declaration.append(Data("\n# changed generation\n".utf8))
    try declaration.write(to: f.store.declarationURL)
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: selected.selection, scope: .project, environment: environment)
    }
    ledger = f.ledger
    ledger.components["duplicate"] = ledger.components[key]
    try f.save(ledger)
    let ambiguous = try f.inspection().selection
    #expect(throws: MCPConnectionPreparationError.invalidSelection) {
      try MCPConnectionOperations.snapshot(
        selection: ambiguous, scope: .project, environment: environment)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.fixture.observation.path).isEmpty)
  }

  @Test func defaultLocalContextStaysLiveAndReplacedIdentityRefusesLaunch() async throws {
    let f = try ManagedMCPFixture(remote: false)
    var ledger = f.ledger
    let key = try #require(ledger.components.keys.first)
    var payload = ledger.components[key]!.payload.object!
    payload["transport"] = .init(object: [
      "kind": .init("stdio"),
      "run": .init(object: [
        "executable": .init("MCPTestProcess"),
        "arguments": .init(array: [LedgerValue("normal"), .init(f.fixture.observation.path)]),
        "environment": .init(object: [:]),
      ]),
    ])
    ledger.components[key]!.payload = .init(object: payload)
    ledger.components[key]!.resources = []
    try f.save(ledger)
    let marker = f.fixture.root.appendingPathComponent("live-marker")
    try Data("before".utf8).write(to: marker)
    let selection = try f.inspection().selection
    let snapshot = try MCPConnectionOperations.snapshot(
      selection: selection, scope: .project, environment: f.fixture.environment)
    try Data("after".utf8).write(to: marker)
    let spy = MCPBindingSpy()
    let result = await MCPConnectionOperations.test(
      snapshot, environment: f.fixture.environment, bindings: spy)
    #expect(result.outcome == .discovered && result.cleanupComplete)
    let wire = try String(
      contentsOf: f.fixture.observation.appendingPathComponent("wire.jsonl"), encoding: .utf8)
    let startup = try #require(wire.split(separator: "\n").first)
    let record = try #require(
      JSONSerialization.jsonObject(with: Data(startup.utf8)) as? [String: Any])
    #expect(record["liveMarker"] as? String == "after")
    let displaced = f.fixture.root.appendingPathExtension("displaced")
    defer { try? FileManager.default.removeItem(at: displaced) }
    try FileManager.default.moveItem(at: f.fixture.root, to: displaced)
    try FileManager.default.createDirectory(at: f.fixture.root, withIntermediateDirectories: false)
    let stale = await MCPConnectionOperations.test(
      snapshot, environment: f.fixture.environment, bindings: spy)
    #expect(stale.issue == .resourceChanged && stale.cleanupComplete && spy.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.fixture.root.path).isEmpty)
  }

  @Test func changedOrMissingRetainedRemoteBytesNeverRefreshTheSource() throws {
    let f = try ManagedMCPFixture(remote: true)
    let selected = try f.inspection().selection
    let id = try #require(f.ledger.groups.first?.source)
    let root = SourceCache(store: f.store).materializedURL(
      sourceID: try f.ledger.sourceIdentity(id, roots: f.store.ledgerRoots),
      revision: f.ledger.sources[id]!.revision)
    try Data("changed retained executable".utf8).write(to: root.appendingPathComponent("tool"))
    #expect(throws: (any Error).self) {
      try MCPConnectionOperations.snapshot(
        selection: selected, scope: .project, environment: f.fixture.environment)
    }
    try FileManager.default.removeItem(at: root)
    #expect(throws: (any Error).self) {
      try MCPConnectionOperations.snapshot(
        selection: selected, scope: .project, environment: f.fixture.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.fixture.observation.path).isEmpty)
  }
}
