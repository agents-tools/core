import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

struct SourcePolicyTests {
  @Test(arguments: [InstallScope.project, .user])
  func editorCreatesPolicyAndPreservesConcurrentEdits(_ scope: InstallScope) throws {
    let fixture = try UpdateFixture()
    let first = try SourcePolicyEditor(scope: scope, environment: fixture.environment)
    let stale = try SourcePolicyEditor(scope: scope, environment: fixture.environment)
    #expect(first.original == nil)
    #expect(throws: ManifestFailure.self) { try first.save(Data("allow: true".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: first.url.path))
    let rules = Data("version: 1\nallow: [local]\n".utf8)
    try first.save(rules)
    #expect(throws: CoreError.self) { try stale.save(Data("version: 1\n".utf8)) }
    var managed = fixture.environment
    managed.organizationSourcePolicyURL = first.url
    let editor = try SourcePolicyEditor(scope: scope, environment: managed)
    #expect(throws: CoreError.self) { try editor.save(Data("version: 1\n".utf8)) }
    #expect(try Data(contentsOf: first.url) == rules)
  }

  @Test func policyDocumentsRoundTripCanonicalOriginsAndReportLocations() throws {
    let identity = DocumentIdentity("synthetic-source-policy.yaml")
    let document = Data(
      """
      version: 1
      allow:
        - git: ssh://git@CODE.EXAMPLE:22/Team/Repository.git/
        - git: ssh://git@code.example:443/Team/another.git.git
        - git: http://code.example:80/Team/legacy.git
        - http: https://INDEX.EXAMPLE:443/some/path
        - local
        - inline
      deny: [missing]
      """.utf8)
    let rules = try SourcePolicyDocument.parse(document, identity: identity)
    let encoded = try SourcePolicyDocument.bytes(for: rules)
    #expect(try SourcePolicyDocument.parse(encoded, identity: identity) == rules)
    #expect(rules.allow?[0] == (try SourceOrigin.git("https://code.example/Team/Repository")))
    #expect(rules.allow?[0] == (try SourceOrigin.git("git@code.example:Team/Repository.git")))
    #expect(rules.allow?[0] == (try SourceOrigin.git("git@code.example:/Team/Repository.git")))
    #expect(rules.allow?[0] != (try SourceOrigin.git("https://code.example/Team/repository")))
    #expect(rules.allow?[0] != (try SourceOrigin.git("http://code.example/Team/Repository")))
    #expect(rules.allow?[3] == (try SourceOrigin.http("https://index.example/?query=redacted")))
    #expect(rules.allow?[3] != (try SourceOrigin.http("http://index.example")))
    #expect(
      try SourceOrigin.git("ssh://git@GitHub.COM./Team/Repository.git")
        == SourceOrigin.git("https://github.com/team/repository"))
    #expect(
      try SourceOrigin.http("http://127.1:8080") == SourceOrigin.http("http://127.0.0.1:8080"))
    #expect(
      try SourceOrigin.http("https://[0:0:0:0:0:0:0:1]") == SourceOrigin.http("https://[::1]"))
    #expect(throws: CoreError.self) {
      try SourceOrigin.git("https://code.example/Team%2fRepository")
    }
    #expect(throws: CoreError.self) {
      try SourceOrigin.git("file:///Team/Repository")
    }
    let invalid = Data("version: 1\nallow: true\n".utf8)
    do {
      _ = try SourcePolicyDocument.parse(invalid, identity: identity)
      Issue.record("Malformed policy was admitted")
    } catch let failure as ManifestFailure {
      let diagnostic = try #require(failure.diagnostics.first)
      #expect(diagnostic.code == "source-policy.field")
      #expect(diagnostic.span.document == identity)
      #expect(diagnostic.span.line == 2)
    }
    #expect(throws: ManifestFailure.self) {
      try SourcePolicyDocument.parse(
        Data("version: 1\ndeny: []\ndeny: []\n".utf8), identity: identity)
    }
  }

  @Test func layersIntersectAndMissingLocalAndInlineAreDistinct() throws {
    let f = try UpdateFixture()
    let user = SourcePolicyOperations.policyURL(scope: .user, environment: f.environment)
    let project = SourcePolicyOperations.policyURL(scope: .project, environment: f.environment)
    let organization = f.root.appendingPathComponent("shared-policy.yaml")
    let unconfigured = try SourcePolicyOperations.inspect(environment: f.environment)
    #expect(!unconfigured.effective.isConfigured)
    #expect(unconfigured.effective.violations(for: .missing).isEmpty)
    let sourceSettings = SourceAccessSettingsEditor.settingsURL(environment: f.environment)
    #expect(Set(unconfigured.readDependencies.map(\.url)) == Set([user, project, sourceSettings]))
    try f.write("version: 1\nallow: [inline, local]\n", to: user)
    try f.write("version: 1\nallow: [inline, missing]\n", to: project)
    try f.write("version: 1\nallow: [inline]\ndeny: [inline]\n", to: organization)
    var environment = f.environment
    environment.organizationSourcePolicyURL = organization
    let effective = try SourcePolicyOperations.inspect(environment: environment).effective
    #expect(effective.layers.map(\.scope) == [.user, .project, .organization])
    #expect(effective.violations(for: .inline).map(\.reason) == [.denied])
    #expect(
      effective.violations(for: .local(at: f.repo)).map(\.scope) == [.project, .organization])
    #expect(effective.violations(for: .missing).map(\.reason) == [.missingOrigin, .missingOrigin])
    let userOnly = try SourcePolicyOperations.inspect(scope: .user, environment: f.environment)
    #expect(userOnly.effective.violations(for: .local(at: f.repo)).isEmpty)
    environment.organizationSourcePolicyURL = f.root.appendingPathComponent("missing-policy.yaml")
    #expect(throws: CoreError.self) { try SourcePolicyOperations.inspect(environment: environment) }
  }

  @Test func directSourceDenialPrecedesAcquisitionAndInstallation() throws {
    let f = try UpdateFixture()
    let user = SourcePolicyOperations.policyURL(scope: .user, environment: f.environment)
    let project = SourcePolicyOperations.policyURL(scope: .project, environment: f.environment)
    try f.write("version: 1\ndeny: [{git: code.invalid/Team/repository}]\n", to: user)
    try f.write("version: 1\nallow: [{git: code.invalid/Team/repository}]\n", to: project)
    let source = SourceDeclaration(
      kind: .git, location: "ssh://git@CODE.invalid/Team/repository.git")
    let declaration = Declaration(
      sources: ["demo": source], skills: ["demo": .init(select: .names(["item"]))])
    let operation = UpdateRequest(operation: .declaration(declaration))
    let before = try f.snapshot()
    do {
      _ = try UpdateOperations.preview(operation, environment: f.environment)
      Issue.record("Disallowed repository was selected")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.scope) == [.user])
      #expect(failure.violations.map(\.reason) == [.denied])
    }
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.inspectSource(alias: "demo", source: source, environment: f.environment)
    }
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.withPreparedUpdate(operation, environment: f.environment) {
        try $0.apply()
      }
    }
    #expect(try f.snapshot() == before)
    #expect(!FileManager.default.fileExists(atPath: f.store.cacheDirectory.path))
  }

  @Test func inlineDeclarationCanInstallWithoutGrantingLocalSourceAccess() throws {
    let f = try UpdateFixture()
    try f.write(
      """
      version: 1
      components:
        - kind: command
          name: policy-inline
          description: Synthetic command
          prompt: Review the sample.
          agents: [claude-code]
      """, to: f.store.declarationURL)
    let project = SourcePolicyOperations.policyURL(scope: .project, environment: f.environment)
    try f.write("version: 1\nallow: [inline]\n", to: project)
    _ = try f.apply()
    #expect(try SourcePolicyOperations.audit(environment: f.environment).violations.isEmpty)
    try f.write("version: 1\nallow: [local]\n", to: project)
    let audit = try SourcePolicyOperations.audit(environment: f.environment)
    #expect(audit.violations.map(\.origin) == [.inline])
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.restore(environment: f.environment)
    }
  }

  @Test func indirectLocalSourceIsCheckedDuringLookupAndLockedRestore() throws {
    let f = try UpdateFixture()
    let producer = f.root.appendingPathComponent("producer")
    try f.write(
      """
      version: 1
      sources: {downstream: {path: '\(f.repo.path)'}}
      exports: [shared]
      groups:
        shared:
          components:
            - kind: skills
              source: downstream
              select: [demo]
              agents: [codex]
              mode: copy
      """, to: producer.appendingPathComponent(".agent/agents.yaml"))
    try f.write(
      """
      version: 1
      sources: {producer: {path: './producer'}}
      uses: [{source: producer, group: shared}]
      """, to: f.store.declarationURL)
    let project = SourcePolicyOperations.policyURL(scope: .project, environment: f.environment)
    let policy = "version: 1\nallow: [{local: '\(producer.path)'}, {local: '\(f.repo.path)'}]\n"
    // Policy paths name physical roots. The fixture may live under macOS's /var alias.
    let allowed = policy.replacingOccurrences(
      of: f.root.path, with: f.root.resolvingSymlinksInPath().path)
    try f.write(allowed, to: project)
    #expect(try f.preview().hasChanges)
    _ = try f.apply()
    #expect(FileManager.default.fileExists(atPath: f.target().path))
    let permitted = try SourcePolicyOperations.audit(environment: f.environment)
    #expect(permitted.hasLock)
    #expect(permitted.violations.isEmpty)
    try FileManager.default.removeItem(at: f.target())
    let denied = allowed + "deny: [{local: '\(f.repo.resolvingSymlinksInPath().path)'}]\n"
    try f.write(denied, to: project)
    let before = try FileHash.folderHash(f.root)
    let audit = try SourcePolicyOperations.audit(environment: f.environment)
    #expect(audit.hasLock)
    #expect(audit.violations.map(\.origin) == [.local(at: f.repo)])
    #expect(!((try JSONEncoder().encode(audit)).isEmpty))
    #expect(throws: SourcePolicyFailure.self) { try f.preview() }
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.restore(environment: f.environment)
    }
    #expect(try FileHash.folderHash(f.root) == before)
    try f.write(allowed, to: project)
    _ = try UpdateOperations.restore(environment: f.environment)
    #expect(FileManager.default.fileExists(atPath: f.target().path))
  }

  @Test(arguments: [false, true], [InstallScope.user, .project])
  func portableResourceWithoutOriginalCoordinatesRequiresMissingOriginOptIn(
    authored: Bool, policyScope: InstallScope
  ) throws {
    let publisher = try UpdateFixture()
    let executable = publisher.repo.appendingPathComponent("server")
    try publisher.write("#!/bin/sh\nexit 1\n", to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try publisher.commit()
    let declaration = Declaration(
      sources: ["program": .init(kind: .local, location: publisher.repo.path)],
      components: [
        .mcpServer(
          name: "resource-server",
          transport: .stdio(.init(executable: "./server", executableSource: "program")),
          agents: [.codex],
        )
      ])
    _ = try UpdateOperations.withPreparedUpdate(
      UpdateRequest(operation: .declaration(declaration)), environment: publisher.environment
    ) { try $0.apply() }
    let published = try UpdateOperations.inspect(environment: publisher.environment)
    let package = BundlePackage(name: "resource-server", version: "1.0.0")
    let bundle: BundleInspection
    if authored {
      let capture = try AuthorPackageOperations.preview(
        .init(package: package, lockedMembers: [.init(kind: .mcpServer, name: "resource-server")]),
        environment: publisher.environment)
      bundle = capture.inspection
    } else {
      bundle = try BundleOperations.inspect(
        BundleOperations.export(
          package, selections: published.components.map(\.selection), scope: .project,
          environment: publisher.environment))
    }
    let server = try #require(bundle.components.first)
    let resourceRevision = try publisher.git(["rev-parse", "HEAD"])
    #expect(
      server.sources.contains { $0.revision == resourceRevision && $0.policyOrigin == .missing })
    #expect(server.entries.contains { $0.path.hasSuffix("/server") && $0.executable })
    try FileManager.default.removeItem(at: publisher.repo)

    let consumer = try UpdateFixture()
    let selected = [BundleImportSelection(componentID: server.id, targets: [.codex])]
    let policy = SourcePolicyOperations.policyURL(
      scope: policyScope, environment: consumer.environment)
    try consumer.write("version: 1\nallow: [local, inline]\n", to: policy)
    let untouched = try FileHash.folderHash(consumer.root)
    do {
      _ = try BundleOperations.previewImport(
        bundle, selections: selected, scope: .project, environment: consumer.environment)
      Issue.record("The original resource origin could not be established")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.reason) == [.missingOrigin])
      #expect(failure.violations.map(\.origin) == [.missing])
    }
    #expect(try FileHash.folderHash(consumer.root) == untouched)
    try consumer.write("version: 1\nallow: [missing, inline]\n", to: policy)
    let preview = try BundleOperations.previewImport(
      bundle, selections: selected, scope: .project, environment: consumer.environment)
    _ = try BundleOperations.withPreparedImport(preview) { try $0.apply() }
    #expect(try SourcePolicyOperations.audit(environment: consumer.environment).violations.isEmpty)
    try consumer.write("version: 1\nallow: [local, inline]\n", to: policy)
    let installed = try FileHash.folderHash(consumer.root)
    #expect(
      try SourcePolicyOperations.audit(environment: consumer.environment).violations.map(\.origin)
        == [.missing])
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.restore(environment: consumer.environment)
    }
    #expect(try FileHash.folderHash(consumer.root) == installed)
  }

  @Test(arguments: [false, true])
  func policyGenerationIsBoundToDisplayedAndPreparedUpdates(_ policyInitiallyExists: Bool) throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.codex])
    let user = SourcePolicyOperations.policyURL(scope: .user, environment: f.environment)
    if policyInitiallyExists { try f.write("version: 1\nallow: [local]\n", to: user) }
    let before = try f.snapshot()
    let report = try f.preview()
    #expect(report.readLocations.contains(user))
    try f.write("version: 1\nallow: [local, inline]\n", to: user)
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(environment: f.environment) {
        try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
      }
    }
    #expect(try f.snapshot() == before)
    if !policyInitiallyExists { try FileManager.default.removeItem(at: user) }
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(environment: f.environment) { prepared in
        try f.write("version: 1\nallow: []\n", to: user)
        _ = try prepared.apply()
      }
    }
    #expect(try f.snapshot() == before)
    #expect(!FileManager.default.fileExists(atPath: f.store.cacheDirectory.path))
  }
}
