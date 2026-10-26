import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction diagnostics")
struct InstructionDoctorTests {
  @Test(arguments: [InstallScope.project, .user], ["transaction.json", "transaction.new"])
  func pendingScopeSkipsInconsistentStateAndCrossScopeChecks(
    _ pendingScope: InstallScope, _ journal: String
  ) throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let healthyScope: InstallScope = pendingScope == .project ? .user : .project
    try fixture.add(scope: healthyScope, agents: [.codex])
    let healthyFile = InstructionLocations.file(
      for: .codex, scope: healthyScope, environment: fixture.environment)!
    try FileManager.default.removeItem(at: healthyFile)
    let pending = fixture.store(pendingScope)
    try fixture.write("{}", to: pending.directory.appendingPathComponent(journal))
    try fixture.write("incomplete declaration", to: pending.declarationURL)
    try fixture.write("incomplete lock", to: pending.resolvedURL)
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(
      scope: pendingScope, environment: fixture.environment)
    #expect(report.diagnostics.map(\.kind) == [.pendingRecovery])
    #expect(report.diagnostics.first?.path == pending.directory)
    let healthy = try InstructionOperations.doctor(
      scope: healthyScope, environment: fixture.environment)
    #expect(healthy.diagnostics.filter { $0.kind == .pendingRecovery }.count == 1)
    #expect(healthy.diagnostics.contains { $0.kind == .missingTarget && $0.path == healthyFile })
    #expect(!healthy.diagnostics.contains { $0.kind == .duplicateScope })
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [true, false])
  func trustedProjectConfigurationOverridesUserByteLimit(_ trusted: Bool) throws {
    let fixture = try InstructionFixture()
    try fixture.write(
      String(repeating: "x", count: 2048), to: fixture.project.appendingPathComponent("AGENTS.md"))
    let userConfig = fixture.home.appendingPathComponent(".codex/config.toml")
    let projectConfig = fixture.project.appendingPathComponent(".codex/config.toml")
    try fixture.write("project_doc_max_bytes = 32768\n", to: userConfig)
    try fixture.write("project_doc_max_bytes = 1024\n", to: projectConfig)
    var effective = try CodexInstructionConfiguration(Data(contentsOf: userConfig))
    if trusted {
      effective = try CodexInstructionConfiguration(
        Data(contentsOf: projectConfig), inheriting: effective)
    }
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(
      environment: fixture.environment, codexConfiguration: effective)
    #expect(report.diagnostics.contains { $0.kind == .codexSize } == trusted)
    if trusted {
      #expect(
        report.diagnostics.contains { $0.kind == .codexSize && $0.message.contains("(1024)") })
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func multiRootAuditUsesEffectiveConfigurationForEachProject() throws {
    let fixture = try InstructionFixture()
    let nested = fixture.project.appendingPathComponent("nested")
    let other = fixture.root.appendingPathComponent("other")
    let userConfig = fixture.home.appendingPathComponent(".codex/config.toml")
    let projectConfig = fixture.project.appendingPathComponent(".codex/config.toml")
    let nestedConfig = nested.appendingPathComponent(".codex/config.toml")
    let otherConfig = other.appendingPathComponent(".codex/config.toml")
    try fixture.write("marker", to: fixture.project.appendingPathComponent(".project-root"))
    try fixture.write(
      "project_doc_max_bytes = 32768\nproject_root_markers = ['.project-root']\n", to: userConfig)
    try fixture.write(
      "project_doc_max_bytes = 1024\nproject_doc_fallback_filenames = ['TEAM.md']\n",
      to: projectConfig)
    try fixture.write("project_doc_max_bytes = 1536\n", to: nestedConfig)
    try fixture.write("project_doc_max_bytes = 4096\n", to: otherConfig)
    for file in [
      fixture.project.appendingPathComponent("TEAM.md"), nested.appendingPathComponent("AGENTS.md"),
      other.appendingPathComponent("AGENTS.md"),
    ] {
      try fixture.write(String(repeating: "x", count: 1024), to: file)
    }
    let before = try fixture.snapshot()
    let reports = InstructionOperations.doctor(
      projectRoots: [nested, other], environment: fixture.environment,
      codexConfiguration: { root in
        let layers =
          root.path == nested.path
          ? [userConfig, projectConfig, nestedConfig] : [userConfig, otherConfig]
        return try layers.reduce(CodexInstructionConfiguration()) { base, layer in
          try CodexInstructionConfiguration(Data(contentsOf: layer), inheriting: base)
        }
      })
    let size = try #require(reports[0].diagnostics.first { $0.kind == .codexSize })
    #expect(size.message.contains("2048 bytes"))
    #expect(size.message.contains("(1536)"))
    #expect(!reports[1].diagnostics.contains { $0.kind == .codexSize })
    #expect(try fixture.snapshot() == before)
  }

  @Test func codexUsesConfiguredRootMarkersAndFallbackFilenames() throws {
    let fixture = try InstructionFixture()
    try fixture.write("marker", to: fixture.project.appendingPathComponent(".project-root"))
    try fixture.write(
      String(repeating: "x", count: 900), to: fixture.project.appendingPathComponent("TEAM.md"))
    let nested = fixture.project.appendingPathComponent("sub")
    try fixture.write(
      String(repeating: "y", count: 900), to: nested.appendingPathComponent("AGENTS.md"))
    try fixture.write(
      "project_doc_max_bytes = 1_024\nproject_root_markers = ['.project-root']\nproject_doc_fallback_filenames = [\n  \"TEAM.md\", # preferred\n  '.rules.md',\n]\n",
      to: fixture.home.appendingPathComponent(".codex/config.toml"))
    var runtime = fixture.environment
    runtime.projectDirectory = nested
    let report = try InstructionOperations.doctor(environment: runtime)
    #expect(
      report.diagnostics.contains { $0.kind == .codexSize && $0.message.contains("1800 bytes") })
    #expect(!report.diagnostics.contains { $0.kind == .invalidConfiguration })
  }

  @Test func doctorReportsEveryDifferenceFromALockedTargetAsDrift() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let file = fixture.project.appendingPathComponent("AGENTS.md")
    try fixture.write("# rules\n\nOriginal\n", to: file)
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .drift && $0.path == file
      })
    try fixture.write(generated(["# rules\n\nCustom"]), to: file)
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(report.diagnostics.contains { $0.kind == .drift && $0.path == file })
    #expect(try fixture.text() == generated(["# rules\n\nCustom"]))
  }

  @Test func diagnosesBothScopesOverridesAncestorsAndConfiguredByteLimit() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    try fixture.add(scope: .user)
    try fixture.write("Ancestor guidance.\n", to: fixture.root.appendingPathComponent("CLAUDE.md"))
    try fixture.write("No import.\n", to: fixture.project.appendingPathComponent("CLAUDE.local.md"))
    try fixture.write(
      String(repeating: "x", count: 2048),
      to: fixture.project.appendingPathComponent("AGENTS.override.md"))
    try fixture.write(
      "project_doc_max_bytes = 1_024 # budget\n[profiles.example]\nproject_doc_max_bytes = 90000\n",
      to: fixture.home.appendingPathComponent(".codex/config.toml"))
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    let kinds = Set(report.diagnostics.map(\.kind))
    #expect(
      kinds.isSuperset(of: [
        .duplicateScope, .codexOverride, .codexSize, .claudeAncestor, .claudeForwarding,
      ]))
    #expect(report.diagnostics.first { $0.kind == .codexSize }?.message.contains("(1024)") == true)
    #expect(try fixture.snapshot() == before)
    #expect(
      !report.diagnostics.contains {
        $0.kind == .claudeAncestor
          && $0.path == fixture.home.appendingPathComponent(".claude/CLAUDE.md")
      })
  }

  @Test func multiRootAuditCreatesNothingAndDoesNotRecoverPendingTransactions() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let empty = fixture.root.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let pending = fixture.root.appendingPathComponent("pending")
    try fixture.write("{}", to: pending.appendingPathComponent(".agent/transaction.json"))
    try FileManager.default.removeItem(at: fixture.project.appendingPathComponent("AGENTS.md"))
    let before = try fixture.snapshot()
    let reports = InstructionOperations.doctor(
      projectRoots: [fixture.project, empty, pending], environment: fixture.environment)
    #expect(reports.count == 3)
    #expect(reports[0].diagnostics.contains { $0.kind == .missingTarget })
    #expect(reports[2].diagnostics.map(\.kind) == [.pendingRecovery])
    #expect(try fixture.snapshot() == before)
    #expect(!FileManager.default.fileExists(atPath: empty.appendingPathComponent(".agent").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: pending.appendingPathComponent(".agent/.agents.lock").path))
  }

  @Test func codexBudgetCountsOnlyTheProjectChainAndEmptyOverridesWin() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(agents: [.codex])
    try fixture.write("marker", to: fixture.project.appendingPathComponent(".git"))
    let nested = fixture.project.appendingPathComponent("sub/deep")
    try fixture.write(
      String(repeating: "x", count: 20_000), to: fixture.project.appendingPathComponent("AGENTS.md")
    )
    try fixture.write(
      String(repeating: "y", count: 20_000), to: nested.appendingPathComponent("AGENTS.md"))
    try fixture.write("", to: nested.appendingPathComponent("AGENTS.override.md"))
    try fixture.write(
      String(repeating: "z", count: 30_000),
      to: fixture.home.appendingPathComponent(".codex/AGENTS.md"))
    try fixture.write(
      String(repeating: "ignored", count: 20_000),
      to: fixture.root.appendingPathComponent("AGENTS.md"))
    var runtime = fixture.environment
    runtime.projectDirectory = nested
    #expect(
      try !InstructionOperations.doctor(environment: runtime).diagnostics.contains {
        $0.kind == .codexSize
      })
    try fixture.write(
      "project_doc_max_bytes = 16384\n",
      to: fixture.home.appendingPathComponent(".codex/config.toml"))
    let report = try InstructionOperations.doctor(environment: runtime)
    let size = try #require(report.diagnostics.first { $0.kind == .codexSize })
    #expect(size.message.contains("20000 bytes"))
    #expect(!size.message.contains(fixture.home.appendingPathComponent(".codex").path))
    #expect(!size.message.contains(fixture.root.appendingPathComponent("AGENTS.md").path))
  }

  @Test func codexOverrideHidesManagedFilesEvenWhenEmptyInProjects() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(agents: [.codex])
    try fixture.add(scope: .user, agents: [.codex])
    try fixture.write("", to: fixture.project.appendingPathComponent("AGENTS.override.md"))
    try fixture.write(" \n", to: fixture.home.appendingPathComponent(".codex/AGENTS.override.md"))
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .codexOverride
      })
    #expect(
      try !InstructionOperations.doctor(scope: .user, environment: fixture.environment)
        .diagnostics.contains { $0.kind == .codexOverride })
    try fixture.write(
      "Override\n", to: fixture.home.appendingPathComponent(".codex/AGENTS.override.md"))
    #expect(
      try InstructionOperations.doctor(scope: .user, environment: fixture.environment)
        .diagnostics.contains { $0.kind == .codexOverride })
  }

  @Test func editedTargetAndLostLockProduceDiagnostics() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    try fixture.write(
      try fixture.text() + "\n<!-- END managed by agents -->\n",
      to: fixture.project.appendingPathComponent("AGENTS.md"))
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .drift
      })
    try FileManager.default.removeItem(at: fixture.store().resolvedURL)
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .missingLock
      })
  }

  @Test func configTableAndMultilineTextDoNotSetRootByteLimit() throws {
    let fixture = try InstructionFixture()
    try fixture.write(
      String(repeating: "x", count: 2048), to: fixture.project.appendingPathComponent("AGENTS.md"))
    let config = fixture.home.appendingPathComponent(".codex/config.toml")
    try fixture.write(
      "description = '''\nproject_doc_max_bytes = 1\n'''\n[profile]\nproject_doc_max_bytes = 1\n",
      to: config)
    #expect(
      try !InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .codexSize
      })
    try fixture.write("project_doc_max_bytes = -1\n", to: config)
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .invalidConfiguration
      })
  }
}
