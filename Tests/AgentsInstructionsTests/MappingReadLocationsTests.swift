import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@Suite("Instruction mapping read locations")
struct MappingReadLocationsTests {
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
