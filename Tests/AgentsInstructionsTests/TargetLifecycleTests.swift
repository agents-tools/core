import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Own instructions and generated targets")
struct TargetLifecycleTests {
  @Test func ownInstructionsAreReadLiveAndRecordedByHash() throws {
    let fixture = try InstructionFixture()
    try fixture.section("shared")
    try fixture.commit()
    try fixture.own("guide", heading: "# Project Guide")
    try fixture.own("review", heading: "## Code Review Rules")
    try fixture.add(names: ["shared"])
    try fixture.addOwn(names: ["guide", "review"])
    #expect(
      try fixture.store().loadDeclaration().instructions?.sections == [
        "rules:shared", "guide", "review",
      ])
    #expect(
      try fixture.text()
        == generated([
          "# shared\n\nOriginal", "# Project Guide\n\nOriginal", "## Code Review Rules\n\nOriginal",
        ]))
    let record = try #require(
      try fixture.store().loadResolved().instructions.sections.first { $0.name == "guide" })
    #expect(record.source == ".")
    #expect(record.path == ".agent/instructions/guide.md")
    #expect(record.revision == nil)
    #expect(try InstructionOperations.listOwn(environment: fixture.environment).count == 2)

    try fixture.own("guide", body: "Edited", heading: "# Project Guide")
    #expect(
      try InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .ownChanged
      })
    #expect(throws: InstructionError.ownChanged(name: "guide")) {
      try InstructionOperations.installResolvedReport(environment: fixture.environment)
    }
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.text().contains("# Project Guide\n\nEdited"))
    #expect(
      try !InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .ownChanged
      })
  }

  @Test func pathsPlaceSectionsInNestedTargets() throws {
    let fixture = try InstructionFixture()
    try FileManager.default.createDirectory(
      at: fixture.project.appendingPathComponent("Sources/Render"),
      withIntermediateDirectories: true)
    try fixture.own("guide")
    try fixture.own("render", paths: ["Sources/Render/**/*.swift"])
    try fixture.own("swift", paths: ["**/*.swift"])
    try fixture.addOwn(names: ["guide", "render", "swift"], agents: [.codex, .geminiCLI])
    let scope = "Applies when working on files matching"
    #expect(
      try fixture.text()
        == generated([
          "# guide\n\nOriginal", "# swift\n\n\(scope) `**/*.swift`.\n\nOriginal",
        ]))
    let nested = generated(["# render\n\n\(scope) `Sources/Render/**/*.swift`.\n\nOriginal"])
    #expect(try fixture.text("Sources/Render/AGENTS.md") == nested)
    #expect(try fixture.text("Sources/Render/GEMINI.md") == nested)
    #expect(
      Set(try fixture.store().loadResolved().instructions.targets.keys) == [
        "AGENTS.md", "GEMINI.md", "Sources/Render/AGENTS.md", "Sources/Render/GEMINI.md",
      ])
    try InstructionOperations.remove(names: ["render"], environment: fixture.environment)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.project.appendingPathComponent("Sources/Render/AGENTS.md").path))
  }

  @Test func nestedTargetsNeedExistingDirectoriesAndOwnedFiles() throws {
    let fixture = try InstructionFixture()
    try fixture.own("render", paths: ["Sources/Render/**"])
    #expect(throws: (any Error).self) { try fixture.addOwn(names: ["render"]) }
    try fixture.write(
      "Hand written.\n", to: fixture.project.appendingPathComponent("Sources/Render/AGENTS.md"))
    #expect(throws: InstructionError.unownedTargets(["Sources/Render/AGENTS.md"])) {
      try fixture.addOwn(names: ["render"])
    }
    try fixture.addOwn(names: ["render"], replace: true)
    #expect(try Instructions.isGenerated(fixture.bytes("Sources/Render/AGENTS.md")))
  }

  @Test func userTargetsScopeByTheLineAlone() throws {
    let fixture = try InstructionFixture()
    try fixture.section("swift", paths: ["**/*.swift"])
    try fixture.commit()
    try fixture.add(scope: .user, agents: [.codex])
    #expect(
      try String(
        contentsOf: fixture.home.appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)
        == generated([
          "# swift\n\nApplies when working on files matching `**/*.swift`.\n\nOriginal"
        ]))
  }

  @Test func linksMustResolveInTheCheckoutBeingWritten() throws {
    let fixture = try InstructionFixture()
    try fixture.write("Checks.\n", to: fixture.project.appendingPathComponent("CONTRIBUTING.md"))
    try fixture.own("guide", body: "Run [the checks](CONTRIBUTING.md#local).")
    try fixture.addOwn(names: ["guide"])
    try fixture.own("missing", body: "Read [notes](notes.md).")
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: ["missing"]) }
    try fixture.write("x\n", to: fixture.project.appendingPathComponent("vendor/lib/README.md"))
    try fixture.write(
      "gitdir: elsewhere\n", to: fixture.project.appendingPathComponent("vendor/lib/.git"))
    try fixture.own("vendor", body: "Read [lib](vendor/lib/README.md).")
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: ["vendor"]) }
    try fixture.own("outside", body: "Read [up](../home/x.md).")
    #expect(throws: InstructionError.self) { try fixture.addOwn(names: ["outside"]) }
    try fixture.section("linked", body: "See [guide](guide.md).")
    try fixture.commit()
    #expect(throws: InstructionError.self) {
      try fixture.add(names: ["linked"], scope: .user, agents: [.codex])
    }
    #expect(
      try fixture.text() == generated(["# guide\n\nRun [the checks](CONTRIBUTING.md#local)."]))
  }

  @Test func exportMapsTargetsToSectionsWithoutWriting() throws {
    let fixture = try InstructionFixture()
    try FileManager.default.createDirectory(
      at: fixture.project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try fixture.section("shared")
    try fixture.commit()
    try fixture.add(scope: .user, agents: [.codex])
    try fixture.own("guide")
    try fixture.own("sources", paths: ["Sources/**"])
    try fixture.addOwn(names: ["guide", "sources"], agents: [.codex])
    let empty = fixture.root.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let before = try fixture.snapshot()
    let mappings = InstructionOperations.export(
      projectRoots: [fixture.project, empty, fixture.project], environment: fixture.environment)
    #expect(mappings.map(\.scope) == [.user, .project, .project])
    #expect(mappings[0].targets.map(\.target) == ["~/.codex/AGENTS.md"])
    #expect(mappings[0].targets[0].sections.map(\.name) == ["shared"])
    let project = mappings[1]
    #expect(project.status == .locked)
    #expect(project.targets.map(\.target) == ["AGENTS.md", "Sources/AGENTS.md"])
    #expect(project.targets.map { $0.sections.map(\.name) } == [["guide"], ["sources"]])
    #expect(mappings[2].status == .missingLock)
    #expect(try fixture.snapshot() == before)
  }
}
