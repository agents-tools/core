import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@Suite("Author project packaging")
struct AuthorPackageTests {
  private let package = BundlePackage(
    name: "workbench", version: "1.0.0", description: "Author fixture description",
    author: "Fixture Author")

  @Test func freshScaffoldPacksExplicitSourceWithoutInstallationAndRelocates() throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author-one")
    let environment = authorEnvironment(fixture, project: project)
    let scaffold = try AuthorPackageOperations.scaffold(
      package, at: project, environment: environment)
    #expect(scaffold.skills == ["skills/getting-started"])
    #expect(
      try AuthorPackageOperations.scaffold(package, at: project, environment: environment)
        == scaffold)
    let original = try AuthorPackageOperations.preview(environment: environment)
    #expect(original.inspection.components.map(\.name) == ["getting-started"])
    let skill = project.appendingPathComponent(scaffold.skills[0])
    try fixture.write("Do not include\n", to: project.appendingPathComponent(".env"))
    try fixture.write("Draft\n", to: project.appendingPathComponent(".agent/instructions/draft.md"))
    try fixture.write(
      "An invisible\u{200B} character\n", to: skill.appendingPathComponent("notes.txt"))
    let script = skill.appendingPathComponent("scripts/run")
    try fixture.write("#!/bin/sh\nexit 99\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try FileManager.default.createSymbolicLink(
      atPath: skill.appendingPathComponent("notes-link").path, withDestinationPath: "notes.txt")
    try FileManager.default.createDirectory(
      at: skill.appendingPathComponent("empty"), withIntermediateDirectories: false)
    try fixture.write(
      "Reference bytes\n", to: project.appendingPathComponent(".agent/instructions/attachment.txt"))
    try fixture.write(
      "---\ndescription: Fixture rules\n---\n# Rules\n\n[Attachment](attachment.txt)\n",
      to: project.appendingPathComponent(".agent/instructions/rules.md"))
    try fixture.write(
      """
      version: 1
      components:
        - kind: mcpServer
          name: docs
          transport:
            kind: stdio
            executable: never-launch-this-program
            arguments: [serve, --token, fixture-literal, --mode=single]
            environment:
              REGION: {env: REGION}
              TOKEN: {secret: docs-token}
      """,
      to: project.appendingPathComponent(".agent/agents.yaml"))
    let specification = AuthorPackageSpecification(
      package: package, instructions: ["rules"], skills: scaffold.skills, mcpServers: ["docs"])
    try JSONEncoder().encode(specification).write(
      to: project.appendingPathComponent(AuthorPackageOperations.specificationFilename))
    let before = try FileHash.folderHash(fixture.root)
    let captured = try AuthorPackageOperations.preview(environment: environment)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(captured.digest != original.digest)
    #expect(captured.inspection.components.map(\.name) == ["rules", "getting-started", "docs"])
    #expect(
      captured.includedPaths.contains { $0.entry.path == "payload/instructions/attachment.txt" })
    #expect(
      captured.includedPaths.contains {
        $0.entry.path == "payload/skill/scripts/run" && $0.entry.executable
      })
    #expect(
      captured.includedPaths.contains {
        $0.entry.path == "payload/skill/empty" && $0.entry.kind == .directory
      })
    #expect(captured.includedPaths.contains { $0.entry.link == "notes.txt" })
    #expect(
      !captured.includedPaths.contains {
        $0.entry.path.contains("draft.md") || $0.entry.path.contains(".env")
      })
    #expect(
      captured.contentFindings.contains {
        $0.reason == .zeroWidthCharacter && $0.location.path.hasSuffix("notes.txt")
      })
    #expect(captured.warnings.count == 1 && captured.warnings[0].count == 2)
    let wire = String(decoding: captured.archive, as: UTF8.self)
    #expect(
      wire.contains("docs-token") && wire.contains("REGION") && wire.contains("--mode=single"))
    #expect(!wire.contains("fixture-literal") && !wire.contains(project.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: project.appendingPathComponent(".agent/agents.resolved").path))
    let relocated = fixture.root.appendingPathComponent("author-two")
    try FileManager.default.moveItem(at: project, to: relocated)
    let restored = try AuthorPackageOperations.rebuild(
      expectedDigest: captured.digest, environment: authorEnvironment(fixture, project: relocated))
    #expect(restored.archive == captured.archive)
  }

  @Test func capturedAndExplicitlyReadArchivesPublishIdenticalBytesAfterDrift() throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author")
    let environment = authorEnvironment(fixture, project: project)
    try AuthorPackageOperations.scaffold(package, at: project, environment: environment)
    let capture = try AuthorPackageOperations.preview(environment: environment)
    let file = fixture.root.appendingPathComponent("reviewed.bundle")
    try AuthorPackageOperations.write(capture, to: file, environment: environment)
    try AuthorPackageOperations.write(capture, to: file, environment: environment)
    #expect(try fixture.bytes(file) == capture.archive)
    let explicit = try AuthorPackageOperations.readArchive(
      at: file, expectedDigest: capture.digest, environment: environment)
    try fixture.write("not an archive", to: file)
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.write(capture, to: file, environment: environment)
    }
    #expect(try fixture.bytes(file) == Data("not an archive".utf8))
    let changed = project.appendingPathComponent("skills/getting-started/added.txt")
    try fixture.write("not reviewed", to: changed)
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.rebuild(expectedDigest: capture.digest, environment: environment)
    }
    let rebuilt = try AuthorPackageOperations.preview(environment: environment)
    #expect(rebuilt.digest != capture.digest)
    let catalog = fixture.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let release = try AuthorPackageOperations.publish(
      explicit, to: catalog, environment: environment)
    #expect(release.archiveDigest == capture.digest)
    #expect(release.summary == package.description)
    #expect(
      try AuthorPackageOperations.publish(capture, to: catalog, environment: environment) == release
    )
    #expect(throws: MarketplaceError.self) {
      try AuthorPackageOperations.publish(rebuilt, to: catalog, environment: environment)
    }
    let verified = try MarketplaceOperations.acquire(release, environment: environment)
    #expect(verified.archive == capture.archive)
    #expect(try verified.inspectBundle().components.map(\.name) == ["getting-started"])
  }

  @Test func credentialNamesAndEscapingReferencesFailWithoutChangingProject() throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author")
    let environment = authorEnvironment(fixture, project: project)
    let scaffold = try AuthorPackageOperations.scaffold(
      package, at: project, environment: environment)
    let skill = project.appendingPathComponent(scaffold.skills[0])
    for name in [".env.template", "identity.PEM", "id_ed25519"] {
      let file = skill.appendingPathComponent(name)
      try fixture.write("fixture only", to: file)
      let before = try FileHash.folderHash(project)
      do {
        _ = try AuthorPackageOperations.preview(environment: environment)
        Issue.record("Expected credential filename refusal")
      } catch let error as CoreError {
        #expect(
          error.description.contains("credential file refused") && error.description.contains(name))
      }
      #expect(try FileHash.folderHash(project) == before)
      try FileManager.default.removeItem(at: file)
    }
    let link = skill.appendingPathComponent("outside")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "../../../source")
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.preview(environment: environment)
    }
    try FileManager.default.removeItem(at: link)
    try fixture.write(
      "---\ndescription: Fixture rules\n---\n# Rules\n\n[Escapes](../../.env)\n",
      to: project.appendingPathComponent(".agent/instructions/rules.md"))
    #expect(throws: CoreError.self) {
      try AuthorPackageOperations.preview(
        .init(package: package, instructions: ["rules"]), environment: environment)
    }
  }

  @Test func changedOrganizationPolicyBlocksEveryOutputBeforeStaging() throws {
    let fixture = try UpdateFixture()
    let policy = fixture.root.appendingPathComponent("org.yaml")
    var environment = fixture.environment
    environment.userOrganizationPolicy = .init(.local(policy))
    try fixture.write("enforcement: warn\ndependencies: {deny: ['_local/workbench']}", to: policy)
    let project = fixture.root.appendingPathComponent("author")
    try AuthorPackageOperations.scaffold(package, at: project, environment: environment)
    environment.projectDirectory = project
    let capture = try AuthorPackageOperations.preview(environment: environment)
    #expect(capture.policyFindings.contains { $0.rule == "package-deny" && $0.outcome == .warn })
    let native = try NativePluginOperations.preview(capture, for: .codex, environment: environment)
    let catalog = fixture.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    try fixture.write("enforcement: block\ndependencies: {deny: ['_local/workbench']}", to: policy)
    let before = try FileHash.folderHash(fixture.root)
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.preview(environment: environment)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.scaffold(
        package, at: fixture.root.appendingPathComponent("denied"), environment: environment)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.write(
        capture, to: fixture.root.appendingPathComponent("denied.bundle"), environment: environment)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try AuthorPackageOperations.publish(capture, to: catalog, environment: environment)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try MarketplaceOperations.publishBundle(
        capture.archive, to: catalog, environment: environment)
    }
    #expect(throws: OrganizationPolicyFailure.self) {
      try NativePluginOperations.write(
        native, to: fixture.root.appendingPathComponent("denied-plugin"), environment: environment)
    }
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func sourcePolicyAlsoAppliesToAnAlreadyCapturedArtifact() throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author")
    let environment = authorEnvironment(fixture, project: project)
    try AuthorPackageOperations.scaffold(package, at: project, environment: environment)
    let capture = try AuthorPackageOperations.preview(environment: environment)
    try fixture.write(
      "version: 1\ndeny: [local]\n",
      to: SourcePolicyOperations.policyURL(scope: .project, environment: environment))
    let destination = fixture.root.appendingPathComponent("denied.bundle")
    #expect(throws: SourcePolicyFailure.self) {
      try AuthorPackageOperations.preview(environment: environment)
    }
    #expect(throws: SourcePolicyFailure.self) {
      try AuthorPackageOperations.write(capture, to: destination, environment: environment)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test(arguments: [InstallScope.user, .project])
  func bothDirectoryPublishersReadTheCurrentDestinationPolicy(_ authority: InstallScope) throws {
    let fixture = try UpdateFixture()
    let project = fixture.root.appendingPathComponent("author")
    let environment = authorEnvironment(fixture, project: project)
    try AuthorPackageOperations.scaffold(package, at: project, environment: environment)
    let artifact = try AuthorPackageOperations.preview(environment: environment)
    let catalog = fixture.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let origin = try #require(SourceOrigin.local(at: catalog).identity)
    let policy = SourcePolicyOperations.policyURL(scope: authority, environment: environment)
    try fixture.write("version: 1\ndeny: [{local: '\(origin)'}]\n", to: policy)
    func refusesCatalog(_ publish: () throws -> MarketplaceRelease) throws {
      do {
        _ = try publish()
        Issue.record("A revoked catalog received a release")
      } catch let error as SourcePolicyFailure {
        #expect(error.violations.map(\.origin) == [.local(at: catalog)])
        #expect(error.violations.map(\.scope.rawValue) == [authority.rawValue])
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: catalog.path).isEmpty)
    }
    try refusesCatalog {
      try MarketplaceOperations.publishBundle(
        artifact.archive, to: catalog, environment: environment)
    }
    try refusesCatalog {
      try AuthorPackageOperations.publish(artifact, to: catalog, environment: environment)
    }
    try refusesCatalog {
      try MarketplaceOperations.publish(artifact.archive, to: catalog, environment: environment) {
        _ in
        try MarketplaceCoordinate(package: package.name, version: package.version)
      }
    }
    if authority == .project {
      let userRelease = try MarketplaceOperations.publishBundle(
        artifact.archive, to: catalog, scope: .user, environment: environment)
      #expect(userRelease.archiveDigest == artifact.digest)
    }
  }

  @Test(arguments: [true, false])
  func literalMCPBindingRequiresSymbolicReplacementInBothExportPaths(_ stdio: Bool) throws {
    let fixture = try UpdateFixture()
    let name = "literal-fixture"
    let value = "synthetic-private-value"
    let transport =
      stdio
      ? "kind: stdio, executable: never-launch, environment: {FIXTURE_VALUE: '\(value)'}"
      : "kind: streamableHTTP, url: 'https://fixture.invalid/mcp', headers: {Authorization: '\(value)'}"
    try fixture.write(
      """
      version: 1
      components:
        - kind: mcpServer
          name: \(name)
          agents: [codex]
          transport: {\(transport)}
      """, to: fixture.store.declarationURL)
    func refusesLiteral(_ share: () throws -> Void) throws {
      do {
        try share()
        Issue.record("An unattested literal was accepted")
      } catch let error as CoreError {
        #expect(error.description.contains("environment or secret reference"))
        #expect(error.description.contains(stdio ? "FIXTURE_VALUE" : "Authorization"))
        #expect(!error.description.contains(value))
      }
    }
    try refusesLiteral {
      _ = try AuthorPackageOperations.preview(
        .init(package: package, mcpServers: [name]), environment: fixture.environment)
    }
    _ = try fixture.apply()
    let scope = try UpdateOperations.inspect(environment: fixture.environment)
    let previous = try fixture.snapshot()
    try refusesLiteral {
      _ = try BundleOperations.export(
        package, selections: scope.components.map(\.selection), scope: .project,
        environment: fixture.environment)
    }
    try refusesLiteral {
      _ = try AuthorPackageOperations.preview(
        .init(package: package, lockedMembers: [.init(kind: .mcpServer, name: name)]),
        environment: fixture.environment)
    }
    #expect(try fixture.snapshot() == previous)
  }

  @Test(arguments: [false, true])
  func codexBearerVariableSurvivesPackageInstallation(authored: Bool) throws {
    let publisher = try UpdateFixture()
    try publisher.write(
      """
      version: 1
      components:
        - kind: mcpServer
          name: team-service
          agents: [codex]
          transport: {kind: streamableHTTP, url: 'https://fixture.invalid/mcp'}
          native: {codex: {bearer_token_env_var: TEAM_SERVICE_TOKEN}}
      """, to: publisher.store.declarationURL)
    var environment = publisher.environment
    environment.environment["TEAM_SERVICE_TOKEN"] = "synthetic-value-never-exported"
    let archive: Data
    if authored {
      archive = try AuthorPackageOperations.preview(
        .init(package: package, mcpServers: ["team-service"]), environment: environment
      ).archive
    } else {
      _ = try publisher.apply()
      let scope = try UpdateOperations.inspect(environment: environment)
      archive = try BundleOperations.export(
        package, selections: scope.components.map(\.selection), scope: .project,
        environment: environment)
    }
    #expect(!String(decoding: archive, as: UTF8.self).contains("synthetic-value-never-exported"))
    let bundle = try BundleOperations.inspect(archive)
    let server = try #require(bundle.components.first)
    let recipient = try UpdateFixture()
    let preview = try BundleOperations.previewImport(
      bundle, selections: [.init(componentID: server.id, targets: [.codex])], scope: .project,
      environment: recipient.environment)
    _ = try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    let config = try String(
      contentsOf: recipient.environment.projectDirectory.appendingPathComponent(
        ".codex/config.toml"),
      encoding: .utf8)
    #expect(config.contains("bearer_token_env_var") && config.contains("TEAM_SERVICE_TOKEN"))
  }

  @Test func outputRaceIsNoReplace() async throws {
    let fixture = try UpdateFixture()
    let environment = fixture.environment
    let author = fixture.root.appendingPathComponent("author")
    try AuthorPackageOperations.scaffold(package, at: author, environment: environment)
    let authored = authorEnvironment(fixture, project: author)
    let first = try AuthorPackageOperations.preview(environment: authored)
    try fixture.write(
      "Second generation\n", to: author.appendingPathComponent("skills/getting-started/new.txt"))
    let second = try AuthorPackageOperations.preview(environment: authored)
    let destination = fixture.root.appendingPathComponent("raced.bundle")
    let winners = await withTaskGroup(of: Bool.self) { group in
      for candidate in [first, second] {
        group.addTask {
          do {
            try AuthorPackageOperations.write(candidate, to: destination, environment: authored)
            return true
          } catch { return false }
        }
      }
      return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    #expect(winners == 1)
    #expect([first.archive, second.archive].contains(try fixture.bytes(destination)))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy {
        !$0.hasPrefix(".stage-")
      })
  }

  private func authorEnvironment(_ fixture: UpdateFixture, project: URL) -> RuntimeEnvironment {
    RuntimeEnvironment(
      projectDirectory: project, homeDirectory: fixture.environment.homeDirectory, environment: [:])
  }
}
