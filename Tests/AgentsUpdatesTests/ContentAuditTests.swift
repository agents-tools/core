import AgentsCore
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

struct ContentAuditTests {
  @Test func discoversSixAgentProfilesWithoutALock() throws {
    let fixture = try Fixture()
    let marker = "\u{202e}"
    let prompts = [
      "src/AGENTS.override.md": "Codex" + marker,
      ".codex/agents/reviewer.toml": "developer_instructions = 'Codex\(marker)'",
      ".claude/rules/nested/review.md": "Claude" + marker,
      ".claude/skills/fixture/SKILL.md": "Skill" + marker,
      ".cursor/rules/nested/review.mdc": "Cursor" + marker,
      ".gemini/commands/nested/review.toml": "prompt = 'Gemini\(marker)'",
      ".opencode/commands/review.md": "OpenCode" + marker,
      ".agents/rules/nested/review.md": "Antigravity" + marker,
      ".agents/skills/common/SKILL.md": "Shared skill" + marker,
      ".agent/instructions/review.md": "Project authoring" + marker,
    ]
    for (path, text) in prompts { try fixture.write(path, text) }

    try fixture.write(".agents/skills/common/examples/reference.md", marker)
    try fixture.write(".codex/auth.json", #"{"prompt":"\u202e"}"#)
    try fixture.write(".claude/history/AGENTS.md", marker)
    try fixture.write(".cursor/rules/credentials.local.mdc", marker)
    try fixture.write("other-checkout/.git", "gitdir: unrelated")
    try fixture.write("other-checkout/AGENTS.md", marker)
    try fixture.write(".claude/hooks/run.sh", marker)
    try fixture.write(".claude/hooks/package.json", #"{"type":"module"}"#)
    try fixture.write(
      ".codex/hooks.json",
      #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\u202e"}]}]}}"#)
    try fixture.write(
      ".agents/hooks.json", #"{"hooks":{"PreToolUse":{"Bash":[{"command":"\u202e"}]}}}"#)

    let audit = ContentAuditOperations.scan(environment: fixture.environment)
    #expect(Set(audit.findings.map(\.location.path)) == Set(prompts.keys))
    #expect(audit.findings.allSatisfy { $0.ownership == .untracked && $0.severity == .critical })
    #expect(audit.ciExitCode == 1)
    #expect(audit.targets.first { $0.path == ".claude/hooks/package.json" }?.status == .skipped)
    #expect(audit.targets.first { $0.path == ".codex/hooks.json" }?.status == .skipped)
    #expect(!audit.readLocations.contains { $0.path.contains("other-checkout") })
    #expect(!audit.readLocations.contains(fixture.url(".codex/auth.json")))
    #expect(!FileManager.default.fileExists(atPath: fixture.url(".agent/.agents.lock").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.url(".agent/agents.resolved").path))

    let onlyCursor = ContentAuditOperations.scan(
      agents: [.cursor], environment: fixture.environment)
    #expect(onlyCursor.findings.contains { $0.location.path.hasPrefix(".cursor/rules/") })
    #expect(!onlyCursor.findings.contains { $0.location.path.hasPrefix(".claude/") })
  }

  @Test func scansOnlyIndexedNativeFieldsAndReportsSourceCoordinates() throws {
    let fixture = try Fixture()
    let claude = ".claude/settings.json"
    try fixture.write(
      claude,
      #"""
      {
        "name": "\u202E",
        "hooks": {
          "Stop/~end": [
            {"hooks":[{"type":"command","command":"\u202E","prompt":"\u202E"}]},
            {"hooks":[{"type":"prompt","prompt":"A\n🧭\uDB40\uDD00"}]}
          ]
        }
      }
      """#)
    let cursor = ".cursor/hooks.json"
    try fixture.write(
      cursor,
      #"{"version":1,"hooks":{"stop":[{"command":"\u202E"},{"type":"prompt","prompt":"\u200B"}]}}"#)
    let gemini = ".gemini/commands/tasks/review.toml"
    try fixture.write(
      gemini,
      #"""
      description = "\u202E"
      prompt = """
      Read 🧭\u202E
      """
      """#)
    let opencode = "opencode.jsonc"
    try fixture.write(
      opencode,
      #"""
      // Sidebar setting
      {"commands":{"a/b":{"template":"Read\u202E","model":"\u202E"}},
       "agents":{"sample":{"system":"Inspect\u200B","description":"\u202E"}},
       "mcp":{"ignored":{"command":["\u202E"]}},}
      """#)

    let audit = ContentAuditOperations.scan(environment: fixture.environment)
    #expect(audit.findings.count == 5)
    let claudeFinding = try #require(audit.findings.first { $0.location.path == claude })
    #expect(claudeFinding.codePoint == 0xe0100)
    #expect(claudeFinding.location.field == "/hooks/Stop~1~0end/1/hooks/0/prompt")
    #expect(claudeFinding.location.line == 6)
    #expect(claudeFinding.location.promptLine == 2)
    #expect(claudeFinding.location.promptColumn == 3)
    let raw = try String(contentsOf: fixture.url(claude), encoding: .utf8)
    let lines = raw.split(separator: "\n")
    try #require(lines.count > 5)
    let claudeLine = lines[5]
    let escape = try #require(claudeLine.range(of: #"\uDB40"#))
    #expect(claudeFinding.location.column == claudeLine[..<escape.lowerBound].utf16.count + 1)
    let tomlFinding = try #require(audit.findings.first { $0.location.path == gemini })
    #expect(tomlFinding.location.field == "/prompt")
    #expect(tomlFinding.location.line == 3)
    #expect(tomlFinding.location.column == 8)
    #expect(tomlFinding.location.promptColumn == 8)
    #expect(
      audit.findings.filter { $0.location.path == opencode }.map(\.location.field)
        == ["/commands/a~1b/template", "/agents/sample/system"])
    #expect(audit.findings.filter { $0.location.path == cursor }.map(\.codePoint) == [0x200b])
    #expect(throws: ContentAuditStripError.unsupportedFile) {
      try ContentAuditOperations.previewStrip(
        file: fixture.url(claude), environment: fixture.environment)
    }
  }

  @Test func explicitScanExportsAStableGateWithoutPromptExcerpts() throws {
    let fixture = try Fixture()
    let file = try fixture.write("manual review #1.txt", "fixture-only content\n🧭\u{202e}")
    let report = ContentAuditOperations.scan(file: file, environment: fixture.environment)
    let finding = try #require(report.findings.first)
    #expect(finding.location.line == 2)
    #expect(finding.location.column == 3)
    #expect(finding.ownership == .untracked)
    #expect(finding.message.contains("U+202E"))
    #expect(report.ciExitCode == 1)
    let serializations = try [ContentAuditReportFormat.json, .sarif, .markdown].map { format in
      let data = try report.export(format)
      #expect(data == (try report.export(format)))
      #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only"))
      #expect(!String(decoding: data, as: UTF8.self).contains(fixture.root.path))
      return data
    }
    let json = try #require(JSONSerialization.jsonObject(with: serializations[0]) as? [String: Any])
    #expect(json["passesCI"] as? Bool == false)
    let sarif = try #require(
      JSONSerialization.jsonObject(with: serializations[1]) as? [String: Any])
    #expect(sarif["version"] as? String == "2.1.0")
    let runs = try #require(sarif["runs"] as? [[String: Any]])
    let run = try #require(runs.first)
    #expect(run["columnKind"] as? String == "utf16CodeUnits")
    let results = try #require(run["results"] as? [[String: Any]])
    let result = try #require(results.first)
    #expect(result["ruleId"] as? String == "bidiControl")
    #expect(result["level"] as? String == "error")
    let locations = try #require(result["locations"] as? [[String: Any]])
    let physical = try #require(locations.first?["physicalLocation"] as? [String: Any])
    let artifact = try #require(physical["artifactLocation"] as? [String: Any])
    #expect(artifact["uri"] as? String == "manual%20review%20%231.txt")
    let region = try #require(physical["region"] as? [String: Int])
    #expect(region == ["startLine": 2, "startColumn": 3])
    #expect(String(decoding: serializations[2], as: UTF8.self).contains("CI gate failed."))
  }

  @Test func preservesLegitimateUnicodeAndByteLayoutInReviewedStrip() throws {
    let fixture = try Fixture()
    let legitimate =
      "\u{feff}Cafe\u{0301} 漢字 हिन्दी می\u{200c}روم\u{00a0}👩🏽\u{200d}💻 ✈\u{fe0f} "
      + "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}\r\n"
    let file = try fixture.write("AGENTS.md", legitimate + "a\u{e0001}b\u{200b}c\u{feff}\r\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let before = try Data(contentsOf: file)
    let review = try ContentAuditOperations.previewStrip(
      file: file, environment: fixture.environment)
    #expect(review.originalBytes == before)
    #expect(review.replacementBytes == Data((legitimate + "abc\r\n").utf8))
    #expect(review.edits.map(\.codePoint) == [0xe0001, 0x200b, 0xfeff])
    #expect(review.edits.map(\.line) == [2, 2, 2])
    #expect(review.edits.map(\.column) == [2, 5, 7])
    #expect(try Data(contentsOf: file) == before)
    try ContentAuditOperations.applyStrip(review)
    #expect(try Data(contentsOf: file) == review.replacementBytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    let clean = ContentAuditOperations.scan(file: file, environment: fixture.environment)
    #expect(clean.passesCI && clean.scanExitCode == 0)
    #expect(clean.findings.contains { $0.reason == .contextualJoiner })
    #expect(clean.findings.contains { $0.reason == .emojiTagSequence })
    #expect(throws: (any Error).self) { try ContentAuditOperations.applyStrip(review) }
    #expect(
      !(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path))
        .contains { $0.hasPrefix(".agents-audit-") })
  }

  @Test func stripRejectsChangedBytesAndReplacedInodes() throws {
    let fixture = try Fixture()
    let file = try fixture.write("AGENTS.md", "A\u{200b}")
    let preview = try ContentAuditOperations.previewStrip(
      file: file, environment: fixture.environment)
    try Data("B\u{200b}".utf8).write(to: file)
    #expect(throws: (any Error).self) { try ContentAuditOperations.applyStrip(preview) }
    #expect(try Data(contentsOf: file) == Data("B\u{200b}".utf8))
    let replacement = try ContentAuditOperations.previewStrip(
      file: file, environment: fixture.environment)
    try Data("B\u{200b}".utf8).write(to: file, options: .atomic)
    #expect(throws: (any Error).self) { try ContentAuditOperations.applyStrip(replacement) }
    #expect(try Data(contentsOf: file) == replacement.originalBytes)
    #expect(
      ContentAuditOperations.scan(file: file, environment: fixture.environment).scanExitCode == 2)
    #expect(ContentAuditOperations.scan(file: file, environment: fixture.environment).passesCI)
  }

  @Test func remoteURLsAndTheFilesystemRootGrantNoLocalReadAuthority() throws {
    let fixture = try Fixture()
    try fixture.write("AGENTS.md", "\u{202e}")
    var remote = URLComponents()
    remote.scheme = "https"
    remote.host = "example.invalid"
    remote.path = fixture.environment.projectDirectory.path
    for root in [try #require(remote.url), URL(fileURLWithPath: "/")] {
      let environment = RuntimeEnvironment(
        projectDirectory: root, homeDirectory: fixture.environment.homeDirectory, environment: [:])
      let report = ContentAuditOperations.scan(environment: environment)
      #expect(report.findings.map(\.reason) == [.outsideScope])
      #expect(report.readLocations.isEmpty)
    }

    remote.scheme = "file"
    remote.path = fixture.url("AGENTS.md").path
    let remoteFile = try #require(remote.url)
    let report = ContentAuditOperations.scan(file: remoteFile, environment: fixture.environment)
    #expect(report.findings.map(\.reason) == [.outsideScope])
    #expect(report.readLocations.isEmpty)
  }

  @Test func scopeBoundariesAndMalformedCoverage() throws {
    let fixture = try Fixture()
    let home = fixture.environment.homeDirectory
    let project = fixture.environment.projectDirectory
    let protected = home.appendingPathComponent(".codex/auth.json")
    let configured = home.appendingPathComponent("configured-claude")
    try fixture.writeAbsolute(protected, "\u{202e}")
    try fixture.writeAbsolute(configured.appendingPathComponent("rules/custom.md"), "\u{200b}")
    try fixture.writeAbsolute(
      home.appendingPathComponent(".gemini/config/rules/guidance.md"), "\u{202e}")
    try fixture.writeAbsolute(
      home.appendingPathComponent(".gemini/config/skills/sample/SKILL.md"), "\u{202e}")
    try fixture.write("AGENTS.md", "\u{202e}")
    try fixture.write(".codex/agents/malformed.toml", #"developer_instructions = ["#)
    try fixture.write(
      ".cursor/hooks.json", #"{"hooks":{"stop":[{"type":"prompt","prompt":"\uD800"}]}}"#)
    let linked = fixture.url(".cursor/rules/linked.mdc")
    try FileManager.default.createDirectory(
      at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: protected)
    let hardlinked = fixture.url(".cursor/rules/hardlinked.mdc")
    try FileManager.default.linkItem(at: protected, to: hardlinked)
    #expect(throws: (any Error).self) {
      try ContentAuditOperations.previewStrip(file: hardlinked, environment: fixture.environment)
    }
    let projectReport = ContentAuditOperations.scan(environment: fixture.environment)
    #expect(
      projectReport.findings.contains {
        $0.location.path == ".codex/agents/malformed.toml" && $0.reason == .unsupportedContent
      })
    #expect(
      projectReport.findings.contains {
        $0.location.path == ".cursor/hooks.json" && $0.reason == .unsupportedContent
      })
    #expect(
      projectReport.findings.contains {
        $0.location.path == ".cursor/rules/linked.mdc" && $0.codePoint == nil
      })
    #expect(
      projectReport.findings.contains {
        $0.location.path == ".cursor/rules/hardlinked.mdc" && $0.codePoint == nil
      })
    #expect(!projectReport.readLocations.contains(protected))
    #expect(
      ContentAuditOperations.scan(file: protected, environment: fixture.environment).findings.first?
        .reason == .outsideScope)

    let userEnvironment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: home,
      environment: ["CLAUDE_CONFIG_DIR": configured.path])
    let userReport = ContentAuditOperations.scan(scope: .user, environment: userEnvironment)
    #expect(
      Set(userReport.findings.map(\.location.path)) == [
        "configured-claude/rules/custom.md", ".gemini/config/rules/guidance.md",
        ".gemini/config/skills/sample/SKILL.md",
      ])
    #expect(!userReport.readLocations.contains(protected))
    #expect(
      ContentAuditOperations.scan(file: protected, scope: .user, environment: userEnvironment)
        .targets.first?.status == .skipped)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents").path))
  }

  @Test(arguments: [InstallScope.project, .user])
  func antigravityRuleOwnershipUsesTheSelectedScope(_ scope: InstallScope) throws {
    let f = try UpdateFixture(scope: scope)
    try f.install(agents: [.antigravity])
    let directory = scope == .project ? ".agents/rules" : ".gemini/config/rules"
    let root = scope == .project ? f.environment.projectDirectory : f.environment.homeDirectory
    let handwritten = directory + "/handwritten.md"
    try f.write("Personal\n", to: root.appendingPathComponent(handwritten))
    let report = ContentAuditOperations.scan(
      scope: scope, agents: [.antigravity], environment: f.environment)
    let rules = report.targets.filter { $0.path.hasPrefix(directory + "/") }
    let managed = try #require(rules.first { $0.ownership == .managedFile })
    #expect(rules.first { $0.path == handwritten }?.ownership == .untracked)
    try f.write("Changed rule\n", to: root.appendingPathComponent(managed.path))
    let changed = ContentAuditOperations.scan(
      scope: scope, agents: [.antigravity], environment: f.environment)
    #expect(
      changed.findings.contains { $0.reason == .contentDrift && $0.location.path == managed.path })
  }

  @Test(arguments: [InstallMode.copy, .link, .edit])
  func managedSkillReadsActualPromptAndManagedFilesReportDrift(_ mode: InstallMode) throws {
    let fixture = try UpdateFixture()
    try fixture.writeSource("Fixture \u{200b}")
    try fixture.commit()
    try fixture.install(mode: mode, agents: [.codex])
    let target = ".agents/skills/demo/SKILL.md"
    let report = ContentAuditOperations.scan(agents: [.codex], environment: fixture.environment)
    #expect(report.targets.first { $0.path == target }?.ownership == .managedFile)
    #expect(report.findings.contains { $0.location.path == target && $0.codePoint == 0x200b })
    #expect(report.targets.first { $0.path == "AGENTS.md" }?.ownership == .managedFile)
    #expect(report.passesCI)
    #expect(
      report.readLocations.contains {
        $0.path.contains("/cache/") && $0.lastPathComponent == "SKILL.md"
      } == (mode == .link))
    if mode == .edit {
      #expect(report.readLocations.contains { $0.path.hasSuffix("/source/skills/demo/SKILL.md") })
    }
    try fixture.write("Changed", to: fixture.instruction())
    #expect(
      ContentAuditOperations.scan(environment: fixture.environment).findings.contains {
        $0.location.path == "AGENTS.md" && $0.reason == .contentDrift
      })
    #expect(
      ContentAuditOperations.scan(file: fixture.instruction(), environment: fixture.environment)
        .passesCI)
  }

  @Test func regionalMarkdownOwnershipUsesPhysicalOffsetsWithBOMAndCRLF() throws {
    let fixture = try UpdateFixture()
    let file = fixture.root.appendingPathComponent("CLAUDE.md")
    try fixture.write("Initial local context.\n", to: file)
    try fixture.install(mode: .copy, agents: [.claudeCode])
    let generated = try String(contentsOf: file, encoding: .utf8)
    try #require(generated.contains("@AGENTS.md"))
    let edited = generated.replacingOccurrences(of: "@AGENTS.md", with: "@AGENTS.md\u{200b}")
      .replacingOccurrences(of: "\n", with: "\r\n")
    try fixture.write("\u{feff}Authored\u{200b}\r\n\r\n" + edited, to: file)

    let report = ContentAuditOperations.scan(file: file, environment: fixture.environment)
    #expect(report.targets.first?.ownership == .managedRegion)
    #expect(report.findings.map(\.ownership) == [.untracked, .managedRegion])
    #expect(report.findings.map(\.codePoint) == [0x200b, 0x200b])
  }

  @Test func managedNativeRegionsUseLedgerEvidenceIndependentlyOfUntrackedSiblings() throws {
    let fixture = try UpdateFixture()
    let config = fixture.root.appendingPathComponent("opencode.jsonc")
    try fixture.write(
      #"{"commands":{"local":{"template":"Other\u200B"}},"unrelated":"\u202E",}"#, to: config)
    try fixture.store.save(
      declaration: Declaration(components: [
        .command(
          name: "managed", description: "Fixture command",
          prompt: .literal("Read \u{200b} sources"),
          agents: [.opencode])
      ]), ledger: ResolvedLedger())
    _ = try fixture.apply()
    let report = ContentAuditOperations.scan(agents: [.opencode], environment: fixture.environment)
    #expect(report.passesCI)
    #expect(report.findings.count == 2)
    #expect(
      report.findings.first { $0.location.field == "/commands/managed/template" }?.ownership
        == .managedRegion)
    #expect(
      report.findings.first { $0.location.field == "/commands/local/template" }?.ownership
        == .untracked)
  }

  @Test func unavailableOwnershipAndPendingRecoveryAreCoverageFailures() throws {
    let fixture = try Fixture()
    try fixture.write("AGENTS.md", "Review\u{200b}")
    let state = try fixture.write(".agent/agents.resolved", "{wrong")
    let corrupt = ContentAuditOperations.scan(environment: fixture.environment)
    #expect(corrupt.findings.contains { $0.reason == .ownershipUnavailable })
    #expect(corrupt.findings.contains { $0.codePoint == 0x200b && $0.ownership == .unknown })
    #expect(!corrupt.passesCI)
    let journal = try fixture.write(".agent/transaction.json", "fixture pending")
    let pending = ContentAuditOperations.scan(environment: fixture.environment)
    #expect(pending.findings.map(\.reason) == [.pendingRecovery])
    #expect(try Data(contentsOf: journal) == Data("fixture pending".utf8))
    #expect(try Data(contentsOf: state) == Data("{wrong".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.url(".agent/.agents.lock").path))
  }

  private final class Fixture {
    let root: URL
    let environment: RuntimeEnvironment

    init() throws {
      let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      root = temporary.appendingPathComponent("content-audit-" + UUID().uuidString)
      environment = RuntimeEnvironment(
        projectDirectory: root.appendingPathComponent("project"),
        homeDirectory: root.appendingPathComponent("home"), environment: [:])
      try FileManager.default.createDirectory(
        at: environment.projectDirectory, withIntermediateDirectories: true)
      do {
        try FileManager.default.createDirectory(
          at: environment.homeDirectory, withIntermediateDirectories: true)
      } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
      }
    }

    deinit {
      do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }

    func url(_ path: String) -> URL { environment.projectDirectory.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
      let file = url(path)
      try writeAbsolute(file, text)
      return file
    }

    func writeAbsolute(_ file: URL, _ text: String) throws {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
  }
}
