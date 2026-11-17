import AgentsCore
import AgentsUpdates
import Foundation
import Synchronization
import Testing

private final class NativeBindings: RuntimeBindingProvider {
  let calls = Mutex(0)
  let secret = "private-tree-materialization-canary"
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    calls.withLock { $0 += 1 }
    return Data(secret.utf8)
  }
}

private struct RefuseNativeBindings: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    throw CoreError.invalidState("an unselected binding must not be replayed")
  }
}

struct PrivateNativeCompositionTests {
  @Test(arguments: [false, true])
  func generatedLSPContainerUsesProductionRenderingAndPrivatePublication(_ sensitive: Bool) throws {
    let f = try UpdateFixture()
    let provider = NativeBindings()
    try f.store.save(
      declaration: Declaration(components: [
        .lspServer(
          name: "language",
          run: .init(
            executable: "fixture-language-server",
            environment: sensitive ? ["TOKEN": .secret("token")] : [:]),
          languages: [".swift": "swift"], agents: [.claudeCode]),
        .command(
          name: "review", description: "Review", prompt: .literal("Before"), agents: [.claudeCode]),
      ]), ledger: ResolvedLedger())
    let inventory = try FileHash.folderHash(f.root)
    let preview = try f.preview()
    #expect(try FileHash.folderHash(f.root) == inventory)
    #expect(provider.calls.withLock { $0 } == 0)
    #expect(
      !String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(provider.secret))
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: provider
    ) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(provider.calls.withLock { $0 } == (sensitive ? 1 : 0))
    let installed = try UpdateOperations.inspect(environment: f.environment)
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    let lsp = try #require(installed.components.first { $0.kind == .lspServer })
    let tree = try #require(
      installed.deployments.first { $0.ownerRecords.contains(lsp.record) }?.location)
    let manifest = tree.appendingPathComponent(".claude-plugin/plugin.json")
    let bytes = try Data(contentsOf: manifest)
    #expect(String(decoding: bytes, as: UTF8.self).contains("fixture-language-server"))
    #expect(String(decoding: bytes, as: UTF8.self).contains(provider.secret) == sensitive)
    #expect(
      !String(decoding: try Data(contentsOf: f.store.resolvedURL), as: UTF8.self).contains(
        provider.secret))
    if sensitive {
      for url in [tree, manifest.deletingLastPathComponent(), manifest] {
        let mode =
          try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == (url == manifest ? 0o600 : 0o700))
      }
    }
    let committed = try f.snapshot()
    let command = try #require(
      installed.deployments.first { !$0.ownerRecords.contains(lsp.record) }?.location)
    let oldCommand = try Data(contentsOf: command)
    var failedDeclaration = try f.store.loadDeclaration()
    failedDeclaration.components[0] = .lspServer(
      name: "language",
      run: .init(
        executable: "fixture-language-server", arguments: ["new-generation"],
        environment: sensitive ? ["TOKEN": .secret("token")] : [:]),
      languages: [".swift": "swift"], agents: [.claudeCode])
    failedDeclaration.components[1] = .command(
      name: "review", description: "Review", prompt: .literal("Interrupted"), agents: [.claudeCode])
    var interrupted = false
    let failed = UpdateOperations.perform(
      .init(operation: .declaration(failedDeclaration)), environment: f.environment,
      bindingProvider: provider,
      checkpoint: { _ in
        if !interrupted, (try? Data(contentsOf: manifest)) != bytes {
          interrupted = true
          throw CoreError.invalidState("fixture interruption after container publication")
        }
      }, { try $0.apply() })
    #expect(interrupted && failed.disposition == .rolledBack && !failed.recovery.pending)
    #expect(throws: (any Error).self) { try failed.result.get() }
    #expect(try f.snapshot() == committed)
    #expect(try Data(contentsOf: manifest) == bytes)
    #expect(try Data(contentsOf: command) == oldCommand)
    let callsBeforeEdit = provider.calls.withLock { $0 }
    #expect(callsBeforeEdit == (sensitive ? 2 : 0))
    var declaration = try f.store.loadDeclaration()
    declaration.components[1] = .command(
      name: "review", description: "Review", prompt: .literal("After"), agents: [.claudeCode])
    let request = UpdateRequest(operation: .declaration(declaration), kinds: [.command])
    let edit = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(
      request, environment: f.environment, bindingProvider: RefuseNativeBindings()
    ) { try $0.apply(ifUnchangedFrom: edit.displayedFingerprint) }
    #expect(try Data(contentsOf: manifest) == bytes)
    #expect(provider.calls.withLock { $0 } == callsBeforeEdit)
    let cold = f.root.appendingPathComponent("cold-project")
    var coldEnvironment = f.environment
    coldEnvironment.projectDirectory = cold
    let coldStore = StateStore(scope: .project, environment: coldEnvironment)
    try FileManager.default.createDirectory(
      at: coldStore.directory, withIntermediateDirectories: true)
    let locked = try Data(contentsOf: f.store.resolvedURL)
    try locked.write(to: coldStore.resolvedURL)
    try Data("invalid: [".utf8).write(to: coldStore.declarationURL)
    try FileManager.default.removeItem(at: tree)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .restore), environment: coldEnvironment, bindingProvider: provider
    ) { try $0.apply() }
    #expect(try Data(contentsOf: coldStore.resolvedURL) == locked)
    try Data(contentsOf: f.store.declarationURL).write(to: coldStore.declarationURL)
    let current = try UpdateOperations.inspect(environment: coldEnvironment)
    let restoredRecord = try #require(current.components.first { $0.kind == .lspServer })
    let restored = try #require(
      current.deployments.first { $0.ownerRecords.contains(restoredRecord.record) }?.location)
    #expect(restored.path.hasPrefix(cold.path + "/"))
    #expect(
      try Data(contentsOf: restored.appendingPathComponent(".claude-plugin/plugin.json")) == bytes)
    #expect(try Data(contentsOf: coldStore.resolvedURL) == locked)
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [restoredRecord.selection]),
      environment: coldEnvironment,
      bindingProvider: RefuseNativeBindings()
    ) { try $0.apply() }
    #expect(!FileManager.default.fileExists(atPath: restored.path))
  }
}

extension PrivateNativeCompositionTests {
  @Test(arguments: [false, true])
  func opaqueFrozenTreeRetainsPrivateClassificationWithoutProviderReplay(_ separateProducer: Bool)
    throws
  {
    let f = try UpdateFixture()
    let source = separateProducer ? f.root.appendingPathComponent("native-source") : f.root
    let tree = source.appendingPathComponent("demo-plugin")
    let manifest = Data("{\"name\":\"demo-plugin\",\"version\":\"1.0.0\"}".utf8)
    let executable = Data("#!/bin/sh\n# Not executed.\n".utf8)
    try f.write(
      String(decoding: manifest, as: UTF8.self),
      to: tree.appendingPathComponent(".claude-plugin/plugin.json"))
    try f.write(
      String(decoding: executable, as: UTF8.self), to: tree.appendingPathComponent("bin/check"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("bin/check").path)
    try FileManager.default.createSymbolicLink(
      atPath: tree.appendingPathComponent("current").path, withDestinationPath: "bin/check")
    try f.store.save(
      declaration: Declaration(
        sources: ["producer": .init(kind: .local, location: source.path)],
        components: [
          .plugin(
            name: "demo-plugin", path: "demo-plugin", source: "producer", mode: .native,
            agents: [.claudeCode])
        ]), ledger: ResolvedLedger())
    _ = try f.apply()
    let installed = try UpdateOperations.inspect(environment: f.environment)
    let location = try #require(installed.deployments.first?.location)
    // A real previously materialized private generation is the input to this E continuity case.
    let route = try NativeTargetRoute.named(
      .claudeSkillPlugin, scope: .project, name: "demo-plugin")
    try f.store.withLock(footprint: [route]) {
      let target = try f.store.nativeTarget(for: route)
      let prepared = try f.store.preparePrivateMaterialization(target, changingAccess: true)
      let transaction = FileTransaction(store: f.store)
      try transaction.replacePrivateTree(
        prepared,
        entries: [
          .init(".claude-plugin", content: .directory),
          .init(".claude-plugin/plugin.json", content: .file(manifest)),
          .init("bin", content: .directory),
          .init("bin/check", content: .file(executable, executable: true)),
          .init("current", content: .symlink("bin/check")),
        ], provider: RefuseNativeBindings())
      try transaction.commit()
    }
    let bytes = try FileHash.folderHash(location)
    let report = try f.preview()
    #expect(report.components.first?.privateMaterialization == true)
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: RefuseNativeBindings()
    ) { try $0.apply(ifUnchangedFrom: report.displayedFingerprint) }
    #expect(try FileHash.folderHash(location) == bytes)
    let current = try UpdateOperations.inspect(environment: f.environment)
    #expect(current.deployments.first?.privateMaterialization == true)
    #expect(current.deployments.first?.status == .current)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: location.appendingPathComponent("bin/check").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: location.appendingPathComponent("current").path) == "bin/check")
    // Exact locked replay must not consult a mutable producer or request a binding.
    try FileManager.default.removeItem(at: tree)
    try FileManager.default.removeItem(at: location)
    _ = try UpdateOperations.restore(
      environment: f.environment, bindingProvider: RefuseNativeBindings())
    #expect(try FileHash.folderHash(location) == bytes)
    #expect(
      try UpdateOperations.inspect(environment: f.environment).deployments.first?.status == .current
    )
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .remove, selections: [try #require(current.components.first?.selection)]),
      environment: f.environment, bindingProvider: RefuseNativeBindings()
    ) { try $0.apply() }
    #expect(!FileManager.default.fileExists(atPath: location.path))
  }
}

extension PrivateNativeCompositionTests {
  @Test func addingBindingToOwnedContainerReportsExplicitMemberAccessChanges() throws {
    let f = try UpdateFixture()
    var declaration = Declaration(components: [
      .lspServer(
        name: "language", run: .init(executable: "fixture-server"), languages: [".swift": "swift"],
        agents: [.claudeCode])
    ])
    try f.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try f.apply()
    let installed = try UpdateOperations.inspect(environment: f.environment)
    let tree = try #require(installed.deployments.first?.location)
    for directory in [tree, tree.appendingPathComponent(".claude-plugin")] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    declaration.components[0] = .lspServer(
      name: "language",
      run: .init(executable: "fixture-server", environment: ["TOKEN": .secret("token")]),
      languages: [".swift": "swift"], agents: [.claudeCode])
    var request = UpdateRequest(operation: .declaration(declaration))
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, environment: f.environment)
    }
    request.changingAccess = true
    let before = try FileHash.folderHash(f.root)
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    let access = try #require(preview.components.first?.permissionChange)
    #expect(
      access.members.contains { $0.path == ".claude-plugin/plugin.json" && $0.afterMode == 0o600 })
    #expect(access.members.contains { $0.path == ".claude-plugin" && $0.afterMode == 0o700 })
    #expect(try FileHash.folderHash(f.root) == before)
    let manifest = tree.appendingPathComponent(".claude-plugin/plugin.json")
    let bytes = try Data(contentsOf: manifest)
    try bytes.write(to: manifest, options: .atomic)
    #expect(
      try UpdateOperations.preview(request, environment: f.environment).displayedFingerprint
        == preview.displayedFingerprint)
    let provider = NativeBindings()
    try UpdateOperations.withPreparedUpdate(
      request, environment: f.environment, bindingProvider: provider
    ) { prepared in
      try bytes.write(to: manifest, options: .atomic)
      #expect(throws: UpdateApplyError.self) {
        try prepared.apply(ifUnchangedFrom: preview.displayedFingerprint)
      }
    }
    #expect(provider.calls.withLock { $0 } == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: manifest.path)
    let changed = try UpdateOperations.preview(request, environment: f.environment)
    #expect(changed.displayedFingerprint != preview.displayedFingerprint)
    _ = try UpdateOperations.withPreparedUpdate(
      request, environment: f.environment, bindingProvider: provider
    ) { try $0.apply(ifUnchangedFrom: changed.displayedFingerprint) }
    let current = try UpdateOperations.inspect(environment: f.environment)
    #expect(current.deployments.allSatisfy { $0.privateMaterialization && $0.status == .current })
  }
}

extension PrivateNativeCompositionTests {
  @Test func differentSymbolicNativeOwnersCannotShareAProgramRegion() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .lspServer(
          name: "language",
          run: .init(executable: "fixture-server", environment: ["TOKEN": .secret("first")]),
          languages: [:], agents: [.opencode]),
        .lspServer(
          name: "language",
          run: .init(executable: "fixture-server", environment: ["TOKEN": .secret("second")]),
          languages: [:], agents: [.opencode]),
      ]), ledger: ResolvedLedger())
    let before = try FileHash.folderHash(f.root)
    #expect(throws: (any Error).self) { try f.preview() }
    #expect(try FileHash.folderHash(f.root) == before)
  }
}

extension PrivateNativeCompositionTests {
  @Test func generatedEnvironmentValuesStayOutOfPreviewAndLedger() throws {
    let f = try UpdateFixture()
    var environment = f.environment
    let canary = "private-native-environment-canary"
    environment.environment["NATIVE_FIXTURE_VALUE"] = canary
    try f.store.save(
      declaration: Declaration(components: [
        .lspServer(
          name: "language",
          run: .init(
            executable: "fixture-server",
            environment: ["TOKEN": .environment("NATIVE_FIXTURE_VALUE")]),
          languages: [".swift": "swift"], agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    let before = try FileHash.folderHash(f.root)
    let preview = try UpdateOperations.preview(environment: environment)
    #expect(!String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(canary))
    #expect(try FileHash.folderHash(f.root) == before)
    _ = try UpdateOperations.withPreparedUpdate(
      environment: environment, bindingProvider: RefuseNativeBindings()
    ) { try $0.apply(ifUnchangedFrom: preview.displayedFingerprint) }
    let current = try UpdateOperations.inspect(environment: environment)
    let tree = try #require(current.deployments.first?.location)
    #expect(current.deployments.first?.privateMaterialization == true)
    #expect(
      try String(
        contentsOf: tree.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8
      ).contains(canary))
    #expect(
      !String(decoding: try Data(contentsOf: f.store.resolvedURL), as: UTF8.self).contains(canary))
  }
}

extension PrivateNativeCompositionTests {
  @Test func aPrivateReceiptDoesNotHideChangedGeneratedManifestSemantics() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(components: [
        .lspServer(
          name: "language",
          run: .init(executable: "fixture-server", environment: ["TOKEN": .secret("token")]),
          languages: [".swift": "swift"], agents: [.claudeCode])
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      environment: f.environment, bindingProvider: NativeBindings()
    ) { try $0.apply() }
    let installed = try UpdateOperations.inspect(environment: f.environment)
    let tree = try #require(installed.deployments.first?.location)
    let manifest = tree.appendingPathComponent(".claude-plugin/plugin.json")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let changed = Data(
      original.replacingOccurrences(of: "fixture-server", with: "different-server").utf8)
    let route = try NativeTargetRoute.named(.claudeSkillPlugin, scope: .project, name: "language")
    try f.store.withLock(footprint: [route]) {
      let prepared = try f.store.preparePrivateMaterialization(f.store.nativeTarget(for: route))
      let transaction = FileTransaction(store: f.store)
      try transaction.replacePrivateTree(
        prepared,
        entries: [
          .init(".claude-plugin", content: .directory),
          .init(".claude-plugin/plugin.json", content: .file(changed)),
        ], provider: RefuseNativeBindings())
      try transaction.commit()
    }
    let before = try FileHash.folderHash(f.root)
    #expect(
      try UpdateOperations.inspect(environment: f.environment).deployments.first?.status == .drifted
    )
    #expect(throws: (any Error).self) { try f.preview() }
    #expect(try FileHash.folderHash(f.root) == before)
    #expect(try Data(contentsOf: manifest) == changed)
  }
}
