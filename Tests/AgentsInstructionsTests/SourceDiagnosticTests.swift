import AgentsCore
import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction source diagnostics")
struct InstructionSourceDiagnosticTests {
  @Test(arguments: [SourceKind.local, .git])
  func annotatedTagObjectRevisionsResolveToLockedCommits(_ kind: SourceKind) throws {
    let fixture = try InstructionFixture()
    try fixture.section("file")
    try fixture.section("prompt")
    try fixture.commit()
    try fixture.git(["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "release"])
    let object = try fixture.git(["rev-parse", "release"])
    let commit = try fixture.git(["rev-parse", "release^{commit}"])
    #expect(object != commit)
    try install(fixture, kind: kind, requirement: .revision(object))
    try fixture.git(["tag", "--delete", "release"])
    for apply in [false, true] {
      if apply {
        _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
      }
      let lock = try fixture.store().loadResolved()
      #expect(lock.instructions.sections.first?.revision == commit)
      #expect(lock.instructions.chatgpt["daily"]?.sections.first?.revision == commit)
      let before = try fixture.snapshot()
      let report = try InstructionOperations.doctor(environment: fixture.environment)
      #expect(
        !report.diagnostics.contains {
          $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
        })
      #expect(try fixture.snapshot() == before)
    }
  }

  @Test(arguments: [true, false])
  func advertisedTagObjectsResolveWithoutFetching(_ retainMirror: Bool) throws {
    let fixture = try InstructionFixture()
    try fixture.section("prompt")
    try fixture.commit()
    let commit = try fixture.git(["rev-parse", "HEAD"])
    try install(fixture, kind: .git, requirement: .revision(commit), files: [])
    try fixture.git(["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "release"])
    let object = try fixture.git(["rev-parse", "release"])
    var declaration = try fixture.store().loadDeclaration()
    declaration.sources["rules"]?.requirement = .revision(object)
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    let mirrors = fixture.store().cacheDirectory.appendingPathComponent("mirrors")
    if retainMirror {
      try fixture.section("prompt", body: "New branch content")
      try fixture.commit()
    } else {
      try FileManager.default.removeItem(at: mirrors)
    }
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(
      !report.diagnostics.contains {
        $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
      })
    #expect(try fixture.snapshot() == before)
    #expect(FileManager.default.fileExists(atPath: mirrors.path) == retainMirror)
  }

  @Test(arguments: ["missing", "tree", "tagged-tree"])
  func unresolvedObjectRevisionsAreReportedWithoutWrites(_ objectKind: String) throws {
    let fixture = try InstructionFixture()
    try fixture.section("prompt")
    try fixture.commit()
    let commit = try fixture.git(["rev-parse", "HEAD"])
    try install(fixture, kind: .git, requirement: .revision(commit), files: [])
    let object: String
    switch objectKind {
    case "tree": object = try fixture.git(["rev-parse", "HEAD^{tree}"])
    case "tagged-tree":
      try fixture.git(["-c", "tag.gpgsign=false", "tag", "-a", "tree", "HEAD^{tree}", "-m", "tree"])
      object = try fixture.git(["rev-parse", "tree"])
    default: object = String(repeating: "a", count: 40)
    }
    var declaration = try fixture.store().loadDeclaration()
    declaration.sources["rules"]?.requirement = .revision(object)
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(
      report.diagnostics.contains {
        $0.kind == .sourceResolutionFailed && $0.message.contains(object)
      })
    #expect(!report.diagnostics.contains { $0.kind == .sourceUpdateAvailable })
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [SourceKind.local, .git])
  func newerBranchRevisionsIncludeFileAndPromptPinsWithoutWrites(_ kind: SourceKind) throws {
    let fixture = try InstructionFixture()
    try fixture.section("file")
    try fixture.section("prompt")
    try fixture.commit()
    try install(fixture, kind: kind, requirement: .branch("main"))
    let first = try fixture.git(["rev-parse", "HEAD"])
    #expect(
      try !InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
      })
    try fixture.section("file", body: "New file instructions")
    try fixture.section("prompt", body: "New prompt instructions")
    try fixture.commit()
    let second = try fixture.git(["rev-parse", "HEAD"])
    #expect(try fixture.git(["--no-optional-locks", "status", "--porcelain"]).isEmpty)
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    let update = try #require(report.diagnostics.first { $0.kind == .sourceUpdateAvailable })
    #expect(update.message.contains(first) && update.message.contains(second))
    #expect(update.message.contains("File sections: file"))
    #expect(update.message.contains("ChatGPT prompt pins: daily"))
    #expect(
      !report.diagnostics.contains {
        $0.kind == .sourceResolutionFailed || $0.kind == .uncommittedSource
      })
    let audits = InstructionOperations.doctor(
      projectRoots: [fixture.project], environment: fixture.environment)
    #expect(audits.first == report)
    #expect(try fixture.snapshot() == before)
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(
      try !InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
      })
  }

  @Test(arguments: [SourceKind.local, .git])
  func promptOnlyPinsUseMatchingVersionBoundsAndAnnotatedTags(_ kind: SourceKind) throws {
    let fixture = try InstructionFixture()
    try fixture.section("prompt")
    try fixture.commit()
    try fixture.git(["-c", "tag.gpgsign=false", "tag", "v1.0.0"])
    try install(fixture, kind: kind, requirement: .upToNextMinor(from: "1.0.0"), files: [])
    try fixture.section("prompt", body: "Unmatched version")
    try fixture.commit()
    try fixture.git(["-c", "tag.gpgsign=false", "tag", "v1.1.0"])
    #expect(
      try !InstructionOperations.doctor(environment: fixture.environment).diagnostics.contains {
        $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
      })
    try fixture.git(["-c", "tag.gpgsign=false", "tag", "-a", "v1.0.1", "-m", "matching"])
    let expected = try fixture.git(["rev-parse", "v1.0.1^{commit}"])
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    let update = try #require(report.diagnostics.first { $0.kind == .sourceUpdateAvailable })
    #expect(update.message.contains(expected + " (1.0.1)"))
    #expect(update.message.contains("ChatGPT prompt pins: daily"))
    #expect(!update.message.contains("File sections:"))
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [SourceKind.local, .git])
  func unavailableMatchingRevisionIsReportedWithoutWrites(_ kind: SourceKind) throws {
    let fixture = try InstructionFixture()
    try fixture.section("prompt")
    try fixture.commit()
    try install(fixture, kind: kind, requirement: .branch("main"), files: [])
    var declaration = try fixture.store().loadDeclaration()
    declaration.sources["rules"]?.requirement = .branch("missing")
    try fixture.store().save(declaration: declaration, resolved: fixture.store().loadResolved())
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    let failure = try #require(report.diagnostics.first { $0.kind == .sourceResolutionFailed })
    if kind == .local {
      #expect(failure.message.contains("Git could not read a revision from \(fixture.repo.path)."))
      #expect(!failure.message.contains("Command failed:"))
    } else {
      #expect(failure.message.contains("missing"))
    }
    #expect(!report.diagnostics.contains { $0.kind == .sourceUpdateAvailable })
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: [SourceKind.local, .git])
  func immutablePinsDoNotAdvanceWithTheBranch(_ kind: SourceKind) throws {
    let fixture = try InstructionFixture()
    try fixture.section("prompt")
    try fixture.commit()
    let pin = try fixture.git(["rev-parse", "HEAD"])
    try install(fixture, kind: kind, requirement: .revision(pin), files: [])
    try fixture.section("prompt", body: "New branch content")
    try fixture.commit()
    let before = try fixture.snapshot()
    let report = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(
      !report.diagnostics.contains {
        $0.kind == .sourceUpdateAvailable || $0.kind == .sourceResolutionFailed
      })
    #expect(try fixture.snapshot() == before)
  }

  private func install(
    _ fixture: InstructionFixture, kind: SourceKind, requirement: SourceRequirement,
    files: [String] = ["file"]
  ) throws {
    let source = SourceDeclaration(
      kind: kind,
      location: kind == .local ? fixture.repo.path : "file://localhost" + fixture.repo.path,
      requirement: requirement)
    try fixture.store().save(
      declaration: Declaration(
        agents: [.codex], sources: ["rules": source],
        instructions: InstructionsDeclaration(
          sections: files.map { "rules:" + $0 },
          chatgpt: ["daily": PromptDeclaration(sections: ["rules:prompt"])])),
      resolved: ResolvedState())
    _ = try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true)
  }
}
