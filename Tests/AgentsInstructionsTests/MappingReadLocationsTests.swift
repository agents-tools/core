import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@Suite("Instruction mapping read dependencies")
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
    let externalPaths = Set(
      [config, base, metadata, lock, URL(fileURLWithPath: "/")]
        .map { $0.standardizedFileURL.path })
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
    #expect(unavailable.readDependencies.allSatisfy { if case .entry = $0 { true } else { false } })
    #expect(
      Set(unavailable.readDependencies.map { $0.url.path }).isSuperset(of: externalPaths))
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
    #expect(repaired.readDependencies.allSatisfy { if case .entry = $0 { true } else { false } })
    #expect(
      Set(repaired.readDependencies.map { $0.url.path }).isSuperset(of: externalPaths))
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
    let paths = Set(mapping.readDependencies.map { $0.url.path })
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

  @Test(arguments: [InstallScope.project, .user])
  func allowedRootAliasesRetainLogicalAndPhysicalEntries(_ scope: InstallScope) throws {
    let f = try InstructionFixture()
    let logical = f.root.appendingPathComponent("scope-alias")
    let first = f.root.appendingPathComponent("physical-first").resolvingSymlinksInPath()
    let second = f.root.appendingPathComponent("physical-second").resolvingSymlinksInPath()
    for root in [first, second] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: first)
    var environment = f.environment
    if scope == .project {
      environment.projectDirectory = logical
    } else {
      environment.homeDirectory = logical
    }
    let stateName = scope == .project ? ".agent" : ".agents"
    func mapping() throws -> InstructionMapping {
      let values = InstructionOperations.export(
        projectRoots: scope == .project ? [logical] : [], environment: environment)
      return try #require(scope == .project ? values.last : values.first)
    }
    let absent = try mapping()
    #expect(absent.status == .missingLock)
    let expected = Set(
      [
        logical, first, logical.appendingPathComponent(stateName),
        first.appendingPathComponent(stateName),
        first.appendingPathComponent(stateName + "/agents.resolved"),
      ].map(\.path))
    #expect(Set(absent.readDependencies.map { $0.url.path }).isSuperset(of: expected))
    #expect(absent.readDependencies.allSatisfy { if case .entry = $0 { true } else { false } })
    let physicalMarker = first.appendingPathComponent(stateName + "/transaction.new")
    try f.write("", to: physicalMarker)
    let before = try f.snapshot()
    let pending = try mapping()
    #expect(pending.status == .pendingRecovery)
    #expect(pending.readDependencies.map { $0.url.path }.contains(physicalMarker.path))
    #expect(try f.snapshot() == before)
    try FileManager.default.removeItem(at: logical)
    try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: second)
    let retargetedBefore = try f.snapshot()
    let retargeted = try mapping()
    #expect(retargeted.status == .missingLock)
    #expect(retargeted.readDependencies.map { $0.url.path }.contains(logical.path))
    #expect(retargeted.readDependencies.map { $0.url.path }.contains(second.path))
    #expect(!retargeted.readDependencies.map { $0.url.path }.contains(first.path))
    #expect(try f.snapshot() == retargetedBefore)
  }

  @Test(arguments: ["state", "lock"])
  func forbiddenLinksDoNotIntroduceTargetAuthority(_ kind: String) throws {
    let f = try InstructionFixture()
    let store = f.store()
    let external = f.root.appendingPathComponent("forbidden-target")
    if kind == "state" {
      try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: external)
    } else {
      try f.write("", to: external)
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(
        at: store.directory.appendingPathComponent(".agents.lock"), withDestinationURL: external)
    }
    let before = try f.snapshot()
    let mapping = try #require(
      InstructionOperations.export(
        projectRoots: [f.project], environment: f.environment
      ).last)
    guard case .unavailable = mapping.status else {
      Issue.record("Forbidden link was admitted")
      return
    }
    #expect(!mapping.readDependencies.map { $0.url.path }.contains(external.path))
    #expect(mapping.readDependencies.allSatisfy { if case .entry = $0 { true } else { false } })
    #expect(try f.snapshot() == before)
  }

  private func expectStateLocations(_ mapping: InstructionMapping, store: StateStore) {
    let root =
      store.scope == .project
      ? store.environment.projectDirectory : store.environment.homeDirectory
    let expected = Set(
      [root, root.resolvingSymlinksInPath()].flatMap { root in
        let state = root.appendingPathComponent(store.scope == .project ? ".agent" : ".agents")
        return [root, state]
          + [
            "agents.yaml", "agents.resolved", "agents.watch", ".agents.lock",
            "transaction.json", "transaction.new", "watch-refs.pending",
          ].map { state.appendingPathComponent($0) }
      }.map(\.path)
    ).sorted()
    #expect(mapping.readDependencies.map { $0.url.path } == expected)
    #expect(mapping.readDependencies.allSatisfy { if case .entry = $0 { true } else { false } })
  }
}

private final class MappingTestBundle: NSObject {}
