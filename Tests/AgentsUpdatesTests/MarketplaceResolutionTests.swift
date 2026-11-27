import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

@Suite("Marketplace dependency resolution")
struct MarketplaceResolutionTests {
  @Test func verifiesEveryCatalogArchiveWithoutInstalling() throws {
    let market = try GraphCatalog()
    let first = try market.publish("handbook", "1.0.0")
    try market.publish("handbook", "1.1.0")
    let consumer = try UpdateFixture()
    let registration = try MarketplaceRegistration(name: "team", origin: market.origin)
    let report = try MarketplaceOperations.verifyCatalog(
      registration, environment: consumer.environment)
    #expect(report.releases.map(\.coordinate.version) == ["1.1.0", "1.0.0"])
    let file = market.catalog.appendingPathComponent(first.coordinate.releasePath)
      .appendingPathComponent("package.bundle")
    var bytes = try Data(contentsOf: file)
    bytes[bytes.startIndex] ^= 1
    try bytes.write(to: file)
    #expect(throws: MarketplaceError.self) {
      try MarketplaceOperations.verifyCatalog(registration, environment: consumer.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.directory.path))
  }

  @Test func lockOnlyFreezesSelectedRecipientsAndDeploysInIndependentScopeWithoutCatalog() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    try market.publish("starter", "1.0.0", ["shared": .exact("1.0.0")])
    let project = try UpdateFixture()
    let root = try market.root("main", package: "starter", recipient: .codex)
    let preview = try MarketplaceOperations.previewLockOnly(
      .install(root), environment: project.environment)
    #expect(!FileManager.default.fileExists(atPath: project.store.directory.path))
    #expect(preview.report.deployedGraph == nil)
    let firstGraph = try #require(preview.report.pendingDeployment.graph)
    let member = try #require(firstGraph.nodes.first { $0.id.package == "shared" }?.members.first)
    #expect(member.targets == [.codex])
    #expect(member.producerResource != nil)

    try MarketplaceOperations.writeLockOnly(preview)
    let state = try UpdateOperations.inspect(environment: project.environment)
    #expect(state.marketplaceIssue == nil)
    #expect(state.marketplaceGraph == nil)
    #expect(state.deployments.isEmpty)
    #expect(state.pendingMarketplaceDeployment?.graph == firstGraph)
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
    #expect(
      !FileManager.default.fileExists(
        atPath: project.store.directory.appendingPathComponent("bundles").path))
    let audit = try OrganizationPolicyOperations.audit(environment: project.environment)
    #expect(audit.pendingMarketplaceDeployment)
    #expect(audit.closureIssue == nil)
    #expect(audit.isBlocked)
    #expect(throws: MarketplaceError.pendingDeployment) {
      try UpdateOperations.restore(environment: project.environment)
    }

    let extra = try market.root("extra", package: "starter", recipient: .antigravity)
    let revised = try MarketplaceOperations.previewLockOnly(
      .install(extra), environment: project.environment)
    let desired = try #require(revised.report.pendingDeployment.graph)
    #expect(
      Set(desired.nodes.first { $0.id.package == "shared" }?.members.first?.targets ?? [])
        == [.codex, .antigravity])
    try MarketplaceOperations.writeLockOnly(revised)
    #expect(!FileManager.default.fileExists(atPath: project.target(.antigravity).path))

    let independent = try UpdateFixture()
    for file in [project.store.declarationURL, project.store.resolvedURL] {
      try independent.write(
        String(contentsOf: file, encoding: .utf8),
        to: independent.store.directory.appendingPathComponent(file.lastPathComponent))
    }
    try FileManager.default.removeItem(at: market.catalog)
    let deploy = try MarketplaceOperations.previewFrozenDeployment(
      environment: independent.environment)
    #expect(deploy.ownershipConflict == nil)
    #expect(deploy.report.marketplaceGraphChange?.after == desired)
    _ = try MarketplaceOperations.deployFrozen(deploy)
    let result = try UpdateOperations.inspect(environment: independent.environment)
    #expect(result.pendingMarketplaceDeployment == nil)
    #expect(result.marketplaceGraph == desired)
    let deployed = try #require(
      result.deployments.first {
        $0.location == independent.target() && $0.recipients.contains(.codex)
      })
    #expect(deployed.status == .current)
    #expect(result.marketplaceOwners(of: deployed).map(\.root) == ["main"])
    let extraTarget = try #require(
      result.deployments.first {
        $0.location == independent.target(.antigravity) && $0.recipients.contains(.antigravity)
      })
    #expect(extraTarget.status == .current)
    #expect(result.marketplaceOwners(of: extraTarget).map(\.root) == ["extra"])
    #expect(try !OrganizationPolicyOperations.audit(environment: independent.environment).isBlocked)
  }

  @Test func lockOnlyUpgradeAndRemovalPreserveActualOwnershipUntilFrozenDeploy() throws {
    let market = try GraphCatalog()
    let range = SourceRequirement.upToNextMajor(from: "1.0.0")
    try market.publish("shared", "1.0.0")
    try market.publish("left", "1.0.0", ["shared": range])
    try market.publish("right", "1.0.0", ["shared": range])
    let project = try UpdateFixture()
    let first = try market.root("one", package: "left", recipient: .codex)
    let second = try market.root("two", package: "right", recipient: .claudeCode)
    try apply(.install(first), project)
    try apply(.install(second), project)
    let deployed = try project.store.loadLedger()
    let codex = project.target().appendingPathComponent("SKILL.md")
    let claude = project.target(.claudeCode).appendingPathComponent("SKILL.md")
    let old = try project.bytes(codex)
    let manual = project.target().deletingLastPathComponent().appendingPathComponent("manual")
    try project.write("personal", to: manual)

    try market.author.advance()
    _ = try market.author.apply()
    let producer = try UpdateOperations.inspect(environment: market.author.environment)
    let refreshedSelection = try #require(
      producer.components.first { $0.kind == .skills }?.selection)
    let archive = try BundleOperations.export(
      .init(name: "shared", version: "1.1.0"), selections: [refreshedSelection],
      scope: .project, environment: market.author.environment)
    try MarketplaceOperations.publishBundle(archive, to: market.catalog)
    let upgrade = try MarketplaceOperations.previewLockOnly(
      .upgrade("one"), environment: project.environment)
    #expect(upgrade.report.marketplaceGraphChange?.affectedRoots == ["one", "two"])
    try MarketplaceOperations.writeLockOnly(upgrade)
    var actual = try project.store.loadLedger()
    actual.pendingDeployment = nil
    #expect(actual == deployed)
    #expect(try project.bytes(codex) == old)
    #expect(try project.bytes(claude) == old)
    #expect(
      try UpdateOperations.inspect(environment: project.environment).deployments.allSatisfy {
        $0.status == .current
      })

    let deployment = try MarketplaceOperations.previewFrozenDeployment(
      environment: project.environment)
    _ = try MarketplaceOperations.deployFrozen(deployment)
    #expect(try project.bytes(codex) != old)
    #expect(try project.bytes(codex) == project.bytes(claude))
    try FileManager.default.removeItem(at: market.catalog)
    let removal = try MarketplaceOperations.previewLockOnly(
      .remove("one"), environment: project.environment)
    try MarketplaceOperations.writeLockOnly(removal)
    #expect(FileManager.default.fileExists(atPath: codex.path))
    #expect(FileManager.default.fileExists(atPath: claude.path))
    let originalLink = try FileManager.default.destinationOfSymbolicLink(
      atPath: project.target().path)
    try FileManager.default.removeItem(at: project.target())
    try project.write("unmanaged replacement", to: codex)
    let occupied = try MarketplaceOperations.previewFrozenDeployment(
      environment: project.environment)
    #expect(occupied.ownershipConflict != nil)
    #expect(throws: CoreError.self) { try MarketplaceOperations.deployFrozen(occupied) }
    #expect(try project.bytes(codex) == Data("unmanaged replacement".utf8))
    try FileManager.default.removeItem(at: project.target())
    try FileManager.default.createSymbolicLink(
      atPath: project.target().path, withDestinationPath: originalLink)
    let removeFirst = try MarketplaceOperations.previewFrozenDeployment(
      environment: project.environment)
    _ = try MarketplaceOperations.deployFrozen(removeFirst)
    #expect(!FileManager.default.fileExists(atPath: codex.path))
    #expect(FileManager.default.fileExists(atPath: claude.path))

    let removeLast = try MarketplaceOperations.previewLockOnly(
      .remove("two"), environment: project.environment)
    try MarketplaceOperations.writeLockOnly(removeLast)
    let beforeLast = try UpdateOperations.inspect(environment: project.environment)
    #expect(beforeLast.pendingMarketplaceDeployment != nil)
    #expect(beforeLast.pendingMarketplaceDeployment?.graph == nil)
    #expect(beforeLast.marketplaceGraph?.roots.map(\.intent.name) == ["two"])
    #expect(FileManager.default.fileExists(atPath: claude.path))
    let deployLast = try MarketplaceOperations.previewFrozenDeployment(
      environment: project.environment)
    _ = try MarketplaceOperations.deployFrozen(deployLast)
    #expect(!FileManager.default.fileExists(atPath: claude.path))
    #expect(try project.bytes(manual) == Data("personal".utf8))
    #expect(try project.store.loadLedger().marketplaceGraph == nil)
  }

  @Test func lockAndDeployRejectChangedGenerationAndPolicyBeforePublication() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let request = try MarketplaceResolutionRequest.install(
      market.root("main", package: "shared", recipient: .codex))
    let policy = project.root.appendingPathComponent("org.yaml")
    var environment = project.environment
    environment.userOrganizationPolicy = .init(.local(policy))
    try project.write("enforcement: block", to: policy)
    let allowed = try MarketplaceOperations.previewLockOnly(request, environment: environment)
    try project.write("enforcement: block\nsources: {deny: [local]}", to: policy)
    #expect(throws: OrganizationPolicyFailure.self) {
      try MarketplaceOperations.writeLockOnly(allowed)
    }
    #expect(!FileManager.default.fileExists(atPath: project.store.directory.path))

    try project.write("enforcement: block", to: policy)
    try market.publish("shared", "1.1.0")
    #expect(throws: CoreError.self) { try MarketplaceOperations.writeLockOnly(allowed) }
    #expect(!FileManager.default.fileExists(atPath: project.store.directory.path))

    let lock = try MarketplaceOperations.previewLockOnly(request, environment: environment)
    try project.write("version: 1\n# changed\n", to: project.store.declarationURL)
    let changed = try project.snapshot()
    #expect(throws: CoreError.self) { try MarketplaceOperations.writeLockOnly(lock) }
    #expect(try project.snapshot() == changed)
    #expect(
      !FileManager.default.fileExists(
        atPath: project.store.directory.appendingPathComponent(".agents.lock").path))

    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(request, environment: environment))
    let frozen = try MarketplaceOperations.previewFrozenDeployment(environment: environment)
    let pending = try project.snapshot()
    try project.write("enforcement: block\nsources: {deny: [local]}", to: policy)
    #expect(throws: OrganizationPolicyFailure.self) {
      try MarketplaceOperations.deployFrozen(frozen)
    }
    #expect(try project.snapshot() == pending)
    try project.write("enforcement: block", to: policy)
    let bytes = try String(contentsOf: project.store.declarationURL, encoding: .utf8)
    try project.write(bytes + "\n# changed since review\n", to: project.store.declarationURL)
    let stale = try project.snapshot()
    #expect(throws: MarketplaceError.changedPendingDeclaration) {
      try MarketplaceOperations.deployFrozen(frozen)
    }
    #expect(try project.snapshot() == stale)
    let state = try UpdateOperations.inspect(environment: environment)
    #expect(state.pendingMarketplaceDeployment != nil)
    #expect(state.marketplaceIssue == .changedPendingDeclaration)
    #expect(state.deployments.isEmpty)
  }

  @Test func changesPendingRootsOfflineAfterRollbackWithoutTouchingOtherDeployments() throws {
    enum Injected: Error { case publication }
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let untouched = project.repo.appendingPathComponent("skills/untouched")
    try FileManager.default.moveItem(
      at: project.repo.appendingPathComponent("skills/demo"), to: untouched)
    let authoredSkill = untouched.appendingPathComponent("SKILL.md")
    let authoredText = try String(contentsOf: authoredSkill, encoding: .utf8)
    try project.write(
      authoredText.replacingOccurrences(of: "name: demo", with: "name: untouched"),
      to: authoredSkill)
    try project.commit()
    try project.install(agents: [.antigravity])
    let existing = project.target(.antigravity).deletingLastPathComponent()
      .appendingPathComponent("untouched/SKILL.md")
    let originalBytes = try project.bytes(existing)
    let policy = project.root.appendingPathComponent("org.yaml")
    try project.write("security: {audit: {fail_on_drift: true}}", to: policy)
    var environment = project.environment
    environment.userOrganizationPolicy = .init(.local(policy))
    let one = try market.root("one", package: "shared", recipient: .codex)
    let two = try market.root("two", package: "shared", recipient: .claudeCode)
    let preview = try MarketplaceOperations.previewLockOnly(.install(one), environment: environment)
    let before = try project.snapshot()
    do {
      _ = try MarketplaceOperations.writeLockOnly(preview) { point in
        if point == "publish.0.synced" { throw Injected.publication }
      }
      Issue.record("Expected lock publication to roll back.")
    } catch let error as UpdateApplyError {
      #expect(error.disposition == .unchanged)
      #expect(error.underlyingError is Injected)
    }
    #expect(try project.snapshot() == before)
    #expect(!(try UpdateOperations.inspect(environment: environment).recovery.pending))
    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(.install(one), environment: environment))
    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(.install(two), environment: environment))
    #expect(try project.bytes(existing) == originalBytes)
    try FileManager.default.removeItem(at: market.catalog)
    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(.remove("one"), environment: environment))
    let modified = originalBytes + Data("\nLocally edited deployment.\n".utf8)
    try modified.write(to: existing)
    let inspection = try UpdateOperations.inspect(environment: environment)
    #expect(inspection.pendingMarketplaceDeployment?.graph?.roots.map(\.intent.name) == ["two"])
    #expect(inspection.marketplaceIssue == nil)
    #expect(
      inspection.deployments.contains {
        $0.location.path == existing.deletingLastPathComponent().path && $0.status == .drifted
      })
    let audit = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(audit.pendingMarketplaceDeployment)
    #expect(audit.organization.findings.contains { $0.rule == "workspace-drift" })

    let deploy = try MarketplaceOperations.previewFrozenDeployment(environment: environment)
    _ = try MarketplaceOperations.deployFrozen(deploy)
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
    #expect(FileManager.default.fileExists(atPath: project.target(.claudeCode).path))
    #expect(try project.bytes(existing) == modified)
    #expect(
      !(try OrganizationPolicyOperations.audit(environment: environment)
        .pendingMarketplaceDeployment))
  }

  @Test func bothSourceAllowlistsGateLockAndFrozenDeploy() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let request = try MarketplaceResolutionRequest.install(
      market.root("main", package: "shared", recipient: .codex))
    let initial = try MarketplaceOperations.previewLockOnly(
      request, environment: project.environment)
    let userPolicy = SourcePolicyOperations.policyURL(
      scope: .user, environment: project.environment)
    let projectPolicy = SourcePolicyOperations.policyURL(
      scope: .project, environment: project.environment)
    try project.write("version: 1\ndeny: [local]\n", to: userPolicy)
    #expect(throws: SourcePolicyFailure.self) { try MarketplaceOperations.writeLockOnly(initial) }
    #expect(!FileManager.default.fileExists(atPath: project.store.directory.path))
    try FileManager.default.removeItem(at: userPolicy)
    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(request, environment: project.environment))
    let deploy = try MarketplaceOperations.previewFrozenDeployment(environment: project.environment)
    let previous = try project.snapshot()
    try project.write("version: 1\ndeny: [local]\n", to: projectPolicy)
    #expect(throws: SourcePolicyFailure.self) { try MarketplaceOperations.deployFrozen(deploy) }
    #expect(try project.snapshot() == previous)
  }

  @Test func frozenRemovalPreservesOtherRegionsInSharedNativeFile() throws {
    let market = try GraphCatalog()
    let component = ComponentDeclaration.mcpServer(
      name: "marketplace", transport: .stdio(.init(executable: "never-run-marketplace")),
      agents: [.claudeCode])
    let authorRequest = UpdateRequest(operation: .declaration(.init(components: [component])))
    try UpdateOperations.withPreparedUpdate(authorRequest, environment: market.author.environment) {
      _ = try $0.apply()
    }
    let authorState = try UpdateOperations.inspect(environment: market.author.environment)
    let item = try #require(authorState.components.first { $0.kind == .mcpServer })
    let archive = try BundleOperations.export(
      .init(name: "servers", version: "1.0.0"), selections: [item.selection],
      scope: .project, environment: market.author.environment)
    try MarketplaceOperations.publishBundle(archive, to: market.catalog)
    let root = try MarketplaceRoot(
      name: "servers", catalog: market.origin, package: "servers", requirement: .exact("1.0.0"),
      selections: [
        .init(
          package: "servers", member: .init(kind: .mcpServer, name: "marketplace"),
          targets: [.claudeCode])
      ])

    let project = try UpdateFixture()
    let config = project.root.appendingPathComponent(".mcp.json")
    let manual = #""manual" : {"command": "never-run-manual"}"#
    try project.write("{\"mcpServers\":{\(manual)}}\n", to: config)
    let adjacent = ComponentDeclaration.mcpServer(
      name: "adjacent", transport: .stdio(.init(executable: "never-run-adjacent")),
      agents: [.claudeCode])
    let localRequest = UpdateRequest(operation: .declaration(.init(components: [adjacent])))
    try UpdateOperations.withPreparedUpdate(localRequest, environment: project.environment) {
      _ = try $0.apply()
    }
    try apply(.install(root), project)
    let installed = try project.bytes(config)
    let original = try project.store.loadLedger()
    #expect(original.nativeAuthorities?.isEmpty == false)
    #expect(String(decoding: installed, as: UTF8.self).contains("never-run-marketplace"))
    try FileManager.default.removeItem(at: market.catalog)
    try MarketplaceOperations.writeLockOnly(
      MarketplaceOperations.previewLockOnly(.remove("servers"), environment: project.environment))
    #expect(try project.bytes(config) == installed)
    #expect(try project.store.loadLedger().nativeAuthorities == original.nativeAuthorities)
    let preview = try MarketplaceOperations.previewFrozenDeployment(
      environment: project.environment)
    _ = try MarketplaceOperations.deployFrozen(preview)
    let text = try String(contentsOf: config, encoding: .utf8)
    #expect(text.contains(manual))
    #expect(text.contains("never-run-adjacent"))
    #expect(!text.contains("never-run-marketplace"))
    let deployed = try UpdateOperations.inspect(environment: project.environment)
    #expect(deployed.deployments.count == 1)
    #expect(deployed.deployments.first?.status == .current)
    #expect(deployed.pendingMarketplaceDeployment == nil)
  }

  @Test func rootedDiamondBacktracksAndRemovesOnlyEachRootsTargets() throws {
    let market = try GraphCatalog()
    let v1 = SourceRequirement.exact("1.0.0")
    let range = SourceRequirement.range(from: "1.0.0", to: "3.0.0")
    try market.publish("shared", "1.0.0")
    try market.publish("shared", "2.0.0")
    try market.publish("left", "1.0.0", ["shared": range])
    try market.publish("left", "2.0.0", ["shared": .exact("2.0.0")])
    try market.publish("right", "1.0.0", ["shared": v1])
    try market.publish("starter", "1.0.0", ["left": range, "right": v1])

    let project = try UpdateFixture()
    let one = try market.root("one", package: "starter", recipient: .codex)
    let two = try market.root("two", package: "right", recipient: .claudeCode)
    let plan = try MarketplaceOperations.resolve(.install(one), environment: project.environment)
    #expect(
      plan.nodes.first { $0.versions.node.package == "left" }?.versions.eligible.version == "1.0.0")
    #expect(
      plan.nodes.first { $0.versions.node.package == "left" }?.versions.latest?.version == "2.0.0")
    #expect(plan.nodes.first { $0.versions.node.package == "shared" }?.availableMembers?.count == 1)
    try apply(.install(one), project)
    let second = try apply(.install(two), project)
    let graph = try #require(second.marketplaceGraphChange?.after)
    let shared = try #require(graph.nodes.first { $0.id.package == "shared" })
    #expect(graph.nodes.count == 4)
    #expect(graph.rootsRequiring(shared.id) == ["one", "two"])
    #expect(graph.incoming(to: shared.id).map(\.parent.package) == ["left", "right"])
    #expect(Set(try #require(shared.members.first).targets) == [.codex, .claudeCode])
    #expect(FileManager.default.fileExists(atPath: project.target().path))
    #expect(FileManager.default.fileExists(atPath: project.target(.claudeCode).path))
    let scope = try UpdateOperations.inspect(environment: project.environment)
    for (agent, alias) in [(AgentID.codex, "one"), (.claudeCode, "two")] {
      let deployment = try #require(
        scope.deployments.first { $0.location.path == project.target(agent).path })
      #expect(scope.marketplaceOwners(of: deployment).map(\.root) == [alias])
    }
    let inventory = try #require(
      JSONSerialization.jsonObject(with: scope.cycloneDXInventory()) as? [String: Any])
    #expect((inventory["dependencies"] as? [[String: Any]])?.count == 3)

    try FileManager.default.removeItem(at: market.catalog)
    let removed = try apply(.remove("one"), project)
    #expect(removed.marketplaceGraphChange?.affectedRoots == ["one"])
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
    #expect(FileManager.default.fileExists(atPath: project.target(.claudeCode).path))
    let last = try apply(.remove("two"), project)
    #expect(last.marketplaceGraphChange?.after == nil)
    #expect(!FileManager.default.fileExists(atPath: project.target(.claudeCode).path))
    #expect(try project.store.loadLedger().marketplaceGraph == nil)
    let producers = project.store.directory.appendingPathComponent("bundles")
    #expect(try FileManager.default.contentsOfDirectory(atPath: producers.path).isEmpty)
  }

  @Test func reportsRequirementConflictAndCyclesWithoutWritingDestination() throws {
    let market = try GraphCatalog()
    let v1 = SourceRequirement.exact("1.0.0")
    try market.publish("shared", "1.0.0")
    try market.publish("shared", "2.0.0")
    try market.publish("left", "1.0.0", ["shared": v1])
    try market.publish("right", "1.0.0", ["shared": .exact("2.0.0")])
    try market.publish("conflict", "1.0.0", ["left": v1, "right": v1])
    try market.publish("loop-a", "1.0.0", ["loop-b": v1])
    try market.publish("loop-b", "1.0.0", ["loop-a": v1])

    let project = try UpdateFixture()
    for package in ["conflict", "loop-a"] {
      let root = try market.root("start", package: package)
      do {
        _ = try MarketplaceOperations.previewResolution(
          .install(root), environment: project.environment)
        Issue.record("Expected resolution failure for \(package)")
      } catch MarketplaceError.unsatisfiable(let detail) {
        #expect(package == "conflict")
        #expect(detail.contains("left") && detail.contains("right") && detail.contains("shared"))
      } catch MarketplaceError.dependencyCycle(let detail) {
        #expect(package == "loop-a")
        #expect(detail.contains("loop-a") && detail.contains("loop-b"))
      }
    }
    #expect(!FileManager.default.fileExists(atPath: project.store.directory.path))
  }

  @Test func upgradesSharedNodeAndReplaysPriorGraphInIndependentProject() throws {
    let market = try GraphCatalog()
    let sharedRange = SourceRequirement.upToNextMajor(from: "1.0.0")
    try market.publish("shared", "1.0.0")
    try market.publish("left", "1.0.0", ["shared": sharedRange])
    try market.publish("right", "1.0.0", ["shared": sharedRange])
    let project = try UpdateFixture()
    let cold = try UpdateFixture()
    try apply(.install(market.root("one", package: "left", recipient: .codex)), project)
    try apply(.install(market.root("two", package: "right", recipient: .claudeCode)), project)
    for name in ["agents.yaml", "agents.resolved"] {
      try cold.write(
        String(contentsOf: project.store.directory.appendingPathComponent(name), encoding: .utf8),
        to: cold.store.directory.appendingPathComponent(name))
    }
    let oldLock = try cold.bytes(cold.store.resolvedURL)
    let old = try #require(cold.store.loadLedger().marketplaceGraph)
    #expect(old.nodes.first { $0.id.package == "shared" }?.coordinate.version == "1.0.0")
    try market.publish("shared", "1.1.0")
    let upgrade = try MarketplaceOperations.previewResolution(
      .upgrade("one"), environment: project.environment)
    #expect(upgrade.report.marketplaceGraphChange?.affectedRoots == ["one", "two"])
    let versions = try #require(
      upgrade.resolution.nodes.first { $0.versions.node.package == "shared" }?.versions)
    #expect(versions.locked?.version == "1.0.0")
    #expect(versions.eligible.version == "1.1.0")
    #expect(versions.latest?.version == "1.1.0")

    try market.publish("shared", "1.2.0")
    #expect(throws: CoreError.self) {
      try MarketplaceOperations.withPreparedResolution(upgrade) { try $0.apply() }
    }
    let updated = try apply(.upgrade("one"), project)
    #expect(
      updated.marketplaceGraphChange?.after?.nodes.first { $0.id.package == "shared" }?.coordinate
        .version == "1.2.0")
    try FileManager.default.removeItem(at: market.catalog)
    _ = try UpdateOperations.restore(environment: cold.environment)
    #expect(try cold.bytes(cold.store.resolvedURL) == oldLock)
    #expect(
      try cold.bytes(cold.target().appendingPathComponent("SKILL.md"))
        == project.bytes(project.target().appendingPathComponent("SKILL.md")))
    #expect(try UpdateOperations.inspect(environment: cold.environment).marketplaceGraph == old)
    try apply(.remove("one"), cold)
    #expect(!FileManager.default.fileExists(atPath: cold.target().path))
    #expect(FileManager.default.fileExists(atPath: cold.target(.claudeCode).path))
  }

  @Test func requiresReconciliationForAuthoredDriftAndMissingLock() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let root = try market.root("shared", package: "shared")
    try project.write(
      """
      version: 1
      packages:
        shared:
          catalog: {kind: directory, location: "\(market.catalog.path)"}
          package: shared
          requirement: {exact: "1.0.0"}
      """,
      to: project.store.declarationURL)
    #expect(try project.store.loadDeclaration().marketplaceRoots == [root])
    #expect(
      try UpdateOperations.inspect(environment: project.environment).marketplaceIssue
        == .missingPin("shared"))
    #expect(throws: MarketplaceError.missingPin("shared")) {
      try UpdateOperations.restore(environment: project.environment)
    }
    let reconciled = try apply(.reconcile, project)
    #expect(reconciled.marketplaceGraphChange?.after?.roots.first?.intent == root)
    #expect(try UpdateOperations.inspect(environment: project.environment).marketplaceIssue == nil)
    let manifest = try String(contentsOf: project.store.declarationURL, encoding: .utf8)
    try project.write(
      manifest.replacingOccurrences(of: "1.0.0", with: "2.0.0"), to: project.store.declarationURL)
    let drifted = try UpdateOperations.inspect(environment: project.environment)
    #expect(drifted.marketplaceIssue == .selectionMismatch("shared"))
    #expect(throws: MarketplaceError.selectionMismatch("shared")) {
      try drifted.cycloneDXInventory()
    }
    #expect(throws: MarketplaceError.selectionMismatch("shared")) {
      try UpdateOperations.restore(environment: project.environment)
    }
  }

  @Test func stalePolicyAndMutableCatalogNeverPublishPreview() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let root = try market.root("one", package: "shared", recipient: .codex)
    let request = MarketplaceResolutionRequest.install(root)
    let preview = try MarketplaceOperations.previewResolution(
      request, environment: project.environment)
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: project.environment)

    try project.write("version: 1\ndeny: [local]\n", to: policy)
    #expect(throws: SourcePolicyFailure.self) {
      try MarketplaceOperations.withPreparedResolution(preview) { try $0.apply() }
    }
    try FileManager.default.removeItem(at: policy)
    let lateRelease = try market.archive("shared", "2.0.0")
    #expect(throws: UpdateApplyError.self) {
      try MarketplaceOperations.withPreparedResolution(preview) {
        try MarketplaceOperations.publishBundle(lateRelease, to: market.catalog)
        return try $0.apply()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
    #expect(!FileManager.default.fileExists(atPath: project.store.resolvedURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: project.store.directory.appendingPathComponent("bundles").path))
  }

  @Test func interruptedGraphPublicationRollsBackTheWholeCandidate() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let root = try market.root("one", package: "shared", recipient: .codex)
    let request = MarketplaceResolutionRequest.install(root)
    let preview = try MarketplaceOperations.previewResolution(
      request, environment: project.environment)
    struct Interrupted: Error {}
    let checkpoint: (String) throws -> Void = { point in
      if point == "publish.0.created" { throw Interrupted() }
    }
    #expect(throws: UpdateApplyError.self) {
      try MarketplaceOperations.prepareResolution(preview, checkpoint: checkpoint) {
        try $0.apply()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
    #expect(!FileManager.default.fileExists(atPath: project.store.declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: project.store.resolvedURL.path))
    let producers = project.store.directory.appendingPathComponent("bundles")
    if FileManager.default.fileExists(atPath: producers.path) {
      #expect(try FileManager.default.contentsOfDirectory(atPath: producers.path).isEmpty)
    }
    _ = try apply(request, project)
    #expect(FileManager.default.fileExists(atPath: project.target().path))
  }

  @Test func incorporatesExactPortableInstallWhenANewRootSharesIt() throws {
    let market = try GraphCatalog()
    let release = try market.publish("shared", "1.0.0")
    try market.publish("starter", "1.0.0", ["shared": .exact("1.0.0")])
    let project = try UpdateFixture()
    let verified = try MarketplaceOperations.acquire(release, environment: project.environment)
    let component = try #require(verified.inspectBundle().components.first)
    let original = try verified.previewImport(
      as: "original", selections: [.init(componentID: component.id, targets: [.codex])],
      scope: .project, environment: project.environment)
    _ = try BundleOperations.withPreparedImport(original) { try $0.apply() }
    #expect(try MarketplaceOperations.installed(environment: project.environment).count == 1)

    let report = try apply(
      .install(market.root("next", package: "starter", recipient: .claudeCode)), project)
    let graph = try #require(report.marketplaceGraphChange?.after)
    let shared = try #require(graph.nodes.first { $0.id.package == "shared" })
    #expect(graph.rootsRequiring(shared.id) == ["next", "original"])
    #expect(Set(try #require(shared.members.first).targets) == [.codex, .claudeCode])
    #expect(try MarketplaceOperations.installed(environment: project.environment).isEmpty)
    #expect(FileManager.default.fileExists(atPath: project.target().path))
    try apply(.remove("next"), project)
    #expect(FileManager.default.fileExists(atPath: project.target().path))
    #expect(!FileManager.default.fileExists(atPath: project.target(.claudeCode).path))
  }

  @Test func catalogIdentityDistinguishesSameNamedReleasesAndRejectsRebinding() throws {
    let first = try GraphCatalog()
    let second = try GraphCatalog()
    try first.publish("shared", "1.0.0")
    try second.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let one = try first.root("one", package: "shared")
    try apply(.install(one), project)
    let two = try second.root("two", package: "shared")
    let report = try apply(.install(two), project)
    let graph = try #require(report.marketplaceGraphChange?.after)
    #expect(graph.nodes.count == 2)
    #expect(graph.nodes[0].id != graph.nodes[1].id)
    #expect(graph.nodes.allSatisfy { $0.id.package == "shared" })
    let rebound = try second.root("one", package: "shared")
    #expect(throws: MarketplaceError.originConflict("one")) {
      try MarketplaceOperations.resolve(.install(rebound), environment: project.environment)
    }
  }

  @Test func upgradesWithReviewedSelectionsForNewAndRemovedMembers() throws {
    let market = try GraphCatalog()
    try market.publish("starter", "1.0.0")
    let project = try UpdateFixture()
    let root = try MarketplaceRoot(
      name: "root", catalog: market.origin, package: "starter",
      requirement: .upToNextMajor(from: "1.0.0"))
    try apply(.install(root), project)
    try market.publish("extra", "1.0.0")
    try market.publish("starter", "1.1.0", ["extra": .exact("1.0.0")])
    let plan = try MarketplaceOperations.resolve(.upgrade("root"), environment: project.environment)
    let extra = try #require(plan.nodes.first { $0.versions.node.package == "extra" })
    let member = try #require(extra.availableMembers?.first?.marketplaceKey)
    let selection = try MarketplaceMemberSelection(
      package: "extra", member: member, targets: [.codex])
    try apply(.upgrade("root", selections: [selection]), project)
    #expect(FileManager.default.fileExists(atPath: project.target().path))

    try market.publish("starter", "1.2.0")
    let next = try MarketplaceOperations.resolve(.upgrade("root"), environment: project.environment)
    #expect(next.nodes.first?.versions.eligible.version == "1.2.0")
    #expect(throws: MarketplaceError.selectionMismatch("root / demo")) {
      try MarketplaceOperations.previewResolution(
        .upgrade("root"), environment: project.environment)
    }
    try apply(.upgrade("root", selections: []), project)
    #expect(!FileManager.default.fileExists(atPath: project.target().path))
  }

  @Test func resolvesGitSubpathsAndRelativeUserCatalogs() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let user = try UpdateFixture(scope: .user)
    for name in ["docs", "tools"] {
      try FileManager.default.copyItem(
        at: market.catalog, to: user.repo.appendingPathComponent(name))
    }
    try user.commit()
    let commit = try user.git(["rev-parse", "HEAD"])
    func root(_ name: String, subpath: String, ref: String? = "main") throws -> MarketplaceRoot {
      try MarketplaceRoot(
        name: name,
        catalog: MarketplaceOrigin(kind: .git, location: "../source", ref: ref, subpath: subpath),
        package: "shared", requirement: .exact("1.0.0"))
    }
    try apply(.install(root("docs", subpath: "docs")), user)
    let installed = try apply(.install(root("tools", subpath: "tools")), user)
    let graph = try #require(installed.marketplaceGraphChange?.after)
    #expect(graph.nodes.compactMap(\.id.catalog.subpath) == ["docs", "tools"])
    #expect(graph.nodes.allSatisfy { $0.catalogCommit == commit })
    #expect(throws: MarketplaceError.self) {
      let conflicting = try root("another", subpath: "docs", ref: nil)
      _ = try MarketplaceOperations.resolve(
        .install(conflicting), scope: .user, environment: user.environment)
    }
  }

  @Test func pinOnlyUpdateReportsLockAndLatestWithoutNativeTargets() throws {
    let market = try GraphCatalog()
    try market.publish("shared", "1.0.0")
    let project = try UpdateFixture()
    let root = try MarketplaceRoot(
      name: "root", catalog: market.origin, package: "shared",
      requirement: .upToNextMajor(from: "1.0.0"))
    try apply(.install(root), project)
    try market.publish("shared", "1.1.0+one")
    try market.publish("shared", "1.1.0+two")
    try market.publish("shared", "1.2.0-rc.1")
    try market.publish("shared", "2.0.0")
    let updated = try MarketplaceOperations.previewResolution(
      .upgrade("root"), environment: project.environment)
    let versions = try #require(updated.resolution.nodes.first?.versions)
    #expect(versions.locked?.version == "1.0.0")
    #expect(versions.eligible.version == "1.1.0+two")
    #expect(versions.latest?.version == "2.0.0")
    #expect(updated.report.hasChanges && updated.report.components.isEmpty)
    let receipt = MarketplaceOperations.performResolution(updated) { try $0.apply() }
    #expect(receipt.disposition == .committed)
    _ = try receipt.result.get()
    #expect(try project.store.loadLedger().deployments.isEmpty)

    let exact = try MarketplaceRoot(
      name: "root", catalog: market.origin, package: "shared",
      requirement: .exact("1.1.0+one"))
    let plan = try MarketplaceOperations.resolve(.install(exact), environment: project.environment)
    #expect(plan.nodes.first?.versions.eligible.version == "1.1.0+one")
  }

  @Test func deniesAnExplicitPortableCatalogBeforeDiscovery() throws {
    let market = try GraphCatalog()
    let denied = try MarketplaceOrigin(kind: .git, location: "https://blocked.invalid/catalog")
    let dependency = try MarketplacePackageRequirement(
      package: "shared", requirement: .exact("1.0.0"), catalog: denied)
    try market.publish("starter", "1.0.0", dependencies: [dependency])
    let project = try UpdateFixture()
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: project.environment)
    try project.write("version: 1\nallow: [local]\n", to: policy)
    let root = try market.root("one", package: "starter")
    #expect(throws: SourcePolicyFailure.self) {
      try MarketplaceOperations.resolve(.install(root), environment: project.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: project.store.resolvedURL.path))
  }

  @discardableResult
  private func apply(_ request: MarketplaceResolutionRequest, _ consumer: UpdateFixture) throws
    -> CombinedUpdateReport
  {
    let preview = try MarketplaceOperations.previewResolution(
      request, scope: consumer.store.scope, environment: consumer.environment)
    #expect(preview.ownershipConflict == nil)
    return try MarketplaceOperations.withPreparedResolution(preview) {
      try $0.apply(ifUnchangedFrom: preview.report.displayedFingerprint).report
    }
  }
}

struct GraphCatalog {
  let author: UpdateFixture
  let catalog: URL
  let origin: MarketplaceOrigin
  let selection: ComponentSelection

  init() throws {
    let author = try UpdateFixture()
    try author.install()
    catalog = author.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    origin = try MarketplaceOrigin(kind: .directory, location: catalog.path)
    let state = try UpdateOperations.inspect(environment: author.environment)
    selection = try #require(state.components.first { $0.kind == .skills }?.selection)
    self.author = author
  }

  @discardableResult
  func publish(
    _ package: String, _ version: String, _ dependencies: [String: SourceRequirement] = [:]
  )
    throws -> MarketplaceRelease
  {
    let edges = try dependencies.keys.sorted().map {
      try MarketplacePackageRequirement(package: $0, requirement: dependencies[$0]!)
    }
    return try publish(package, version, dependencies: edges)
  }

  @discardableResult
  func publish(_ package: String, _ version: String, dependencies: [MarketplacePackageRequirement])
    throws -> MarketplaceRelease
  {
    try MarketplaceOperations.publishBundle(
      archive(package, version, dependencies: dependencies), to: catalog)
  }

  func archive(
    _ package: String, _ version: String, dependencies: [MarketplacePackageRequirement] = []
  ) throws -> Data {
    try BundleOperations.export(
      .init(name: package, version: version, dependencies: dependencies), selections: [selection],
      scope: .project, environment: author.environment)
  }

  func root(_ name: String, package: String, recipient: AgentID? = nil) throws -> MarketplaceRoot {
    let selections =
      try recipient.map { target in
        [
          try MarketplaceMemberSelection(
            package: "shared", member: .init(kind: .skills, name: "demo"), targets: [target])
        ]
      } ?? []
    return try MarketplaceRoot(
      name: name, catalog: origin, package: package, requirement: .exact("1.0.0"),
      selections: selections)
  }
}

extension MarketplaceResolutionTests {
  @Test func organizationChecksNewAndRetainedTransitiveEdgesBeforeAcquisition() throws {
    let market = try GraphCatalog()
    try market.publish("leaf", "1.0.0")
    try market.publish("starter", "1.0.0", ["leaf": .exact("1.0.0")])
    let root = try market.root("main", package: "starter")
    let consumer = try UpdateFixture()
    let policy = consumer.root.appendingPathComponent("org.yaml")
    var environment = consumer.environment
    environment.userOrganizationPolicy = .init(.local(policy))

    try consumer.write("enforcement: block\ndependencies: {max_depth: 1}", to: policy)
    do {
      _ = try MarketplaceOperations.previewResolution(.install(root), environment: environment)
      Issue.record("A depth-two dependency was admitted.")
    } catch let error as OrganizationPolicyFailure {
      let depth = try #require(error.report.findings.first { $0.rule == "dependency-depth" })
      #expect(depth.dependencyPath.count == 2)
      #expect(depth.dependencyPath.last?.hasSuffix("#leaf") == true)
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.directory.path))

    try consumer.write("enforcement: warn\ndependencies: {max_depth: 1}", to: policy)
    let preview = try MarketplaceOperations.previewResolution(
      .install(root), environment: environment)
    #expect(
      preview.report.organizationPolicy?.findings.contains { $0.rule == "dependency-depth" } == true
    )
    _ = try MarketplaceOperations.withPreparedResolution(preview) { try $0.apply() }

    let denied = "local:" + market.catalog.resolvingSymlinksInPath().path + "#leaf"
    try consumer.write("enforcement: block\ndependencies: {deny: ['\(denied)']}", to: policy)
    let previous = try FileHash.folderHash(consumer.root)
    #expect(throws: OrganizationPolicyFailure.self) {
      _ = try MarketplaceOperations.previewResolution(.reconcile, environment: environment)
    }
    try FileManager.default.removeItem(at: market.catalog)
    let audit = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(audit.isBlocked)
    #expect(
      audit.organization.findings.contains {
        $0.rule == "package-deny" && $0.matchedPattern == denied
      })
    #expect(throws: OrganizationPolicyFailure.self) {
      _ = try UpdateOperations.restore(environment: environment)
    }
    #expect(try FileHash.folderHash(consumer.root) == previous)
  }

  @Test func organizationVersionConflictModesKeepAuthoredAndResolvedEvidence() throws {
    let market = try GraphCatalog()
    try market.publish("tools", "1.0.0")
    try market.publish("tools", "2.0.0")
    let consumer = try UpdateFixture()
    let root = try MarketplaceRoot(
      name: "tools", catalog: market.origin, package: "tools", requirement: .exact("1.0.0"),
      selections: [
        .init(package: "tools", member: .init(kind: .skills, name: "demo"), targets: [.codex])
      ])
    let policy = consumer.root.appendingPathComponent("org.yaml")
    let identity = "local:" + market.catalog.resolvingSymlinksInPath().path + "#tools"
    var environment = consumer.environment
    environment.userOrganizationPolicy = .init(.local(policy))
    func rules(_ resolution: String) -> String {
      """
      enforcement: block
      dependencies:
        require_resolution: \(resolution)
        require: [{identity: '\(identity)', exact: '2.0.0'}]
      """
    }
    try consumer.write(rules("project-wins"), to: policy)
    let project = try MarketplaceOperations.previewResolution(
      .install(root), environment: environment)
    #expect(project.resolution.nodes.first?.versions.eligible.version == "1.0.0")
    try consumer.write(rules("block"), to: policy)
    #expect(throws: OrganizationPolicyFailure.self) {
      _ = try MarketplaceOperations.previewResolution(.install(root), environment: environment)
    }

    try consumer.write(rules("policy-wins"), to: policy)
    let organization = try MarketplaceOperations.previewResolution(
      .install(root), environment: environment)
    #expect(organization.resolution.nodes.first?.versions.eligible.version == "2.0.0")
    #expect(organization.resolution.roots.first?.intent.requirement == root.requirement)
    _ = try MarketplaceOperations.withPreparedResolution(organization) { try $0.apply() }
    #expect(try !OrganizationPolicyOperations.audit(environment: environment).isBlocked)
    try FileManager.default.removeItem(at: market.catalog)
    _ = try UpdateOperations.restore(environment: environment)

    try consumer.write("enforcement: off", to: policy)
    let stale = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(
      stale.organization.findings.contains {
        $0.rule == "dependency-policy-override" && $0.outcome == .block
      })
    #expect(throws: OrganizationPolicyFailure.self) {
      _ = try UpdateOperations.restore(environment: environment)
    }
  }
}
