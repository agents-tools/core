import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@Suite("Instruction mapping read locations")
struct MappingReadLocationsTests {
  @Test(arguments: [
    "base-absent", "metadata-absent", "lock-absent", "base-access", "metadata-access",
    "lock-access",
  ])
  func sharedRecoveryAdmissionRepairChangesStatusWithoutChangingScope(_ damage: String) throws {
    let f = try InstructionFixture()
    let config = f.root.appendingPathComponent("shared-config")
    let home = f.project.appendingPathComponent("home")
    for directory in [config, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let environment = RuntimeEnvironment(
      projectDirectory: f.project, homeDirectory: home,
      environment: ["CLAUDE_CONFIG_DIR": config.path])
    let store = StateStore(scope: .project, environment: environment)
    try store.save(declaration: Declaration(), ledger: ResolvedLedger())
    try f.write("Before", to: f.project.appendingPathComponent("old-data/AGENTS.md"))
    var binaryDirectory = Bundle(for: MappingTestBundle.self).bundleURL
    while !FileManager.default.isExecutableFile(
      atPath: binaryDirectory.appendingPathComponent("StateTestProcess").path),
      binaryDirectory.path != "/"
    {
      binaryDirectory.deleteLastPathComponent()
    }
    let child = Process()
    child.executableURL = binaryDirectory.appendingPathComponent("StateTestProcess")
    child.arguments = [
      f.project.path, "shared-install", "shared.ready", "--shared-config", config.path,
    ]
    child.environment = ProcessInfo.processInfo.environment
    try child.run()
    defer { do { try ProcessWait.terminate(child) } catch { Issue.record(error) } }
    try ProcessWait.marker(f.project.appendingPathComponent("ready"), child: child, root: f.project)
    try ProcessWait.terminate(child)
    func mapping() throws -> InstructionMapping {
      try #require(
        InstructionOperations.export(projectRoots: [f.project], environment: environment).last)
    }
    #expect(try mapping().status == .pendingRecovery)
    let base = config.resolvingSymlinksInPath().appendingPathComponent(".agents-native")
    let metadata = try #require(
      FileManager.default.contentsOfDirectory(
        at: base, includingPropertiesForKeys: nil
      ).first)
    let lock = metadata.appendingPathComponent("lock")
    let externalPaths = Set([config, base, metadata, lock].map { $0.standardizedFileURL.path })
    let damaged = damage.hasPrefix("base") ? base : damage.hasPrefix("metadata") ? metadata : lock
    let backup = f.root.appendingPathComponent("metadata-backup")
    let scopeBefore = try f.snapshot(store.directory)
    if damage.hasSuffix("absent") {
      try FileManager.default.moveItem(at: damaged, to: backup)
    } else {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: damaged.path)
    }
    let beforeInspection = try f.snapshot()
    let unavailable = try mapping()
    guard case .unavailable = unavailable.status else {
      Issue.record("Expected failed shared admission, got \(unavailable.status)")
      return
    }
    #expect(
      Set(unavailable.readLocations.map(\.path)).isSuperset(of: externalPaths))
    #expect(try f.snapshot() == beforeInspection)
    #expect(try f.snapshot(store.directory) == scopeBefore)
    if damage.hasSuffix("absent") {
      try FileManager.default.moveItem(at: backup, to: damaged)
    } else {
      try FileManager.default.setAttributes(
        [.posixPermissions: damage == "lock-access" ? 0o600 : 0o700],
        ofItemAtPath: damaged.path)
    }
    let repairedBeforeInspection = try f.snapshot()
    let repaired = try mapping()
    #expect(repaired.status == .pendingRecovery)
    #expect(
      Set(repaired.readLocations.map(\.path)).isSuperset(of: externalPaths))
    #expect(try f.snapshot(store.directory) == scopeBefore)
    #expect(try f.snapshot() == repairedBeforeInspection)
  }

  @Test func lockedMappingReadsMetadataWithoutContentDependencies() throws {
    let f = try InstructionFixture()
    try f.section("shared")
    try f.commit()
    try f.add(agents: [.codex])
    try f.own("own")
    try f.addOwn(names: ["own"], agents: [.codex])
    let store = f.store()
    var declaration = try store.loadDeclaration()
    try declaration.updateInstructions {
      $0?.chatgpt = [
        "daily": PromptDeclaration(sections: ["rules:shared", "own"], append: "append.md")
      ]
    }
    try store.save(declaration: declaration, ledger: store.loadLedger())
    _ = try InstructionOperations.updateInstalled(environment: f.environment, apply: true)
    let own = f.project.appendingPathComponent(".agent/instructions/own.md")
    let target = f.project.appendingPathComponent("AGENTS.md")
    for url in [own, target, store.cacheDirectory] {
      try FileManager.default.removeItem(at: url)
    }
    let before = try f.snapshot()
    let mapping = try #require(
      InstructionOperations.export(projectRoots: [f.project], environment: f.environment).last)
    #expect(mapping.status == .locked)
    #expect(mapping.targets.flatMap(\.sections).map(\.name) == ["shared", "own"])
    #expect(mapping.prompts["daily"]?.map(\.name) == ["shared", "own"])
    #expect(mapping.unplaced.isEmpty)
    expectStateLocations(mapping, store: store)
    let paths = Set(mapping.readLocations.map(\.path))
    #expect(!paths.contains(own.path))
    #expect(!paths.contains(target.path))
    #expect(!paths.contains(f.project.appendingPathComponent("append.md").path))
    #expect(!paths.contains { $0.hasPrefix(store.cacheDirectory.path) })
    #expect(try f.snapshot() == before)
  }

  @Test func missingScopesRetainAbsentLeavesWithoutCreatingState() throws {
    let f = try InstructionFixture()
    let before = try f.snapshot()
    let mappings = InstructionOperations.export(
      projectRoots: [f.project, f.project.appendingPathComponent(".")], environment: f.environment)
    #expect(mappings.map(\.scope) == [.user, .project])
    for mapping in mappings {
      #expect(mapping.status == .missingLock)
      expectStateLocations(mapping, store: f.store(mapping.scope))
      #expect(!FileManager.default.fileExists(atPath: f.store(mapping.scope).directory.path))
    }
    #expect(try f.snapshot() == before)
  }

  @Test(arguments: ["transaction.json", "transaction.new", "watch-refs.pending"])
  func pendingRecoveryRetainsAdmissionLocations(_ marker: String) throws {
    let f = try InstructionFixture()
    let store = f.store()
    try f.write("", to: store.directory.appendingPathComponent(marker))
    let before = try f.snapshot()
    let mapping = try #require(
      InstructionOperations.export(projectRoots: [f.project], environment: f.environment).last)
    #expect(mapping.status == .pendingRecovery)
    expectStateLocations(mapping, store: store)
    #expect(mapping.targets.isEmpty)
    #expect(try f.snapshot() == before)
  }

  @Test(arguments: ["agents.yaml", "agents.resolved", "agents.watch", ".agents.lock"])
  func unavailableScopesRetainLocationsForRepair(_ name: String) throws {
    let f = try InstructionFixture()
    let store = f.store()
    let file = store.directory.appendingPathComponent(name)
    if name == ".agents.lock" {
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: file, withDestinationURL: f.root.appendingPathComponent("absent-lock"))
    } else {
      try f.write("invalid", to: file)
    }
    let before = try f.snapshot()
    let mapping = try #require(
      InstructionOperations.export(projectRoots: [f.project], environment: f.environment).last)
    guard case .unavailable(let message) = mapping.status else {
      Issue.record("Expected unavailable scope, got \(mapping.status)")
      return
    }
    if name == "agents.watch" || name == "agents.resolved" {
      #expect(message.contains(store.declarationURL.path))
    }
    expectStateLocations(mapping, store: store)
    #expect(mapping.targets.isEmpty)
    #expect(try f.snapshot() == before)
  }

  private func expectStateLocations(_ mapping: InstructionMapping, store: StateStore) {
    let expected = [
      store.directory, store.declarationURL, store.resolvedURL, store.watchURL,
      store.directory.appendingPathComponent(".agents.lock"),
      store.directory.appendingPathComponent("transaction.json"),
      store.directory.appendingPathComponent("transaction.new"),
      store.directory.appendingPathComponent("watch-refs.pending"),
    ].map(\.path).sorted()
    #expect(mapping.readLocations.map(\.path) == expected)
  }
}

private final class MappingTestBundle: NSObject {}
