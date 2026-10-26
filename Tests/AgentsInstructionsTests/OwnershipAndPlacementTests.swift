import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Ownership, placement and restore safety")
struct OwnershipAndPlacementTests {
  @Test func lockedTargetWithoutTheNoticeNeedsReplace() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add()
    let file = fixture.project.appendingPathComponent("AGENTS.md")
    let handWritten =
      "# Project\n\nHand notes.\n\n<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->\n# rules\n\nOriginal\n<!-- END managed by agents -->\n"
    try fixture.write(handWritten, to: file)
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .foreignTarget && $0.path == file
      })
    #expect(throws: InstructionError.unownedTargets(["AGENTS.md"])) {
      try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    }
    #expect(throws: InstructionError.unownedTargets(["AGENTS.md"])) {
      try InstructionOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try fixture.text() == handWritten)
    _ = try InstructionOperations.updateInstalled(
      environment: fixture.environment, apply: true, replace: true)
    #expect(try fixture.text() == generated(["# rules\n\nOriginal"]))
  }

  @Test func retiringATargetNeverWritesOverAFileThatDiffersFromItsLock() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.addOwn(names: ["guide"])
    let handWritten = "# Project\n\nHand notes.\n"
    try fixture.write(handWritten, to: fixture.project.appendingPathComponent("AGENTS.md"))
    let report = try InstructionOperations.remove(
      names: ["guide"], environment: fixture.environment)
    #expect(report.targets.first?.changed == false)
    #expect(try fixture.text() == handWritten)
    #expect(try fixture.store().loadResolved().instructions.targets.isEmpty)
  }

  @Test func removeSelectsTheDeclaredReferenceBeforeASourceName() throws {
    let fixture = try InstructionFixture()
    try fixture.section("guide", heading: "# Shared Guide")
    try fixture.commit()
    try fixture.add(names: ["guide"])
    try fixture.own("guide", heading: "# Project Guide")
    try fixture.addOwn(names: ["guide"])
    #expect(
      try fixture.store().loadDeclaration().instructions?.sections == ["rules:guide", "guide"])
    try InstructionOperations.remove(names: ["guide"], environment: fixture.environment)
    #expect(try fixture.store().loadDeclaration().instructions?.sections == ["rules:guide"])
    #expect(try fixture.text() == generated(["# Shared Guide\n\nOriginal"]))
  }

  @Test func nestedTargetsStayInRealDirectoriesOfThisCheckout() throws {
    let fixture = try InstructionFixture()
    let sources = fixture.project.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent("Alias"), withDestinationURL: sources)
    try fixture.own("alias", paths: ["Alias/**"])
    #expect(throws: CoreError.self) { try fixture.addOwn(names: ["alias"]) }
    try fixture.write(
      "gitdir: elsewhere\n", to: fixture.project.appendingPathComponent("vendor/lib/.git"))
    try fixture.own("vendor", paths: ["vendor/lib/**"])
    #expect(throws: CoreError.self) { try fixture.addOwn(names: ["vendor"]) }
    for path in ["Sources/AGENTS.md", "vendor/lib/AGENTS.md"] {
      #expect(
        !FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(path).path))
    }
  }

  @Test func installKeepsTheLockedClaudeImportWithoutRecomputingIt() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    let directory = fixture.project.appendingPathComponent(".claude/CLAUDE.md")
    try fixture.write("# Claude\n\nCustom.\n", to: directory)
    try fixture.add()
    #expect(
      try fixture.store().loadResolved().instructions.targets[".claude/CLAUDE.md"]?.import
        == "../AGENTS.md")
    try FileManager.default.removeItem(at: directory)
    let root = fixture.project.appendingPathComponent("CLAUDE.md")
    try fixture.write("# Root\n", to: root)
    let report = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    #expect(report.targets.first { $0.target == ".claude/CLAUDE.md" }?.drift == .missing)
    #expect(try String(contentsOf: root, encoding: .utf8) == "# Root\n")
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func unrelatedOwnFilesDoNotAffectLockedOrSelectedOnes() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.addOwn(names: ["guide"])
    try fixture.write(
      "# Draft without front matter\n",
      to: fixture.project.appendingPathComponent(".agent/instructions/draft.md"))
    #expect(throws: Never.self) {
      _ = try InstructionOperations.installResolvedReport(environment: fixture.environment)
    }
    #expect(try !InstructionOperations.updateInstalled(environment: fixture.environment).hasChanges)
    #expect(throws: InstructionError.self) {
      try InstructionOperations.listOwn(environment: fixture.environment)
    }
    try fixture.own("second")
    try fixture.addOwn(names: ["second"])
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: []) }
    let mapping = InstructionOperations.export(
      projectRoots: [fixture.project], environment: fixture.environment)[1]
    #expect(mapping.unplaced.isEmpty)
    #expect(mapping.targets.map { $0.sections.map(\.name) } == [["guide", "second"]])
  }

  @Test func ownInstructionsContainerCannotBeASymbolicLink() throws {
    let fixture = try InstructionFixture()
    let units = fixture.project.appendingPathComponent("docs/units")
    try fixture.write(unitText("guide"), to: units.appendingPathComponent("guide.md"))
    try FileManager.default.createDirectory(
      at: fixture.project.appendingPathComponent(".agent"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent(".agent/instructions"), withDestinationURL: units)
    #expect(throws: CoreError.self) {
      try InstructionOperations.listOwn(environment: fixture.environment)
    }
    #expect(throws: CoreError.self) { try fixture.addOwn(names: ["guide"]) }
  }

  @Test func linksResolveSymbolicLinksBeforeParentSegmentsAndRejectRawHTML() throws {
    let fixture = try InstructionFixture()
    let outside = fixture.root.appendingPathComponent("outside/subdir")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.project.appendingPathComponent("link"), withDestinationURL: outside)
    let readme = fixture.project.appendingPathComponent("README.md")
    try fixture.write("Read me.\n", to: readme)
    try fixture.own("parent", body: "[Read](link/../README.md)")
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: ["parent"]) }
    try fixture.own("html", body: "<a href=\"README.md\">Read</a>")
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: ["html"]) }
    try fixture.own("checks", body: "[Read](README.md)")
    try fixture.addOwn(names: ["checks"])
    try FileManager.default.removeItem(at: readme)
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .invalidLink
      })
  }

  @Test func doctorReportsChangedOwnFilesUsedOnlyByPrompts() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.write(
      "{\"instructions\": {\"sections\": [], \"chatgpt\": {\"weekly\": {\"sections\": [\"guide\"]}}}}\n",
      to: fixture.store().declarationURL)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try fixture.store().loadResolved().instructions.chatgpt["weekly"]?.sections.map(\.name)
        == ["guide"])
    try fixture.own("guide", body: "Edited")
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .ownChanged
      })
  }

  @Test func doctorReportsClaudeFilesThatHideNestedTargets() throws {
    let fixture = try InstructionFixture()
    let sources = fixture.project.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try fixture.own("swift", paths: ["Sources/**"])
    try fixture.addOwn(names: ["swift"])
    func forwarding() throws -> [URL?] {
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics
        .filter { $0.kind == .claudeForwarding }.map(\.path)
    }
    #expect(try forwarding().isEmpty)
    try fixture.write("# Root\n", to: fixture.project.appendingPathComponent("CLAUDE.md"))
    #expect(try forwarding() == [sources.appendingPathComponent("AGENTS.md")])
    try fixture.write("# Sources\n", to: sources.appendingPathComponent("CLAUDE.md"))
    #expect(try forwarding() == [sources.appendingPathComponent("CLAUDE.md")])
    try fixture.write("@AGENTS.md\n", to: sources.appendingPathComponent("CLAUDE.md"))
    #expect(try forwarding().isEmpty)
  }

  @Test func discoverySkipsGeneratedTargetNames() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.write(
      generated(["# Scoped\n\nFor instructions files."]),
      to: fixture.repo.appendingPathComponent("instructions/AGENTS.md"))
    try fixture.commit()
    let units = try InstructionOperations.list(
      source: SourceDeclaration(kind: .local, location: fixture.repo.path),
      environment: fixture.environment)
    #expect(units.map(\.record.name) == ["rules"])
  }

  @Test func exportPlacesUserSectionsWithoutTheirContent() throws {
    let fixture = try InstructionFixture()
    try fixture.section("rules")
    try fixture.commit()
    try fixture.add(scope: .user, agents: [.codex])
    try FileManager.default.removeItem(at: fixture.store(.user).cacheDirectory)
    let user = InstructionOperations.export(projectRoots: [], environment: fixture.environment)[0]
    #expect(user.unplaced.isEmpty)
    #expect(user.targets.map { $0.sections.map(\.name) } == [["rules"]])
  }
}
