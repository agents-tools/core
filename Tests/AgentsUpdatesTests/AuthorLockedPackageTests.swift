import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@Suite("Author locked dependencies")
struct AuthorLockedPackageTests {
  @Test func packsMixedEmbeddedAndGitResourcesWithTheCatalogUnavailable() throws {
    let fixture = try UpdateFixture()
    let vendorProject = fixture.root.appendingPathComponent("vendor")
    var vendorEnvironment = fixture.environment
    vendorEnvironment.projectDirectory = vendorProject
    let catalog = fixture.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let origin = try MarketplaceOrigin(kind: .directory, location: catalog.path)
    for package in [
      BundlePackage(name: "leaf", version: "1.0.0"),
      try BundlePackage(
        name: "starter", version: "1.0.0",
        dependencies: [.init(package: "leaf", requirement: .exact("1.0.0"))]),
    ] {
      let project = vendorProject.appendingPathComponent(package.name)
      try FileManager.default.createDirectory(at: vendorProject, withIntermediateDirectories: true)
      vendorEnvironment.projectDirectory = project
      try AuthorPackageOperations.scaffold(package, at: project, environment: vendorEnvironment)
      let artifact = try AuthorPackageOperations.preview(environment: vendorEnvironment)
      try AuthorPackageOperations.publish(artifact, to: catalog, environment: vendorEnvironment)
    }
    try fixture.install(agents: [.codex])
    let root = try MarketplaceRoot(
      name: "vendor", catalog: origin, package: "starter", requirement: .exact("1.0.0"),
      selections: [
        .init(
          package: "starter", member: .init(kind: .skills, name: "getting-started"),
          targets: [.codex])
      ])
    let resolution = try MarketplaceOperations.previewResolution(
      .install(root), environment: fixture.environment)
    _ = try MarketplaceOperations.withPreparedResolution(resolution) { try $0.apply() }
    let ledger = try fixture.store.loadLedger()
    #expect(ledger.resources.values.contains { $0.kind == .git })
    #expect(ledger.resources.values.contains { $0.kind == .embedded })
    let lockedSkill = MarketplaceMemberKey(kind: .skills, name: "getting-started")
    let spec = AuthorPackageSpecification(
      package: .init(name: "mixed", version: "2.0.0"),
      lockedMembers: [lockedSkill, .init(kind: .instructions, name: "rules")])
    try FileManager.default.removeItem(at: catalog)
    let before = try FileHash.folderHash(fixture.root)
    let artifact = try AuthorPackageOperations.preview(spec, environment: fixture.environment)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(Set(artifact.inspection.components.map(\.name)) == ["getting-started", "rules"])
    let skill = try #require(artifact.inspection.components.first { $0.kind == .skills })
    #expect(Set(skill.sources.compactMap(\.packageName)) == ["starter", "leaf"])
    #expect(!String(decoding: artifact.archive, as: UTF8.self).contains(fixture.root.path))
    let consumer = try UpdateFixture()
    let assignment = BundleImportSelection(componentID: skill.id, targets: [.codex])
    let preview = try BundleOperations.previewImport(
      artifact.inspection, selections: [assignment], scope: .project,
      environment: consumer.environment)
    _ = try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    let installed = try UpdateOperations.inspect(environment: consumer.environment)
    #expect(installed.components.map(\.name) == ["getting-started"])

    let policySpec = AuthorPackageSpecification(package: spec.package, lockedMembers: [lockedSkill])
    let policyArtifact = try AuthorPackageOperations.preview(
      policySpec, environment: fixture.environment)
    let policy = fixture.root.appendingPathComponent("org.yaml")
    var denied = fixture.environment
    denied.userOrganizationPolicy = .init(.local(policy))
    try fixture.write("enforcement: block\ndependencies: {deny: ['_local/leaf']}", to: policy)
    do {
      _ = try AuthorPackageOperations.preview(policySpec, environment: denied)
      Issue.record("Transitive package was not denied.")
    } catch let error as OrganizationPolicyFailure {
      let findings = error.report.findings.map { "\($0.rule): \($0.identity)" }
      #expect(findings.contains("package-deny: _local/leaf"))
    }
    let output = fixture.root.appendingPathComponent("denied.bundle")
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.write(policyArtifact, to: output, environment: denied)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func missingOrTamperedLockAndLiveDependenciesCannotBePacked() throws {
    let fixture = try UpdateFixture()
    let spec = AuthorPackageSpecification(
      package: .init(name: "offline", version: "1.0.0"),
      lockedMembers: [.init(kind: .skills, name: "demo")])
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.preview(spec, environment: fixture.environment)
    }
    try fixture.install(mode: .edit, agents: [.codex])
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.preview(spec, environment: fixture.environment)
    }

    let embedded = try UpdateFixture()
    let publisher = try AuthorPackageOperations.preview(
      .init(package: .init(name: "fixture", version: "1.0.0"), skills: ["source/skills/demo"]),
      environment: embedded.environment)
    let consumer = try UpdateFixture()
    let selection = try #require(publisher.inspection.components.first)
    let preview = try BundleOperations.previewImport(
      publisher.inspection, selections: [.init(componentID: selection.id, targets: [.codex])],
      scope: .project, environment: consumer.environment)
    _ = try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    let ledger = try consumer.store.loadLedger()
    let id = try #require(ledger.contentObjects.keys.sorted().first)
    let before = try consumer.bytes(consumer.store.resolvedURL)
    var document = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    var objects = try #require(document["contentObjects"] as? [String: String])
    objects[id] = Data("tampered dependency".utf8).base64EncodedString()
    document["contentObjects"] = objects
    try JSONSerialization.data(
      withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]
    )
    .write(to: consumer.store.resolvedURL)
    let tampered = try consumer.bytes(consumer.store.resolvedURL)
    #expect(throws: (any Error).self) {
      try AuthorPackageOperations.preview(spec, environment: consumer.environment)
    }
    #expect(try consumer.bytes(consumer.store.resolvedURL) == tampered)
  }

  @Test func sameLengthChangesToACachedGitFileRejectTheCapturedBytes() throws {
    let fixture = try UpdateFixture()
    try fixture.install(agents: [.codex])
    let spec = AuthorPackageSpecification(
      package: .init(name: "offline-git", version: "1.0.0"),
      lockedMembers: [.init(kind: .instructions, name: "rules")])
    _ = try AuthorPackageOperations.preview(spec, environment: fixture.environment)
    let ledger = try fixture.store.loadLedger()
    let resource = try #require(
      ledger.resources.values.first {
        $0.kind == .git && $0.path == "instructions/rules.md"
      })
    let source = try #require(ledger.sources[resource.source])
    let identity = try ledger.sourceIdentity(
      resource.source, roots: fixture.store.ledgerRoots(recordedIn: ledger))
    let cached = SourceCache(store: fixture.store)
      .materializedURL(sourceID: identity, revision: source.revision)
      .appendingPathComponent(resource.path)
    let original = try fixture.bytes(cached)
    var tampered = original
    tampered[tampered.startIndex] ^= 1
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cached.path)
    try tampered.write(to: cached)
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.preview(spec, environment: fixture.environment)
    }
    #expect(try fixture.bytes(cached) == tampered)
  }
}
