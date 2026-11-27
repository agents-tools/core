import AgentsCore
import AgentsManifest
import Foundation
import Synchronization
import Testing

@testable import AgentsUpdates

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Hosted HTTPS marketplace")
struct HostedMarketplaceTests {
  private static let token = "synthetic-team-token"

  @Test func canonicalIdentityAndIndexAdmission() throws {
    let origin = try MarketplaceOrigin(
      kind: .hosted, location: "HTTPS://TEAM.invalid:443/a/index.json")
    #expect(origin.location == "https://team.invalid/a/index.json")
    #expect(origin == (try MarketplaceOrigin(hostedIndex: #require(origin.hostedIndex))))
    for bad in [
      "http://team.invalid/a/index.json", "https://user@team.invalid/a/index.json",
      "https://team.invalid/a/index.json#x", "https://team.invalid/a/index.json?token=value",
      "https://team.invalid/a/%2e/index.json", "https://team.invalid/a/../index.json",
      "https://team.invalid/a/%2Findex.json", "https://team.invalid/a//index.json",
    ] {
      #expect(throws: MarketplaceError.self) { try MarketplaceOrigin(kind: .hosted, location: bad) }
    }

    let package = try GraphCatalog()
    let bytes = try package.archive("demo", "1.0.0")
    let fixture = try HostedFixture(archive: bytes)
    let market = HostedResponses(fixture.responses)
    let consumer = try UpdateFixture()
    let catalog = try MarketplaceOperations.verifyCatalog(
      fixture.registration, environment: consumer.environment, hostedAccess: market.access())
    #expect(catalog.search("HanDbook").map(\.coordinate.package) == ["demo"])
    #expect(catalog.indexDigest == ReleaseMetadata.digest(fixture.index))
    #expect(!FileManager.default.fileExists(atPath: consumer.store.directory.path))

    let valid = try HostedMarketplaceIndex.read(fixture.index, maximumReleases: 2)
    let entry = try #require(valid.releases.first)
    #expect(throws: MarketplaceError.self) {
      try HostedMarketplaceIndex.read(fixture.index, maximumReleases: 0)
    }
    #expect(throws: MarketplaceError.self) {
      try HostedMarketplaceIndex.read(
        ResolvedLedgerCodec.bytes(
          HostedMarketplaceIndex(formatVersion: 1, releases: [entry, entry])),
        maximumReleases: 2)
    }
    for path in [
      "/outside.bundle", "../outside.bundle", "a/../outside.bundle", "a%2fb", "a//b",
      "https://outside.invalid/bundle", "a?token=value", "a#fragment",
    ] {
      let bad = HostedMarketplaceIndex.Entry(
        coordinate: entry.coordinate, archiveDigest: entry.archiveDigest,
        archiveByteCount: entry.archiveByteCount, summary: nil, archivePath: path)
      #expect(throws: MarketplaceError.self) {
        try HostedMarketplaceIndex.read(
          ResolvedLedgerCodec.bytes(HostedMarketplaceIndex(formatVersion: 1, releases: [bad])),
          maximumReleases: 2)
      }
    }

    market.set(fixture.archiveURL, status: 200, bytes: bytes + Data([0]))
    #expect(throws: HostedMarketplaceError.responseTooLarge) {
      try MarketplaceOperations.verifyCatalog(
        fixture.registration, environment: consumer.environment, hostedAccess: market.access())
    }
    var changed = bytes
    changed[changed.startIndex] ^= 1
    market.set(fixture.archiveURL, status: 200, bytes: changed)
    #expect(throws: MarketplaceError.integrityMismatch("demo@1.0.0")) {
      try MarketplaceOperations.verifyCatalog(
        fixture.registration, environment: consumer.environment, hostedAccess: market.access())
    }
  }

  @Test func userRegistrationAndPerHopCredentialIsolation() throws {
    let package = try GraphCatalog()
    let fixture = try HostedFixture(archive: package.archive("demo", "1.0.0"))
    let market = HostedResponses(fixture.responses)
    let consumer = try UpdateFixture()
    let index = fixture.registration.origin.location
    let alias = fixture.registration.name
    let environment = consumer.environment
    let mirror = try #require(URL(string: "https://cdn.invalid"))
    let cdn = mirror.absoluteString + "/snapshots/demo.bundle"
    let returned = "https://team.invalid/team/return.bundle"
    market.set(fixture.archiveURL, status: 302, location: cdn)
    market.set(cdn, status: 307, location: returned)
    market.set(returned, status: 200, bytes: fixture.archive)
    market.requireToken(at: index)
    let access = market.access(downloadOrigins: [try .http(mirror.absoluteString)]) { url in
      url.absoluteString == index ? Self.token : nil
    }

    try MarketplaceDirectory.register(
      fixture.registration, scope: .project, environment: environment)
    #expect(throws: HostedMarketplaceError.credentialRequired) {
      try MarketplaceOperations.browse(
        fixture.registration, environment: environment, hostedAccess: access)
    }
    #expect(market.takeRequests() == [.init(url: index, authorization: nil)])

    try MarketplaceDirectory.register(fixture.registration, scope: .user, environment: environment)
    let selected = try MarketplaceOperations.browse(
      fixture.registration, environment: environment, hostedAccess: access
    ).select(package: "demo")
    let verified = try MarketplaceOperations.acquire(
      selected, environment: environment, hostedAccess: access)
    #expect(
      verified.hostedEvidence?.archiveRequests.map(\.absoluteString) == [
        fixture.archiveURL, cdn, returned,
      ])
    #expect(
      market.takeRequests() == [
        .init(url: index, authorization: "Bearer " + Self.token),
        .init(url: fixture.archiveURL, authorization: "Bearer " + Self.token),
        .init(url: cdn, authorization: nil), .init(url: returned, authorization: nil),
      ])

    let userPolicy = SourcePolicyOperations.policyURL(scope: .user, environment: environment)
    try consumer.write("version: 1\ndeny: [{http: 'https://cdn.invalid'}]\n", to: userPolicy)
    #expect(throws: SourcePolicyFailure.self) {
      try MarketplaceOperations.acquire(selected, environment: environment, hostedAccess: access)
    }
    #expect(market.takeRequests().map(\.url) == [fixture.archiveURL])
    try FileManager.default.removeItem(at: userPolicy)
    let org = consumer.root.appendingPathComponent("org.yaml")
    try consumer.write("enforcement: block\nsources: {deny: ['https://cdn.invalid']}\n", to: org)
    var governed = environment
    governed.userOrganizationPolicy = .init(.local(org))
    #expect(throws: OrganizationPolicyFailure.self) {
      try MarketplaceOperations.acquire(selected, environment: governed, hostedAccess: access)
    }
    #expect(market.takeRequests().map(\.url) == [fixture.archiveURL])

    market.set(index, status: 302, location: cdn)
    #expect(throws: MarketplaceError.self) {
      try MarketplaceOperations.browse(
        fixture.registration, environment: environment, hostedAccess: access)
    }
    #expect(market.takeRequests().map(\.url) == [index])
    market.set(index, status: 200, bytes: fixture.index)

    #expect(throws: HostedMarketplaceError.redirectDenied) {
      try MarketplaceOperations.acquire(
        selected, environment: environment, hostedAccess: market.access())
    }
    #expect(market.takeRequests().map(\.url) == [fixture.archiveURL])

    market.set(fixture.archiveURL, status: 302, location: "/team-sibling/demo.bundle")
    #expect(throws: MarketplaceError.self) {
      try MarketplaceOperations.acquire(selected, environment: environment, hostedAccess: access)
    }
    #expect(market.takeRequests().map(\.url) == [fixture.archiveURL])

    let wrong = try MarketplaceRegistration(
      name: alias,
      origin: MarketplaceOrigin(kind: .hosted, location: "https://team.invalid/other/index.json"))
    try MarketplaceDirectory.unregister(alias, scope: .user, environment: environment)
    try MarketplaceDirectory.register(wrong, scope: .user, environment: environment)
    let shouldNotTransfer = market.access { _ in Self.token }
    #expect(throws: HostedMarketplaceError.credentialRequired) {
      try MarketplaceOperations.browse(
        fixture.registration, environment: environment, hostedAccess: shouldNotTransfer)
    }
    #expect(market.takeRequests() == [.init(url: index, authorization: nil)])

    try MarketplaceDirectory.register(
      MarketplaceRegistration(name: "original", origin: fixture.registration.origin),
      scope: .user, environment: environment)
    for invalid in ["", "\r\nX-Test: injected", "two words", "\u{1F512}"] {
      #expect(throws: HostedMarketplaceError.invalidCredential) {
        try MarketplaceOperations.browse(
          fixture.registration, environment: environment,
          hostedAccess: market.access { _ in invalid })
      }
    }
    #expect(market.takeRequests().isEmpty)
  }

  @Test func privateHostedLockWritesReviewedBytesAndDeploysInAnotherProjectOffline() throws {
    let producer = try GraphCatalog()
    let remote = try HostedFixture(archive: producer.archive("starter", "1.0.0"))
    let market = HostedResponses(remote.responses)
    let consumer = try UpdateFixture()
    let env = consumer.environment
    let index = remote.registration.origin.location
    market.requireToken(at: index)
    try MarketplaceDirectory.register(remote.registration, scope: .user, environment: env)
    let access = market.access { url in url.absoluteString == index ? Self.token : nil }
    let root = try MarketplaceRoot(
      name: "starter", catalog: remote.registration.origin, package: "starter",
      requirement: .exact("1.0.0"),
      selections: [
        MarketplaceMemberSelection(
          package: "starter", member: .init(kind: .skills, name: "demo"), targets: [.codex])
      ])
    func preview() throws -> MarketplaceLockPreview {
      try MarketplaceOperations.previewLockOnly(
        .install(root), environment: env, hostedAccess: access)
    }
    let revoked = try preview()
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: env)
    try consumer.write("version: 1\ndeny: [{http: 'https://team.invalid'}]\n", to: policy)
    #expect(throws: CoreError.self) { try MarketplaceOperations.writeLockOnly(revoked) }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.resolvedURL.path))
    try FileManager.default.removeItem(at: policy)
    let checked = try preview()
    #expect(!market.takeRequests().isEmpty)
    market.set(index, status: 503)
    market.set(remote.archiveURL, status: 503)
    _ = try MarketplaceOperations.writeLockOnly(checked)
    #expect(!FileManager.default.fileExists(atPath: consumer.target().path))
    #expect(market.takeRequests().isEmpty)
    let cold = try UpdateFixture()
    for name in ["agents.yaml", "agents.resolved"] {
      let text = try String(
        contentsOf: consumer.store.directory.appendingPathComponent(name), encoding: .utf8)
      #expect(!text.contains(Self.token))
      try cold.write(text, to: cold.store.directory.appendingPathComponent(name))
    }
    let deployment = try MarketplaceOperations.previewFrozenDeployment(
      environment: cold.environment)
    _ = try MarketplaceOperations.deployFrozen(deployment)
    #expect(
      try cold.bytes(cold.target().appendingPathComponent("SKILL.md"))
        == producer.author.bytes(producer.author.target().appendingPathComponent("SKILL.md")))
    #expect(
      try UpdateOperations.inspect(environment: cold.environment).pendingMarketplaceDeployment
        == nil)
    #expect(market.takeRequests().isEmpty)
  }

  @Test func deniedHostedStagingLeavesTheOutputDirectoryEmpty() throws {
    let producer = try GraphCatalog()
    let bundle = try producer.archive("starter", "1.0.0")
    let consumer = try UpdateFixture()
    let env = consumer.environment
    let directory = consumer.root.appendingPathComponent("stage", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let policy = consumer.root.appendingPathComponent("organization.yaml")
    var denied = env
    denied.userOrganizationPolicy = .init(.local(policy))
    try consumer.write("enforcement: block\ndependencies: {deny: ['_local/starter']}\n", to: policy)
    #expect(throws: OrganizationPolicyFailure.self) {
      try MarketplaceOperations.exportHostedBundle(bundle, to: directory, environment: denied)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func recapturePreservesNamedHostedReleaseAndChecksItsDownloadRoute() throws {
    let producer = try GraphCatalog()
    let remote = try HostedFixture(archive: producer.archive("starter", "1.0.0"))
    let market = HostedResponses(remote.responses)
    let author = try UpdateFixture()
    let environment = author.environment
    let index = remote.registration.origin.location
    let cdn = "https://cdn.invalid"
    let download = cdn + "/snapshots/starter.bundle"
    market.set(remote.archiveURL, status: 302, location: download)
    market.set(download, status: 200, bytes: remote.archive)
    market.requireToken(at: index)
    try MarketplaceDirectory.register(remote.registration, scope: .user, environment: environment)
    let access = market.access(downloadOrigins: [try .http(cdn)]) {
      $0.absoluteString == index ? Self.token : nil
    }
    let root = try MarketplaceRoot(
      name: "starter", catalog: remote.registration.origin, package: "starter",
      requirement: .exact("1.0.0"),
      selections: [
        .init(package: "starter", member: .init(kind: .skills, name: "demo"), targets: [.codex])
      ])
    let reviewed = try MarketplaceOperations.previewResolution(
      .install(root), environment: environment, hostedAccess: access)
    _ = try MarketplaceOperations.withPreparedResolution(reviewed) { try $0.apply() }
    #expect(market.takeRequests().map(\.url).contains(download))

    let package = BundlePackage(name: "derivative", version: "2.0.0")
    let spec = AuthorPackageSpecification(
      package: package, lockedMembers: [.init(kind: .skills, name: "demo")])
    let authorCapture = try AuthorPackageOperations.preview(spec, environment: environment)
    let installed = try UpdateOperations.inspect(environment: environment)
    let selection = try #require(installed.components.first?.selection)
    let bytes = try BundleOperations.export(
      package, selections: [selection], scope: .project, environment: environment)
    let installedExport = try BundleOperations.inspect(bytes)
    for capture in [authorCapture.inspection, installedExport] {
      let member = try #require(capture.components.first)
      let named = try #require(member.sources.first { $0.packageName == "starter" })
      #expect(named.identity == index)
      #expect(named.root == "team/index.json")
      #expect(named.origin == (try .http("https://team.invalid")))
      #expect(named.version == "1.0.0")
      #expect(named.revision == BundleArchive.digest(remote.archive))
      #expect(
        member.sources.contains {
          $0.origin == (try? .http(cdn)) && $0.root == "snapshots/starter.bundle"
        })
      #expect(
        !String(decoding: try ResolvedLedgerCodec.bytes(member.sources), as: UTF8.self)
          .contains(Self.token))
    }

    let catalog = author.root.appendingPathComponent("derivatives")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let sourcePolicy = SourcePolicyOperations.policyURL(scope: .project, environment: environment)
    try author.write("version: 1\ndeny: [{http: '\(cdn)'}]\n", to: sourcePolicy)
    #expect(throws: SourcePolicyFailure.self) {
      try AuthorPackageOperations.publish(authorCapture, to: catalog, environment: environment)
    }
    #expect(throws: SourcePolicyFailure.self) {
      try MarketplaceOperations.publishBundle(bytes, to: catalog, environment: environment)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: catalog.path).isEmpty)
    try FileManager.default.removeItem(at: sourcePolicy)

    let policyURL = author.root.appendingPathComponent("org.yaml")
    var restricted = environment
    restricted.projectOrganizationPolicy = .init(.local(policyURL))
    try author.write("enforcement: block\nsources: {deny: ['\(download)']}\n", to: policyURL)
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.preview(spec, environment: restricted)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try BundleOperations.export(
        package, selections: [selection], scope: .project, environment: restricted)
    }
    #expect(market.takeRequests().isEmpty)
  }

  @Test func capturesGraphAndRestoresInAnIndependentProject() throws {
    let package = try GraphCatalog()
    let child = try HostedFixture(
      path: "/child", archive: package.archive("leaf", "1.0.0"))
    let edge = try MarketplacePackageRequirement(
      package: "leaf", requirement: .exact("1.0.0"), catalog: child.registration.origin)
    let parent = try HostedFixture(archive: package.archive("root", "1.0.0", dependencies: [edge]))
    let market = HostedResponses(parent.responses.merging(child.responses) { _, next in next })
    let access = market.access { _ in Self.token }
    let consumer = try UpdateFixture()
    let root = try MarketplaceRoot(
      name: "path", catalog: parent.registration.origin, package: "root",
      requirement: .upToNextMajor(from: "1.0.0"),
      selections: [
        MarketplaceMemberSelection(
          package: "leaf", catalog: child.registration.origin,
          member: .init(kind: .skills, name: "demo"), targets: [.codex])
      ])
    try MarketplaceDirectory.register(
      child.registration, scope: .project, environment: consumer.environment)
    #expect(throws: HostedMarketplaceError.registrationRequired) {
      try MarketplaceOperations.resolve(
        .install(root), environment: consumer.environment, hostedAccess: access)
    }
    #expect(
      market.takeRequests().map(\.url) == [parent.registration.origin.location, parent.archiveURL])
    try MarketplaceDirectory.register(
      child.registration, scope: .user, environment: consumer.environment)

    func preview() throws -> MarketplaceResolutionPreview {
      try MarketplaceOperations.previewResolution(
        .install(root), environment: consumer.environment, hostedAccess: access)
    }

    let revoked = try preview()
    let policyURL = SourcePolicyOperations.policyURL(
      scope: .project, environment: consumer.environment)
    try consumer.write("version: 1\ndeny: [{http: 'https://team.invalid'}]\n", to: policyURL)
    #expect(throws: CoreError.self) {
      try MarketplaceOperations.withPreparedResolution(revoked) { try $0.apply() }
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.target().path))
    #expect(!FileManager.default.fileExists(atPath: consumer.store.resolvedURL.path))
    try FileManager.default.removeItem(at: policyURL)

    let untrusted = try preview()
    try MarketplaceDirectory.unregister(
      child.registration.name, scope: .user, environment: consumer.environment)
    #expect(throws: HostedMarketplaceError.registrationRequired) {
      try MarketplaceOperations.withPreparedResolution(untrusted) { try $0.apply() }
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.resolvedURL.path))
    try MarketplaceDirectory.register(
      child.registration, scope: .user, environment: consumer.environment)

    let stale = try preview()
    try consumer.write("version: 1\n", to: consumer.store.declarationURL)
    #expect(throws: CoreError.self) {
      try MarketplaceOperations.withPreparedResolution(stale) { try $0.apply() }
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.resolvedURL.path))

    let replaced = try preview()
    let sameManifest = try consumer.bytes(consumer.store.declarationURL)
    try sameManifest.write(to: consumer.store.declarationURL, options: .atomic)
    #expect(throws: CoreError.self) {
      try MarketplaceOperations.withPreparedResolution(replaced) { try $0.apply() }
    }
    #expect(!FileManager.default.fileExists(atPath: consumer.store.resolvedURL.path))

    let reviewed = try preview()
    _ = market.takeRequests()
    market.set(child.archiveURL, status: 404)
    _ = try MarketplaceOperations.withPreparedResolution(reviewed) { try $0.apply() }
    #expect(market.takeRequests().isEmpty)
    let ledger = try consumer.store.loadLedger()
    let graph = try #require(ledger.marketplaceGraph)
    #expect(
      Set(graph.nodes.compactMap(\.id.catalog.hostedIndex)) == [
        try #require(child.registration.origin.hostedIndex),
        try #require(parent.registration.origin.hostedIndex),
      ])
    for release in graph.nodes {
      let archive = release.coordinate.package == "root" ? parent.archive : child.archive
      #expect(ledger.contentObjects[release.archiveDigest] == archive)
      #expect(release.hostedEvidence?.archiveByteCount == archive.count)
    }
    var corrupt = ledger.contentObjects
    let leaf = try #require(graph.nodes.first { $0.id.package == "leaf" })
    corrupt[leaf.archiveDigest] = Data(repeating: 0, count: child.archive.count)
    #expect(throws: (any Error).self) {
      try MarketplaceGraphChange.validateHosted(
        graph, objects: corrupt, policy: SourcePolicySnapshot(store: consumer.store).effective,
        organizationPolicy: OrganizationPolicySnapshot(store: consumer.store))
    }
    let lock = try consumer.bytes(consumer.store.resolvedURL)
    #expect(!String(decoding: lock, as: UTF8.self).contains(Self.token))

    let cold = try UpdateFixture()
    for name in ["agents.yaml", "agents.resolved"] {
      try cold.write(
        String(contentsOf: consumer.store.directory.appendingPathComponent(name), encoding: .utf8),
        to: cold.store.directory.appendingPathComponent(name))
    }
    var corruptLock = ledger
    corruptLock.contentObjects = corrupt
    try ResolvedLedgerCodec.bytes(corruptLock).write(to: cold.store.resolvedURL, options: .atomic)
    #expect(throws: CoreError.self) {
      try UpdateOperations.restore(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.target().path))
    try lock.write(to: cold.store.resolvedURL, options: .atomic)
    _ = try UpdateOperations.restore(environment: cold.environment)
    #expect(try cold.bytes(cold.store.resolvedURL) == lock)
    #expect(
      try cold.bytes(cold.target().appendingPathComponent("SKILL.md"))
        == consumer.bytes(consumer.target().appendingPathComponent("SKILL.md")))
    #expect(market.takeRequests().isEmpty)

    let other = try MarketplaceRegistration(
      name: parent.registration.name,
      origin: MarketplaceOrigin(kind: .hosted, location: "https://team.invalid/other/index.json"))
    try MarketplaceDirectory.register(other, scope: .user, environment: consumer.environment)
    let rebound = try MarketplaceRoot(
      name: root.name, catalog: other.origin, package: root.package, requirement: root.requirement)
    #expect(throws: MarketplaceError.originConflict(root.name)) {
      try MarketplaceOperations.resolve(
        .install(rebound), environment: consumer.environment, hostedAccess: access)
    }
    #expect(market.takeRequests().isEmpty)

    let latest = try HostedFixture(archive: package.archive("root", "1.1.0", dependencies: [edge]))
    let updatedIndex = try HostedMarketplaceIndex(
      formatVersion: 1,
      releases: [
        #require(HostedMarketplaceIndex.read(parent.index, maximumReleases: 2).releases.first),
        #require(HostedMarketplaceIndex.read(latest.index, maximumReleases: 2).releases.first),
      ])
    market.set(
      parent.registration.origin.location, status: 200,
      bytes: try ResolvedLedgerCodec.bytes(updatedIndex))
    market.set(latest.archiveURL, status: 200, bytes: latest.archive)
    let available = try MarketplaceOperations.resolve(
      .reconcile, environment: consumer.environment, hostedAccess: access)
    let rootVersions = try #require(
      available.nodes.first { $0.versions.node.package == "root" }?.versions)
    #expect(rootVersions.eligible.version == "1.0.0")
    #expect(rootVersions.latest?.version == "1.1.0")
    let upgrade = try MarketplaceOperations.previewResolution(
      .upgrade("path"), environment: consumer.environment, hostedAccess: access)
    #expect(
      upgrade.report.marketplaceGraphChange?.after?.nodes.contains {
        $0.coordinate.version == "1.1.0"
      } == true)
    let changedIndex = HostedMarketplaceIndex(
      formatVersion: 1,
      releases: updatedIndex.releases.map { entry in
        guard entry.coordinate.version == "1.0.0" else { return entry }
        return .init(
          coordinate: entry.coordinate,
          archiveDigest: latest.archive == parent.archive
            ? "" : ReleaseMetadata.digest(latest.archive),
          archiveByteCount: entry.archiveByteCount, summary: entry.summary,
          archivePath: entry.archivePath)
      })
    market.set(
      parent.registration.origin.location, status: 200,
      bytes: try ResolvedLedgerCodec.bytes(changedIndex))
    #expect(throws: MarketplaceError.integrityMismatch("root@1.0.0")) {
      try MarketplaceOperations.resolve(
        .upgrade("path"), environment: consumer.environment, hostedAccess: access)
    }
    #expect(try consumer.bytes(consumer.store.resolvedURL) == lock)
  }

  @Test func exportSerializesPublicationAndRetainsTheVisibleIndexOnInterruption() async throws {
    let author = try GraphCatalog()
    let first = try author.archive("kit", "1.0.0")
    let second = try author.archive("kit", "1.1.0")
    let third = try author.archive("tool", "1.0.0")
    let stage = author.catalog
    let mirror = author.author.root.appendingPathComponent("mirror", isDirectory: true)
    try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: false)
    let index = try MarketplaceOperations.exportHostedBundle(first, to: stage)
    let initial = try Data(contentsOf: index)
    struct Interrupted: Error {}
    #expect(throws: Interrupted.self) {
      try MarketplaceOperations.exportHostedBundle(second, to: stage, summary: nil) {
        throw Interrupted()
      }
    }
    #expect(try Data(contentsOf: index) == initial)
    #expect(
      try Data(contentsOf: stage.appendingPathComponent("releases/kit/1.1.0/package.bundle"))
        == second)
    async let addSecond = MarketplaceOperations.exportHostedBundle(second, to: stage)
    async let addThird = MarketplaceOperations.exportHostedBundle(third, to: stage)
    let published = try await [addSecond, addThird]
    #expect(published == [index, index])
    let final = try Data(contentsOf: index)
    _ = try MarketplaceOperations.exportHostedBundle(third, to: mirror)
    _ = try MarketplaceOperations.exportHostedBundle(first, to: mirror)
    let mirrored = try MarketplaceOperations.exportHostedBundle(second, to: mirror)
    #expect(try Data(contentsOf: mirrored) == final)
    _ = try MarketplaceOperations.exportHostedBundle(first, to: stage, summary: "ignored on replay")
    #expect(try Data(contentsOf: index) == final)
    let conflict = try author.archive(
      "kit", "1.0.0", dependencies: [.init(package: "tool", requirement: .exact("1.0.0"))])
    #expect(throws: MarketplaceError.publicationConflict("kit@1.0.0")) {
      try MarketplaceOperations.exportHostedBundle(conflict, to: stage)
    }
    #expect(try Data(contentsOf: index) == final)
    let contest = author.author.root.appendingPathComponent("contest", isDirectory: true)
    try FileManager.default.createDirectory(at: contest, withIntermediateDirectories: false)
    @Sendable func publish(_ bytes: Data) -> Result<URL, any Error> {
      Result { try MarketplaceOperations.exportHostedBundle(bytes, to: contest) }
    }
    async let candidateOne = publish(first)
    async let candidateTwo = publish(conflict)
    let contestResults = await [candidateOne, candidateTwo]
    #expect(contestResults.filter { (try? $0.get()) != nil }.count == 1)
    let rejected = contestResults.compactMap { result -> MarketplaceError? in
      guard case .failure(let error) = result else { return nil }
      return error as? MarketplaceError
    }
    #expect(rejected == [.publicationConflict("kit@1.0.0")], "\(contestResults)")

    let relocated = author.author.root.appendingPathComponent("relocated", isDirectory: true)
    try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: false)
    let manualArchive = relocated.appendingPathComponent("first.bundle")
    try first.write(to: manualArchive)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 123)],
      ofItemAtPath: manualArchive.path)
    let entry = try #require(
      HostedMarketplaceIndex.read(initial, maximumReleases: 1).releases.first)
    let alternate = HostedMarketplaceIndex.Entry(
      coordinate: entry.coordinate, archiveDigest: entry.archiveDigest,
      archiveByteCount: entry.archiveByteCount, summary: entry.summary, archivePath: "first.bundle")
    let relocatedIndex = relocated.appendingPathComponent(MarketplaceOperations.hostedIndexFilename)
    try ResolvedLedgerCodec.bytes(
      HostedMarketplaceIndex(formatVersion: 1, releases: [alternate])
    ).write(to: relocatedIndex)
    _ = try MarketplaceOperations.exportHostedBundle(third, to: relocated)
    let mixed = try HostedMarketplaceIndex.read(
      Data(contentsOf: relocatedIndex), maximumReleases: 2)
    #expect(
      mixed.releases.map(\.archivePath) == [
        "first.bundle", "releases/tool/1.0.0/package.bundle",
      ])
    #expect(try Data(contentsOf: manualArchive) == first)

    try Data([0]).write(to: stage.appendingPathComponent("releases/kit/1.0.0/package.bundle"))
    #expect(throws: MarketplaceError.integrityMismatch("kit@1.0.0")) {
      try MarketplaceOperations.exportHostedBundle(third, to: stage)
    }
    #expect(try Data(contentsOf: index) == final)
  }
}

private struct HostedFixture {
  let registration: MarketplaceRegistration
  let archive: Data
  let index: Data
  let archiveURL: String

  init(path: String = "/team", archive: Data) throws {
    let package = try BundleOperations.inspect(archive).package
    registration = try MarketplaceRegistration(
      name: String(path.dropFirst()),
      origin: MarketplaceOrigin(
        kind: .hosted, location: "https://team.invalid" + path + "/index.json"))
    let coordinate = try MarketplaceCoordinate(package: package.name, version: package.version)
    let filename = coordinate.releasePath + "/package.bundle"
    self.archive = archive
    archiveURL = "https://team.invalid" + path + "/" + filename
    let entry = HostedMarketplaceIndex.Entry(
      coordinate: coordinate, archiveDigest: ReleaseMetadata.digest(archive),
      archiveByteCount: archive.count, summary: "Team handbook", archivePath: filename)
    index = try ResolvedLedgerCodec.bytes(
      HostedMarketplaceIndex(formatVersion: 1, releases: [entry]))
  }

  var responses: [String: HostedMarketplaceHTTP.Response] {
    [
      registration.origin.location: .init(status: 200, location: nil, bytes: index),
      archiveURL: .init(status: 200, location: nil, bytes: archive),
    ]
  }
}

private final class HostedResponses: Sendable {
  struct Request: Equatable {
    let url: String
    let authorization: String?
  }

  struct State {
    var responses: [String: HostedMarketplaceHTTP.Response]
    var requests: [Request] = []
    var privateURLs: Set<String> = []
  }

  private let state: Mutex<State>

  init(_ responses: [String: HostedMarketplaceHTTP.Response]) {
    state = Mutex(State(responses: responses))
  }

  func set(_ url: String, status: Int, location: String? = nil, bytes: Data = Data()) {
    state.withLock { $0.responses[url] = .init(status: status, location: location, bytes: bytes) }
  }

  func requireToken(at url: String) {
    state.withLock { _ = $0.privateURLs.insert(url) }
  }

  func takeRequests() -> [Request] {
    state.withLock {
      let captured = $0.requests
      $0.requests.removeAll()
      return captured
    }
  }

  func access(
    downloadOrigins: Set<SourceOrigin> = [],
    credentialProvider: HostedMarketplaceAccess.CredentialProvider? = nil
  ) -> HostedMarketplaceAccess {
    HostedMarketplaceAccess(
      downloadOrigins: downloadOrigins, credentialProvider: credentialProvider
    ) { request, _ in
      self.state.withLock { state in
        let url = request.url!.absoluteString
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        state.requests.append(Request(url: url, authorization: authorization))
        if state.privateURLs.contains(url), authorization != "Bearer synthetic-team-token" {
          return .init(status: 401, location: nil, bytes: Data())
        }
        return state.responses[url] ?? .init(status: 404, location: nil, bytes: Data())
      }
    }
  }
}
