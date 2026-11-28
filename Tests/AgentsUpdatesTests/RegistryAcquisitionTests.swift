import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import AgentsUpdates

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct RegistryAcquisitionTests {
  @Test func proxyOnlyAdmitsTheConfiguredNamespaceAndRechecksWarmEntries() async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let base = "https://registry.example.invalid:8443/team/registry"
    var environment = fixture.environment
    environment.environment["MCP_REGISTRY_URL"] = base + "/"
    environment.sourceAccess = .init(egress: .proxyOnly)
    let registry = try MCPRegistry(endpoint: #require(URL(string: base)))
    let reply = RegistryResponses([.init(headers: ["cache-control": "max-age=3600"])])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      let result = try await registry.search(environment: environment)
      #expect(result.servers.first?.version == "1.0.0")
      for other in [
        base + "-other", base + "/child", "https://registry.example.invalid/team/registry",
      ] {
        let sibling = try MCPRegistry(endpoint: #require(URL(string: other)))
        await #expect(throws: SourceAccessError.egressDenied) {
          try await sibling.search(environment: environment)
        }
      }
      environment.environment["MCP_REGISTRY_URL"] = "https://registry.example.invalid/replacement"
      await #expect(throws: SourceAccessError.egressDenied) {
        try await registry.search(environment: environment)
      }
      #expect(await reply.calls.count == 1)
    }
  }

  @Test(arguments: [InstallScope.project, .user])
  func lockedServerRequiresItsOriginalRegistryInProxyOnlyMode(_ scope: InstallScope) async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let base = "https://registry.example.invalid:8443/team"
    var environment = fixture.environment
    for directory in [environment.projectDirectory, environment.homeDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    environment.environment["MCP_REGISTRY_URL"] = base
    let settings = try SourceAccessSettingsEditor(environment: environment)
    try settings.save(settings.preview(Data("version: 1\negress: proxyOnly\n".utf8)))
    environment.reloadSourceAccessSettings()
    environment.userOrganizationPolicy = try fixture.registryOnlyPolicy()
    let registry = try MCPRegistry.configured(environment: environment)
    let transport: @Sendable (URLRequest) async throws -> RegistryHTTP.Response = { request in
      let url = try #require(request.url)
      #expect(url.absoluteString == base + "/v0.1/servers/test.example%2Ftool/versions/1.0.0")
      let data = Data(
        """
        {"server":{"name":"test.example/tool","version":"1.0.0","description":"fixture",
         "remotes":[{"type":"streamable-http","url":"https://tools.example.invalid/mcp"}]}}
        """.utf8)
      return .init(url: url, status: 200, headers: [:], body: data)
    }
    let entry = try await RegistryAcquisition.$transport.withValue(transport) {
      try await registry.server(
        named: "test.example/tool", version: "1.0.0", environment: environment)
    }
    let selection = try #require(entry.choices.first)
    let destination = try UpdateOperations.inspect(scope: scope, environment: environment)
    let request = try selection.select(named: "team", agents: [.codex], in: destination)
      .updateRequest()
    _ = try UpdateOperations.withPreparedUpdate(request, scope: scope, environment: environment) {
      try $0.apply()
    }
    _ = try UpdateOperations.restore(scope: scope, environment: environment)
    #expect(try SourcePolicyOperations.audit(scope: scope, environment: environment).hasLock)
    #expect(
      !(try OrganizationPolicyOperations.audit(
        scope: scope, environment: environment, requireOrganizationPolicy: true
      )).isBlocked)
    let root = scope == .project ? environment.projectDirectory : environment.homeDirectory
    let output = root.appendingPathComponent(".codex/config.toml")
    let installed = try Data(contentsOf: output)
    let lock = StateStore(scope: scope, environment: environment).resolvedURL
    let resolved = try Data(contentsOf: lock)
    environment.environment["MCP_REGISTRY_URL"] = base + "/another-base"
    #expect(throws: SourceAccessError.egressDenied) {
      try UpdateOperations.restore(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessError.egressDenied) {
      try SourcePolicyOperations.audit(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessError.egressDenied) {
      try OrganizationPolicyOperations.audit(scope: scope, environment: environment)
    }
    environment.environment["MCP_REGISTRY_URL"] = base + "?invalid=1"
    #expect(throws: SourceAccessError.invalidConfiguration) {
      try UpdateOperations.restore(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessError.invalidConfiguration) {
      try SourcePolicyOperations.audit(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessError.invalidConfiguration) {
      try OrganizationPolicyOperations.audit(scope: scope, environment: environment)
    }
    environment.environment["MCP_REGISTRY_URL"] = base
    try Data("version: 1\negress: unknown\n".utf8).write(to: settings.url)
    environment.reloadSourceAccessSettings()
    #expect(throws: SourceAccessSettingsError.self) {
      try UpdateOperations.restore(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessSettingsError.self) {
      try SourcePolicyOperations.audit(scope: scope, environment: environment)
    }
    #expect(throws: SourceAccessSettingsError.self) {
      try OrganizationPolicyOperations.audit(scope: scope, environment: environment)
    }
    #expect(try Data(contentsOf: output) == installed)
    #expect(try Data(contentsOf: lock) == resolved)
  }

  @Test(arguments: ["npm", "pypi", "oci", "oci-digest", "http", "sse"])
  func registrySelectionBindsTheManifestInvocation(_ variant: String) async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    var environment = try fixture.initializedEnvironment()
    environment.userOrganizationPolicy = try fixture.registryOnlyPolicy()
    let digest = String(repeating: "a", count: 64)
    let definition = """
      {"server":{"name":"test.example/tool","version":"1.0.0","description":"fixture",
       "remotes":[
         {"type":"streamable-http","url":"https://tools.example.invalid/stream"},
         {"type":"sse","url":"https://tools.example.invalid/events"}],
       "packages":[
         {"registryType":"npm","identifier":"@fixture/tools","version":"2.0.0",
          "registryBaseUrl":"https://packages.example.invalid/team","transport":{"type":"stdio"},
          "environmentVariables":[{"name":"FIXTURE_MODE","choices":["safe","fast"]}]},
         {"registryType":"pypi","identifier":"fixture-tools","version":"3.0.0",
          "transport":{"type":"stdio"}},
         {"registryType":"oci","identifier":"fixture/tools","version":"4.0.0",
          "transport":{"type":"stdio"},
          "environmentVariables":[{"name":"FIXTURE_ROLE","isRequired":true,"isSecret":true}]},
         {"registryType":"oci","identifier":"images.example.invalid/fixture/tools@sha256:\(digest)",
          "transport":{"type":"stdio"}}]}}
      """
    let entry = try await fixture.definition(definition, environment: environment)
    let choice = try #require(
      entry.choices.first {
        switch $0.source {
        case .package(let package):
          if package.registryType == "oci" {
            return variant == (package.identifier.contains("@sha256:") ? "oci-digest" : "oci")
          }
          return package.registryType == variant
        case .remote: return $0.transport == (variant == "http" ? "streamable-http" : variant)
        }
      })
    let bindings: [String: MCPRegistryBinding]
    let mutations: [(String, String)]
    switch variant {
    case "npm":
      bindings = ["FIXTURE_MODE": .choice("safe")]
      mutations = [
        (#""executable": "npx""#, #""executable": "echo""#),
        ("@fixture/tools@2.0.0", "@fixture/tools@2.0.1"),
        ("https://packages.example.invalid/team", "https://packages.example.invalid/other"),
        ("safe", "fast"),
      ]
    case "pypi":
      bindings = [:]
      mutations = [("fixture-console", "different-console"), ("==3.0.0", "==3.0.1")]
    case "oci":
      bindings = ["FIXTURE_ROLE": .environment("FIXTURE_ROLE")]
      mutations = [
        ("fixture/tools:4.0.0", "fixture/tools:4.1.0"),
        (#""executable": "docker""#, #""executable": "echo""#),
      ]
    case "oci-digest":
      bindings = [:]
      mutations = [
        (digest, String(repeating: "b", count: 64)),
        ("images.example.invalid", "alternate.example.invalid"),
      ]
    case "http":
      bindings = [:]
      mutations = [(#""kind": "streamableHTTP""#, #""kind": "sse""#), ("/stream", "/elsewhere")]
    default:
      bindings = [:]
      mutations = [(#""kind": "sse""#, #""kind": "streamableHTTP""#)]
    }

    let store = StateStore(scope: .project, environment: environment)
    let destination = try UpdateOperations.inspect(environment: environment)
    let request = try choice.select(
      named: "selected", agents: [.claudeCode], in: destination, bindings: bindings,
      packageCommand: variant == "pypi" ? "fixture-console" : nil
    ).updateRequest()
    let preview = try UpdateOperations.preview(request, environment: environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: environment) {
      try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let original = try String(contentsOf: store.declarationURL, encoding: .utf8)
    let originalLock = try Data(contentsOf: store.resolvedURL)
    let native = environment.projectDirectory.appendingPathComponent(".mcp.json")
    let expectedNative = try Data(contentsOf: native)
    let component = try #require(store.loadDeclaration().components.first)
    guard case .mcpServer(_, let transport, _, _, _, let recorded) = component else {
      Issue.record("Expected a parsed MCP declaration")
      return
    }
    let evidence = try #require(recorded)
    #expect(evidence.invocationDigest?.hasPrefix("sha256:") == true)
    #expect(
      try evidence.portableLiteralBindings(in: transport)
        == (variant == "npm" ? ["FIXTURE_MODE"] : []))
    #expect(!(try OrganizationPolicyOperations.audit(environment: environment)).isBlocked)
    if variant == "npm" {
      let state = try UpdateOperations.inspect(environment: environment)
      let package = BundlePackage(name: "fixture-registry", version: "1.0.0")
      let bytes = try BundleOperations.export(
        package, selections: state.components.map(\.selection), scope: .project,
        environment: environment)
      let member = try #require(BundleOperations.inspect(bytes).components.first)
      #expect(member.mcpRegistry == evidence)
    }
    for (initial, replacement) in mutations {
      let edited = original.replacingOccurrences(of: initial, with: replacement)
      try #require(edited != original)
      try Data(edited.utf8).write(to: store.declarationURL)
      #expect(throws: CoreError.self) { try store.loadDeclaration() }
      #expect(throws: CoreError.self) { try UpdateOperations.preview(environment: environment) }
      do {
        _ = try OrganizationPolicyOperations.audit(environment: environment)
        Issue.record("CI admitted a changed MCP declaration")
      } catch let error as CoreError {
        #expect(error.description.contains("does not match the configured invocation"))
        #expect(error.description.contains("Reselect the exact MCP registry version"))
      }
    }
    #expect(try Data(contentsOf: store.resolvedURL) == originalLock)
    #expect(try Data(contentsOf: native) == expectedNative)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("launched").path))
    if variant == "pypi" {
      try Data(original.utf8).write(to: store.declarationURL)
      let alteredLock = String(decoding: originalLock, as: UTF8.self)
        .replacingOccurrences(of: "fixture-console", with: "different-console")
      try #require(Data(alteredLock.utf8) != originalLock)
      try Data(alteredLock.utf8).write(to: store.resolvedURL)
      #expect(throws: CoreError.self) {
        try SourcePolicyOperations.audit(environment: environment)
      }
      #expect(throws: CoreError.self) {
        try UpdateOperations.restore(environment: environment)
      }
      #expect(try Data(contentsOf: native) == expectedNative)
    }
  }

  @Test func legacyRegistryLockReplaysAndRequiresReselectionForRegistryOnlyPolicy() throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    var environment = try fixture.initializedEnvironment()
    let store = StateStore(scope: .project, environment: environment)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let original = """
      version: 1
      components:
        - kind: mcpServer
          name: selected
          agents: [claude-code]
          transport:
            kind: stdio
            executable: uvx
            arguments: [--default-index, 'https://pypi.org/simple', --from, 'fixture-tools==3.0.0', --, fixture-console]
            environment: {FIXTURE_PROFILE: safe}
          registry:
            registry: https://registry.example.invalid
            server: test.example/tool
            version: 1.0.0
            origin: https://pypi.org
            package: 'fixture-tools==3.0.0'

      """
    try Data(original.utf8).write(to: store.declarationURL)
    _ = try UpdateOperations.withPreparedUpdate(environment: environment) { try $0.apply() }
    _ = try UpdateOperations.restore(environment: environment)
    let item = try #require(UpdateOperations.inspect(environment: environment).components.first)
    let evidence = try #require(item.mcpRegistry)
    #expect(evidence.package == "fixture-tools==3.0.0")
    #expect(evidence.invocationDigest == nil)
    let component = try #require(store.loadDeclaration().components.first)
    guard case .mcpServer(_, let transport, _, _, _, _) = component else {
      Issue.record("Expected a parsed MCP declaration")
      return
    }
    do {
      _ = try evidence.portableLiteralBindings(in: transport)
      Issue.record("Legacy literal was classified without Registry selection evidence")
    } catch let error as CoreError {
      #expect(error.description.contains("Reselect the exact MCP registry version"))
    }
    environment.userOrganizationPolicy = try fixture.registryOnlyPolicy()
    let audit = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(audit.isBlocked)
    let findings = audit.organization.findings.filter { $0.rule == "mcp-registry-evidence" }
    #expect(findings.contains { $0.message.contains("Reselect the exact MCP registry version") })
    #expect(throws: OrganizationPolicyFailure.self) {
      try UpdateOperations.restore(environment: environment)
    }

    let mismatched = original.replacingOccurrences(
      of: "--from, 'fixture-tools==3.0.0'", with: "--from, 'different-tools==3.0.0'")
    try #require(mismatched != original)
    try Data(mismatched.utf8).write(to: store.declarationURL)
    #expect(throws: CoreError.self) { try store.loadDeclaration() }
  }

  @Test func cacheSeparatesQueriesAndProjectsAndChecksPolicyBeforeReuse() async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let reply = RegistryResponses([
      .init(headers: ["cache-control": "max-age=3600", "vary": "Accept"], version: "1.0.0"),
      .init(headers: ["cache-control": "max-age=3600"], version: "2.0.0"),
      .init(headers: ["cache-control": "max-age=3600"], version: "3.0.0"),
    ])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      let first = try await fixture.registry.search("a+b", environment: fixture.environment)
      #expect(first.servers.first?.version == "1.0.0")
      var independent = fixture.environment
      independent.projectDirectory = fixture.root.appendingPathComponent("second")
      let warm = try await fixture.registry.search("a+b", environment: independent)
      #expect(warm.servers.first?.version == "1.0.0")
      #expect(await reply.calls.count == 1)
      var proxyOnly = independent
      proxyOnly.sourceAccess = .init(egress: .proxyOnly)
      await #expect(throws: SourceAccessError.egressDenied) {
        _ = try await fixture.registry.search("a+b", environment: proxyOnly)
      }
      #expect(await reply.calls.count == 1)
      let other = try await fixture.registry.search("a b", environment: independent)
      #expect(other.servers.first?.version == "2.0.0")
      let refreshed = try await fixture.registry.search(
        "a+b", environment: independent, refresh: true)
      #expect(refreshed.servers.first?.version == "3.0.0")
      let policy = SourcePolicyOperations.policyURL(scope: .project, environment: independent)
      try FileManager.default.createDirectory(
        at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("version: 1\ndeny: [{http: 'https://registry.example.invalid'}]\n".utf8)
        .write(to: policy)
      await #expect(throws: SourcePolicyFailure.self) {
        try await fixture.registry.search("a+b", environment: independent)
      }
      #expect(await reply.calls.count == 3)
      #expect(try fixture.cache.inspect().entries.map(\.store) == [.http, .http])
    }
  }

  @Test func staleEntriesRevalidateAndNoStoreOn304EvictsImmediately() async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let reply = RegistryResponses([
      .init(headers: ["cache-control": "max-age=0", "etag": "\"v1\""]),
      .init(status: 304, headers: ["cache-control": "max-age=60, no-store", "etag": "\"v1\""]),
    ])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      _ = try await fixture.registry.search(environment: fixture.environment)
      #expect(try fixture.cache.inspect().entries.count == 1)
      let revalidated = try await fixture.registry.search(environment: fixture.environment)
      #expect(revalidated.servers.first?.version == "1.0.0")
      #expect(await reply.calls.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
      #expect(try fixture.cache.inspect().entries.isEmpty)
      await #expect(throws: MCPRegistryError.requestFailed) {
        try await fixture.registry.search(environment: fixture.environment)
      }
      #expect(await reply.calls.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }
  }

  @Test(arguments: [
    ["cache-control": "max-age=3600, no-cache", "etag": "\"v1\""],
    ["cache-control": "max-age=3600, private"],
    ["cache-control": "max-age=3600", "vary": "Accept-Language"],
    ["cache-control": "max-age=3600", "vary": "*"],
    ["cache-control": "max-age=3600", "set-cookie": "session=fixture"],
  ])
  func ineligibleResponsesAlwaysFetchAndFailOffline(headers: [String: String]) async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let reply = RegistryResponses([
      .init(headers: headers, version: "1.0.0"),
      .init(headers: headers, version: "2.0.0"),
    ])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      let first = try await fixture.registry.search(environment: fixture.environment)
      #expect(first.servers.first?.version == "1.0.0")
      let other = try await fixture.registry.search(environment: fixture.environment)
      #expect(other.servers.first?.version == "2.0.0")
      await #expect(throws: MCPRegistryError.requestFailed) {
        try await fixture.registry.search(environment: fixture.environment)
      }
      #expect(await reply.calls.count == 3)
      #expect(try fixture.cache.inspect().entries.isEmpty)
    }
  }

  @Test func changedVaryForcesAnUnconditionalFetchAndCredentialsCannotReadPublicEntries()
    async throws
  {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let reply = RegistryResponses([
      .init(headers: ["cache-control": "max-age=0", "etag": "\"v1\""]),
      .init(status: 304, headers: ["vary": "Accept-Language"]),
      .init(headers: ["cache-control": "max-age=3600"], version: "2.0.0"),
      .init(headers: ["cache-control": "max-age=3600"], version: "8.0.0"),
    ])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      _ = try await fixture.registry.search(environment: fixture.environment)
      let fresh = try await fixture.registry.search(environment: fixture.environment)
      #expect(fresh.servers.first?.version == "2.0.0")
      let privateResult = try await fixture.registry.search(
        credentials: ["X-Key": "fixture-key"], environment: fixture.environment)
      #expect(privateResult.servers.first?.version == "8.0.0")
      let warm = try await fixture.registry.search(environment: fixture.environment)
      #expect(warm.servers.first?.version == "2.0.0")
      let calls = await reply.calls
      #expect(
        calls.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [
          nil, "\"v1\"", nil, nil,
        ])
      #expect(calls.last?.value(forHTTPHeaderField: "X-Key") == "fixture-key")
      #expect(try fixture.cache.inspect().entries.count == 1)
    }
  }

  @Test func validatorsRefreshFreshnessOnceAndStaleErrorsRemainExplicit() async throws {
    let fixture = try RegistryAcquisitionFixture()
    defer { fixture.remove() }
    let reply = RegistryResponses([
      .init(headers: ["cache-control": "max-age=20", "age": "21", "etag": "\"v1\""]),
      .init(status: 304, headers: ["cache-control": "max-age=120", "etag": "\"v1\""]),
    ])
    try await RegistryAcquisition.$transport.withValue(reply.transport) {
      _ = try await fixture.registry.search(environment: fixture.environment)
      _ = try await fixture.registry.search(environment: fixture.environment)
      _ = try await fixture.registry.search(environment: fixture.environment)
      #expect(await reply.calls.count == 2)
      await #expect(throws: MCPRegistryError.requestFailed) {
        try await fixture.registry.search(environment: fixture.environment, refresh: true)
      }
    }
    let stale = RegistryResponses([
      .init(headers: [
        "cache-control": "max-age=0", "last-modified": "Tue, 24 Nov 2026 08:00:00 GMT",
      ])
    ])
    try await RegistryAcquisition.$transport.withValue(stale.transport) {
      _ = try await fixture.registry.search("stale", environment: fixture.environment)
      await #expect(throws: MCPRegistryError.requestFailed) {
        try await fixture.registry.search("stale", environment: fixture.environment)
      }
      #expect(
        await stale.calls.last?.value(forHTTPHeaderField: "If-Modified-Since")
          == "Tue, 24 Nov 2026 08:00:00 GMT")
    }
  }
}

private struct RegistryAcquisitionFixture {
  let root: URL
  let registry: MCPRegistry
  let environment: RuntimeEnvironment
  var cache: AcquisitionCache { AcquisitionCache(environment: environment) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-registry-acquisition-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    registry = try MCPRegistry(endpoint: URL(string: "https://registry.example.invalid")!)
    environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"), environment: [:],
      acquisitionCacheRoot: root.appendingPathComponent("cache"))
  }

  func initializedEnvironment() throws -> RuntimeEnvironment {
    for directory in [environment.projectDirectory, environment.homeDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let launcher = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: launcher, withIntermediateDirectories: false)
    for command in ["npx", "uvx", "docker"] {
      let program = launcher.appendingPathComponent(command)
      try Data("#!/bin/sh\n/usr/bin/touch '\(root.appendingPathComponent("launched").path)'\n".utf8)
        .write(to: program)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }
    var runtime = environment
    runtime.environment["PATH"] = launcher.path + ":/usr/bin:/bin"
    return runtime
  }

  func registryOnlyPolicy() throws -> OrganizationPolicySelection {
    let file = root.appendingPathComponent("organization.yaml")
    try Data("enforcement: block\nmcp: {self_defined: deny}\n".utf8).write(to: file)
    return .init(.local(file))
  }

  func definition(_ json: String, environment: RuntimeEnvironment) async throws -> MCPRegistryServer
  {
    let transport: @Sendable (URLRequest) async throws -> RegistryHTTP.Response = { request in
      .init(url: request.url!, status: 200, headers: [:], body: Data(json.utf8))
    }
    return try await RegistryAcquisition.$transport.withValue(transport) {
      try await registry.server(
        named: "test.example/tool", version: "1.0.0", environment: environment)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor RegistryResponses {
  struct Reply: Sendable {
    var status = 200
    var headers: [String: String]
    var version = "1.0.0"
  }

  private let responses: [Reply]
  private(set) var calls: [URLRequest] = []

  init(_ responses: [Reply]) { self.responses = responses }

  nonisolated var transport: @Sendable (URLRequest) async throws -> RegistryHTTP.Response {
    { try await self.request($0) }
  }

  func request(_ request: URLRequest) throws -> RegistryHTTP.Response {
    calls.append(request)
    guard calls.count <= responses.count else { throw MCPRegistryError.requestFailed }
    let reply = responses[calls.count - 1]
    let body = """
      {"servers":[{"server":{"name":"test.example/tool","version":"\(reply.version)","description":"fixture"}}]}
      """
    return .init(
      url: request.url!, status: reply.status, headers: reply.headers,
      body: reply.status == 200 ? Data(body.utf8) : Data())
  }
}
