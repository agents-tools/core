import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@testable import AgentsUpdates

struct OrganizationPolicyTests {
  @Test func hostEnvironmentSelectsRequiredPoliciesByScope() throws {
    let fixture = try UpdateFixture()
    let user = fixture.root.appendingPathComponent("team.yaml")
    try fixture.write("enforcement: warn", to: user)
    let environment = RuntimeEnvironment(
      projectDirectory: fixture.environment.projectDirectory,
      homeDirectory: fixture.environment.homeDirectory,
      environment: [
        "AGENTS_USER_ORGANIZATION_POLICY": user.path,
        "AGENTS_PROJECT_ORGANIZATION_POLICY": "project-relative.yaml",
      ])
    let project = try OrganizationPolicyOperations.status(scope: .project, environment: environment)
    #expect(project.policies.map(\.outcome) == [.loaded, .unavailable])
    #expect(project.isBlocked)
    let global = try OrganizationPolicyOperations.status(scope: .user, environment: environment)
    #expect(global.policies.map(\.outcome) == [.loaded])
    #expect(!global.isBlocked)
    #expect(throws: OrganizationPolicyFailure.self) {
      try UpdateOperations.withPreparedUpdate(request(fixture), environment: environment) {
        try $0.apply()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
  }

  @Test func hardSourceDenialStillRefusesWithOrganizationOff() throws {
    let fixture = try UpdateFixture()
    var environment = try configured(fixture, "enforcement: off")
    let user = SourcePolicyOperations.policyURL(scope: .user, environment: environment)
    try fixture.write("version: 1\ndeny: [local]\n", to: user)
    let project = fixture.root.appendingPathComponent("project-policy.yaml")
    try fixture.write("enforcement: off\nsources: {allow: [local]}", to: project)
    environment.projectOrganizationPolicy = .init(.local(project))
    let report = try OrganizationPolicyOperations.status(environment: environment)
    #expect(report.policies.map(\.mode) == [.off, .off])
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.withPreparedUpdate(request(fixture), environment: environment) {
        try $0.apply()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
  }

  @Test func parentAndIndependentUserAuthorityKeepTheirRestrictions() throws {
    let fixture = try UpdateFixture()
    let parent = fixture.root.appendingPathComponent("parent.yaml")
    try fixture.write(
      "enforcement: block\nsources: {allow: [], deny: []}", to: parent)
    var environment = try configured(
      fixture, "extends: parent.yaml\nenforcement: off\nsources: {allow: null}")
    let project = fixture.root.appendingPathComponent("project-policy.yaml")
    try fixture.write("enforcement: warn\nsources: {deny: [local]}", to: project)
    environment.projectOrganizationPolicy = .init(.local(project))
    let status = try OrganizationPolicyOperations.status(environment: environment)
    #expect(status.policies.map(\.mode) == [.block, .warn])
    #expect(
      status.policies[0].documents.map(\.url.lastPathComponent) == ["parent.yaml", "org.yaml"])
    do {
      _ = try UpdateOperations.preview(request(fixture), environment: environment)
      Issue.record("An empty parent allow list admitted a source.")
    } catch let error as OrganizationPolicyFailure {
      #expect(
        error.report.findings.contains {
          $0.authority == .user && $0.rule == "source-allow" && $0.document == parent
            && $0.outcome == .block
        })
      #expect(
        error.report.findings.contains {
          $0.authority == .project && $0.rule == "source-deny" && $0.outcome == .warn
        })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
  }

  @Test func warningInstallsAndReadOnlyAuditKeepsAttribution() throws {
    let fixture = try UpdateFixture()
    let environment = try configured(fixture, "enforcement: warn\nsources: {deny: [local]}")
    let report = try UpdateOperations.preview(request(fixture), environment: environment)
    let advisory = try #require(report.organizationPolicy)
    #expect(!advisory.isBlocked)
    #expect(advisory.findings.contains { $0.rule == "source-deny" && $0.outcome == .warn })
    _ = try UpdateOperations.withPreparedUpdate(request(fixture), environment: environment) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.target().path))
    let before = try FileHash.folderHash(fixture.root)
    let audit = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(audit.hasLock && !audit.isBlocked)
    let previewAttribution = try #require(advisory.findings.first { $0.rule == "source-deny" })
    #expect(audit.organization.findings.contains(previewAttribution))
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func directInstallDenialsCreateNoScopeOrTargetArtifacts() throws {
    let early = try UpdateFixture()
    let first = try configured(
      early, "enforcement: block\ndependencies: {require_pinned_constraint: true}")
    let remote = SourceDeclaration(
      kind: .git, location: "https://never-contact.invalid/example/repo",
      requirement: .branch("main"))
    let moving = UpdateRequest(
      operation: .declaration(
        Declaration(
          sources: ["remote": remote], skills: ["remote": .init(select: .names(["demo"]))])))
    let initial = try FileHash.folderHash(early.root)
    do {
      _ = try UpdateOperations.withPreparedUpdate(moving, environment: first) { try $0.apply() }
      Issue.record("A moving authored branch was admitted.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.map(\.rule) == ["dependency-pinned-constraint"])
    }
    #expect(try FileHash.folderHash(early.root) == initial)
    #expect(!FileManager.default.fileExists(atPath: early.store.directory.path))

    let late = try UpdateFixture()
    let run = late.repo.appendingPathComponent("skills/demo/run.sh")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
    try late.commit()
    let second = try configured(late, "enforcement: block\nexecutables: {deny_all: true}")
    let before = try FileHash.folderHash(late.root)
    do {
      _ = try UpdateOperations.withPreparedUpdate(request(late), environment: second) {
        try $0.apply()
      }
      Issue.record("Resolved executable was admitted.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.contains { $0.rule == "executables-deny" })
    }
    #expect(try FileHash.folderHash(late.root) == before)
    #expect(!FileManager.default.fileExists(atPath: late.store.directory.path))
    #expect(!FileManager.default.fileExists(atPath: late.target().path))
  }

  @Test func policyChangeDuringConfirmationRefusesBeforePublication() throws {
    let fixture = try UpdateFixture()
    let environment = try configured(fixture, "enforcement: warn\nsources: {deny: [local]}")
    let selection = try #require(environment.userOrganizationPolicy)
    guard case .local(let url) = selection.source else { return }
    let report = try UpdateOperations.preview(request(fixture), environment: environment)
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(request(fixture), environment: environment) {
        update in
        try fixture.write("enforcement: block\nsources: {deny: [local]}", to: url)
        return try update.apply(ifUnchangedFrom: report.displayedFingerprint)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.target().path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }

  @Test func requiredMCPDistinguishesIntentFromDeploymentAndCIStartsNoProgram() throws {
    let fixture = try UpdateFixture()
    let marker = fixture.root.appendingPathComponent("execution-marker")
    let transport = MCPTransportDeclaration.stdio(
      .init(executable: "touch", arguments: [marker.path]))
    let absent = Declaration(components: [
      .mcpServer(
        name: "tools", transport: transport, agents: [.codex], condition: .init(scopes: [.user]))
    ])
    let environment = try configured(
      fixture,
      """
      enforcement: block
      mcp:
        require: [inline/tools]
        transport: {allow: [stdio]}
      """)
    let intentOnly = UpdateRequest(operation: .declaration(absent))
    do {
      _ = try UpdateOperations.preview(intentOnly, environment: environment)
      Issue.record("A server outside the selected scope satisfied deployment.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.contains { $0.rule == "mcp-required-deployment" })
      #expect(!error.report.findings.contains { $0.rule == "mcp-required-declaration" })
    }
    try fixture.write(
      "---\ndescription: Rules\n---\n# Rules\n",
      to: fixture.root.appendingPathComponent(".agent/instructions/rules.md"))
    let present = Declaration(components: [
      .mcpServer(name: "tools", transport: transport, agents: [.codex]),
      .instructions(.init(agents: [.codex], sections: ["rules"])),
    ])
    try fixture.store.save(declaration: present, ledger: ResolvedLedger())
    do {
      _ = try InstructionOperations.previewOutputs(environment: environment)
      Issue.record("Instruction preview admitted an undeployed required server.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.contains { $0.rule == "mcp-required-deployment" })
    }
    let update = try UpdateOperations.withPreparedUpdate(environment: environment) {
      try $0.apply()
    }
    let beforePreview = try FileHash.folderHash(fixture.root)
    let preview = try InstructionOperations.previewOutputs(environment: environment)
    #expect(preview.organizationPolicy?.isBlocked == false)
    #expect(preview.instructions.outputs.count == 1)
    #expect(preview.instructions.outputs == update.report.instructions.outputs)
    #expect(try FileHash.folderHash(fixture.root) == beforePreview)
    #expect(!(try OrganizationPolicyOperations.audit(environment: environment)).isBlocked)
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    try fixture.write("version: 1\n", to: fixture.store.declarationURL)
    let before = try FileHash.folderHash(fixture.root)
    let stale = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(stale.isBlocked)
    #expect(stale.organization.findings.contains { $0.rule == "mcp-required-declaration" })
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func instructionPreviewEnforcesContentPolicyOnCopyProducts() throws {
    let fixture = try UpdateFixture()
    let environment = try configured(
      fixture, "enforcement: block\nmanifest: {content_types: {allow: [skills]}}")
    try fixture.write(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - kind: instructions
          sections: [{name: rules, source: fixture, recipients: [chatgpt-app]}]
      """, to: fixture.store.declarationURL)
    let before = try fixture.snapshot()
    do {
      _ = try InstructionOperations.previewOutputs(environment: environment)
      Issue.record("Instruction preview admitted a prohibited copy product.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.contains { $0.rule == "manifest-content-types" })
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func unmanagedAndDriftUsePassiveWorkspaceEvidence() throws {
    let fixture = try UpdateFixture()
    _ = try UpdateOperations.withPreparedUpdate(request(fixture), environment: fixture.environment)
    {
      try $0.apply()
    }
    let rogue = fixture.root.appendingPathComponent(".agents/skills/rogue/SKILL.md")
    try fixture.write("unmanaged content", to: rogue)
    try fixture.write("changed deployment", to: fixture.target().appendingPathComponent("SKILL.md"))
    let environment = try configured(
      fixture,
      """
      enforcement: block
      unmanaged_files: {action: deny, directories: [.agents/skills]}
      security: {audit: {fail_on_drift: true}, integrity: {require_hashes: true}}
      """)
    let before = try FileHash.folderHash(fixture.root)
    let audit = try OrganizationPolicyOperations.audit(environment: environment)
    #expect(audit.organization.findings.contains { $0.rule == "workspace-drift" })
    #expect(
      audit.organization.findings.contains {
        $0.rule == "workspace-unmanaged" && $0.identity == ".agents/skills/rogue/SKILL.md"
      })
    #expect(
      !audit.organization.findings.contains {
        $0.rule == "workspace-unmanaged" && $0.identity.contains("/demo/")
      })
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func boundedHTTPSCacheRequiresAnEligibleCompleteChain() throws {
    let fixture = try UpdateFixture()
    let leaf = try #require(URL(string: "https://policy.example/leaf"))
    let parent = try #require(URL(string: "https://policy.example/parent"))
    let foreign = try #require(URL(string: "https://other.example/parent"))
    var environment = fixture.environment
    environment.userOrganizationPolicy = .init(.https(leaf))
    let store = StateStore(scope: .project, environment: environment)
    let time = Date(timeIntervalSince1970: 4_000_000)
    var calls: [URL] = []
    let first = try OrganizationPolicySnapshot(store: store, now: time) { url in
      calls.append(url)
      let policy =
        url == leaf
        ? "extends: https://policy.example/parent\nenforcement: warn\ncache: {ttl: 10}"
        : "enforcement: block\nfetch_failure: block\ncache: {ttl: 5}"
      return .init(status: 200, url: url, bytes: Data(policy.utf8))
    }
    #expect(calls == [leaf, parent])
    #expect(first.statuses.first?.mode == .block)
    let cache = environment.homeDirectory.appendingPathComponent(
      ".cache/agents/organization-policies")
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    calls.removeAll()
    let reviewed = try OrganizationPolicySnapshot(
      store: store, now: time.addingTimeInterval(4), offlineObservations: first
    ) { url in
      calls.append(url)
      throw OrganizationPolicyLoader.Offline()
    }
    #expect(calls.isEmpty)
    #expect(reviewed.fingerprint == first.fingerprint)
    #expect(reviewed.statuses.first?.mode == .block)
    #expect(!FileManager.default.fileExists(atPath: cache.path))

    first.rememberVerifiedPolicies()

    calls.removeAll()
    let fresh = try OrganizationPolicySnapshot(store: store, now: time.addingTimeInterval(4)) {
      url in
      calls.append(url)
      throw OrganizationPolicyLoader.Offline()
    }
    #expect(calls.isEmpty)
    #expect(fresh.statuses.first?.documents.allSatisfy { !$0.stale } == true)
    let stale = try OrganizationPolicySnapshot(store: store, now: time.addingTimeInterval(6)) {
      url in
      calls.append(url)
      throw OrganizationPolicyLoader.Offline()
    }
    #expect(calls == [leaf, parent])
    #expect(stale.statuses.first?.documents.allSatisfy(\.stale) == true)
    let expired = try OrganizationPolicySnapshot(
      store: store, now: time.addingTimeInterval(7 * 86_400 + 1)
    ) { _ in throw OrganizationPolicyLoader.Offline() }
    #expect(expired.report().isBlocked)
    #expect(expired.statuses.first?.documents.isEmpty == true)

    let redirected = try OrganizationPolicySnapshot(store: store, now: time.addingTimeInterval(50))
    {
      url in
      .init(
        status: 200, url: url == parent ? foreign : url,
        bytes: Data(
          (url == leaf ? "extends: https://policy.example/parent" : "enforcement: off").utf8))
    }
    #expect(redirected.report().isBlocked)
    #expect(redirected.statuses.first?.outcome == .unavailable)

    let auth = try OrganizationPolicySnapshot(store: store, now: time.addingTimeInterval(80)) {
      url in .init(status: 403, url: url, bytes: Data())
    }
    #expect(auth.report().isBlocked)
    #expect(auth.statuses.first?.outcome == .unavailable)
  }

  @Test func discoversAnOrganizationFromTheCallerRemoteAndCanRequirePresence() throws {
    let fixture = try UpdateFixture()
    let absent = try OrganizationPolicyOperations.status(environment: fixture.environment)
    #expect(absent.policies.map(\.outcome) == [.absent])
    let mandatory = try OrganizationPolicyOperations.audit(
      environment: fixture.environment, requireOrganizationPolicy: true)
    #expect(mandatory.isBlocked)
    #expect(mandatory.organization.findings.map(\.rule) == ["policy-required"])

    var environment = fixture.environment
    environment.userOrganizationPolicy = .init(
      .organization(gitRemote: "git@github.com:Team/Main.git"))
    let store = StateStore(scope: .project, environment: environment)
    var requests: [String] = []
    let status = try OrganizationPolicySnapshot(store: store) { url in
      requests.append(url.path)
      return .init(
        status: url.path.contains("/.github-private/") ? 404 : 200,
        url: url, bytes: Data("enforcement: block".utf8))
    }
    #expect(
      requests == [
        "/team/.github-private/HEAD/agents-policy.yaml", "/team/.github/HEAD/agents-policy.yaml",
      ])
    #expect(status.statuses.first?.mode == .block)
    #expect(!status.report().isBlocked)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.path))
  }

  @Test func stableManifestRulesInspectPresentFieldsAndSelection() throws {
    let fixture = try UpdateFixture()
    let environment = try configured(
      fixture,
      """
      enforcement: block
      manifest:
        required_fields: [version, components]
        require_explicit_includes: true
        content_types: {allow: [skills]}
      """)
    let request = UpdateRequest(
      operation: .declaration(
        .init(
          sources: ["demo": .init(kind: .local, location: fixture.repo.path)],
          skills: ["demo": .init(select: .all, agents: [.codex], mode: .copy)])))
    do {
      _ = try UpdateOperations.preview(request, environment: environment)
      Issue.record("An implicit selection was admitted.")
    } catch let error as OrganizationPolicyFailure {
      #expect(error.report.findings.contains { $0.rule == "manifest-explicit-includes" })
      #expect(!error.report.findings.contains { $0.rule == "manifest-required-field" })
    }
  }

  @Test func invalidParentAndCyclesNeverApplyAPartialPolicy() throws {
    let fixture = try UpdateFixture()
    let environment = try configured(fixture, "enforcement: warn\nextends: parent.yaml")
    let parent = fixture.root.appendingPathComponent("parent.yaml")
    for yaml in ["enforcement: [block]", "extends: org.yaml"] {
      try fixture.write(yaml, to: parent)
      let status = try OrganizationPolicyOperations.status(environment: environment)
      #expect(status.isBlocked && status.policies.first?.documents.isEmpty == true)
    }
    for index in 0..<5 {
      let url = fixture.root.appendingPathComponent("level-\(index).yaml")
      try fixture.write(
        index < 4 ? "extends: level-\(index + 1).yaml" : "enforcement: block", to: url)
    }
    try fixture.write("extends: level-0.yaml", to: parent)
    #expect(try OrganizationPolicyOperations.status(environment: environment).isBlocked)
  }

  private func configured(_ fixture: UpdateFixture, _ yaml: String) throws -> RuntimeEnvironment {
    let policy = fixture.root.appendingPathComponent("org.yaml")
    try fixture.write(yaml, to: policy)
    var environment = fixture.environment
    environment.userOrganizationPolicy = .init(.local(policy))
    return environment
  }

  private func request(_ fixture: UpdateFixture) -> UpdateRequest {
    .init(
      operation: .declaration(
        .init(
          sources: ["demo": .init(kind: .local, location: fixture.repo.path)],
          skills: ["demo": .init(select: .names(["demo"]), agents: [.codex], mode: .copy)])))
  }
}
