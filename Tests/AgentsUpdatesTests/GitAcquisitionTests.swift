import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

// Each case launches multiple Git children. Serializing this suite leaves queue capacity
// for the asynchronous registry fixture's readiness deadline.
@Suite(.serialized, .enabled(if: GitHTTPSFixture.toolsAvailable))
struct GitAcquisitionTests {
  @Test func productionUpdateReusesExactObjectsAndRetainsOfflineLinks() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    let first = try fixture.environment("first")
    let second = try fixture.environment("second")
    let naked = try fixture.environment("naked")
    let cache = AcquisitionCache(environment: first)
    let url = fixture.url("package")
    let source = SourceDeclaration(kind: .git, location: url, requirement: .branch("main"))
    let acquisition = try #require(GitAcquisition(source, environment: first))

    try GitAcquisition.$fixtureCertificateAuthority.withValue(fixture.certificate) {
      let original = try fixture.release("version-one")
      try install(source, in: first)
      let originalBytes = try Data(contentsOf: fixture.skill(first))
      #expect(String(decoding: originalBytes, as: UTF8.self).contains("version-one"))
      #expect(try acquisition.observedRevision("refs/heads/main") == original)
      let firstInventory = try cache.inspect()
      #expect(firstInventory.entries.contains { $0.store == .git && $0.object == original })
      #expect(firstInventory.entries.contains { $0.store == .deployed })
      #expect(
        try cache.verifiedDeployedBytes(sha256: FileHash.sha256Hex(data: originalBytes))
          == originalBytes)
      let target = fixture.skill(first).deletingLastPathComponent()
      _ = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
      let destination = try #require(PathSafety.realPath(target.path))
      let state = StateStore(scope: .project, environment: first).cacheDirectory
      let statePath = try #require(PathSafety.realPath(state.path))
      #expect(destination.hasPrefix(statePath + "/"))
      #expect(!destination.hasPrefix(cache.root.resolvingSymlinksInPath().path + "/"))

      try fixture.copyLock(from: first, to: second)
      let requestsBefore = try fixture.requests()
      let policy = SourcePolicyOperations.policyURL(scope: .project, environment: second)
      try Data("version: 1\ndeny: [{git: '\(url)'}]\n".utf8).write(to: policy)
      #expect(throws: SourcePolicyFailure.self) {
        try UpdateOperations.restore(environment: second, offline: true)
      }
      #expect(try fixture.requests() == requestsBefore)
      try FileManager.default.removeItem(at: policy)
      _ = try UpdateOperations.restore(environment: second, offline: true)
      #expect(try fixture.requests() == requestsBefore)
      #expect(try Data(contentsOf: fixture.skill(second)) == originalBytes)

      let advanced = try fixture.release("version-two")
      try UpdateOperations.withPreparedUpdate(.init(operation: .update), environment: first) {
        _ = try $0.apply()
      }
      #expect(try acquisition.observedRevision("refs/heads/main") == advanced)
      _ = try UpdateOperations.restore(environment: second, offline: true)
      #expect(try acquisition.observedRevision("refs/heads/main") == advanced)
      #expect(try Data(contentsOf: fixture.skill(second)) == originalBytes)
      let firstBytes = try Data(contentsOf: fixture.skill(first))
      #expect(String(decoding: firstBytes, as: UTF8.self).contains("version-two"))

      try fixture.copyLock(from: first, to: naked)
      #expect(try cache.apply(cache.preview(.clean)).isComplete)
      fixture.stop()
      #expect(try Data(contentsOf: fixture.skill(first)) == firstBytes)
      #expect(try Data(contentsOf: fixture.skill(second)) == originalBytes)
      try FileManager.default.removeItem(at: target)
      _ = try UpdateOperations.restore(environment: first, offline: true)
      #expect(try Data(contentsOf: fixture.skill(first)) == firstBytes)
      #expect(throws: (any Error).self) {
        try UpdateOperations.preview(.init(operation: .update), environment: first)
      }
      do {
        _ = try UpdateOperations.restore(environment: naked, offline: true)
        Issue.record("A naked lock unexpectedly restored with no state or acquisition")
      } catch {
        #expect(String(describing: error).contains("cached Git commit \(advanced)"))
      }
    }
    #expect(try fixture.requests().allSatisfy { !$0.contains("credential=1") })
  }

  @Test func preparedUpdateRetainsItsPackAcrossConcurrentCleanAndProducerLoss() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    let environment = try fixture.environment("prepared")
    let cache = AcquisitionCache(environment: environment)
    let source = SourceDeclaration(
      kind: .git, location: fixture.url("package"), requirement: .branch("main"))
    _ = try fixture.release("prepared")
    try GitAcquisition.$fixtureCertificateAuthority.withValue(fixture.certificate) {
      try UpdateOperations.withPreparedUpdate(
        request(source), environment: environment
      ) { prepared in
        let preview = try cache.preview(.clean)
        #expect(preview.candidates.contains { $0.store == .git && !$0.isGitObservation })
        #expect(try cache.apply(preview).isComplete)
        fixture.stop()
        _ = try prepared.apply()
      }
    }
    #expect(try Data(contentsOf: fixture.skill(environment)).count > 0)
    #expect(try cache.apply(cache.preview(.clean)).isComplete)
    #expect(try Data(contentsOf: fixture.skill(environment)).count > 0)
  }

  @Test func privateAndRefusedInstallsNeverPublishDeployedBytes() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    let environment = try fixture.environment("public-contested")
    let cache = AcquisitionCache(environment: environment)
    let privateRevision = try fixture.release("private-and-public")
    try fixture.git([
      "clone", "--bare", "--no-local", fixture.repository.path,
      fixture.root.appendingPathComponent("private.git").path,
    ])
    let privateConfig = fixture.root.appendingPathComponent("private.gitconfig")
    try fixture.git([
      "config", "--file", privateConfig.path, "http.sslCAInfo", fixture.certificate.path,
    ])
    try fixture.git([
      "config", "--file", privateConfig.path, "credential.helper",
      "!f() { printf 'username=fixture\\npassword=fixture\\n'; }; f",
    ])
    let anonymousConfig = fixture.root.appendingPathComponent("anonymous.gitconfig")
    try fixture.git([
      "config", "--file", anonymousConfig.path, "http.sslCAInfo", fixture.certificate.path,
    ])
    for (project, config, result) in [
      ("private-first", privateConfig, "applied"), ("private-second", anonymousConfig, "refused"),
    ] {
      let arguments =
        [project, fixture.url("private"), result]
        + (result == "refused" ? [privateRevision] : [])
      let child = try fixture.child(arguments, configuration: config)
      defer { try? ProcessWait.terminate(child) }
      try ProcessWait.exit(child, root: fixture.root, timeout: 20)
      #expect(child.terminationStatus == 0)
    }
    #expect(try cache.inspect().entries.isEmpty)
    #expect(try Data(contentsOf: fixture.skill(fixture.environment("private-first"))).count > 0)
    #expect(
      !FileManager.default.fileExists(
        atPath: try fixture.skill(fixture.environment("private-second")).path))

    let source = SourceDeclaration(
      kind: .git, location: fixture.url("package"), requirement: .branch("main"))
    try FileManager.default.createDirectory(
      at: fixture.skill(environment).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unmanaged skill".utf8).write(to: fixture.skill(environment))
    GitAcquisition.$fixtureCertificateAuthority.withValue(fixture.certificate) {
      #expect(throws: (any Error).self) { try install(source, in: environment) }
    }
    #expect(try cache.inspect().entries.allSatisfy { $0.store != .deployed })
    #expect(try Data(contentsOf: fixture.skill(environment)) == Data("unmanaged skill".utf8))
  }

  @Test func anonymousGitDoesNotFollowRedirects() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    _ = try fixture.release("redirect target")
    let environment = try fixture.environment("redirect")
    let source = SourceDeclaration(kind: .git, location: fixture.url("redirect"))
    let acquisition = try #require(GitAcquisition(source, environment: environment))
    GitAcquisition.$fixtureCertificateAuthority.withValue(fixture.certificate) {
      #expect(throws: GitError.self) { try acquisition.discover() }
    }
    let requests = try fixture.requests()
    #expect(requests.count == 1)
    #expect(requests.first?.contains("/redirect.git/") == true)
    #expect(requests.first?.contains("credential=0") == true)
    #expect(try AcquisitionCache(environment: environment).inspect().entries.isEmpty)
  }

  @Test func localLiveProducerRemainsAuthoritativeWhenMissing() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    let environment = try fixture.environment("live")
    let producer = fixture.root.appendingPathComponent("local")
    let skill = producer.appendingPathComponent("skills/fixture/SKILL.md")
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("---\nname: fixture\ndescription: Live fixture\n---\n# Fixture\n".utf8).write(
      to: skill)
    let intent = Declaration(
      agents: [.codex], sources: ["fixture": .init(kind: .local, location: producer.path)],
      skills: ["fixture": .init(select: .names(["fixture"]), mode: .edit)])
    try UpdateOperations.withPreparedUpdate(
      .init(operation: .declaration(intent)), environment: environment
    ) { _ = try $0.apply() }
    let cache = AcquisitionCache(environment: environment)
    #expect(try cache.apply(cache.preview(.clean)).isComplete)
    #expect(try Data(contentsOf: fixture.skill(environment)) == Data(contentsOf: skill))
    try FileManager.default.removeItem(at: producer)
    do {
      _ = try UpdateOperations.restore(environment: environment, offline: true)
      Issue.record("A live install restored without its producer")
    } catch {
      #expect(String(describing: error).contains("live edit skill source"))
    }
  }

  @Test func transportIdentityPreservesCasePortsAndCredentialEligibility() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    let environment = try fixture.environment("keys")
    let values = [
      "https://example.invalid/repo.git", "https://example.invalid/Repo.git",
      "https://example.invalid:443/repo.git", "https://example.invalid/repo",
    ]
    let keys = try values.map {
      let acquisition = try #require(
        GitAcquisition(
          .init(kind: .git, location: $0), environment: environment))
      return acquisition.key(String(repeating: "a", count: 40))
    }
    #expect(Set(keys).count == values.count)
    for url in [
      "http://example.invalid/repo", "git@example.invalid:repo", "https://a:b@example.invalid/repo",
    ] {
      #expect(GitAcquisition(.init(kind: .git, location: url), environment: environment) == nil)
    }
    var credentialed = environment
    credentialed.credentialedGitHosts = ["EXAMPLE.invalid"]
    #expect(
      GitAcquisition(.init(kind: .git, location: values[0]), environment: credentialed) == nil)
  }

  @Test func managedCredentialReachesOnlyItsExactGitRepository() throws {
    let fixture = try GitHTTPSFixture()
    defer { fixture.remove() }
    var environment = try fixture.environment("managed")
    try FileManager.default.createDirectory(
      at: environment.homeDirectory, withIntermediateDirectories: false)
    let url = fixture.url("org/private")
    let source = SourceDeclaration(kind: .git, location: url, requirement: .branch("main"))
    let authority = try SourceAuthority(URLComponents(string: url)!)
    let binding = try SourceCredentialBinding(
      route: .direct, authority: authority, path: "/org/private.git", gitUsername: "fixture"
    ) { "fixture-managed-secret" }
    environment.sourceAccess = .init(providers: [authority: .github], credentials: [binding])
    let first = try fixture.release("managed-first")
    let privateURL = fixture.root.appendingPathComponent("org/private.git")
    try FileManager.default.createDirectory(
      at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: false)
    try fixture.git(["clone", "--bare", fixture.repository.path, privateURL.path])

    try GitAcquisition.$fixtureCertificateAuthority.withValue(fixture.certificate) {
      let store = StateStore(scope: .project, environment: environment)
      let cache = SourceCache(store: store)
      #expect(GitAcquisition(source, environment: environment) == nil)
      #expect(try cache.inspectRevision(source).revision == first)
      #expect(try cache.resolve(source).revision == first)
      let second = try fixture.release("managed-second")
      try fixture.git(["-C", fixture.repository.path, "push", privateURL.path, "main"])
      #expect(try cache.resolve(source).revision == second)
      try install(source, in: environment)

      var proxied = environment
      proxied.sourceAccess = .init(
        egress: .proxyOnly,
        mirrors: [
          try SourceArchiveMirror(
            source: authority, base: URL(string: "https://archive-fixture.invalid/base")!,
            flavor: .github)
        ])
      let directRequests = try fixture.requests()
      #expect(throws: SourceAccessError.routeChanged) {
        _ = try UpdateOperations.restore(environment: proxied, offline: true)
      }
      let zip = fixture.root.appendingPathComponent("managed.zip")
      try fixture.git([
        "-C", fixture.repository.path, "archive", "--format=zip", "--prefix=fixture/",
        "--output", zip.path, "HEAD",
      ])
      let archive = try Data(contentsOf: zip)
      try PackageSourceHTTP.$fixture.withValue(
        .init { request, _ in
          #expect(
            request.url?.absoluteString
              == "https://archive-fixture.invalid/base/org/private/archive/refs/heads/main.zip")
          return .init(status: 200, body: archive)
        },
        operation: {
          try UpdateOperations.withPreparedUpdate(.init(operation: .update), environment: proxied) {
            _ = try $0.apply()
          }
        })
      #expect(try store.loadLedger().sources.values.contains { $0.archive != nil })
      #expect(try fixture.requests() == directRequests)

      #expect(try cache.resolve(source).revision == second)
      let mirror = try cache.mirrorURL(sourceID: source.identity(environment: environment))
      let rewritten = fixture.url("redirect")
      try fixture.git(["-C", mirror.path, "config", "url.\(rewritten).insteadOf", url])
      let before = try fixture.requests()
      #expect(throws: SourceAccessError.routeChanged) { _ = try cache.resolve(source) }
      #expect(try fixture.requests() == before)
    }
    let requests = try fixture.requests()
    #expect(requests.contains { $0.contains("credential=1") })
    #expect(requests.allSatisfy { $0.contains("/org/private.git/") })
  }

  private func request(_ source: SourceDeclaration) -> UpdateRequest {
    UpdateRequest(
      operation: .declaration(
        Declaration(
          agents: [.codex], sources: ["fixture": source],
          skills: ["fixture": .init(select: .names(["fixture"]), mode: .link)])))
  }

  private func install(_ source: SourceDeclaration, in environment: RuntimeEnvironment) throws {
    try UpdateOperations.withPreparedUpdate(request(source), environment: environment) {
      _ = try $0.apply()
    }
  }
}

private final class GitHTTPSFixture {
  static var toolsAvailable: Bool {
    ["/usr/bin/python3", "/usr/bin/openssl", "/usr/bin/git"].allSatisfy {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  let root: URL
  let repository: URL
  let certificate: URL
  private let process = Process()
  private var base = ""

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-git-https-" + UUID().uuidString)
    repository = root.appendingPathComponent("package.git")
    certificate = root.appendingPathComponent("certificate.pem")
    do {
      try setUp()
    } catch {
      remove()
      throw error
    }
  }

  private func setUp() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let key = root.appendingPathComponent("key.pem")
    let config = root.appendingPathComponent("openssl.cnf")
    try Data(
      """
      [req]
      distinguished_name = dn
      x509_extensions = extension
      prompt = no
      [dn]
      CN = 127.0.0.1
      [extension]
      basicConstraints = critical,CA:TRUE
      subjectAltName = IP:127.0.0.1
      """.utf8
    ).write(to: config)
    try run(
      "/usr/bin/openssl",
      [
        "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-config", config.path, "-keyout", key.path, "-out", certificate.path,
      ])
    try git(["init", "--initial-branch=main", repository.path])
    try git(["-C", repository.path, "config", "user.name", "Acquisition Fixture"])
    try git(["-C", repository.path, "config", "user.email", "fixture@example.invalid"])
    try git(["-C", repository.path, "config", "http.getanyfile", "false"])
    try FileManager.default.createDirectory(
      at: repository.appendingPathComponent("skills/fixture"), withIntermediateDirectories: true)
    let script = root.appendingPathComponent("server.py")
    try Data(Self.server.utf8).write(to: script)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path, root.path, certificate.path, key.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let ready = root.appendingPathComponent("port")
    try ProcessWait.marker(ready, child: process, root: root, timeout: 10)
    base = "https://127.0.0.1:" + (try String(contentsOf: ready, encoding: .utf8))
  }

  func release(_ contents: String) throws -> String {
    let directory = repository.appendingPathComponent("skills/fixture")
    try Data(
      """
      ---
      name: fixture
      description: Acquisition cache fixture
      ---
      # Fixture
      \(contents)
      """.utf8
    ).write(to: directory.appendingPathComponent("SKILL.md"))
    try Data([0x01, 0x04, 0x07]).write(to: directory.appendingPathComponent("asset.bin"))
    try git(["-C", repository.path, "add", "."])
    try git(["-C", repository.path, "commit", "-m", contents])
    return try ProcessRunner.run(
      "/usr/bin/git", arguments: ["-C", repository.path, "rev-parse", "HEAD"]
    ).stdout.trimmingCharacters(in: .newlines)
  }

  func git(_ arguments: [String]) throws {
    try run("/usr/bin/git", ["-c", "gc.auto=0", "-c", "maintenance.auto=false"] + arguments)
  }

  private func run(_ path: String, _ arguments: [String]) throws {
    if path == "/usr/bin/openssl" {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: path)
      child.arguments = arguments
      child.standardError = FileHandle.nullDevice
      child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
      try child.run()
      defer { try? ProcessWait.terminate(child) }
      try ProcessWait.exit(child, root: root, timeout: 10)
      try #require(child.terminationStatus == 0)
    } else {
      try ProcessRunner.run(path, arguments: arguments)
    }
  }

  func url(_ name: String) -> String { base + "/" + name + ".git" }

  func environment(_ project: String) throws -> RuntimeEnvironment {
    let path = root.appendingPathComponent(project)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return RuntimeEnvironment(
      projectDirectory: path, homeDirectory: root.appendingPathComponent("home"), environment: [:],
      acquisitionCacheRoot: root.appendingPathComponent("shared/cache"))
  }

  func copyLock(from: RuntimeEnvironment, to: RuntimeEnvironment) throws {
    let original = StateStore(scope: .project, environment: from)
    let target = StateStore(scope: .project, environment: to)
    try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: original.declarationURL, to: target.declarationURL)
    try FileManager.default.copyItem(at: original.resolvedURL, to: target.resolvedURL)
  }

  func skill(_ environment: RuntimeEnvironment) -> URL {
    environment.projectDirectory.appendingPathComponent(".agents/skills/fixture/SKILL.md")
  }

  func requests() throws -> [String] {
    try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func child(_ arguments: [String], configuration: URL) throws -> Process {
    var directory = Bundle(for: GitFixtureBundle.self).bundleURL
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let child = Process()
    child.executableURL = directory.appendingPathComponent("StateTestProcess")
    child.arguments = [root.path, "acquisition-private-install"] + arguments
    child.environment = [
      "PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": configuration.path,
    ]
    try child.run()
    return child
  }

  func stop() {
    if process.isRunning { try? ProcessWait.terminate(process) }
  }

  func remove() {
    stop()
    try? FileManager.default.removeItem(at: root)
  }

  private static let server = #"""
    import base64, http.server, os, pathlib, ssl, subprocess, sys, urllib.parse

    root, cert, key = sys.argv[1:]
    backend = pathlib.Path(subprocess.check_output(
        ["/usr/bin/git", "--exec-path"], text=True).strip()) / "git-http-backend"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.serve_git()

        def do_POST(self):
            self.serve_git()

        def serve_git(self):
            parsed = urllib.parse.urlsplit(self.path)
            headers = self.headers
            supplied = bool(headers.get("Authorization") or headers.get("Cookie")
                            or headers.get("X-Fixture-Secret"))
            with open(os.path.join(root, "requests"), "a") as log:
                log.write(f"{self.command} {parsed.path} credential={int(supplied)}\n")
            if parsed.path.startswith(("/private.git/", "/org/private.git/")):
                token = b"fixture:fixture" if parsed.path.startswith("/private.git/") else b"fixture:fixture-managed-secret"
                expected = "Basic " + base64.b64encode(token).decode()
                if headers.get("Authorization") != expected:
                    self.send_response(401)
                    self.send_header("WWW-Authenticate", 'Basic realm="Fixture"')
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            if parsed.path.startswith("/redirect.git/"):
                self.send_response(302)
                self.send_header("Location", self.path.replace("/redirect.git/", "/package.git/"))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            length = int(headers.get("Content-Length", "0"))
            env = {"PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_PROJECT_ROOT": root,
                   "GIT_HTTP_EXPORT_ALL": "1", "REQUEST_METHOD": self.command,
                   "PATH_INFO": urllib.parse.unquote(parsed.path), "QUERY_STRING": parsed.query,
                   "CONTENT_TYPE": headers.get("Content-Type", ""), "CONTENT_LENGTH": str(length),
                   "HTTP_GIT_PROTOCOL": headers.get("Git-Protocol", "")}
            result = subprocess.run([backend], input=self.rfile.read(length),
                                    env=env, capture_output=True)
            meta, _, body = result.stdout.partition(b"\r\n\r\n")
            response = [field.split(b": ", 1) for field in meta.split(b"\r\n") if b": " in field]
            status = next((int(value.split()[0]) for name, value in response
                           if name.lower() == b"status"), 200)
            self.send_response(status)
            for name, value in response:
                if name.lower() not in (b"status", b"content-length"):
                    self.send_header(name.decode(), value.decode())
            # GnuTLS needs a complete HTTP message before the fixture closes the socket.
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    port = pathlib.Path(root, "port")
    temporary = port.with_suffix(".tmp")
    temporary.write_text(str(server.server_port))
    temporary.replace(port)
    server.serve_forever()
    """#
}

private final class GitFixtureBundle: NSObject {}
