import AgentsCore
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import Testing

@Suite("Versioned team marketplace")
struct MarketplaceTests {
  @Test func publishesIdempotentlyAndVerifiesSelectedBytes() throws {
    let fixture = try MarketplaceFixture()
    let first = try fixture.publish(version: "1.0.0", content: "alpha")
    #expect(first == (try fixture.publish(version: "1.0.0", content: "alpha")))
    #expect(throws: MarketplaceError.publicationConflict("team-kit@1.0.0")) {
      try fixture.publish(version: "1.0.0", content: "other")
    }
    let abandoned = fixture.catalog.appendingPathComponent("releases/team-kit/.stage-interrupted")
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
    try Data("partial".utf8).write(to: abandoned.appendingPathComponent("package.bundle"))
    let catalog = try fixture.browse()
    #expect(catalog.search("TEAM GUIDE").map(\.coordinate) == [first.coordinate])
    #expect(catalog.search("absent").isEmpty)
    let selected = try catalog.select(package: "team-kit", version: "1.0.0")
    let acquired = try fixture.acquire(selected)
    #expect(try fixture.decode(acquired.archive).content == "alpha")

    let archive = fixture.catalog.appendingPathComponent(first.coordinate.releasePath)
      .appendingPathComponent("package.bundle")
    var tampered = acquired.archive
    tampered[tampered.startIndex] ^= 1
    try tampered.write(to: archive)
    #expect(throws: MarketplaceError.integrityMismatch("team-kit@1.0.0")) {
      try fixture.acquire(selected)
    }
    #expect(throws: MarketplaceError.integrityMismatch("team-kit@1.0.0")) {
      try fixture.publish(version: "1.0.0", content: "alpha")
    }
  }

  @Test func publishedCatalogKeepsEachConcurrentReleaseComplete() async throws {
    let fixture = try MarketplaceFixture()
    let directory = fixture.catalog
    let environment = fixture.environment
    let first = MarketplaceFixture.Archive(package: "team-kit", version: "1.0.0", content: "one")
    let conflicting = MarketplaceFixture.Archive(
      package: "team-kit", version: "1.0.0", content: "three")
    let second = MarketplaceFixture.Archive(package: "team-kit", version: "2.0.0", content: "two")

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for archive in [first, conflicting, second] {
        group.addTask {
          do {
            try MarketplaceFixture.publish(archive, to: directory, environment: environment)
            return true
          } catch MarketplaceError.publicationConflict {
            return false
          } catch {
            Issue.record(error)
            return false
          }
        }
      }
      var outcomes: [Bool] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }

    #expect(outcomes.filter { $0 }.count == 2)
    let catalog = try fixture.browse()
    #expect(catalog.releases.map(\.coordinate.version) == ["2.0.0", "1.0.0"])
    for release in catalog.releases {
      let archive = try fixture.decode(fixture.acquire(release).archive)
      #expect(archive.version == release.coordinate.version)
      let names = try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent(release.coordinate.releasePath)
          .deletingLastPathComponent().path)
      #expect(names.allSatisfy { !$0.hasPrefix(".stage-") })
    }
  }

  @Test func distinctProjectsAdvanceIndependentlyAndRestoreWithoutProducer() throws {
    let fixture = try MarketplaceFixture()
    let one = try fixture.project("one")
    let two = try fixture.project("two")
    let initial = try fixture.publish(version: "1.0.0", content: "first version")
    let v1 = try fixture.acquire(fixture.browse().select(package: initial.coordinate.package))
    try fixture.install(v1, in: one)
    try fixture.install(v1, in: two)
    #expect(try one.skillText().contains("first version"))
    #expect(try two.skillText().contains("first version"))
    #expect(try one.executable())
    #expect(try two.executable())
    let pin = try #require(try MarketplaceOperations.installed(environment: two.environment).first)
    #expect(pin.archiveDigest == v1.release.archiveDigest)
    #expect(pin.dependency.catalog.location == "../catalog")
    #expect(pin.dependency.coordinate.version == "1.0.0")
    #expect(pin.componentRecords.count == 1)

    try fixture.publish(version: "1.2.0", content: "second version")
    let available = try fixture.browse().updates(for: pin)
    #expect(available.map(\.coordinate.version) == ["1.2.0"])
    let v2 = try fixture.acquire(try #require(available.first))
    let request = try fixture.importRequest(v2, in: one)
    let preview = try UpdateOperations.preview(request, environment: one.environment)
    #expect(preview.hasChanges)
    let packageChange = try #require(preview.marketplaceChanges?.first)
    #expect(packageChange.before?.dependency.coordinate.version == "1.0.0")
    #expect(packageChange.after?.dependency.coordinate.version == "1.2.0")
    #expect(packageChange.after?.archiveDigest == v2.release.archiveDigest)
    #expect(try one.skillText().contains("first version"))
    _ = try UpdateOperations.withPreparedUpdate(request, environment: one.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    #expect(try one.skillText().contains("second version"))
    #expect(try two.skillText().contains("first version"))
    #expect(try MarketplaceOperations.installed(environment: two.environment) == [pin])
    let inspection = try UpdateOperations.inspect(environment: two.environment)
    #expect(inspection.marketplacePackages == [pin])
    let inventory = String(decoding: try inspection.cycloneDXInventory(), as: UTF8.self)
    #expect(inventory.contains(pin.archiveDigest))
    #expect(inventory.contains("agents:marketplace-origin"))
    let spdx = try #require(
      try JSONSerialization.jsonObject(with: inspection.inventory(format: .spdx))
        as? [String: Any])
    let packages = try #require(spdx["packages"] as? [[String: Any]])
    let release = try #require(packages.first { $0["checksums"] != nil })
    let ownedItem = try #require(
      packages.first {
        ($0["sourceInfo"] as? String)?.contains("agents:kind skills") == true
      })
    let relationships = try #require(spdx["relationships"] as? [[String: String]])
    #expect(release["versionInfo"] as? String == "1.0.0")
    #expect(
      relationships.contains {
        $0["relationshipType"] == "CONTAINS"
          && $0["spdxElementId"] == release["SPDXID"] as? String
          && $0["relatedSpdxElement"] == ownedItem["SPDXID"] as? String
      })

    let cold = try fixture.project("cold")
    try cold.copyState(from: two)
    let committed = try Data(contentsOf: cold.store.resolvedURL)
    try FileManager.default.removeItem(at: fixture.catalog)
    try FileManager.default.removeItem(at: two.environment.projectDirectory)
    _ = try UpdateOperations.restore(environment: cold.environment)
    #expect(try cold.skillText().contains("first version"))
    #expect(try cold.executable())
    #expect(try MarketplaceOperations.installed(environment: cold.environment) == [pin])
    #expect(try Data(contentsOf: cold.store.resolvedURL) == committed)

    let removal = MarketplaceOperations.removalRequest(for: "starter")
    let removalPreview = try UpdateOperations.preview(removal, environment: one.environment)
    _ = try UpdateOperations.withPreparedUpdate(removal, environment: one.environment) {
      try $0.apply(ifUnchangedFrom: removalPreview.displayedFingerprint)
    }
    #expect(!FileManager.default.fileExists(atPath: one.skillDirectory.path))
    #expect(try MarketplaceOperations.installed(environment: one.environment).isEmpty)
    #expect(try cold.skillText().contains("first version"))
  }

  @Test func restoreRejectsMissingPinAndDivergentManifestBeforeDeploying() throws {
    let fixture = try MarketplaceFixture()
    let project = try fixture.project("first")
    try fixture.publish(version: "1.0.0", content: "sealed")
    let selected = try fixture.browse().select(package: "team-kit")
    try fixture.install(fixture.acquire(selected), in: project)

    let cold = try fixture.project("cold")
    try cold.copyState(from: project)
    let declaration = try Data(contentsOf: cold.store.declarationURL)
    let lock = try Data(contentsOf: cold.store.resolvedURL)
    try Data("{broken".utf8).write(to: cold.store.declarationURL)
    #expect(throws: (any Error).self) {
      try SkillOperations.installResolvedReport(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.skillDirectory.path))
    #expect(try Data(contentsOf: cold.store.resolvedURL) == lock)
    try declaration.write(to: cold.store.declarationURL)
    try FileManager.default.removeItem(at: cold.store.resolvedURL)
    #expect(throws: MarketplaceError.missingPin("starter")) {
      try UpdateOperations.restore(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.skillDirectory.path))

    try lock.write(to: cold.store.resolvedURL)
    let wrongVersion = String(decoding: declaration, as: UTF8.self)
      .replacingOccurrences(of: "1.0.0", with: "2.0.0")
    try Data(wrongVersion.utf8).write(to: cold.store.declarationURL)
    #expect(throws: MarketplaceError.selectionMismatch("starter")) {
      try UpdateOperations.restore(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.skillDirectory.path))
    let audit = try UpdateOperations.inspect(environment: cold.environment)
    #expect(audit.marketplaceIssue == .selectionMismatch("starter"))
    #expect(throws: MarketplaceError.selectionMismatch("starter")) {
      try audit.cycloneDXInventory()
    }

    try declaration.write(to: cold.store.declarationURL)
    let wrongDigest = String(decoding: lock, as: UTF8.self).replacingOccurrences(
      of: selected.archiveDigest, with: "sha256:" + String(repeating: "a", count: 64))
    try Data(wrongDigest.utf8).write(to: cold.store.resolvedURL)
    #expect(throws: MarketplaceError.contributionMismatch("starter")) {
      try UpdateOperations.restore(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.skillDirectory.path))

    try lock.write(to: cold.store.resolvedURL)
    let wrongSource = String(decoding: declaration, as: UTF8.self)
      .replacingOccurrences(of: ".agent/imported/", with: ".agent/changed/")
    try Data(wrongSource.utf8).write(to: cold.store.declarationURL)
    #expect(throws: MarketplaceError.contributionMismatch("starter")) {
      try UpdateOperations.restore(environment: cold.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: cold.skillDirectory.path))
  }

  @Test func gitCatalogUsesCommittedSnapshotAndPinsEachPackageIndependently() throws {
    let fixture = try MarketplaceFixture()
    let project = try fixture.project("git-consumer")
    try fixture.git(["init", "--initial-branch=main"])
    try fixture.git(["config", "user.name", "Fixture"])
    try fixture.git(["config", "user.email", "fixture@example.invalid"])
    try fixture.git(["config", "gc.auto", "0"])
    try fixture.git(["config", "maintenance.auto", "false"])
    try fixture.publish(version: "1.0.0", content: "first team package")
    let firstCommit = try fixture.commitCatalog()
    let observed = try fixture.browse(kind: .git)
    let first = try observed.select(package: "team-kit")
    #expect(observed.catalogCommit == firstCommit)
    #expect(first.catalogCommit == firstCommit)

    try fixture.publish(package: "extra", version: "2.0.0", content: "second team package")
    #expect(try fixture.browse(kind: .git).releases.count == 1)
    let secondCommit = try fixture.commitCatalog()
    let now = try fixture.browse(kind: .git)
    let second = try now.select(package: "extra")
    #expect(now.catalogCommit == secondCommit)
    #expect(first.catalogCommit != second.catalogCommit)
    let a = try fixture.acquire(first)
    let b = try fixture.acquire(second)
    try fixture.install(a, in: project)
    try fixture.install(b, as: "extra", in: project)
    let pins = try MarketplaceOperations.installed(environment: project.environment)
    #expect(pins.map(\.catalogCommit) == [firstCommit, secondCommit])
    let reacquired = try MarketplaceOperations.acquire(
      try #require(pins.first), environment: project.environment)
    #expect(reacquired.release.catalogCommit == firstCommit)
    #expect(reacquired.archive == a.archive)
    #expect(try project.skillText().contains("first team package"))
    #expect(try project.skillText(for: "extra").contains("second team package"))

    let rebound = try fixture.browse()
    #expect(throws: MarketplaceError.originConflict("starter")) {
      try rebound.updates(for: try #require(pins.first))
    }
    let reboundPackage = try fixture.acquire(rebound.select(package: "team-kit"))
    let reboundRequest = try fixture.importRequest(reboundPackage, in: project)
    #expect(throws: MarketplaceError.originConflict("starter")) {
      try UpdateOperations.preview(reboundRequest, environment: project.environment)
    }
  }

  @Test func previewFingerprintRejectsAnInterveningPackageUpdate() throws {
    let fixture = try MarketplaceFixture()
    let project = try fixture.project("first")
    for (version, content) in [("1.0.0", "first"), ("2.0.0", "second"), ("3.0.0", "third")] {
      try fixture.publish(version: version, content: content)
    }
    let catalog = try fixture.browse()
    func acquire(_ version: String) throws -> VerifiedMarketplacePackage {
      try fixture.acquire(catalog.select(package: "team-kit", version: version))
    }
    try fixture.install(acquire("1.0.0"), in: project)
    let second = try fixture.importRequest(acquire("2.0.0"), in: project)
    let preview = try UpdateOperations.preview(second, environment: project.environment)
    try fixture.install(acquire("3.0.0"), in: project)
    let refreshed = try fixture.importRequest(acquire("2.0.0"), in: project)
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(refreshed, environment: project.environment) {
        try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
      }
    }
    #expect(try project.skillText().contains("third"))
  }
}

private final class MarketplaceFixture {
  struct Archive: Codable, Sendable {
    let package: String
    let version: String
    let content: String
  }

  struct Project {
    let environment: RuntimeEnvironment
    var store: StateStore { StateStore(scope: .project, environment: environment) }
    var skillDirectory: URL { skillDirectory(for: "team-kit") }

    func skillDirectory(for name: String) -> URL {
      environment.projectDirectory.appendingPathComponent(".agents/skills/" + name)
    }

    func skillText(for name: String = "team-kit") throws -> String {
      try String(
        contentsOf: skillDirectory(for: name).appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    func executable() throws -> Bool {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: skillDirectory.appendingPathComponent("run.sh").path)
      return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o111 != 0
    }

    func copyState(from origin: Project) throws {
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      for (source, destination) in [
        (origin.store.declarationURL, store.declarationURL),
        (origin.store.resolvedURL, store.resolvedURL),
      ] {
        try FileManager.default.copyItem(at: source, to: destination)
      }
    }
  }

  let root: URL
  let catalog: URL
  let environment: RuntimeEnvironment

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "marketplace-tests-" + UUID().uuidString)
    catalog = root.appendingPathComponent("catalog")
    environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("producer"),
      homeDirectory: root.appendingPathComponent("producer-home"), environment: [:])
    do {
      for directory in [catalog, environment.projectDirectory, environment.homeDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }

  func project(_ name: String) throws -> Project {
    let project = root.appendingPathComponent(name)
    let home = root.appendingPathComponent(name + "-home")
    for directory in [project, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return Project(
      environment: RuntimeEnvironment(
        projectDirectory: project, homeDirectory: home, environment: [:]))
  }

  @discardableResult
  func publish(package: String = "team-kit", version: String, content: String) throws
    -> MarketplaceRelease
  {
    try Self.publish(
      Archive(package: package, version: version, content: content),
      to: catalog, environment: environment)
  }

  @discardableResult
  static func publish(
    _ fixture: Archive, to directory: URL, environment: RuntimeEnvironment
  ) throws -> MarketplaceRelease {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try MarketplaceOperations.publish(
      encoder.encode(fixture), to: directory, summary: "Team guide", environment: environment
    ) { bytes in
      let archive = try JSONDecoder().decode(Archive.self, from: bytes)
      return try MarketplaceCoordinate(package: archive.package, version: archive.version)
    }
  }

  func browse(kind: MarketplaceOrigin.Kind = .directory) throws -> MarketplaceCatalog {
    let origin = try MarketplaceOrigin(kind: kind, location: "../catalog")
    return try MarketplaceOperations.browse(
      MarketplaceRegistration(name: "team", origin: origin), environment: environment)
  }

  func acquire(_ release: MarketplaceRelease) throws -> VerifiedMarketplacePackage {
    try MarketplaceOperations.acquire(release, environment: environment)
  }

  func decode(_ data: Data) throws -> Archive { try JSONDecoder().decode(Archive.self, from: data) }

  func install(
    _ package: VerifiedMarketplacePackage, as name: String = "starter", in project: Project
  )
    throws
  {
    let request = try importRequest(package, as: name, in: project)
    let preview = try UpdateOperations.preview(request, environment: project.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: project.environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
  }

  /// Exercises the archive owner's integration contract with an independently written fixture.
  func importRequest(
    _ package: VerifiedMarketplacePackage, as name: String = "starter", in project: Project
  ) throws -> UpdateRequest {
    let archive = try decode(package.archive)
    let coordinate = try MarketplaceCoordinate(package: archive.package, version: archive.version)
    guard coordinate == package.release.coordinate else {
      throw MarketplaceError.integrityMismatch(archive.package)
    }
    let key = String(package.release.archiveDigest.dropFirst("sha256:".count))
    let alias = "fixture-" + key
    let relative = ".agent/imported/" + key
    let producer = project.environment.projectDirectory.appendingPathComponent(relative)
    let skill = producer.appendingPathComponent("skills/" + archive.package)
    let manifest = producer.appendingPathComponent(".agent/agents.yaml")
    for directory in [skill, manifest.deletingLastPathComponent()] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(
      """
      version: 1
      groups:
        release:
          components:
            - kind: skills
              source: "."
              mode: copy
              select: ["\(archive.package)"]
              agents: ["codex"]
      exports: ["release"]
      """.utf8
    ).write(to: manifest)
    try Data(
      """
      ---
      name: \(archive.package)
      description: fixture
      ---

      \(archive.content)
      """.utf8
    ).write(to: skill.appendingPathComponent("SKILL.md"))
    let executable = skill.appendingPathComponent("run.sh")
    try Data("#!/bin/sh\ntrue\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    var declaration = try project.store.loadDeclaration()
    if declaration.sources[alias] == nil {
      declaration.sourceDeclarations.append(
        .init(
          name: alias, source: SourceDeclaration(kind: .local, location: relative)))
      declaration.uses.append(GroupUseDeclaration(name: "release", source: alias))
    }
    let document = try project.store.loadManifest()
    return try package.bindingImport(
      UpdateRequest(
        operation: .declaration(declaration),
        expectedDeclarationDigest: document?.digest ?? "absent"),
      as: name, sourceAliases: [alias])
  }

  @discardableResult
  func git(_ args: [String]) throws -> String {
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", catalog.path, "-c", "commit.gpgsign=false"] + args
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func commitCatalog() throws -> String {
    try git(["add", "."])
    try git(["commit", "-m", "test catalog"])
    return try git(["rev-parse", "HEAD"])
  }
}
