#if os(macOS)
  import AgentsCore
  import Foundation
  import Darwin
  import Testing

  @testable import AgentsUpdates

  @Suite("Hosted marketplace loopback TLS")
  struct HostedMarketplaceTLSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTS_TEST_HOSTED_TLS"] == "1"))
    func verifiesTLSAndControlsRedirectsAndResponseSize() throws {
      let fixture = try UpdateFixture()
      let root = fixture.root
      let ca = root.appendingPathComponent("certificate.pem")
      let caKey = root.appendingPathComponent("authority.key")
      _ = try ProcessRunner.run(
        "/usr/bin/openssl",
        arguments: [
          "req", "-x509", "-newkey", "rsa:2048", "-days", "1", "-nodes",
          "-subj", "/CN=Hosted Marketplace Loopback CA", "-keyout", caKey.path,
          "-out", ca.path,
        ])
      let request = root.appendingPathComponent("server.csr")
      let key = root.appendingPathComponent("fixture.key")
      _ = try ProcessRunner.run(
        "/usr/bin/openssl",
        arguments: [
          "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
          "-keyout", key.path, "-out", request.path,
        ])
      let extensions = root.appendingPathComponent("tls.conf")
      try fixture.write(
        """
        basicConstraints = critical,CA:FALSE
        subjectAltName = IP:127.0.0.1
        extendedKeyUsage = serverAuth
        keyUsage = critical,digitalSignature,keyEncipherment
        """, to: extensions)
      let leaf = root.appendingPathComponent("server.pem")
      _ = try ProcessRunner.run(
        "/usr/bin/openssl",
        arguments: [
          "x509", "-req", "-in", request.path, "-CA", ca.path, "-CAkey", caKey.path,
          "-CAcreateserial", "-days", "1", "-extfile", extensions.path, "-out", leaf.path,
        ])
      let der = root.appendingPathComponent("certificate.der")
      _ = try ProcessRunner.run(
        "/usr/bin/openssl",
        arguments: ["x509", "-in", ca.path, "-outform", "der", "-out", der.path])
      let anchor = try Data(contentsOf: der)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["python3", "-c", Self.server, root.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      try process.run()
      defer {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + .seconds(3)) == .timedOut {
          if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
          #expect(exited.wait(timeout: .now() + .seconds(3)) == .success)
        }
      }
      let portFile = root.appendingPathComponent("port")
      let clock = ContinuousClock()
      let deadline = clock.now + .seconds(3)
      var port: Int?
      while process.isRunning && clock.now < deadline {
        if let value = try? String(contentsOf: portFile, encoding: .utf8), let number = Int(value) {
          port = number
          break
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      let authority = try "https://127.0.0.1:\(#require(port))"
      let redirect = try URLRequest(url: #require(URL(string: authority + "/redirect")))
      #expect(throws: HostedMarketplaceError.requestFailed) {
        try HostedMarketplaceHTTP.fetch(redirect, maximumBytes: 32)
      }
      let hop = try HostedMarketplaceHTTP.fetch(
        redirect, maximumBytes: 32, localTrustAnchor: anchor)
      #expect(hop.status == 307)
      #expect(hop.location == "/data")
      let hit = root.appendingPathComponent("data-hit")
      #expect(!FileManager.default.fileExists(atPath: hit.path))
      var data = try URLRequest(url: #require(URL(string: authority + "/data")))
      data.setValue("Bearer synthetic-loopback", forHTTPHeaderField: "Authorization")
      #expect(throws: HostedMarketplaceError.responseTooLarge) {
        try HostedMarketplaceHTTP.fetch(data, maximumBytes: 4, localTrustAnchor: anchor)
      }
      let received = try HostedMarketplaceHTTP.fetch(
        data, maximumBytes: 32, localTrustAnchor: anchor)
      #expect(String(decoding: received.bytes, as: UTF8.self) == "Bearer synthetic-loopback")
    }

    private static let server = """
      import http.server, pathlib, ssl, sys
      root = pathlib.Path(sys.argv[1])
      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == "/redirect":
                  self.send_response(307)
                  self.send_header("Location", "/data")
                  self.send_header("Set-Cookie", "fixture=redirect; Secure; Path=/")
                  self.end_headers()
                  return
              (root / "data-hit").touch()
              body = self.headers.get("Authorization", "").encode()
              if self.headers.get("Cookie"):
                  body = b"unexpected-cookie"
              self.send_response(200)
              self.end_headers()
              self.wfile.write(body)
      server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
      context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      context.load_cert_chain(root / "server.pem", root / "fixture.key")
      server.socket = context.wrap_socket(server.socket, server_side=True)
      (root / "port").write_text(str(server.server_port))
      server.serve_forever()
      """
  }
#endif
