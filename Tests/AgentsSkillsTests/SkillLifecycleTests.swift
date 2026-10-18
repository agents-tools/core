import AgentsCore
import Foundation
import Testing

@testable import AgentsSkills

@Suite("Declared skill lifecycle")
struct SkillLifecycleTests {
  @Test(arguments: [InstallMode.link, .copy], [InstallScope.project, .user])
  func restoresPinnedContentAndPreservesLock(_ mode: InstallMode, _ scope: InstallScope) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let first = try fixture.head()
    _ = try fixture.add(mode: mode, scope: scope)
    let store = fixture.store(scope)
    let bytes = try Data(contentsOf: store.resolvedURL)
    try fixture.skill("demo", body: "B")
    try fixture.commit()
    let target = fixture.target("demo", scope: scope)
    try FileManager.default.removeItem(at: target)
    _ = try SkillOperations.installResolvedReport(scope: scope, environment: fixture.environment)
    #expect(try fixture.body(target).contains("A"))
    #expect(try store.loadResolved().skills["demo"]?.revision == first)
    #expect(try Data(contentsOf: store.resolvedURL) == bytes)
  }

  @Test func previewIsReadOnlyAndApplyReportsBeforeReplacing() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let lock = try Data(contentsOf: fixture.store().resolvedURL)
    let declaration = try Data(contentsOf: fixture.store().declarationURL)
    try fixture.skill("demo", body: "B")
    try fixture.commit()
    let preview = try SkillOperations.updateInstalled(environment: fixture.environment)
    #expect(preview.first?.changed == true)
    #expect(preview.first?.changes.isEmpty == false)
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lock)
    #expect(try Data(contentsOf: fixture.store().declarationURL) == declaration)
    #expect(try fixture.body(fixture.target("demo")).contains("A"))
    var called = false
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true) {
      changes in
      called = true
      #expect(changes.first?.newRevision != changes.first?.oldRevision)
      let oldBody = try fixture.body(fixture.target("demo"))
      #expect(oldBody.contains("A"))
    }
    #expect(called)
    #expect(try fixture.body(fixture.target("demo")).contains("B"))
    #expect(try fixture.store().loadResolved().skills["demo"]?.revision == fixture.head())
  }

  @Test func namedUpdateKeepsOtherPinAndRejectsMissingUpstreamMember() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    let old = try fixture.store().loadResolved().skills["two"]
    try fixture.skill("one", body: "B")
    try fixture.skill("two", body: "B")
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(
      environment: fixture.environment, skillNames: ["one"], apply: true)
    #expect(try fixture.store().loadResolved().skills["two"] == old)
    #expect(try fixture.body(fixture.target("two")).contains("A"))
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("skills/one"))
    try fixture.commit()
    let bytes = try Data(contentsOf: fixture.store().resolvedURL)
    #expect(throws: (any Error).self) {
      try SkillOperations.updateInstalled(
        environment: fixture.environment, skillNames: ["one"], apply: true)
    }
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == bytes)
  }

  @Test func allReconcilesMembershipAndRemovalPersistsExclusion() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    try fixture.skill("two", body: "B")
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(FileManager.default.fileExists(atPath: fixture.target("two").path))
    try SkillOperations.remove(skillNames: ["one"], environment: fixture.environment)
    #expect(try fixture.store().loadDeclaration().skills?["fixture"]?.exclude == ["one"])
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(!FileManager.default.fileExists(atPath: fixture.target("one").path))
    try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("skills/two"))
    try fixture.commit()
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.store().loadResolved().skills.isEmpty)
  }

  @Test func rejectsNameAndSourceIdentityCollisions() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    let other = fixture.root.appendingPathComponent("other")
    _ = try SkillOperations.initializeSkill(named: "demo", directory: other)
    try initGitRepo(other)
    let bytes = try Data(contentsOf: fixture.store().resolvedURL)
    #expect(throws: (any Error).self) {
      try SkillOperations.add(
        AddOptions(source: other.path, all: true, environment: fixture.environment))
    }
    #expect(throws: (any Error).self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path, alias: "duplicate", all: true, environment: fixture.environment
        ))
    }
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == bytes)
  }

  @Test(arguments: [InstallMode.link, .copy])
  func localGitIgnoresDirtyContentAndDoctorReportsIt(_ mode: InstallMode) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "committed")
    try fixture.commit()
    try fixture.skill("demo", body: "uncommitted")
    _ = try fixture.add(mode: mode)
    #expect(!(try fixture.body(fixture.target("demo"))).contains("uncommitted"))
    let doctor = try SkillOperations.doctor(environment: fixture.environment)
    #expect(doctor.checks.contains { $0.id == "uncommitted-source" })
  }

  @Test func editLinksLiveContentWithoutPinAndRejectsRequirements() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    _ = try fixture.add(mode: .edit)
    let locked = try #require(try fixture.store().loadResolved().skills["demo"])
    #expect(locked.revision == nil && locked.hash == nil && locked.artifact == nil)
    try fixture.skill("demo", body: "changed")
    #expect(try fixture.body(fixture.target("demo")).contains("changed"))
    #expect(throws: (any Error).self) {
      try SkillOperations.add(
        AddOptions(
          source: fixture.repo.path, mode: .edit, sourceRequirement: .branch("master"),
          environment: fixture.environment))
    }
  }

  @Test(arguments: [InstallMode.link, .copy])
  func rejectsNonGitPinnedSources(_ mode: InstallMode) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "live")
    #expect(throws: (any Error).self) { try fixture.add(mode: mode) }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
  }

  @Test(arguments: ["agents.json", "agents.resolved"], ["add", "update", "install", "remove"])
  func corruptStateStopsEveryMutation(_ filename: String, _ operation: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let corrupt = fixture.store().directory.appendingPathComponent(filename)
    try Data("{broken".utf8).write(to: corrupt)
    let before = try fixture.stateAndTargetBytes()
    #expect(throws: (any Error).self) {
      switch operation {
      case "add": _ = try fixture.add()
      case "update":
        _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
      case "install":
        _ = try SkillOperations.installResolvedReport(environment: fixture.environment)
      default: try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
      }
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }

  @Test func sharedMaterializationSurvivesUntilLastConsumerIsRemoved() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    let one = fixture.target("one").resolvingSymlinksInPath().deletingLastPathComponent()
    let two = fixture.target("two").resolvingSymlinksInPath().deletingLastPathComponent()
    #expect(one == two)
    try SkillOperations.remove(skillNames: ["one"], environment: fixture.environment)
    #expect(FileManager.default.fileExists(atPath: two.path))
    try SkillOperations.remove(skillNames: ["two"], environment: fixture.environment)
    #expect(!FileManager.default.fileExists(atPath: two.path))
  }

  @Test func skillMutationsPreserveInstructionAndWatchDeclarations() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add()
    var declaration = try fixture.store().loadDeclaration()
    declaration.instructions = InstructionsDeclaration(
      sections: ["fixture:rules"],
      chatgpt: ["prompt": PromptDeclaration(sections: ["fixture:rules"])])
    declaration.watch = ["fixture"]
    var lock = try fixture.store().loadResolved()
    let skill = try #require(lock.skills["demo"])
    lock.instructions = LockedInstructions(sections: [
      LockedSection(
        name: "rules", source: skill.source, revision: skill.revision,
        path: "instructions/rules.md", hash: skill.hash!)
    ])
    try fixture.store().save(declaration: declaration, resolved: lock)
    try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    #expect(try fixture.store().loadResolved().instructions == lock.instructions)
    #expect(try fixture.store().loadDeclaration().instructions == declaration.instructions)
    #expect(try fixture.store().loadDeclaration().watch == ["fixture"])
  }

  @Test func listsMissingAndDriftedInstallsAndCreatesSkeleton() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try Data("drift".utf8).write(to: fixture.target("one").appendingPathComponent("extra.md"))
    try FileManager.default.removeItem(at: fixture.target("two"))
    let listed = try SkillOperations.listManaged(environment: fixture.environment)
    #expect(listed.contains { $0.name == "one" && $0.status == .copyDrift })
    #expect(listed.contains { $0.name == "two" && $0.status == .missing })
    let report = try SkillOperations.doctor(environment: fixture.environment)
    #expect(report.checks.count == 2)
    let skeleton = try SkillOperations.initializeSkill(named: "My Skill", directory: fixture.root)
    #expect(skeleton.lastPathComponent == "my-skill")
    #expect(throws: (any Error).self) {
      try SkillOperations.initializeSkill(named: "My Skill", directory: fixture.root)
    }
  }

  @Test func multipleUnselectedSkillsAreListedWithoutState() throws {
    let fixture = try SkillFixture()
    try fixture.skill("one", body: "A")
    try fixture.skill("two", body: "A")
    try fixture.commit()
    let outcome = try SkillOperations.add(
      AddOptions(source: fixture.repo.path, environment: fixture.environment))
    #expect(outcome.availableSkills.count == 2 && outcome.installed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
  }

  @Test func callbackFailureLeavesEverythingUnchanged() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try fixture.skill("demo", body: "B")
    try fixture.commit()
    let before = try fixture.stateAndTargetBytes()
    #expect(throws: CoreError.self) {
      try SkillOperations.updateInstalled(environment: fixture.environment, apply: true) { _ in
        throw CoreError.invalidState("cancel")
      }
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }
}

final class SkillFixture {
  let root: URL
  let repo: URL
  let environment: RuntimeEnvironment

  init() throws {
    root = try temporaryDirectory()
    repo = root.appendingPathComponent("source")
    environment = RuntimeEnvironment(
      projectDirectory: root.appendingPathComponent("project"),
      homeDirectory: root.appendingPathComponent("home"), environment: [:])
  }

  deinit { removeTemporaryDirectory(root) }

  func store(_ scope: InstallScope = .project) -> StateStore {
    StateStore(scope: scope, environment: environment)
  }
  func skill(_ name: String, body: String) throws {
    let directory = repo.appendingPathComponent("skills/\(name)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: Test skill\n---\n\n\(body)\n".write(
      to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }
  func commit() throws {
    if !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
      try initGitRepo(repo)
    } else {
      try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path, "add", "."])
      try ProcessRunner.run(
        "/usr/bin/env",
        arguments: ["git", "-C", repo.path, "commit", "--allow-empty", "-m", "fixture"])
    }
  }
  func head() throws -> String { try gitHead(repo) }
  func add(mode: InstallMode = .link, scope: InstallScope = .project) throws -> AddOutcome {
    try SkillOperations.add(
      AddOptions(
        source: repo.path, alias: "fixture", agents: [.codex], scope: scope, mode: mode, all: true,
        environment: environment))
  }
  func target(_ name: String, scope: InstallScope = .project) -> URL {
    (scope == .project ? environment.projectDirectory : environment.homeDirectory)
      .appendingPathComponent(".agents/skills/\(name)")
  }
  func body(_ target: URL) throws -> String {
    try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
  }
  func stateAndTargetBytes() throws -> [Data] {
    try [
      Data(contentsOf: store().declarationURL), Data(contentsOf: store().resolvedURL),
      Data(contentsOf: target("demo").appendingPathComponent("SKILL.md")),
    ]
  }
}
