#if os(macOS)
  import AgentsCore
  import AgentsManifest
  import Darwin
  import Foundation
  import Testing

  @testable import AgentsUpdates

  @Suite("Package lifecycle loopback TLS")
  struct PackageLifecycleTLSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTS_TEST_LIFECYCLE_TLS"] == "1"))
    func dispatchOrderingResponseWaitingAndRedaction() async throws {
      let fixture = try LifecycleFixture()
      let transport = try LifecycleLoopbackTLS(fixture: fixture)
      try await fixture.withoutAdministratorFiles {
        try await LifecycleHTTPClient.$loopbackTrustAnchorForTesting.withValue(transport.anchor) {
          var environment = fixture.environment
          environment.environment["FIXTURE_TOKEN"] = "synthetic-token-value"
          environment.environment["FIXTURE_BUILD"] = "synthetic-build"
          try fixture.write(
            """
            version: 1
            lifecycle:
              pre-install:
                - type: http
                  url: \(transport.origin)/pre?private=synthetic-query
                  headers: {Authorization: 'Bearer ${FIXTURE_TOKEN}', X-Build: '$FIXTURE_BUILD'}
                  allowedEnvVars: [FIXTURE_TOKEN]
                  timeout: 5
              post-install:
                - {type: http, url: "\(transport.origin)/redirect", timeout: 5}
              pre-update:
                - type: http
                  url: \(transport.origin)/wait
                  timeout: 5
                - type: command
                  run: 'printf second >> count'
              pre-uninstall:
                - type: http
                  url: \(transport.origin)/blocked
                  headers: {Authorization: 'Bearer ${FIXTURE_TOKEN}'}
              post-uninstall:
                - {type: http, url: "\(transport.origin)/lost", timeout: 2}
            """)
          _ = try await fixture.enable()
          let req = UpdateRequest(operation: .edit([.setDefaultAgents([.codex])]))
          let review = try UpdateOperations.previewLifecycle(
            req, intent: .install, environment: environment)
          #expect(!fixture.exists(transport.path("pre-hit")))
          let output = try fixture.completed(
            await UpdateOperations.perform(
              review,
              onDispatch: { summary in
                if summary.event == .preInstall {
                  #expect(!fixture.exists(fixture.store.resolvedURL))
                }
              }))
          _ = try output.package.result.get()
          #expect(output.pre.map(\.disposition) == [.httpSucceeded])
          #expect(output.pre.map(\.httpStatus) == [202])
          #expect(output.post.map(\.disposition) == [.httpRejected])
          #expect(output.post.map(\.httpStatus) == [307])
          #expect(!fixture.exists(transport.path("never-hit")))
          #expect(try String(contentsOf: transport.path("pre-hit"), encoding: .utf8) == "verified")
          let resultBytes = try JSONEncoder().encode(output.pre)
          let report = String(decoding: resultBytes, as: UTF8.self)
          #expect(!report.contains("synthetic-token-value"))
          #expect(!report.contains("synthetic-query"))
          #expect(!report.contains("synthetic-build"))

          let preview = LifecycleOperations.simulate(.preUpdate, environment: environment)
          #expect(!fixture.exists(transport.path("wait-hit")))
          let running = Task { await LifecycleOperations.executeTest(preview) }
          try await transport.awaitMarker("wait-hit")
          #expect(!fixture.exists(fixture.counter))
          try Data().write(to: transport.path("wait-release"))
          let tested = try fixture.completed(await running.value)
          #expect(tested.map(\.disposition) == [.httpSucceeded, .commandSucceeded])
          #expect(try fixture.counterText() == "second")

          let blocked = LifecycleOperations.simulate(.preUninstall, environment: environment)
          let refused = try fixture.completed(await LifecycleOperations.executeTest(blocked))
          #expect(refused.map(\.withholding) == [.headerExpansionRefused])
          #expect(!fixture.exists(transport.path("blocked-hit")))

          let lost = LifecycleOperations.simulate(.postUninstall, environment: environment)
          let unknown = try fixture.completed(await LifecycleOperations.executeTest(lost))
          #expect(unknown.map(\.disposition) == [.deliveryUnknown])
          #expect(unknown.map(\.dispatched) == [true])
          #expect(try String(contentsOf: transport.path("lost-hit"), encoding: .utf8) == "hit\n")
        }
      }
    }
  }

  private final class LifecycleLoopbackTLS: @unchecked Sendable {
    let anchor: Data
    private(set) var origin = ""
    private let root: URL
    private let server = Process()
    private let exited = DispatchSemaphore(value: 0)

    init(fixture: LifecycleFixture) throws {
      root = fixture.root
      func path(_ name: String) -> URL { fixture.root.appendingPathComponent(name) }
      let authority = path("authority.pem")
      let authorityKey = path("authority.key")
      let key = path("server.key")
      let certificate = path("server.pem")
      let request = path("server.csr")
      let extensions = path("server.conf")
      let certificateDER = path("authority.der")
      try Self.openssl([
        "req", "-x509", "-newkey", "rsa:2048", "-days", "1", "-nodes",
        "-subj", "/CN=Agents Synthetic Lifecycle", "-keyout", authorityKey.path,
        "-out", authority.path,
      ])
      try Self.openssl([
        "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
        "-keyout", key.path, "-out", request.path,
      ])
      try Data(
        """
        basicConstraints = critical,CA:FALSE
        subjectAltName = IP:127.0.0.1
        extendedKeyUsage = serverAuth
        """.utf8
      ).write(to: extensions)
      try Self.openssl([
        "x509", "-req", "-in", request.path, "-CA", authority.path, "-CAkey", authorityKey.path,
        "-CAcreateserial", "-days", "1", "-extfile", extensions.path, "-out", certificate.path,
      ])
      try Self.openssl([
        "x509", "-in", authority.path, "-outform", "der", "-out", certificateDER.path,
      ])
      anchor = try Data(contentsOf: certificateDER)

      server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      server.arguments = ["python3", "-c", Self.handler, fixture.root.path, fixture.project.path]
      server.standardOutput = FileHandle.nullDevice
      let diagnostics = fixture.root.appendingPathComponent("tls-diagnostics")
      FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
      server.standardError = try FileHandle(forWritingTo: diagnostics)
      server.terminationHandler = { [exited] _ in exited.signal() }
      try server.run()
      let deadline = ContinuousClock.now + .seconds(5)
      var selectedPort: Int?
      while server.isRunning && ContinuousClock.now < deadline {
        if let content = try? String(contentsOf: path("tls-port"), encoding: .utf8),
          let port = Int(content)
        {
          selectedPort = port
          break
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      guard let selectedPort else {
        stop()
        let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
        throw CoreError.invalidState("Synthetic TLS server could not start: " + detail)
      }
      origin = "https://127.0.0.1:\(selectedPort)"
    }

    deinit { stop() }

    private func stop() {
      guard server.isRunning else { return }
      server.terminate()
      if exited.wait(timeout: .now() + .seconds(3)) == .timedOut {
        _ = kill(server.processIdentifier, SIGKILL)
        #expect(exited.wait(timeout: .now() + .seconds(3)) == .success)
      }
    }

    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    func awaitMarker(_ name: String) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !FileManager.default.fileExists(atPath: path(name).path), ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(FileManager.default.fileExists(atPath: path(name).path))
    }

    private static func openssl(_ arguments: [String]) throws {
      _ = try ProcessRunner.run("/usr/bin/openssl", arguments: arguments)
    }

    private static let handler = """
      import http.server, json, pathlib, socket, ssl, sys, time, urllib.parse
      root = pathlib.Path(sys.argv[1])
      project = pathlib.Path(sys.argv[2])
      class Handler(http.server.BaseHTTPRequestHandler):
          def do_POST(self):
              path = urllib.parse.urlsplit(self.path).path
              body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
              marker = root / (path.lstrip("/") + "-hit")
              if path == "/lost":
                  with marker.open("a") as file:
                      file.write("hit\\n")
                  self.connection.shutdown(socket.SHUT_RDWR)
                  return
              marker.touch()
              status = 204
              if path == "/pre":
                  deadline = time.monotonic() + 4
                  ledger = project / ".agent" / "agents.resolved"
                  while not ledger.exists() and time.monotonic() < deadline:
                      time.sleep(0.01)
                  valid = (
                      ledger.exists() and body == {"version": 1, "event": "pre-install", "scope": "project", "test": False}
                      and self.headers.get("Authorization") == "Bearer synthetic-token-value"
                      and self.headers.get("X-Build") == "synthetic-build"
                      and self.headers.get("Cookie") is None
                  )
                  if valid:
                      marker.write_text("verified")
                  status = 202 if valid else 422
              if path == "/wait":
                  deadline = time.monotonic() + 4
                  while not (root / "wait-release").exists() and time.monotonic() < deadline:
                      time.sleep(0.01)
                  status = 204 if body["test"] and (root / "wait-release").exists() else 422
              if path == "/redirect":
                  self.send_response(307)
                  self.send_header("Location", "/never")
                  self.end_headers()
                  return
              self.send_response(status)
              self.end_headers()
      server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
      context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      context.load_cert_chain(root / "server.pem", root / "server.key")
      server.socket = context.wrap_socket(server.socket, server_side=True)
      (root / "tls-port").write_text(str(server.server_port))
      server.serve_forever()
      """
  }
#endif
