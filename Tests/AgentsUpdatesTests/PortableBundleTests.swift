import AgentsCore
import AgentsInstructions
import AgentsSkills
import AgentsUpdates
import Foundation
import Synchronization
import Testing

@Suite("Portable bundles")
struct PortableBundleTests {
  @Test func bundleOffersOnlyClientsThatCanRenderItsRemoteTransport() throws {
    let publisher = try UpdateFixture()
    try publisher.store.save(
      declaration: Declaration(components: [
        .mcpServer(
          name: "events", transport: .sse(url: "https://example.invalid/events"),
          agents: [.claudeCode]),
        .mcpServer(
          name: "http", transport: .streamableHTTP(url: "https://example.invalid/mcp"),
          agents: [.codex]),
      ]), ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(environment: publisher.environment) {
      try $0.apply()
    }
    let components = try UpdateOperations.inspect(environment: publisher.environment).components
    let archive = try BundleOperations.export(
      .init(name: "remote", version: "1.0.0"),
      selections: components.map(\.selection), scope: .project, environment: publisher.environment)
    let members = try BundleOperations.inspect(archive).components
    let sse = try #require(members.first { $0.name == "events" })
    let http = try #require(members.first { $0.name == "http" })
    for scope in [InstallScope.project, .user] {
      #expect(Set(sse.supportedTargets(in: scope)) == [.claudeCode, .geminiCLI])
      #expect(
        Set(http.supportedTargets(in: scope)) == [
          .claudeCode, .geminiCLI, .codex, .opencode, .antigravity,
        ])
    }
  }

  @Test func freshClaudeUserInstallCreatesSharedInstructionAndSkillParents() throws {
    let bundle = try BundleOperations.inspect(BundleFixture().export())
    let consumer = try UpdateFixture(scope: .user)
    var environment = consumer.environment
    environment.environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
    let selections = bundle.components.filter { $0.kind != .mcpServer }.map {
      BundleImportSelection(componentID: $0.id, targets: [.claudeCode])
    }
    let root = environment.homeDirectory.appendingPathComponent(".claude")
    let preview = try BundleOperations.previewImport(
      bundle, selections: selections, scope: .user, environment: environment)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let result = try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    #expect(result.report.displayedFingerprint == preview.report.displayedFingerprint)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("skills/demo/SKILL.md").path))
  }

  @Test(arguments: [InstallScope.project, .user])
  func lockedComponentsRoundTripAcrossIndependentHomes(_ scope: InstallScope) throws {
    let publisher = try BundleFixture()
    let bytes = try publisher.export()
    let bundle = try BundleOperations.inspect(bytes)
    #expect(bundle.formatVersion == 1)
    #expect(bundle.package == .init(name: "fixture", version: "1.2.0"))
    #expect(Set(bundle.components.map(\.kind)) == [.instructions, .skills, .mcpServer])
    let skill = try #require(bundle.components.first { $0.kind == .skills })
    let instruction = try #require(bundle.components.first { $0.kind == .instructions })
    #expect(
      instruction.sources.contains { $0.revision == publisher.revision && $0.identity == nil })
    #expect(skill.entries.contains { $0.path.hasSuffix("/scripts/run.sh") && $0.executable })
    #expect(skill.entries.contains { $0.path.hasSuffix("/assets/empty") && $0.kind == .directory })
    let server = try #require(bundle.components.first { $0.kind == .mcpServer })
    let symbolic = try #require(server.configuration)
    #expect(String(describing: symbolic).contains("bundle-token"))
    let wire = String(decoding: bytes, as: UTF8.self)
    #expect(!wire.contains(publisher.base.root.path))
    #expect(!wire.contains(publisher.provider.valueToSupply))

    let consumer = try UpdateFixture(scope: scope)
    let provider = BundleBindings()
    let selections = bundle.components.map { component in
      BundleImportSelection(
        componentID: component.id, targets: [component.kind == .mcpServer ? .geminiCLI : .codex])
    }
    let before = try FileHash.folderHash(consumer.root)
    let preview = try BundleOperations.previewImport(
      bundle, selections: selections, scope: scope, environment: consumer.environment)
    #expect(preview.ownershipConflict == nil)
    #expect(preview.report.hasChanges)
    #expect(try FileHash.folderHash(consumer.root) == before)
    #expect(provider.calls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: consumer.store.directory.path))

    // Transfer only archive bytes. The next update must be able to reconstruct its own graph.
    try FileManager.default.removeItem(at: publisher.base.repo)
    let receipt = try BundleOperations.withPreparedImport(preview, bindingProvider: provider) {
      #expect($0.report == preview.report)
      #expect(provider.calls.withLock { $0 } == 0)
      return try $0.apply()
    }
    #expect(receipt.report == preview.report)
    let instructionHealth = try InstructionOperations.doctor(
      scope: scope, environment: consumer.environment)
    #expect(
      !instructionHealth.diagnostics.contains {
        [.sourceUpdateAvailable, .sourceResolutionFailed, .uncommittedSource, .stateUnavailable]
          .contains($0.kind)
      })
    let skillHealth = try SkillOperations.doctor(scope: scope, environment: consumer.environment)
    #expect(
      !skillHealth.checks.contains {
        ["source-update", "source-unavailable", "uncommitted-source"].contains($0.id)
      })
    let target = consumer.target()
    #expect(
      try Data(contentsOf: target.appendingPathComponent("assets/nested/data.bin"))
        == Data([0, 38, 128, 255]))
    #expect(
      try Data(contentsOf: target.appendingPathComponent("assets/data-link"))
        == Data([0, 38, 128, 255]))
    #expect(
      FileManager.default.fileExists(atPath: target.appendingPathComponent("assets/empty").path))
    let mode = try #require(
      FileManager.default.attributesOfItem(
        atPath: target.appendingPathComponent("scripts/run.sh").path)[
          .posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 != 0)
    #expect(
      String(decoding: try Data(contentsOf: consumer.instruction()), as: UTF8.self)
        .contains("locked fixture text"))
    #expect(!FileManager.default.fileExists(atPath: consumer.target(.claudeCode).path))

    let installed = try UpdateOperations.inspect(scope: scope, environment: consumer.environment)
    #expect(installed.components.count == 3)
    #expect(installed.components.first { $0.kind == .skills }?.recipients == [.codex])
    let storedSources = consumer.store.directory.appendingPathComponent(
      BundleSourceLocation.directory)
    let producers = try FileManager.default.contentsOfDirectory(
      at: storedSources, includingPropertiesForKeys: nil
    )
    .map { container in
      try String(
        contentsOf: container.appendingPathComponent(BundleSourceLocation.tree)
          .appendingPathComponent(".agent/agents.yaml"), encoding: .utf8)
    }
    #expect(producers.count == 3)
    #expect(producers.filter { $0.contains("antigravity") }.count == 1)
    let native = try #require(installed.deployments.first { $0.format.hasSuffix("-mcp@1") })
    let nativeText = String(decoding: try Data(contentsOf: native.location), as: UTF8.self)
    #expect(nativeText.contains(provider.valueToSupply))
    #expect(nativeText.contains("BUNDLE_REGION"))
    #expect(provider.calls.withLock { $0 } == 1)
    let stored = String(decoding: try Data(contentsOf: consumer.store.resolvedURL), as: UTF8.self)
    #expect(!stored.contains(provider.valueToSupply))
    #expect(!stored.contains(publisher.base.root.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: consumer.environment.homeDirectory.appendingPathComponent("bundle-ran").path))
    let ordinaryPreview = try consumer.preview()
    #expect(!ordinaryPreview.instructions.hasChanges)
    #expect(ordinaryPreview.components.allSatisfy { $0.privateMaterialization })
    #expect(provider.calls.withLock { $0 } == 1)

    let forwarded = try BundleOperations.inspect(
      BundleOperations.export(
        bundle.package, selections: installed.components.map(\.selection), scope: scope,
        environment: consumer.environment))
    let forwardedSkill = try #require(forwarded.components.first { $0.kind == .skills })
    #expect(forwardedSkill.sources == skill.sources)
    #expect(forwarded.archiveDigest == bundle.archiveDigest)
  }

  @Test(arguments: [InstallScope.project, .user])
  func antigravityBundleSelectionDeploysAllPortableKinds(_ scope: InstallScope) throws {
    let publisher = try BundleFixture()
    let bundle = try BundleOperations.inspect(publisher.export())
    let consumer = try UpdateFixture(scope: scope)
    let selections = bundle.components.map { component in
      #expect(component.supportedTargets(in: scope).contains(.antigravity))
      return BundleImportSelection(componentID: component.id, targets: [.antigravity])
    }
    let preview = try BundleOperations.previewImport(
      bundle, selections: selections, scope: scope, environment: consumer.environment)
    #expect(preview.ownershipConflict == nil)
    let region = "fixture-region"
    let bindings = BundleBindings(region: region)
    _ = try BundleOperations.withPreparedImport(preview, bindingProvider: bindings) {
      try $0.apply()
    }
    let installed = try UpdateOperations.inspect(scope: scope, environment: consumer.environment)
    #expect(installed.components.count == 3)
    #expect(installed.components.allSatisfy { $0.recipients == [.antigravity] })
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    #expect(installed.deployments.contains { $0.format == "agents/antigravity-rule@1" })
    let mcp = try #require(installed.deployments.first { $0.format == "agents/antigravity-mcp@1" })
    let native = String(decoding: try consumer.bytes(mcp.location), as: UTF8.self)
    #expect(native.contains(region) && native.contains(bindings.valueToSupply))
    let lock = String(decoding: try consumer.bytes(consumer.store.resolvedURL), as: UTF8.self)
    #expect(!lock.contains(region) && !lock.contains(bindings.valueToSupply))
    #expect(FileManager.default.fileExists(atPath: consumer.target(.antigravity).path))
    #expect(bindings.calls.withLock { $0 } == 2)
  }

  @Test func marketplaceUpgradePreservesOtherProjectsLockedBundle() throws {
    let author = try BundleFixture()
    let catalog = author.base.root.appendingPathComponent("team-market")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let registration = try MarketplaceRegistration(
      name: "team",
      origin: MarketplaceOrigin(kind: .directory, location: catalog.path))
    let first = try UpdateFixture()
    let second = try UpdateFixture()
    func install(_ release: MarketplaceRelease, to project: UpdateFixture) throws {
      let package = try MarketplaceOperations.acquire(release, environment: project.environment)
      let selections = try package.inspectBundle().components.map {
        BundleImportSelection(
          componentID: $0.id, targets: [$0.kind == .mcpServer ? .geminiCLI : .codex])
      }
      let preview = try package.previewImport(
        as: "team-kit", selections: selections,
        scope: .project, environment: project.environment)
      #expect(preview.report.hasChanges)
      #expect(preview.ownershipConflict == nil)
      _ = try BundleOperations.withPreparedImport(preview, bindingProvider: author.provider) {
        try $0.apply()
      }
    }
    let old = try MarketplaceOperations.publishBundle(author.export(), to: catalog)
    try install(old, to: first)
    try install(old, to: second)
    let previousLock = try Data(contentsOf: second.store.resolvedURL)
    let content = "assets/nested/data.bin"
    let newBytes = Data("new bundle payload".utf8)
    try newBytes.write(
      to: author.base.root.appendingPathComponent("authoring").appendingPathComponent(content))
    _ = try UpdateOperations.withPreparedUpdate(
      environment: author.base.environment, bindingProvider: author.provider
    ) { try $0.apply() }
    _ = try MarketplaceOperations.publishBundle(author.export(version: "2.0.0"), to: catalog)
    let pin = try #require(MarketplaceOperations.installed(environment: first.environment).first)
    #expect(pin.dependency.catalog == registration.origin)
    let upgrade = try #require(
      MarketplaceOperations.availableUpdates(
        for: pin, scope: .project, environment: first.environment
      ).first)
    let verified = try MarketplaceOperations.acquire(upgrade, environment: first.environment)
    let bundle = try verified.inspectBundle()
    let retained = try bundle.retainedSelections(
      for: pin, in: UpdateOperations.inspect(environment: first.environment))
    for item in bundle.components {
      let selection = try #require(retained.first { $0.componentID == item.id })
      #expect(selection.targets == [item.kind == .mcpServer ? .geminiCLI : .codex])
    }
    let preview = try verified.previewImport(
      as: pin.dependency.name, selections: retained, scope: .project, environment: first.environment
    )
    #expect(preview.report.marketplaceChanges?.first?.before == pin)
    #expect(
      preview.report.marketplaceChanges?.first?.after?.dependency.coordinate.version == "2.0.0")
    _ = try BundleOperations.withPreparedImport(preview, bindingProvider: author.provider) {
      try $0.apply()
    }
    #expect(try Data(contentsOf: first.target().appendingPathComponent(content)) == newBytes)
    #expect(
      try MarketplaceOperations.installed(environment: first.environment).first?.dependency
        .coordinate.version == "2.0.0")
    try FileManager.default.removeItem(at: second.target())
    _ = try UpdateOperations.restore(
      environment: second.environment, bindingProvider: author.provider)
    #expect(
      try Data(contentsOf: second.target().appendingPathComponent(content))
        == Data([0, 38, 128, 255]))
    #expect(try Data(contentsOf: second.store.resolvedURL) == previousLock)
    #expect(try MarketplaceOperations.installed(environment: second.environment) == [pin])
  }

  @Test func selectivelyImportsAndPreviewsSafeDestinationCollisions() throws {
    let publisher = try BundleFixture()
    let bundle = try BundleOperations.inspect(publisher.export())
    let instruction = try #require(bundle.components.first { $0.kind == .instructions })
    let skill = try #require(bundle.components.first { $0.kind == .skills })
    let consumer = try UpdateFixture()
    try consumer.write("Handwritten instructions.\n", to: consumer.instruction())
    try consumer.write(
      "Unmanaged skill.\n", to: consumer.target().appendingPathComponent("SKILL.md"))
    let instructions = [BundleImportSelection(componentID: instruction.id, targets: [.codex])]
    let skills = [BundleImportSelection(componentID: skill.id, targets: [.codex])]
    let before = try FileHash.folderHash(consumer.root)
    let collisions = try BundleOperations.previewImport(
      bundle, selections: instructions, scope: .project, environment: consumer.environment)
    #expect(collisions.ownershipConflict != nil)
    #expect(collisions.report.instructions.targets.contains { $0.foreign })
    #expect(throws: CoreError.self) {
      try BundleOperations.withPreparedImport(collisions) { try $0.apply() }
    }
    let skillCollision = try BundleOperations.previewImport(
      bundle, selections: skills, scope: .project, environment: consumer.environment, replace: true)
    #expect(skillCollision.ownershipConflict != nil)
    #expect(throws: CoreError.self) {
      try BundleOperations.withPreparedImport(skillCollision) { try $0.apply() }
    }
    #expect(try FileHash.folderHash(consumer.root) == before)

    let replacement = try BundleOperations.previewImport(
      bundle, selections: instructions, scope: .project, environment: consumer.environment,
      replace: true)
    #expect(replacement.ownershipConflict == nil)
    try consumer.write("Changed since preview.\n", to: consumer.instruction())
    #expect(throws: (any Error).self) {
      try BundleOperations.withPreparedImport(replacement) { try $0.apply() }
    }
    #expect(
      try String(contentsOf: consumer.instruction(), encoding: .utf8) == "Changed since preview.\n")
    let fresh = try BundleOperations.previewImport(
      bundle, selections: instructions, scope: .project, environment: consumer.environment,
      replace: true)
    _ = try BundleOperations.withPreparedImport(fresh) { try $0.apply() }
    #expect(
      try UpdateOperations.inspect(environment: consumer.environment).components.map(\.kind)
        == [.instructions])
    #expect(
      try String(contentsOf: consumer.target().appendingPathComponent("SKILL.md"), encoding: .utf8)
        == "Unmanaged skill.\n")
  }

  @Test func bindingFailureLeavesBundleSourceAndDeploymentsUnpublished() throws {
    let publisher = try BundleFixture()
    let bundle = try BundleOperations.inspect(publisher.export())
    let consumer = try UpdateFixture()
    let server = try #require(bundle.components.first { $0.kind == .mcpServer })
    let preview = try BundleOperations.previewImport(
      bundle, selections: [.init(componentID: server.id, targets: [.geminiCLI])],
      scope: .project, environment: consumer.environment)
    #expect {
      try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    } throws: { error in
      guard let failure = error as? UpdateApplyError, case .unchanged = failure.disposition else {
        return false
      }
      return true
    }
    #expect(try consumer.store.loadDeclaration().uses.isEmpty)
    #expect(try consumer.store.loadLedger().components.isEmpty)
    #expect(
      FileManager.default.enumerator(atPath: consumer.store.directory.path)?
        .allObjects.contains(where: { ($0 as? String)?.hasSuffix("bundle-source.json") == true })
        == false)
    #expect(
      try UpdateOperations.inspect(environment: consumer.environment).deployments.isEmpty)
  }

  @Test func alteredObjectsAndSealedTraversalFailBeforeImport() throws {
    let publisher = try BundleFixture()
    let bytes = try publisher.export()
    var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var objects = try #require(json["contentObjects"] as? [String: String])
    let canary = Data([0, 38, 128, 255]).base64EncodedString()
    let key = try #require(objects.first { $0.value == canary }?.key)
    objects[key] = Data([1, 38, 128, 255]).base64EncodedString()
    json["contentObjects"] = objects
    #expect(throws: CoreError.self) { try BundleOperations.inspect(canonical(json)) }

    json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var manifest = try #require(json["manifest"] as? [String: Any])
    var components = try #require(manifest["components"] as? [[String: Any]])
    let index = try #require(components.firstIndex { $0["kind"] as? String == "skills" })
    var entries = try #require(components[index]["entries"] as? [[String: Any]])
    let link = try #require(entries.firstIndex { $0["kind"] as? String == "symlink" })
    var escaping = entries
    escaping[link]["link"] = "../../../../../outside"
    entries[link]["path"] = "payload/../../outside"
    for (invalid, expected) in [
      (entries, "bundle member path"), (escaping, "resource link escapes tree"),
    ] {
      components[index]["entries"] = invalid
      manifest["components"] = components
      json["manifest"] = manifest
      json["manifestDigest"] = "sha256:" + FileHash.sha256Hex(data: try canonical(manifest))
      #expect {
        try BundleOperations.inspect(canonical(json))
      } throws: { error in
        String(describing: error).contains(expected)
      }
    }
  }

  private func canonical(_ value: [String: Any]) throws -> Data {
    var bytes = try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    bytes.append(10)
    return bytes
  }
}

private final class BundleBindings: RuntimeBindingProvider {
  let calls = Mutex(0)
  let valueToSupply = "runtime-materialization-canary"
  let region: String?

  init(region: String? = nil) { self.region = region }

  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    calls.withLock { $0 += 1 }
    if binding == "BUNDLE_REGION", let region { return Data(region.utf8) }
    #expect(binding == "bundle-token")
    return Data(valueToSupply.utf8)
  }
}

private struct BundleFixture {
  let base: UpdateFixture
  let revision: String
  let provider: BundleBindings

  init() throws {
    let base = try UpdateFixture()
    let provider = BundleBindings()
    let repo = base.repo
    let skill = repo.appendingPathComponent("skills/demo")
    try base.write(
      "---\ndescription: Locked instructions.\n---\n# Bundle rules\n\nlocked fixture text\n",
      to: repo.appendingPathComponent("instructions/rules.md"))
    let assets = skill.appendingPathComponent("assets")
    let data = assets.appendingPathComponent("nested/data.bin")
    let fm = FileManager.default
    try fm.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0, 38, 128, 255]).write(to: data)
    try fm.createSymbolicLink(
      atPath: assets.appendingPathComponent("data-link").path,
      withDestinationPath: "nested/data.bin")
    let run = skill.appendingPathComponent("scripts/run.sh")
    try base.write("#!/bin/sh\nprintf fixture\n", to: run)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
    let server = repo.appendingPathComponent("mcp/server.sh")
    try base.write("#!/bin/sh\ntouch \"$HOME/bundle-ran\"\n", to: server)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    try base.write("package data\n", to: repo.appendingPathComponent("mcp/working/support"))
    try base.commit()
    let revision = try base.git(["rev-parse", "HEAD"])
    // Git preserves file and symlink content. A second local source contributes an empty directory.
    let tree = base.root.appendingPathComponent("authoring")
    try fm.copyItem(at: skill, to: tree)
    try fm.createDirectory(
      at: tree.appendingPathComponent("assets/empty"), withIntermediateDirectories: false)
    try base.store.save(
      declaration: Declaration(
        sources: [
          "fixture": .init(kind: .local, location: repo.path, requirement: .revision(revision)),
          "full-skill": .init(kind: .local, location: tree.path),
        ],
        skills: ["full-skill": .init(select: .names(["demo"]), agents: [.codex], mode: .copy)],
        instructions: .init(agents: [.codex], sections: ["fixture:rules"]),
        components: [
          .mcpServer(
            name: "bundle-server",
            transport: .stdio(
              .init(
                executable: "./mcp/server.sh", executableSource: "fixture",
                environment: [
                  "TOKEN": .secret("bundle-token"), "REGION": .environment("BUNDLE_REGION"),
                ],
                workingDirectory: .init(path: "mcp/working", source: "fixture"))),
            agents: [.geminiCLI])
        ]),
      ledger: ResolvedLedger())
    _ = try UpdateOperations.withPreparedUpdate(
      environment: base.environment, bindingProvider: provider
    ) { try $0.apply() }
    try base.advance()
    #expect(
      !FileManager.default.fileExists(
        atPath: base.environment.homeDirectory.appendingPathComponent("bundle-ran").path))
    self.base = base
    self.provider = provider
    self.revision = revision
  }

  func export(version: String = "1.2.0") throws -> Data {
    let state = try UpdateOperations.inspect(environment: base.environment)
    return try BundleOperations.export(
      .init(name: "fixture", version: version), selections: state.components.map(\.selection),
      scope: .project, environment: base.environment)
  }
}
