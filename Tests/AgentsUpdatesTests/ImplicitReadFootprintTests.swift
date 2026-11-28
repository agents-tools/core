import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import AgentsUpdates

struct ImplicitReadFootprintTests {
  @Test(arguments: [InstallScope.project, .user])
  func implicitResourcesKeepInputsAndTargetsWithoutWatchingOwnedMirrors(_ scope: InstallScope)
    throws
  {
    let f = try UpdateFixture(scope: scope)
    let root = scope == .user ? f.store.directory : f.root
    let tool = root.appendingPathComponent("bin/tool")
    let body = root.appendingPathComponent("prompts/body.md")
    try f.write("#!/bin/sh\nexit 0\n", to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    try f.write("Prompt body", to: body)
    let declaration = Declaration(
      agents: [.claudeCode],
      components: [
        .mcpServer(name: "tool", transport: .stdio(.init(executable: "./bin/tool"))),
        .command(name: "body", description: "Body", prompt: .file(.init(path: "prompts/body.md"))),
      ])
    let request = UpdateRequest(operation: .declaration(declaration))
    let report = try UpdateOperations.preview(request, scope: scope, environment: f.environment)
    let discovery = try UpdateOperations.discover(
      declaration, scope: scope, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, scope: scope, environment: f.environment) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    let inspection = try UpdateOperations.inspect(scope: scope, environment: f.environment)
    for locations in [report.readLocations, discovery.readLocations, inspection.readLocations] {
      let paths = Set(locations.map(\.path))
      #expect(!paths.contains(root.path))
      #expect(
        paths.isSuperset(of: [
          tool.path, body.path, f.store.declarationURL.path,
          f.store.resolvedURL.path, f.store.watchURL.path,
        ]))
      let mirror = f.store.directory.appendingPathComponent("cache/mirrors/owned.git/FETCH_HEAD")
      #expect(
        !locations.contains { mirror.path.hasPrefix($0.path + "/") || mirror.path == $0.path })
    }
    let selected = try #require(inspection.components.first { $0.kind == .mcpServer })
    let connection = try MCPConnectionOperations.snapshot(
      selection: selected.selection, scope: scope, environment: f.environment)
    #expect(connection.readDependencies.map { $0.url.path }.contains(tool.path))
    if scope == .user {
      #expect(!connection.readDependencies.map { $0.url.path }.contains(root.path))
    }
    #expect(
      Set(inspection.readLocations.map(\.path)).isSuperset(
        of:
          inspection.deployments.map { $0.location.path }))
  }

  @Test func absentDeclarationsAndGroupResourcesRemainInputs() throws {
    let f = try UpdateFixture()
    let absent = f.root.appendingPathComponent("absent-source")
    let declaration = Declaration(
      sources: ["unused": .init(kind: .local, location: absent.path, path: "nested")],
      groups: [
        .init(
          name: "unused",
          components: [
            .command(name: "future", description: "Future", prompt: .file(.init(path: "future.md")))
          ])
      ])
    let paths = try UpdateOperations.readLocations(
      declarations: [declaration], ledgers: [], store: f.store)
    #expect(
      Set(paths.map(\.path)).isSuperset(of: [
        absent.path, f.root.appendingPathComponent("future.md").path,
      ]))
  }

  @Test func emptyOwnSkillAndPluginSelectionsKeepDiscoveryRoots() throws {
    let f = try UpdateFixture(scope: .user)
    let plugin = f.store.directory.appendingPathComponent("plugins/empty")
    try f.write(
      "{\"name\":\"empty\",\"version\":\"1.0.0\"}",
      to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
    let declaration = Declaration(
      agents: [.claudeCode],
      components: [
        .plugin(name: "empty", path: "plugins/empty", source: ".", agents: [])
      ])
    let report = try UpdateOperations.preview(
      .init(operation: .declaration(declaration)), scope: .user, environment: f.environment)
    #expect(report.readLocations.map(\.path).contains(plugin.path))
    #expect(!report.readLocations.map(\.path).contains(f.store.directory.path))
    let ownSkills = Declaration(components: [.skills(source: ".", .init(select: .all))])
    let ownReport = try UpdateOperations.preview(
      .init(operation: .declaration(ownSkills)), scope: .user, environment: f.environment)
    #expect(ownReport.readLocations.map(\.path).contains(f.store.directory.path))
  }

  @Test func explicitRootsRetainWholeTreeSemanticsAndLiveIsNotEnoughToSuppressThem() throws {
    let f = try UpdateFixture()
    let sameRoot = Declaration(sources: [
      "own": .init(kind: .local, location: f.root.path, path: "skills")
    ])
    var ledger = ResolvedLedger()
    ledger.sources["implicit"] = .init(
      kind: .local, location: .init(kind: .absolute, path: f.root.path), revision: "live")
    let elsewhere = f.root.appendingPathComponent("elsewhere")
    ledger.sources["explicit"] = .init(
      kind: .local, location: .init(kind: .absolute, path: elsewhere.path), revision: "live")
    ledger.sources["pinned"] = .init(
      kind: .local, location: .init(kind: .absolute, path: f.root.path),
      revision: String(repeating: "a", count: 40))
    let paths = try UpdateOperations.readLocations(
      declarations: [sameRoot], ledgers: [ledger], store: f.store)
    #expect(Set(paths.map(\.path)).isSuperset(of: [f.root.path, elsewhere.path]))
    ledger.sources = ["implicit": ledger.sources["implicit"]!]
    ledger.sourceUses = [.init(source: "implicit", root: "skills")]
    let retained = try UpdateOperations.readLocations(
      declarations: [], ledgers: [ledger], store: f.store)
    #expect(retained.map(\.path).contains(f.root.path))
  }

  @Test func supportingFilesAndLinkReplacementRemainInputs() throws {
    let f = try UpdateFixture(scope: .user)
    let root = f.store.directory
    let selected = root.appendingPathComponent("bin/tool")
    let support = root.appendingPathComponent("shared/actual")
    try f.write("#!/bin/sh\n", to: support)
    try FileManager.default.createDirectory(
      at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: selected.path, withDestinationPath: "../shared/actual")
    let declaration = Declaration(
      agents: [],
      components: [
        .mcpServer(name: "supported", transport: .stdio(.init(executable: "bin/tool")))
      ])
    let request = UpdateRequest(operation: .declaration(declaration))
    let first = try UpdateOperations.preview(request, scope: .user, environment: f.environment)
    let paths = first.readLocations
    #expect(Set(paths.map(\.path)).isSuperset(of: [selected.path, support.path]))
    #expect(!paths.map(\.path).contains(root.path))
    #expect(!paths.map(\.path).contains(root.appendingPathComponent("shared").path))
    try f.write("#!/bin/sh\n# changed support\n", to: support)
    let changed = try UpdateOperations.preview(request, scope: .user, environment: f.environment)
    #expect(changed.displayedFingerprint != first.displayedFingerprint)
    let replacement = root.appendingPathComponent("shared/replacement")
    try f.write("#!/bin/sh\n", to: replacement)
    try FileManager.default.removeItem(at: selected)
    try FileManager.default.createSymbolicLink(
      atPath: selected.path, withDestinationPath: "../shared/replacement")
    let replaced = try UpdateOperations.preview(request, scope: .user, environment: f.environment)
    #expect(replaced.readLocations.map(\.path).contains(selected.path))
    #expect(replaced.readLocations.map(\.path).contains(replacement.path))
    #expect(!replaced.readLocations.map(\.path).contains(support.path))
    #expect(replaced.displayedFingerprint != changed.displayedFingerprint)
  }
}
