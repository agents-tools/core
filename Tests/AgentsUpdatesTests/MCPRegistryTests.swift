import AgentsCore
import Foundation
import StateTestSupport
import Testing

@testable import AgentsUpdates

@Suite struct MCPRegistryTests {
  @Test func configuredRegistryKeepsTheOperatorPrefixAndRejectsInvalidSettings() throws {
    var environment = RuntimeEnvironment(environment: [:])
    #expect(
      try MCPRegistry.configured(environment: environment).endpoint == MCPRegistry.official.endpoint
    )
    environment.environment["MCP_REGISTRY_URL"] = "https://packages.example.invalid/team/registry"
    let registry = try MCPRegistry.configured(environment: environment)
    #expect(registry.endpoint.absoluteString == "https://packages.example.invalid/team/registry")
    environment.environment["MCP_REGISTRY_URL"] = "registry.invalid/path"
    #expect(throws: MCPRegistryError.invalidEndpoint) {
      try MCPRegistry.configured(environment: environment)
    }
  }

  @Test func discoveryPaginatesAndLooksUpAnExactVersionWithoutChangingScope() async throws {
    let fixture = try await RegistryFixture.start()
    let registry = try fixture.registry("/private")
    let before = try fixture.scopeContents()
    let page = try await registry.search(
      "fixture +&/", limit: 1, credentials: fixture.credentials, environment: fixture.environment)
    let entry = try #require(page.servers.first)
    #expect(page.servers.count == 1)
    #expect(entry.name == "dev.example/fixture")
    #expect(entry.title == "Fixture tools")
    #expect(entry.version == "1.2.3+build")
    #expect(entry.status == "active")
    #expect(entry.registry == registry.endpoint)
    #expect(entry.choices.map(\.transport).prefix(2) == ["streamable-http", "sse"])
    let cursor = try #require(page.nextCursor)
    #expect(cursor == "dev.example/fixture:1.2.3+build & next=%")
    let next = try await registry.search(
      "fixture +&/", limit: 1, cursor: cursor, credentials: fixture.credentials,
      environment: fixture.environment)
    #expect(next.servers.isEmpty && next.nextCursor == nil)

    let exact = try await registry.server(
      named: entry.name, version: entry.version, credentials: fixture.credentials,
      environment: fixture.environment)
    #expect(exact.version == entry.version)
    let latest = try await registry.server(
      named: entry.name, credentials: fixture.credentials, environment: fixture.environment)
    #expect(latest.version == exact.version)
    await #expect(throws: MCPRegistryError.invalidResponse) {
      try await registry.server(
        named: entry.name, version: "wrong-version", credentials: fixture.credentials,
        environment: fixture.environment)
    }
    await #expect(throws: MCPRegistryError.httpStatus(401)) {
      try await registry.search()
    }

    let requests = try fixture.requests()
    #expect(requests[0].target.contains("search=fixture%20%2B%26%2F"))
    #expect(requests[0].target.contains("version=latest"))
    #expect(
      requests[1].target.contains("cursor=dev.example%2Ffixture%3A1.2.3%2Bbuild%20%26%20next%3D%25")
    )
    #expect(
      requests[2].target == "/private/v0.1/servers/dev.example%2Ffixture/versions/1.2.3%2Bbuild")
    #expect(requests[3].target.hasSuffix("/versions/latest"))
    #expect(requests.dropLast().allSatisfy { $0.authorization && $0.apiKey })
    #expect(requests.last?.authorization == false && requests.last?.apiKey == false)
    #expect(requests.allSatisfy { !$0.cookie })
    #expect(try fixture.scopeContents() == before)
  }

  @Test func requestsAdmitExplicitCredentialsAndRejectRedirectsBeforeForwarding() async throws {
    let fixture = try await RegistryFixture.start()
    for path in ["/cross-origin", "/same-origin"] {
      let registry = try fixture.registry(path)
      await #expect(throws: MCPRegistryError.redirectRejected) {
        try await registry.search(
          credentials: fixture.credentials, environment: fixture.environment)
      }
    }
    #expect(
      try fixture.requests().map(\.target) == [
        "/cross-origin/v0.1/servers?limit=20&version=latest",
        "/same-origin/v0.1/servers?limit=20&version=latest",
      ])
    let registry = try fixture.registry("/public")
    await #expect(throws: MCPRegistryError.invalidCredentials) {
      try await registry.search(credentials: ["Host": "other.example.invalid"])
    }
    await #expect(throws: MCPRegistryError.invalidCredentials) {
      try await registry.search(credentials: ["X-Key": "one\r\nInjected: two"])
    }
    let unsecured = try MCPRegistry(endpoint: URL(string: "http://registry.example.invalid")!)
    await #expect(throws: MCPRegistryError.invalidCredentials) {
      try await unsecured.search(credentials: fixture.credentials, environment: fixture.environment)
    }
    #expect(throws: MCPRegistryError.invalidEndpoint) {
      try MCPRegistry(endpoint: URL(string: "https://user:password@registry.example.invalid")!)
    }
    #expect(throws: MCPRegistryError.invalidEndpoint) {
      try MCPRegistry(endpoint: URL(string: "https://registry.example.invalid/?key=one")!)
    }
    let page = try await registry.search(version: nil)
    #expect(page.servers.count == 1)
    let last = try #require(fixture.requests().last)
    #expect(last.target == "/public/v0.1/servers?limit=20")
    #expect(!last.authorization && !last.apiKey && !last.cookie)
  }

  @Test func rejectsOversizeAndCancelsAnInFlightRequest() async throws {
    let fixture = try await RegistryFixture.start()
    let oversize = try fixture.registry("/large")
    await #expect(throws: MCPRegistryError.responseTooLarge) {
      try await oversize.search()
    }
    let slow = try fixture.registry("/slow")
    let request = Task { try await slow.search() }
    defer { request.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while try !fixture.requests().contains(where: { $0.target.hasPrefix("/slow/") }) {
      try #require(clock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
  }

  @Test func selectedRemoteBecomesAProjectMCPDeclarationWithAReference() async throws {
    let fixture = try await RegistryFixture.start()
    let registry = try fixture.registry("/private")
    let entry = try await registry.server(
      named: "dev.example/fixture", credentials: fixture.credentials,
      environment: fixture.environment)
    let remote = try #require(entry.choices.first)
    guard case .remote(let endpoint) = remote.source else {
      Issue.record("Expected a remote choice")
      return
    }
    #expect(endpoint?.absoluteString == "https://tools.example.invalid/v2/mcp")
    #expect(remote.bindings.map(\.name) == ["Authorization", "X-Mode", "X-Profile"])
    #expect(remote.bindings.first?.isRequired == true && remote.bindings.first?.isSecret == true)
    #expect(remote.bindings[1].defaultValue == "steady")
    #expect(remote.bindings[2].defaultValue == "safe")
    #expect(remote.bindings[2].choices == ["fast", "safe"])
    let environment = fixture.environment
    let destination = try UpdateOperations.inspect(environment: environment)
    #expect(throws: MCPRegistryError.missingBinding("Authorization")) {
      try remote.select(named: "fixture", agents: [.codex], in: destination)
    }
    #expect(throws: MCPRegistryError.invalidBinding("Authorization")) {
      try remote.select(
        named: "fixture", agents: [.codex], in: destination,
        bindings: ["Authorization": .environment("Bearer raw-token")])
    }
    let defaults = ["Authorization": MCPRegistryBinding.environment("FIXTURE_SERVICE_AUTH")]
    #expect(throws: MCPRegistryError.missingBinding("X-Profile")) {
      try remote.compatibleAgents(in: .project, bindings: defaults)
    }
    #expect(throws: MCPRegistryError.invalidBinding("X-Profile")) {
      try remote.compatibleAgents(
        in: .project,
        bindings: defaults.merging(["X-Profile": .choice("unknown")]) { _, new in new }
      )
    }
    let defaultRequest = try remote.select(
      named: "fixture-default", agents: [.codex], in: destination,
      bindings: defaults.merging(["X-Profile": .choice("safe")]) { _, new in new }
    ).updateRequest()
    let defaultPreview = try UpdateOperations.preview(defaultRequest, environment: environment)
    #expect(defaultPreview.components.first?.symbolicAfter?.contains("steady") == true)

    let references: [String: MCPRegistryBinding] = [
      "Authorization": .environment("FIXTURE_SERVICE_AUTH"), "X-Profile": .choice("fast"),
      "X-Mode": .environment("FIXTURE_MODE"),
    ]
    #expect(
      Set(try remote.compatibleAgents(in: .project, bindings: references))
        == [.codex, .claudeCode, .geminiCLI])
    #expect(throws: (any Error).self) {
      try remote.select(
        named: "fixture", agents: [.opencode], in: destination, bindings: references)
    }
    let sse = try #require(entry.choices.first { $0.transport == "sse" })
    #expect(Set(try sse.compatibleAgents(in: .project)) == [.claudeCode, .geminiCLI])
    let sseRequest = try sse.select(named: "legacy", agents: [.claudeCode], in: destination)
      .updateRequest()
    let ssePreview = try UpdateOperations.preview(sseRequest, environment: environment)
    #expect(ssePreview.components.first?.symbolicAfter?.contains("sse") == true)

    // A registry response can change after selection. Publication uses the captured choice.
    let discovery = try remote.select(
      named: "fixture", agents: [.codex, .claudeCode], in: destination,
      bindings: references)
    let request = discovery.updateRequest()
    let requestsBefore = try fixture.requests().count
    let before = try fixture.scopeContents()
    try fixture.replaceRegistryEndpoint(with: "https://replacement.example.invalid")
    let refreshed = try await registry.server(
      named: entry.name, version: entry.version, credentials: fixture.credentials,
      environment: fixture.environment)
    #expect(
      try #require(refreshed.choices.first).sourceEndpoint?.host == "replacement.example.invalid")
    let report = try UpdateOperations.preview(request, environment: environment)
    #expect(report.hasChanges && report.components.count == 2)
    #expect(
      report.components.allSatisfy {
        $0.name == "fixture" && !$0.privateMaterialization
          && $0.symbolicAfter?.contains("FIXTURE_SERVICE_AUTH") == true
      })
    #expect(try fixture.scopeContents() == before)

    _ = try UpdateOperations.withPreparedUpdate(request, environment: environment) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    let state = try UpdateOperations.inspect(environment: environment)
    let transport = MCPTransportDeclaration.streamableHTTP(
      url: "https://tools.example.invalid/v2/mcp",
      headers: [
        "Authorization": .environment("FIXTURE_SERVICE_AUTH"), "X-Schema": .literal("2"),
        "X-Mode": .environment("FIXTURE_MODE"), "X-Profile": .literal("fast"),
      ])
    let evidence = try #require(state.components.first?.mcpRegistry)
    #expect(
      state.declaration?.components == [
        .mcpServer(
          name: "fixture", transport: transport, agents: [.codex, .claudeCode], registry: evidence)
      ])
    #expect(evidence.registry == registry.endpoint.absoluteString)
    #expect(evidence.server == entry.name && evidence.version == entry.version)
    #expect(evidence.origin == "https://tools.example.invalid" && evidence.package == nil)
    #expect(try evidence.portableLiteralBindings(in: transport) == ["X-Schema", "X-Profile"])
    #expect(state.components.first?.version == entry.version)
    let exportedPackage = BundlePackage(name: "shared-remote", version: "1.0.0")
    #expect(throws: CoreError.self) {
      try BundleOperations.export(
        exportedPackage, selections: state.components.map(\.selection), scope: .project,
        environment: environment, registrySchemas: [refreshed])
    }
    let portable = try BundleOperations.inspect(
      BundleOperations.export(
        exportedPackage, selections: state.components.map(\.selection), scope: .project,
        environment: environment, registrySchemas: [entry]))
    #expect(
      portable.components.first?.transport
        == .streamableHTTP(
          url: "https://tools.example.invalid/v2/mcp",
          headers: [
            "Authorization": .environment("FIXTURE_SERVICE_AUTH"), "X-Schema": .literal("2"),
            "X-Mode": .environment("FIXTURE_MODE"), "X-Profile": .literal("fast"),
          ]))
    let home = environment.homeDirectory
    #expect(
      !FileManager.default.fileExists(
        atPath: home.appendingPathComponent(".codex/config.toml").path))
    let codex = try fixture.text("project/.codex/config.toml")
    #expect(codex.contains("https://tools.example.invalid/v2/mcp"))
    #expect(codex.contains("env_http_headers") && codex.contains("FIXTURE_SERVICE_AUTH"))
    let claude = try fixture.text("project/.mcp.json")
    #expect(claude.contains("\"Authorization\": \"${FIXTURE_SERVICE_AUTH}\""))
    #expect(try fixture.requests().count == requestsBefore + 1)
    try fixture.checkPublishedValues(scope: .project, native: [codex, claude])
  }

  @Test func scopePolicyChecksTheRegistryAndSelectedEndpointThroughReplay() async throws {
    let fixture = try await RegistryFixture.start()
    let registry = try fixture.registry("/public")
    let environment = fixture.environment
    let store = StateStore(scope: .project, environment: environment)
    let projectPolicy = SourcePolicyOperations.policyURL(scope: .project, environment: environment)
    let userPolicy = SourcePolicyOperations.policyURL(scope: .user, environment: environment)
    let registryOrigin = try SourceOrigin.http(registry.endpoint.absoluteString)
    let endpointOrigin = try SourceOrigin.http("https://tools.example.invalid")
    try fixture.writePolicy("deny: [{http: '\(registry.endpoint.absoluteString)'}]", to: userPolicy)
    await #expect(throws: SourcePolicyFailure.self) {
      try await registry.server(named: "dev.example/fixture", environment: environment)
    }
    #expect(try fixture.requests().isEmpty)
    try FileManager.default.removeItem(at: userPolicy)
    let entry = try await registry.server(
      named: "dev.example/fixture", environment: fixture.environment)
    let remote = try #require(entry.choices.first)
    let destination = try UpdateOperations.inspect(environment: environment)
    let bindings: [String: MCPRegistryBinding] = [
      "Authorization": .environment("FIXTURE_SERVICE_AUTH"), "X-Profile": .choice("safe"),
    ]
    try fixture.writePolicy(
      "allow: [inline, {http: '\(registry.endpoint.absoluteString)'}]\n"
        + "deny: [{http: 'https://tools.example.invalid'}]", to: projectPolicy)
    let before = try fixture.scopeContents()
    do {
      _ = try remote.select(named: "fixture", agents: [.codex], in: destination, bindings: bindings)
      Issue.record("Selected a server with a denied endpoint")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.origin) == [endpointOrigin])
      #expect(failure.violations.map(\.reason) == [.denied])
    }
    #expect(try fixture.scopeContents() == before)
    let allowed =
      "allow: [{http: '\(registry.endpoint.absoluteString)'}, "
      + "{http: 'https://tools.example.invalid'}]"
    try fixture.writePolicy(allowed, to: projectPolicy)
    let request = try remote.select(
      named: "fixture", agents: [.codex], in: destination, bindings: bindings
    ).updateRequest()
    let preview = try UpdateOperations.preview(request, environment: environment)
    try fixture.writePolicy("deny: [{http: '\(registry.endpoint.absoluteString)'}]", to: userPolicy)
    do {
      _ = try UpdateOperations.withPreparedUpdate(request, environment: environment) {
        try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
      }
      Issue.record("Published a selection after its registry was denied")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.origin) == [registryOrigin])
      #expect(failure.violations.map(\.scope) == [.user])
    }
    #expect(try fixture.snapshot(environment: environment).isEmpty)
    try FileManager.default.removeItem(at: userPolicy)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: environment) { update in
      try update.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let ledger = try store.loadLedger()
    let component = try #require(ledger.components.values.first)
    #expect(component.version == entry.version)
    #expect(component.mcpRegistry?.registry == registry.endpoint.absoluteString)
    #expect(component.mcpRegistry?.origin == endpointOrigin.identity)
    #expect(try SourcePolicyOperations.audit(environment: environment).violations.isEmpty)

    var restricted = environment
    let organization = fixture.root.appendingPathComponent("team-policy.yaml")
    try fixture.writePolicy("deny: [{http: 'https://tools.example.invalid'}]", to: organization)
    restricted.organizationSourcePolicyURL = organization
    let audit = try SourcePolicyOperations.audit(environment: restricted)
    #expect(audit.violations.map(\.scope) == [.organization])
    #expect(audit.violations.map(\.origin) == [endpointOrigin])
    let installed = try fixture.snapshot(environment: restricted)
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.preview(environment: restricted)
    }
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.restore(environment: restricted)
    }
    #expect(try fixture.snapshot(environment: restricted) == installed)
    #expect(try fixture.requests().count == 1)
  }

  @Test func forwardedRegistryBundleAndLocalTeamCatalogRetainOriginalOrigins() async throws {
    let fixture = try await RegistryFixture.start()
    let registry = try fixture.registry("/public")
    let publisher = fixture.environment
    let entry = try await registry.server(
      named: "dev.example/fixture", environment: fixture.environment)
    let choice = try #require(entry.choice(packageType: "npm"))
    let request = try choice.select(
      named: "team-server", agents: [.codex], in: UpdateOperations.inspect(environment: publisher),
      bindings: [
        "FIXTURE_PACKAGE_TOKEN": .environment("FIXTURE_PACKAGE_TOKEN"),
        "FIXTURE_LOG_LEVEL": .choice("info"),
      ]
    ).updateRequest()
    _ = try UpdateOperations.withPreparedUpdate(request, environment: publisher) { try $0.apply() }
    let publisherScope = try UpdateOperations.inspect(environment: publisher)
    let evidence = try #require(publisherScope.components.first?.mcpRegistry)
    #expect(evidence.package == "@fixture/tools@2.0.0")
    let package = BundlePackage(name: "team-kit", version: "1.0.0")
    let offlineExport = try BundleOperations.export(
      package, selections: publisherScope.components.map(\.selection), scope: .project,
      environment: publisher)
    let bytes = try BundleOperations.export(
      package, selections: publisherScope.components.map(\.selection), scope: .project,
      environment: publisher, registrySchemas: [entry])
    try fixture.replaceRegistryEndpoint(
      "https://npm.example.invalid", with: "https://npm.example.invalid/other-index")
    let otherIndex = try await registry.server(
      named: entry.name, version: entry.version,
      environment: publisher)
    #expect(throws: CoreError.self) {
      try BundleOperations.export(
        package, selections: publisherScope.components.map(\.selection), scope: .project,
        environment: publisher, registrySchemas: [otherIndex])
    }
    #expect(offlineExport == bytes)
    let bundle = try BundleOperations.inspect(bytes)
    let member = try #require(bundle.components.first)
    #expect(member.mcpRegistry == evidence)
    guard case .stdio(let run) = member.transport else {
      Issue.record("Expected a captured stdio server")
      return
    }
    #expect(run.environment["FIXTURE_LOG_LEVEL"] == .literal("info"))
    #expect(run.environment["FIXTURE_PACKAGE_TOKEN"] == .environment("FIXTURE_PACKAGE_TOKEN"))
    let authorCapture = try AuthorPackageOperations.preview(
      .init(
        package: package, lockedMembers: [.init(kind: .mcpServer, name: "team-server")]),
      environment: publisher)
    #expect(authorCapture.inspection.components.first?.transport == member.transport)
    #expect(authorCapture.warnings.isEmpty)
    let reviewFile = fixture.root.appendingPathComponent("author-review.bundle")
    try AuthorPackageOperations.write(authorCapture, to: reviewFile, environment: publisher)
    let reread = try AuthorPackageOperations.readArchive(
      at: reviewFile, expectedDigest: authorCapture.digest, environment: publisher)
    #expect(reread.archive == authorCapture.archive)
    #expect(
      Set(member.sources.compactMap(\.origin))
        == Set(
          try [
            SourceOrigin.http(registry.endpoint.absoluteString), SourceOrigin.http(evidence.origin),
          ]))

    let consumer = try fixture.consumer("consumer")
    let projectPolicy = SourcePolicyOperations.policyURL(scope: .project, environment: consumer)
    let selections = [BundleImportSelection(componentID: member.id, targets: [.codex])]
    try fixture.writePolicy(
      "allow: [inline, local, {http: '\(registry.endpoint.absoluteString)'}]\n"
        + "deny: [{http: '\(evidence.origin)'}]", to: projectPolicy)
    #expect(throws: SourcePolicyFailure.self) {
      try BundleOperations.previewImport(
        bundle, selections: selections, scope: .project, environment: consumer)
    }
    #expect(try fixture.snapshot(environment: consumer).isEmpty)

    let catalog = fixture.root.appendingPathComponent("catalog")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
    let registration = try MarketplaceRegistration(
      name: "team", origin: .init(kind: .directory, location: catalog.path))
    let release = try MarketplaceOperations.publishBundle(
      bytes, to: catalog, environment: publisher)
    let catalogOrigin = try #require(SourceOrigin.local(at: catalog).identity)
    try fixture.writePolicy("deny: [{local: '\(catalogOrigin)'}]", to: projectPolicy)
    do {
      _ = try MarketplaceOperations.acquire(release, environment: consumer)
      Issue.record("Acquired a release from a denied catalog")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.origin) == [.local(at: catalog)])
      #expect(failure.violations.map(\.reason) == [.denied])
    }
    let allow =
      "allow: [{local: '\(catalogOrigin)'}, "
      + "{http: '\(registry.endpoint.absoluteString)'}, {http: '\(evidence.origin)'}]"
    try fixture.writePolicy(allow, to: projectPolicy)
    let listing = try MarketplaceOperations.browse(registration, environment: consumer)
    let acquired = try MarketplaceOperations.acquire(
      listing.select(package: package.name), environment: consumer)
    #expect(acquired.archive == bytes)
    let consumerStore = StateStore(scope: .project, environment: consumer)
    try BundleInstallation.withStagedSources(
      BundleOperations.inspect(acquired.archive), selections: selections, store: consumerStore
    ) { installation in
      var request = UpdateRequest()
      request.bundleInstallation = installation
      request = try acquired.bindingImport(
        request, as: "team", sourceAliases: installation.members.map(\.alias))
      let preview = try UpdateOperations.preview(request, environment: consumer)
      let denied = allow + "\ndeny: [{http: '\(evidence.origin)'}]"
      try fixture.writePolicy(denied, to: projectPolicy)
      #expect(throws: SourcePolicyFailure.self) {
        try UpdateOperations.withPreparedUpdate(request, environment: consumer) {
          try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
        }
      }
      #expect(try fixture.snapshot(environment: consumer).isEmpty)
      try fixture.writePolicy(allow, to: projectPolicy)
      _ = try UpdateOperations.withPreparedUpdate(request, environment: consumer) {
        try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
      }
    }
    let installed = try UpdateOperations.inspect(environment: consumer)
    #expect(installed.marketplacePackages.first?.catalogOrigin == .local(at: catalog))
    #expect(installed.components.first?.mcpRegistry == evidence)
    let resourceSource = try #require(installed.components.first?.sourceRecord)
    let sealed = try #require(consumerStore.loadLedger().sources[resourceSource]?.bundleSources)
    #expect(sealed.contains { $0.origin == .local(at: catalog) })
    #expect(try SourcePolicyOperations.audit(environment: consumer).violations.isEmpty)
    #expect(try !UpdateOperations.preview(environment: consumer).hasChanges)

    let forwarded = try BundleOperations.inspect(
      BundleOperations.export(
        .init(name: "forwarded-kit", version: "1.0.0"),
        selections: installed.components.map(\.selection),
        scope: .project, environment: consumer, registrySchemas: [entry]))
    let forwardedMember = try #require(forwarded.components.first)
    #expect(forwardedMember.mcpRegistry == evidence)
    #expect(Set(member.sources).isSubset(of: Set(forwardedMember.sources)))
    #expect(forwardedMember.sources.contains { $0.origin == .local(at: catalog) })
    #expect(
      forwardedMember.sources.contains {
        $0.packageName == package.name && $0.version == package.version
          && $0.revision == bundle.archiveDigest && $0.origin == .local(at: catalog)
      })

    let second = try fixture.consumer("second")
    let secondPolicy = SourcePolicyOperations.policyURL(scope: .project, environment: second)
    let forwardedSelections = [
      BundleImportSelection(
        componentID: forwardedMember.id, targets: [.codex])
    ]
    try fixture.writePolicy(allow + "\ndeny: [{local: '\(catalogOrigin)'}]", to: secondPolicy)
    #expect(throws: SourcePolicyFailure.self) {
      try BundleOperations.previewImport(
        forwarded, selections: forwardedSelections, scope: .project, environment: second)
    }
    #expect(try fixture.snapshot(environment: second).isEmpty)
    try fixture.writePolicy(allow, to: secondPolicy)
    let org = fixture.root.appendingPathComponent("recipient-organization.yaml")
    var deniedRecipient = second
    deniedRecipient.projectOrganizationPolicy = .init(.local(org))
    try fixture.writePolicy(
      "enforcement: block\ndependencies: {deny: ['_local/team-kit']}", to: org)
    #expect(throws: OrganizationPolicyFailure.self) {
      try BundleOperations.previewImport(
        forwarded, selections: forwardedSelections, scope: .project, environment: deniedRecipient)
    }
    let reinstallation = try BundleOperations.previewImport(
      forwarded, selections: forwardedSelections, scope: .project, environment: second)
    _ = try BundleOperations.withPreparedImport(reinstallation) { try $0.apply() }
    let before = try fixture.snapshot(environment: second)
    try fixture.writePolicy(allow + "\ndeny: [{http: '\(evidence.origin)'}]", to: secondPolicy)
    let violations = try SourcePolicyOperations.audit(environment: second).violations
    #expect(Set(violations.map(\.origin)) == [try SourceOrigin.http(evidence.origin)])
    #expect(throws: SourcePolicyFailure.self) { try UpdateOperations.preview(environment: second) }
    #expect(throws: SourcePolicyFailure.self) { try UpdateOperations.restore(environment: second) }
    #expect(try fixture.snapshot(environment: second) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.launchMarker.path))
    #expect(try fixture.requests().count == 2)
  }

  @Test func selectedPackageRegistersInUserScopeWithoutLaunchingTheDeclaredCommand() async throws {
    let fixture = try await RegistryFixture.start()
    let registry = try fixture.registry("/public")
    let entry = try await registry.server(
      named: "dev.example/fixture", environment: fixture.environment)
    let npm = try #require(entry.choice(packageType: "npm"))
    let region = try #require(npm.bindings.first { $0.name == "FIXTURE_REGION" })
    let logLevel = try #require(npm.bindings.first { $0.name == "FIXTURE_LOG_LEVEL" })
    #expect(region.defaultValue == "us")
    #expect(logLevel.choices == ["warn", "info"])
    #expect(throws: MCPRegistryError.missingBinding("FIXTURE_LOG_LEVEL")) {
      try npm.compatibleAgents(
        in: .user, bindings: ["FIXTURE_PACKAGE_TOKEN": .environment("FIXTURE_PACKAGE_TOKEN")])
    }
    let references: [String: MCPRegistryBinding] = [
      "FIXTURE_PACKAGE_TOKEN": .environment("FIXTURE_PACKAGE_TOKEN"),
      "FIXTURE_REGION": .environment("FIXTURE_REGION"),
      "FIXTURE_LOG_LEVEL": .choice("info"),
    ]
    #expect(
      Set(try npm.compatibleAgents(in: .user, bindings: references))
        == [.codex, .claudeCode, .geminiCLI])
    #expect(
      Set(
        try npm.compatibleAgents(
          in: .user,
          bindings: [
            "FIXTURE_PACKAGE_TOKEN": .environment("RENAMED_TOKEN"),
            "FIXTURE_LOG_LEVEL": .choice("warn"),
          ]))
        == [.claudeCode, .geminiCLI])

    let environment = fixture.environment
    let destination = try UpdateOperations.inspect(scope: .user, environment: environment)
    let discovery = try npm.select(
      named: "pkg", agents: [.codex], in: destination, bindings: references)
    let request = discovery.updateRequest()
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, scope: .project, environment: environment)
    }
    var changed = request
    changed.operation = .declaration(.init())
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(changed, scope: .user, environment: environment)
    }
    let report = try UpdateOperations.preview(request, scope: .user, environment: environment)
    #expect(report.components.first?.symbolicAfter?.contains("@fixture/tools@2.0.0") == true)
    #expect(try fixture.scopeContents().allSatisfy { $0.hasPrefix("launcher/") })
    _ = try UpdateOperations.withPreparedUpdate(request, scope: .user, environment: environment) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    let config = try fixture.text("home/.codex/config.toml")
    #expect(config.contains("npx") && config.contains("@fixture/tools@2.0.0"))
    #expect(config.contains("--port=8080") && config.contains("stdio-start"))
    #expect(config.contains("FIXTURE_PACKAGE_TOKEN") && config.contains("env_vars"))
    #expect(config.contains("FIXTURE_REGION") && config.contains("FIXTURE_LOG_LEVEL"))
    #expect(config.contains("\"info\""))
    #expect(
      !FileManager.default.fileExists(
        atPath: environment.projectDirectory.appendingPathComponent(".codex/config.toml").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchMarker.path))
    try fixture.checkPublishedValues(scope: .user, native: [config])
    #expect(!(try UpdateOperations.preview(scope: .user, environment: environment)).hasChanges)
  }

  @Test func packageChoicesPreserveExactCoordinatesAndReportUnsupportedVariants() async throws {
    let fixture = try await RegistryFixture.start()
    let entry = try await fixture.registry("/public").server(
      named: "dev.example/fixture", environment: fixture.environment)
    let environment = fixture.environment
    let destination = try UpdateOperations.inspect(environment: environment)
    let python = try #require(entry.choice(packageType: "pypi"))
    #expect(python.requiresPackageCommand)
    #expect(throws: MCPRegistryError.missingPackageCommand) {
      try python.compatibleAgents(in: .project)
    }
    #expect(throws: MCPRegistryError.invalidPackageCommand) {
      try python.compatibleAgents(in: .project, packageCommand: "../fixture-weather")
    }
    for (type, command, expected) in [
      ("pypi", Optional("fixture-weather"), ["uvx", "fixture_tools==2.3.0", "fixture-weather"]),
      ("oci", nil, ["docker", "ghcr.io/fixture/registry-mcp:3.5.0", "-i"]),
    ] {
      let selected = try #require(entry.choice(packageType: type))
      for scope in [InstallScope.project, .user] {
        #expect(
          try selected.compatibleAgents(in: scope, packageCommand: command).contains(.antigravity))
      }
      let request = try selected.select(
        named: type, agents: [.codex], in: destination, packageCommand: command
      ).updateRequest()
      let report = try UpdateOperations.preview(request, environment: environment)
      let rendered = try #require(report.components.first?.symbolicAfter)
      #expect(expected.allSatisfy { rendered.contains($0) })
    }
    #expect(entry.choice(packageType: "mcpb")?.unavailableReason?.contains("checksum") == true)
    #expect(entry.choices.filter { $0.unavailableReason != nil }.count == 5)
    let interactive = try #require(
      entry.choices.first {
        if case .package(let package) = $0.source {
          return package.identifier == "@fixture/interactive"
        }
        return false
      })
    #expect(interactive.unavailableReason?.contains("argument") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.launchMarker.path))
  }
}

extension MCPRegistryChoice {
  fileprivate var sourceEndpoint: URL? {
    if case .remote(let endpoint) = source { return endpoint }
    return nil
  }
}

extension MCPRegistryServer {
  fileprivate func choice(packageType: String) -> MCPRegistryChoice? {
    choices.first {
      if case .package(let package) = $0.source { return package.registryType == packageType }
      return false
    }
  }
}

private final class RegistryFixture {
  struct Request: Decodable {
    let target: String
    let authorization: Bool
    let apiKey: Bool
    let cookie: Bool
  }

  let root: URL
  let environment: RuntimeEnvironment
  let launchMarker: URL
  let credentials = [
    "Authorization": "Bearer registry-request-canary", "X-Registry-Key": "registry-key-canary",
  ]
  private let process = Process()
  private var port: Int?

  private init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-registry-" + UUID().uuidString)
    let launcher = root.appendingPathComponent("launcher")
    launchMarker = launcher.appendingPathComponent("started")
    environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"),
      environment: [
        "PATH": launcher.path + ":/usr/bin:/bin",
        "FIXTURE_SERVICE_AUTH": "Bearer service-runtime-canary",
        "FIXTURE_PACKAGE_TOKEN": "package-runtime-canary",
        "FIXTURE_REGION": "region-runtime-canary",
      ])
    for directory in [launcher, environment.projectDirectory, environment.homeDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for command in ["npx", "uvx", "docker"] {
      let executable = launcher.appendingPathComponent(command)
      try Data("#!/bin/sh\ntouch '\(launchMarker.path)'\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    try Data(Self.response.utf8).write(to: root.appendingPathComponent("response.json"))
    try Data().write(to: root.appendingPathComponent("requests.jsonl"))
  }

  static func start() async throws -> RegistryFixture {
    let fixture = try RegistryFixture()
    fixture.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    fixture.process.arguments = ["python3", "-c", server, fixture.root.path]
    fixture.process.standardOutput = FileHandle.nullDevice
    fixture.process.standardError = FileHandle.nullDevice
    try fixture.process.run()
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while fixture.process.isRunning {
      if let value = try? fixture.text("port"), let port = Int(value), (1...65535).contains(port) {
        fixture.port = port
        return fixture
      }
      // A resumed test may observe a readiness file published while it was suspended.
      guard clock.now < deadline else { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CoreError.invalidState("registry HTTP fixture did not start")
  }

  deinit {
    if process.isRunning {
      do { try ProcessWait.terminate(process, timeout: 3) } catch { Issue.record(error) }
    }
    try? FileManager.default.removeItem(at: root)
  }

  func consumer(_ name: String) throws -> RuntimeEnvironment {
    let environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent(name),
      homeDirectory: root.appendingPathComponent(name + "-home"), environment: [:])
    for directory in [environment.projectDirectory, environment.homeDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    return environment
  }

  func writePolicy(_ rules: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(("version: 1\n" + rules + "\n").utf8).write(to: url, options: .atomic)
  }

  func snapshot(environment: RuntimeEnvironment) throws -> [URL: Data] {
    let store = StateStore(scope: .project, environment: environment)
    let files = [
      store.declarationURL, store.resolvedURL,
      environment.projectDirectory.appendingPathComponent(".codex/config.toml"),
    ]
    return try Dictionary(
      uniqueKeysWithValues: files.compactMap { url in
        FileManager.default.fileExists(atPath: url.path) ? (url, try Data(contentsOf: url)) : nil
      })
  }

  func registry(_ path: String) throws -> MCPRegistry {
    try MCPRegistry(endpoint: URL(string: "http://127.0.0.1:\(try #require(port))" + path)!)
  }

  func text(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  func requests() throws -> [Request] {
    try text("requests.jsonl").split(separator: "\n").map {
      try JSONDecoder().decode(Request.self, from: Data($0.utf8))
    }
  }

  func scopeContents() throws -> [String] {
    try ["project", "home", "launcher"].flatMap { prefix in
      let contents = try FileManager.default.subpathsOfDirectory(
        atPath: root.appendingPathComponent(prefix).path)
      return contents.sorted().map { prefix + "/" + $0 }
    }
  }

  func replaceRegistryEndpoint(
    _ original: String = "https://tools.example.invalid", with replacement: String
  ) throws {
    let modified = Self.response.replacingOccurrences(
      of: original, with: replacement)
    try Data(modified.utf8).write(
      to: root.appendingPathComponent("response.json"), options: .atomic)
  }

  func checkPublishedValues(scope: InstallScope, native: [String]) throws {
    let store = StateStore(scope: scope, environment: environment)
    let texts =
      try native
      + [store.declarationURL, store.resolvedURL].map {
        try String(contentsOf: $0, encoding: .utf8)
      }
    for canary in [
      "registry-request-canary", "registry-key-canary", "service-runtime-canary",
      "package-runtime-canary", "region-runtime-canary", "publisher-has-secret",
    ] {
      #expect(!texts.contains(where: { $0.contains(canary) }))
    }
  }

  private static let response = #"""
    {
      "server": {
        "name": "dev.example/fixture", "title": "Fixture tools",
        "description": "An independently authored v0.1 fixture.", "version": "1.2.3+build",
        "remotes": [
          {"type": "streamable-http", "url": "https://tools.example.invalid/{route}/mcp",
           "variables": {"route": {"value": "v2"}},
           "headers": [
             {"name": "Authorization", "isRequired": true, "isSecret": true,
              "value": "Bearer {token}", "variables": {"token": {"default": "publisher-has-secret", "isSecret": true}}},
             {"name": "X-Schema", "value": "2"},
             {"name": "X-Mode", "default": "steady", "isRequired": true},
             {"name": "X-Profile", "default": "safe", "choices": ["fast", "safe"]}
           ]},
          {"type": "sse", "url": "https://tools.example.invalid/events"},
          {"type": "streamable-http", "url": "https://tools.example.invalid/mcp?api_key=publisher-has-secret"},
          {"type": "streamable-http", "url": "https://{tenant}.example.invalid/mcp",
           "variables": {"tenant": {"isRequired": true, "default": "can-change"}}}
        ],
        "packages": [
          {"registryType": "npm", "identifier": "@fixture/tools", "version": "2.0.0",
           "runtimeHint": "npx", "registryBaseUrl": "https://npm.example.invalid",
           "transport": {"type": "stdio"},
           "packageArguments": [{"type": "positional", "value": "stdio-start"},
                                {"type": "named", "name": "--port", "value": "{port}",
                                 "variables": {"port": {"value": "8080"}}}],
           "environmentVariables": [{"name": "FIXTURE_PACKAGE_TOKEN", "isRequired": true, "isSecret": true,
                                     "value": "publisher-has-secret"},
                                    {"name": "FIXTURE_REGION", "default": "us"},
                                    {"name": "FIXTURE_LOG_LEVEL", "choices": ["warn", "info"]}]},
          {"registryType": "npm", "identifier": "@fixture/interactive", "version": "2.0.0",
           "transport": {"type": "stdio"},
           "packageArguments": [{"type": "named", "name": "--port", "isRequired": true, "default": "8080"}]},
          {"registryType": "pypi", "identifier": "fixture_tools", "version": "2.3.0",
           "transport": {"type": "stdio"}},
          {"registryType": "oci", "identifier": "ghcr.io/fixture/registry-mcp:3.5.0",
           "transport": {"type": "stdio"}},
          {"registryType": "oci", "identifier": ":", "transport": {"type": "stdio"}},
          {"registryType": "mcpb", "identifier": "https://tools.example.invalid/tools.mcpb",
           "fileSha256": "80084795b3b4df6264cc2d2ace29f4b04ce1451a83d66cd22c8792f24f4bff63",
           "transport": {"type": "stdio"}}
        ]
      },
      "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active", "isLatest": true}}
    }
    """#

  private static let server = #"""
    import http.server, json, pathlib, socketserver, sys, threading, time, urllib.parse
    root = pathlib.Path(sys.argv[1])

    class LoopbackServer(http.server.ThreadingHTTPServer):
        def server_bind(self):
            # The fixture uses numeric loopback addresses; startup needs no reverse DNS.
            socketserver.TCPServer.server_bind(self)
            self.server_name, self.server_port = self.server_address[:2]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = urllib.parse.urlsplit(self.path)
            auth = self.headers.get("Authorization") == "Bearer registry-request-canary"
            api = self.headers.get("X-Registry-Key") == "registry-key-canary"
            cookie = self.headers.get("Cookie") is not None
            with (root / "requests.jsonl").open("a") as records:
                records.write(json.dumps(dict(target=self.path, authorization=auth, apiKey=api, cookie=cookie)) + "\n")
            if path.path.startswith("/cross-origin/"):
                return self.reply(302, Location=f"http://127.0.0.1:{sink.server_port}/sink")
            if path.path.startswith("/same-origin/"):
                return self.reply(307, Location="/sink")
            if path.path == "/sink":
                return self.reply(200, b'{"servers":[]}')
            if path.path.startswith("/large/"):
                self.send_response(200)
                self.end_headers()
                for part in range(9):
                    self.wfile.write(b"x" * (1024 * 1024))
                return
            if path.path.startswith("/slow/"):
                time.sleep(15)
                return
            if path.path.startswith("/private/") and not (auth and api):
                return self.reply(401, b'{"error":"Credentials are needed"}')
            entry = json.loads((root / "response.json").read_text())
            if "/v0.1/servers/" in path.path:
                result = entry
            else:
                cursor = urllib.parse.parse_qs(path.query).get("cursor")
                result = {"servers": [] if cursor else [entry], "metadata": {
                    "nextCursor": "" if cursor else "dev.example/fixture:1.2.3+build & next=%"
                }}
            self.reply(200, json.dumps(result).encode(), **{"Set-Cookie": "ambient=ignored; Path=/"})

        def reply(self, status, body=b"", **headers):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

    sink = LoopbackServer(("127.0.0.1", 0), Handler)
    main = LoopbackServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=sink.serve_forever, daemon=True).start()
    port_file = root / "port.tmp"
    port_file.write_text(str(main.server_port))
    port_file.replace(root / "port")
    main.serve_forever()
    """#
}
