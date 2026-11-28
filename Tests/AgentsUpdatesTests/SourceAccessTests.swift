import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Synchronization
import Testing

@testable import AgentsCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite("Trusted package source access", .serialized)
struct SourceAccessTests {
  @Test func credentialParityAndExportBoundary() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let endpoint = URL(string: "https://enterprise.invalid:8443/api/v3/user")!
    let direct = try SourceAuthority(host: "enterprise.invalid", port: 8443)
    let upstream = try SourceAuthority(host: "other.invalid", port: 8443)
    let mirror = try SourceAuthority(host: "mirror.invalid", port: 9443)
    let selected = Mutex([String]())
    let first = try SourceCredentialBinding(
      route: .direct, authority: direct, path: "/org/first.git", exportable: true,
      validationEndpoint: endpoint
    ) {
      selected.withLock { $0.append("first") }
      return "fixture-first-secret"
    }
    let second = try SourceCredentialBinding(
      route: .direct, authority: direct, path: "/org/second", validationEndpoint: endpoint
    ) {
      selected.withLock { $0.append("second") }
      return "fixture-second-secret"
    }
    let proxied = try SourceCredentialBinding(
      route: .mirror, authority: mirror, path: "/proxy/org/third"
    ) {
      selected.withLock { $0.append("third") }
      return "fixture-mirror-secret"
    }
    var environment = fixture.environment
    environment.sourceAccess = .init(
      providers: [direct: .github, upstream: .github],
      mirrors: [
        try .init(
          source: upstream, base: URL(string: "https://mirror.invalid:9443/proxy")!,
          flavor: .github)
      ],
      credentials: [first, second, proxied])
    let declaration = Declaration(
      sources: ["first": .init(kind: .git, location: "https://enterprise.invalid:8443/org/first")])
    let policy = EffectiveSourcePolicy()
    let firstStatus = try SourceCredentialOperations.inspect(
      source: "first", declaration: declaration, environment: environment, policy: policy)
    #expect(firstStatus.provider == .github)
    #expect(firstStatus.effectiveHost == "enterprise.invalid:8443")
    #expect(firstStatus.availability == .available)
    #expect(
      try SourceCredentialOperations.inspect(host: direct, environment: environment)
        .availability == .unconfigured)
    #expect(selected.withLock { $0 }.isEmpty)

    let requests = Mutex([String]())
    try PackageSourceHTTP.$fixture.withValue(
      .init { request, maximum in
        #expect(request.url == endpoint)
        #expect(maximum == nil)
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        requests.withLock { $0.append(header) }
        return .init(
          status: header == "Bearer fixture-first-secret" ? 200 : 401,
          body: Data("fixture-private-provider-response".utf8))
      },
      operation: {
        let accepted = try SourceCredentialOperations.validate(
          source: "first", declaration: declaration, environment: environment, policy: policy)
        let refused = try SourceCredentialOperations.validate(
          source: "https://enterprise.invalid:8443/org/second@tag:release/v1",
          declaration: declaration, environment: environment, policy: policy)
        let indeterminate = try SourceCredentialOperations.validate(
          source: "https://other.invalid:8443/org/third", declaration: declaration,
          environment: environment, policy: policy)
        #expect(accepted.validation == .accepted)
        #expect(refused.validation == .refused)
        #expect(indeterminate.validation == .indeterminate)
        #expect(indeterminate.transport == .archive)
        #expect(indeterminate.effectiveHost == "mirror.invalid:9443")
        let reportBytes = try JSONEncoder().encode([accepted, refused, indeterminate])
        #expect(!String(decoding: reportBytes, as: UTF8.self).contains("fixture-"))
      })
    #expect(
      requests.withLock { $0 } == ["Bearer fixture-first-secret", "Bearer fixture-second-secret"])
    #expect(selected.withLock { $0 } == ["first", "second"])

    let pipe = Pipe()
    defer {
      pipe.fileHandleForWriting.closeFile()
      pipe.fileHandleForReading.closeFile()
    }
    let file = fixture.root.appendingPathComponent("export-denied")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    defer { handle.closeFile() }
    #expect(throws: SourceAccessError.exportRefused) {
      try SourceCredentialOperations.export(
        source: "first", declaration: declaration, environment: environment, policy: policy,
        to: handle.fileDescriptor)
    }
    #expect(try Data(contentsOf: file).isEmpty)
    #if canImport(Darwin)
      var master: Int32 = -1
      var terminal: Int32 = -1
      try #require(openpty(&master, &terminal, nil, nil, nil) == 0)
      defer {
        close(master)
        close(terminal)
      }
      #expect(throws: SourceAccessError.exportRefused) {
        try SourceCredentialOperations.export(
          source: "first", declaration: declaration, environment: environment, policy: policy,
          to: terminal)
      }
    #endif
    var ambiguous = environment
    ambiguous.sourceAccess = .init(providers: [direct: .github], credentials: [first, first])
    #expect(throws: SourceAccessError.ambiguousCredential) {
      try SourceCredentialOperations.export(
        source: "first", declaration: declaration, environment: ambiguous, policy: policy,
        to: pipe.fileHandleForWriting.fileDescriptor)
    }
    #expect(selected.withLock { $0 } == ["first", "second"])
    try SourceCredentialOperations.export(
      source: "first", declaration: declaration, environment: environment, policy: policy,
      to: pipe.fileHandleForWriting.fileDescriptor)
    pipe.fileHandleForWriting.closeFile()
    let exported = try pipe.fileHandleForReading.readToEnd()
    #expect(exported == Data("fixture-first-secret".utf8))
  }

  @Test func routeMatrixAndPreNetworkAdmission() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let repository = try SourceRepository(fixture.source.location)
    let github = try ArchiveSourceFixture.profile(.github)
    let tag = try VCSArchiveRequest(repository: repository, ref: .tag("release/v1"), mirror: github)
    let branch = try VCSArchiveRequest(
      repository: repository, ref: .branch("release/v1"), mirror: github)
    #expect(
      tag.url.absoluteString
        == "https://mirror.invalid:9443/base/org/repo/archive/refs/tags/release/v1.zip")
    #expect(
      branch.url.absoluteString
        == "https://mirror.invalid:9443/base/org/repo/archive/refs/heads/release/v1.zip")
    let gitlab = try ArchiveSourceFixture.profile(.gitlab, qualified: true)
    let nested = try SourceRepository("https://origin.invalid:8443/group/sub/repo.git")
    let qualified = try VCSArchiveRequest(
      repository: nested, ref: .tag("release/v1"), mirror: gitlab)
    #expect(
      qualified.url.absoluteString
        == "https://mirror.invalid:9443/base/api/v4/projects/group%2Fsub%2Frepo/repository/archive.zip?sha=refs%2Ftags%2Frelease%2Fv1"
    )
    let sha = String(repeating: "a", count: 40)
    let bare = try ArchiveSourceFixture.profile(.gitlab)
    let exact = try VCSArchiveRequest(repository: nested, ref: .commit(sha), mirror: bare)
    #expect(exact.url.absoluteString.hasSuffix("archive.zip?sha=" + sha))
    #expect(throws: SourceAccessError.discoveryUnavailable) {
      _ = try VCSArchiveRequest(repository: nested, ref: .branch("release/v1"), mirror: bare)
    }
    #expect(throws: SourceAccessError.invalidRepository) {
      _ = try VCSArchiveRequest(repository: repository, ref: .tag("../escape"), mirror: github)
    }

    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in
        Issue.record("denied route ran a request")
        throw SourceAccessError.requestFailed
      },
      operation: {
        let store = StateStore(scope: .project, environment: fixture.environment)
        try SourceResolutionSession.withTemporaryRead(store: store) { session in
          #expect(throws: SourceAccessError.discoveryUnavailable) {
            _ = try session.candidates(for: fixture.source, requirements: [.exact("1.2.3")])
          }
          var ambiguous = fixture.source
          ambiguous.requirement = .exact("1.2.3")
          #expect(throws: SourceAccessError.discoveryUnavailable) {
            _ = try SourceCache(store: store).inspectRevision(ambiguous)
          }
          #expect(throws: SourceAccessError.egressDenied) {
            _ = try session.requireSource(
              .init(kind: .wellKnown, location: "https://mirror.invalid:9443/index"))
          }
        }
        var unsupported = fixture.environment
        unsupported.sourceAccess = .init(
          egress: .proxyOnly, mirrors: [try ArchiveSourceFixture.profile(.artifactory)])
        _ = try SourceResolutionSession.withTemporaryRead(
          store: StateStore(scope: .project, environment: unsupported)
        ) { session in
          #expect(throws: SourceAccessError.unsupportedMirror) {
            _ = try session.candidates(
              for: fixture.source, requirements: [fixture.source.requirement])
          }
        }
      })
  }

  @Test func redirectAndDeniedEffectiveOriginDoNotRetry() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let requests = Mutex(0)
    let mirror = try SourceAuthority(host: "mirror.invalid", port: 9443)
    var environment = fixture.environment
    environment.sourceAccess = .init(
      egress: .proxyOnly, mirrors: [try ArchiveSourceFixture.profile(.github)],
      credentials: [
        try .init(route: .mirror, authority: mirror) {
          "fixture-mirror-route-secret"
        }
      ])
    try PackageSourceHTTP.$fixture.withValue(
      .init { request, _ in
        #expect(
          request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-mirror-route-secret"
        )
        requests.withLock { $0 += 1 }
        return .init(status: 302, body: Data())
      },
      operation: {
        let store = StateStore(scope: .project, environment: environment)
        let layer = SourcePolicyLayer(
          scope: .project, url: fixture.root.appendingPathComponent("source-policy.json"),
          rules: .init(allow: [try .git(fixture.source.location)]))
        _ = try SourceResolutionSession.withTemporaryRead(
          store: store, sourcePolicy: .init(layers: [layer])
        ) { session in
          #expect(throws: SourcePolicyFailure.self) {
            _ = try session.candidates(
              for: fixture.source, requirements: [fixture.source.requirement])
          }
        }
        #expect(requests.withLock { $0 } == 0)
        _ = try SourceResolutionSession.withTemporaryRead(store: store) { session in
          #expect(throws: SourceAccessError.requestFailed) {
            _ = try session.candidates(
              for: fixture.source, requirements: [fixture.source.requirement])
          }
        }
        #expect(requests.withLock { $0 } == 1)
      })
  }

  @Test func lockedRangeUsesItsExactTagEvidence() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let bytes = fixture.zip()
    let calls = Mutex(0)
    try PackageSourceHTTP.$fixture.withValue(
      .init { request, _ in
        #expect(request.url?.path.hasSuffix("refs/tags/v1.2.3.zip") == true)
        calls.withLock { $0 += 1 }
        return .init(status: 200, body: bytes)
      },
      operation: {
        try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
          let pin = try #require(
            session.candidates(
              for: fixture.source, requirements: [.revision("refs/tags/v1.2.3")]
            ).first)
          #expect(pin.version == "1.2.3")
          let archive = try #require(pin.archive)
          #expect(archive.admits(.upToNextMajor(from: "1.1.0"), version: pin.version))
          #expect(!archive.admits(.upToNextMajor(from: "2.0.0"), version: pin.version))
          let view = try session.snapshot(fixture.source, at: pin, offline: true)
          #expect(try Data(contentsOf: view.resource("skills/demo/SKILL.md")) == fixture.skillBytes)
        }
      })
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: [InstallMode.link, .copy])
  func privateDeploymentAndOfflineRecovery(_ mode: InstallMode) throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let requests = Mutex(0)
    let bytes = fixture.zip()
    try PackageSourceHTTP.$fixture.withValue(
      .init { request, _ in
        #expect(request.url?.path == "/base/org/repo/archive/refs/tags/release/v1.zip")
        requests.withLock { $0 += 1 }
        return .init(status: 200, body: bytes)
      },
      operation: {
        try fixture.install(mode)
      })
    #expect(requests.withLock { $0 } == 1)
    let ledger = try fixture.store.loadLedger()
    let archive = try #require(ledger.sources.values.first(where: { $0.archive != nil })?.archive)
    #expect(archive.observedArchiveDigest == "sha256:" + FileHash.sha256Hex(data: bytes))
    #expect(archive.requiredArchiveDigest == nil)
    #expect(ledger.resources.values.contains { $0.kind == .archive })
    #expect(ledger.contentObjects.isEmpty)
    let lockBytes = try Data(contentsOf: fixture.store.resolvedURL)
    #expect(!String(decoding: lockBytes, as: UTF8.self).contains("fixture-private"))
    #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
    let deployed = fixture.skill.deletingLastPathComponent().resolvingSymlinksInPath()
    let script = deployed.appendingPathComponent("run.sh")
    #expect(try fixture.mode(deployed) == 0o700)
    #expect(try fixture.mode(deployed.appendingPathComponent("SKILL.md")) == 0o600)
    #expect(try fixture.mode(script) == 0o700)
    let retained = try fixture.recoveryEntry(archive)
    #expect(try fixture.mode(retained.deletingLastPathComponent()) == 0o700)
    #expect(try fixture.mode(retained.appendingPathComponent("archive")) == 0o600)
    #expect(try AcquisitionCache(environment: fixture.environment).inspect().entries.isEmpty)

    let damage = mode == .link ? retained.appendingPathComponent("tree") : deployed
    try FileManager.default.removeItem(at: damage)
    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in
        Issue.record("offline replay ran an HTTP request")
        throw SourceAccessError.requestFailed
      },
      operation: {
        _ = try UpdateOperations.restore(environment: fixture.environment, offline: true)
        #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
        #expect(try Data(contentsOf: fixture.store.resolvedURL) == lockBytes)
        let outsider = try fixture.copyLock()
        #expect(throws: SourceAccessError.recoveryUnavailable) {
          _ = try UpdateOperations.restore(environment: outsider, offline: true)
        }
      })
  }

  @Test func recompressionAndStrictArchivePin() throws {
    for strict in [false, true] {
      let fixture = try ArchiveSourceFixture(strict: strict)
      defer { fixture.remove() }
      let original = fixture.zip()
      let recompressed = fixture.zip(deflate: true, enclosing: "mirror-renamed")
      #expect(original != recompressed)
      #expect(
        try VerifiedVCSArchive(original).treeDigest == VerifiedVCSArchive(recompressed).treeDigest)
      #expect(
        try VerifiedVCSArchive(original).treeDigest
          != VerifiedVCSArchive(fixture.zip(executable: false)).treeDigest)
      try PackageSourceHTTP.$fixture.withValue(
        .init { _, _ in .init(status: 200, body: original) },
        operation: {
          try fixture.install(.link)
        })
      let archive = try #require(
        fixture.store.loadLedger().sources.values.compactMap(\.archive).first)
      let representation = try fixture.recoveryEntry(archive).appendingPathComponent("archive")
      let sealed = try Data(contentsOf: representation)
      try FileManager.default.removeItem(at: representation)
      try PackageSourceHTTP.$fixture.withValue(
        .init { _, _ in .init(status: 200, body: recompressed) },
        operation: {
          if strict {
            #expect(throws: SourceAccessError.archiveChanged) {
              _ = try UpdateOperations.restore(environment: fixture.environment)
            }
            #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
            try sealed.write(to: representation)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: representation.path)
          } else {
            let deploy = fixture.skill.deletingLastPathComponent()
            try FileManager.default.removeItem(at: deploy)
            _ = try UpdateOperations.restore(environment: fixture.environment)
            #expect(try Data(contentsOf: representation) != sealed)
            let report = try UpdateOperations.preview(
              .init(operation: .update), environment: fixture.environment)
            #expect(report.archiveRepresentationChanges?.count == 1)
          }
        })
      _ = try UpdateOperations.restore(environment: fixture.environment, offline: true)
      let stored = try Data(contentsOf: representation)
      try (stored + Data([0])).write(to: representation)
      #expect(throws: SourceAccessError.invalidArchive) {
        _ = try UpdateOperations.restore(environment: fixture.environment, offline: true)
      }
    }
  }

  @Test func renderedAggregateUsesAnOwnerOnlyDestination() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let text = """
      ---
      description: private instruction fixture
      ---
      # Guidance
      fixture-private-guidance
      """
    let archive = ArchiveSourceFixture.zip(
      [("producer/instructions/guidance.md", Data(text.utf8), 0o100644)], deflate: false)
    let declaration = Declaration(
      agents: [.codex], sources: ["fixture": fixture.source],
      instructions: .init(agents: [.codex], sections: ["fixture:guidance"]))
    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in .init(status: 200, body: archive) },
      operation: {
        try UpdateOperations.withPreparedUpdate(
          .init(operation: .declaration(declaration)), environment: fixture.environment
        ) { _ = try $0.apply() }
      })
    let destination = fixture.environment.projectDirectory.appendingPathComponent("AGENTS.md")
    #expect(try fixture.mode(destination) == 0o600)
    let contents = try String(contentsOf: destination, encoding: .utf8)
    #expect(contents.contains("fixture-private-guidance"))
    let lock = try String(contentsOf: fixture.store.resolvedURL, encoding: .utf8)
    #expect(!lock.contains("fixture-private-guidance"))
  }

  @Test func privateArchiveSurvivesUntilItsLastCommittedScopeReleasesIt() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let bytes = fixture.zip()
    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in .init(status: 200, body: bytes) },
      operation: {
        try fixture.install(.link)
      })
    let ledger = try fixture.store.loadLedger()
    let archive = try #require(ledger.sources.values.compactMap(\.archive).first)
    let entry = try fixture.recoveryEntry(archive)
    let other = try fixture.copyLock(sameHome: true)
    _ = try UpdateOperations.restore(environment: other, offline: true)
    let remove = UpdateRequest(operation: .declaration(Declaration()))
    try UpdateOperations.withPreparedUpdate(remove, environment: fixture.environment) {
      _ = try $0.apply()
    }
    #expect(FileManager.default.fileExists(atPath: entry.path))
    let otherSkill = other.projectDirectory.appendingPathComponent(".agents/skills/demo/SKILL.md")
    #expect(try Data(contentsOf: otherSkill) == fixture.skillBytes)
    try UpdateOperations.withPreparedUpdate(remove, environment: other) { _ = try $0.apply() }
    #expect(!FileManager.default.fileExists(atPath: entry.path))
  }

  @Test(arguments: ["archive.recovery.reserved", TransactionCheckpoint.phase(.committed).name])
  func interruptedRetentionKeepsOnlyVisibleGenerations(_ checkpoint: String) throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let bytes = fixture.zip()
    let child = try fixture.launch(checkpoint: checkpoint, archive: bytes)
    defer { try? ProcessWait.terminate(child) }
    try ProcessWait.marker(
      fixture.root.appendingPathComponent("ready"), child: child, root: fixture.root)
    try ProcessWait.stopped(child, root: fixture.root)
    try ProcessWait.terminate(child)

    if checkpoint == "archive.recovery.reserved" {
      #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
      #expect(!FileManager.default.fileExists(atPath: fixture.skill.path))
      try PackageSourceHTTP.$fixture.withValue(
        .init { _, _ in .init(status: 200, body: bytes) },
        operation: {
          try fixture.install(.link)
        })
    } else {
      #expect(FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
      #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
      do {
        _ = try UpdateOperations.restore(environment: fixture.environment, offline: true)
        Issue.record("the committed journal was not recovered")
      } catch let error as CoreError {
        guard case .transactionRecovered = error else { throw error }
      }
    }
    let cache = AcquisitionCache(environment: fixture.environment)
    #expect(try cache.apply(cache.preview(.clean)).isComplete)
    try FileManager.default.removeItem(at: fixture.skill.deletingLastPathComponent())
    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in
        Issue.record("offline crash recovery made a request")
        throw SourceAccessError.requestFailed
      },
      operation: {
        _ = try UpdateOperations.restore(environment: fixture.environment, offline: true)
      })
    #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
  }

  @Test func changedParentPermissionsInvalidatePreparedPublication() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let destinationParent = fixture.skill.deletingLastPathComponent().deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: destinationParent, withIntermediateDirectories: true)
    let bytes = fixture.zip()
    PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in .init(status: 200, body: bytes) },
      operation: {
        #expect(throws: UpdateApplyError.self) {
          try UpdateOperations.withPreparedUpdate(
            fixture.request(.copy), environment: fixture.environment
          ) { prepared in
            #expect(prepared.report.hasChanges)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o777], ofItemAtPath: destinationParent.path)
            _ = try prepared.apply()
          }
        }
      })
    #expect(!FileManager.default.fileExists(atPath: fixture.skill.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
  }
}

private struct ArchiveSourceFixture: Sendable {
  let root: URL
  let environment: RuntimeEnvironment
  let source = SourceDeclaration(
    kind: .git, location: "https://origin.invalid:8443/org/repo.git",
    requirement: .revision("refs/tags/release/v1"))
  let skillBytes = Data(
    "---\nname: demo\ndescription: fixture-private-description\n---\n# Demo\nfixture-private-source\n"
      .utf8)

  init(strict: Bool = false) throws {
    root = try SourceCache.privateWorkspace(prefix: "agents-source-access-test-")
    let project = root.appendingPathComponent("project")
    let home = root.appendingPathComponent("home")
    do {
      for directory in [project, home] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      environment = RuntimeEnvironment(
        projectDirectory: project, homeDirectory: home, environment: [:],
        acquisitionCacheRoot: root.appendingPathComponent("disposable"),
        sourceAccess: .init(
          egress: .proxyOnly, mirrors: [try Self.profile(.github, strict: strict)]))
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  static func profile(
    _ flavor: SourceArchiveMirror.Flavor, qualified: Bool = false, strict: Bool = false
  ) throws -> SourceArchiveMirror {
    try .init(
      source: SourceAuthority(host: "origin.invalid", port: 8443),
      base: URL(string: "https://mirror.invalid:9443/base/")!, flavor: flavor,
      supportsQualifiedGitLabRefs: qualified, requiresExactArchiveBytes: strict)
  }

  var store: StateStore { .init(scope: .project, environment: environment) }
  var skill: URL {
    environment.projectDirectory.appendingPathComponent(".agents/skills/demo/SKILL.md")
  }

  func request(_ mode: InstallMode) -> UpdateRequest {
    .init(
      operation: .declaration(
        Declaration(
          agents: [.codex], sources: ["fixture": source],
          skills: ["fixture": .init(select: .names(["demo"]), mode: mode)])))
  }

  func install(_ mode: InstallMode) throws {
    try UpdateOperations.withPreparedUpdate(request(mode), environment: environment) {
      _ = try $0.apply()
    }
  }

  func recoveryEntry(_ evidence: SourceArchiveEvidence) throws -> URL {
    let tree = SourceCache(store: store).archiveTree(transport: source.location, evidence: evidence)
    return tree.deletingLastPathComponent()
  }

  func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }

  func copyLock(sameHome: Bool = false) throws -> RuntimeEnvironment {
    var other = environment
    if !sameHome { other.homeDirectory = root.appendingPathComponent("other-home") }
    other.projectDirectory = root.appendingPathComponent("other-project")
    if !sameHome {
      try FileManager.default.createDirectory(
        at: other.homeDirectory, withIntermediateDirectories: false)
    }
    let target = StateStore(scope: .project, environment: other)
    try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: store.declarationURL, to: target.declarationURL)
    try FileManager.default.copyItem(at: store.resolvedURL, to: target.resolvedURL)
    return other
  }

  func launch(checkpoint: String, archive: Data) throws -> Process {
    var directory = Bundle(for: SourceArchiveTestBundle.self).bundleURL
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let scratch = root.appendingPathComponent("child-temporary")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    let input = root.appendingPathComponent("response.zip")
    try archive.write(to: input)
    let process = Process()
    process.executableURL = directory.appendingPathComponent("StateTestProcess")
    process.arguments = [root.path, "source-archive", checkpoint, input.path]
    process.environment = [
      "HOME": environment.homeDirectory.path, "TMPDIR": scratch.path,
      "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_ALLOW_PROTOCOL": "file",
    ]
    try process.run()
    return process
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func zip(deflate: Bool = false, enclosing: String = "producer", executable: Bool = true) -> Data {
    Self.zip(
      [
        (enclosing + "/skills/demo/SKILL.md", skillBytes, 0o100644),
        (
          enclosing + "/skills/demo/run.sh", Data("#!/bin/sh\n".utf8),
          executable ? 0o100755 : 0o100644
        ),
      ],
      deflate: deflate)
  }

  fileprivate static func zip(
    _ members: [(String, Data, UInt32)], deflate: Bool
  ) -> Data {
    func pair(_ value: Int) -> Data {
      Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }
    func word(_ value: Int) -> Data { pair(value) + pair(value >> 16) }
    func crc(_ content: Data) -> Int {
      let register = content.reduce(UInt32.max) { crc, byte in
        (0..<8).reduce(crc ^ UInt32(byte)) { state, _ in
          (state >> 1) ^ ((state & 1) == 1 ? 0xEDB8_8320 : 0)
        }
      }
      return Int(~register)
    }
    var result = Data()
    var directory = Data()
    for (path, contents, mode) in members {
      let compressed =
        deflate
        ? Data([1]) + pair(contents.count) + pair(~contents.count) + contents : contents
      let method = deflate ? 8 : 0
      let name = Data(path.utf8)
      let fields =
        pair(0x800) + pair(method) + word(0) + word(crc(contents))
        + word(compressed.count) + word(contents.count) + pair(name.count) + pair(0)
      directory += word(0x0201_4b50) + pair(0x0314) + pair(20) + fields
      directory += word(0) + pair(0) + word(Int(mode) << 16) + word(result.count) + name
      result += word(0x0403_4b50) + pair(20) + fields + name + compressed
    }
    let end =
      word(0x0605_4b50) + word(0) + pair(members.count) + pair(members.count)
      + word(directory.count) + word(result.count) + pair(0)
    return result + directory + end
  }
}

private final class SourceArchiveTestBundle: NSObject {}

extension SourceAccessTests {
  @Test func userSettingsDriveDefaultDiagnosisAndInstallation() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let project = fixture.environment.projectDirectory
    let home = fixture.environment.homeDirectory
    let variables = [
      "HOME": home.path, "PACKAGE_ARCHIVE_FIXTURE": "synthetic-profile-value",
      "UNSCOPED_FIXTURE": "never-selected-value",
    ]
    let absent = RuntimeEnvironment(projectDirectory: project, environment: variables)
    let editor = try SourceAccessSettingsEditor(environment: absent)
    let profile = Data(
      """
      version: 1
      egress: proxyOnly
      providers:
        - host: origin.invalid
          port: 8443
          provider: github
      mirrors:
        - source: {host: origin.invalid, port: 8443}
          base: https://mirror.invalid:9443/base
          flavor: github
      credentials:
        - route: mirror
          host: mirror.invalid
          port: 9443
          path: /base/org/repo
          environmentVariable: PACKAGE_ARCHIVE_FIXTURE
      """.utf8)
    let projectSettings = project.appendingPathComponent(".agent/source-access.yaml")
    try FileManager.default.createDirectory(
      at: projectSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try profile.write(to: projectSettings)
    #expect(try absent.resolvedSourceAccess().egress == .directAllowed)
    #expect(!FileManager.default.fileExists(atPath: editor.url.path))

    try editor.save(editor.preview(profile))
    #expect(throws: SourceAccessSettingsError.changed(editor.url)) {
      try absent.resolvedSourceAccess()
    }
    let runtime = RuntimeEnvironment(projectDirectory: project, environment: variables)
    let policy = EffectiveSourcePolicy()
    func inspect(_ selector: String, environment: RuntimeEnvironment = runtime) throws
      -> SourceCredentialReport
    {
      try SourceCredentialOperations.inspect(
        source: selector, declaration: Declaration(), environment: environment, policy: policy)
    }

    let bytes = fixture.zip()
    let requests = Mutex(0)
    try PackageSourceHTTP.$fixture.withValue(
      .init { request, _ in
        requests.withLock { $0 += 1 }
        #expect(
          request.url?.absoluteString
            == "https://mirror.invalid:9443/base/org/repo/archive/refs/tags/release/v1.zip")
        #expect(
          request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-profile-value")
        return .init(status: 200, body: bytes)
      },
      operation: {
        let status = try inspect("https://origin.invalid:8443/org/repo@tag:release/v1")
        #expect(status.provider == .github)
        #expect(status.transport == .archive)
        #expect(status.effectiveHost == "mirror.invalid:9443")
        #expect(status.credentialSource == .environment)
        #expect(status.availability == .available)
        #expect(
          try inspect("https://origin.invalid:8443/org/another").availability == .unconfigured)
        #expect(throws: SourceAccessError.egressDenied) {
          try inspect("https://origin.invalid:443/org/repo.git")
        }
        let missing = RuntimeEnvironment(
          projectDirectory: project, environment: ["HOME": home.path, "UNSCOPED_FIXTURE": "value"])
        #expect(
          try inspect("https://origin.invalid:8443/org/repo", environment: missing)
            .availability == .unavailable)
        let serialized = try JSONEncoder().encode(status)
        for secret in ["synthetic-profile-value", "never-selected-value"] {
          #expect(!String(decoding: serialized, as: UTF8.self).contains(secret))
          #expect(
            !String(decoding: try Data(contentsOf: editor.url), as: UTF8.self).contains(secret))
        }
        #expect(requests.withLock { $0 } == 0)
        try UpdateOperations.withPreparedUpdate(fixture.request(.copy), environment: runtime) {
          _ = try $0.apply()
        }
      })
    #expect(requests.withLock { $0 } > 0)
    #expect(try Data(contentsOf: fixture.skill) == fixture.skillBytes)
  }

  @Test func malformedSettingsBlockDiagnosisAndCanBeRepairedAndReloaded() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let home = fixture.environment.homeDirectory
    let root = fixture.environment.projectDirectory
    var runtime = RuntimeEnvironment(projectDirectory: root, environment: ["HOME": home.path])
    let url = SourceAccessSettingsEditor.settingsURL(environment: runtime)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("version: 1\negress: SENSITIVE_INVALID_FIELD_VALUE\n".utf8).write(to: url)
    runtime.reloadSourceAccessSettings()
    let syntax = SourceAccessSettingsError.invalidFile(url, reason: "Missing or invalid egress.")
    let authority = try SourceAuthority(host: "github.com")
    #expect(throws: syntax) {
      try SourceCredentialOperations.inspect(host: authority, environment: runtime)
    }
    #expect(throws: syntax) {
      try UpdateOperations.preview(fixture.request(.copy), environment: runtime)
    }
    #expect(!syntax.localizedDescription.contains("SENSITIVE_INVALID_FIELD_VALUE"))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))

    let repair = try SourceAccessSettingsEditor(environment: runtime)
    try repair.save(repair.preview(Data("version: 1\negress: proxyOnly\n".utf8)))
    runtime.reloadSourceAccessSettings()
    #expect(try runtime.resolvedSourceAccess().egress == .proxyOnly)
    #expect(throws: SourceAccessError.egressDenied) {
      try SourceCredentialOperations.inspect(
        source: "org/repo", declaration: Declaration(), environment: runtime, policy: .init())
    }
    let reset = try SourceAccessSettingsEditor(environment: runtime)
    try reset.save(reset.preview(nil))
    #expect(throws: SourceAccessSettingsError.changed(url)) { try runtime.resolvedSourceAccess() }
    runtime.reloadSourceAccessSettings()
    #expect(try runtime.resolvedSourceAccess().egress == .directAllowed)
    let report = try SourceCredentialOperations.inspect(
      source: "org/repo", declaration: Declaration(), environment: runtime, policy: .init())
    #expect(report.transport == .https && report.availability == .unconfigured)
  }

  @Test func profileReplacementInvalidatesPreparedInstall() throws {
    let fixture = try ArchiveSourceFixture()
    defer { fixture.remove() }
    let runtime = RuntimeEnvironment(
      projectDirectory: fixture.environment.projectDirectory,
      environment: ["HOME": fixture.environment.homeDirectory.path])
    let editor = try SourceAccessSettingsEditor(environment: runtime)
    try editor.save(
      editor.preview(
        Data(
          """
          version: 1
          egress: proxyOnly
          mirrors:
            - source: {host: origin.invalid, port: 8443}
              base: https://mirror.invalid:9443/base
              flavor: github
          """.utf8)))
    var reloaded = runtime
    reloaded.reloadSourceAccessSettings()
    let bytes = fixture.zip()
    let requests = Mutex(0)
    try PackageSourceHTTP.$fixture.withValue(
      .init { _, _ in
        requests.withLock { $0 += 1 }
        return .init(status: 200, body: bytes)
      },
      operation: {
        try UpdateOperations.withPreparedUpdate(fixture.request(.copy), environment: reloaded) {
          prepared in
          #expect(prepared.report.hasChanges)
          let reset = try SourceAccessSettingsEditor(environment: reloaded)
          try reset.save(reset.preview(nil))
          let count = requests.withLock { $0 }
          #expect(throws: UpdateApplyError.self) { try prepared.apply() }
          #expect(requests.withLock { $0 } == count)
        }
      })
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.skill.path))
  }
}
