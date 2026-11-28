import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Watch source selection")
struct WatchSourceTests {
  @Test(arguments: ["alias", "identity", "location"])
  func addSelectsTheRequestedRootOfASharedRepository(_ input: String) throws {
    let fixture = try WatchGitFixture()
    try fixture.store.save(
      declaration: Declaration(sources: [
        "a": SourceDeclaration(kind: .local, location: fixture.repo.path, path: "."),
        "b": SourceDeclaration(kind: .local, location: fixture.repo.path, path: "second"),
      ]), ledger: ResolvedLedger())
    let sources = try fixture.store.loadDeclaration().sources
    let location =
      input == "alias"
      ? "b" : (input == "identity" ? fixture.id : fixture.repo.path) + "@path:second"
    let added = try fixture.watch.add(location, environment: fixture.environment)
    #expect(added.alias == "b" && added.sourceID == fixture.id)

    let second = fixture.repo.appendingPathComponent("second/instructions")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("---\ndescription: Second rule.\n---\n# Second\n".utf8)
      .write(to: second.appendingPathComponent("second.md"))
    try fixture.git(["add", "."])
    try fixture.git(["commit", "-m", "add second-root instructions"])

    let declaration = try fixture.store.loadDeclaration()
    #expect(declaration.sources == sources)
    #expect(declaration.watch == ["b"])
    let status = try #require(fixture.watch.status(environment: fixture.environment).first)
    #expect(status.alias == "b")
    #expect(status.changes.map(\.name) == ["second"])
  }

  @Test(arguments: [InstallScope.project, .user])
  func addAcceptsDeclaredLocalIdentityAndPreservesSource(_ scope: InstallScope) throws {
    let fixture = try WatchGitFixture()
    let store = StateStore(scope: scope, environment: fixture.environment)
    let source = SourceDeclaration(
      kind: .local, location: "./source", requirement: .exact("1.0.0"), path: "instructions",
      environment: SourceEnvironment(
        projectDirectory: fixture.environment.projectDirectory,
        homeDirectory: fixture.environment.homeDirectory))
    try store.save(declaration: Declaration(sources: ["source": source]), ledger: ResolvedLedger())
    let lock = try FileSnapshot.read(at: store.resolvedURL)

    let added = try fixture.watch.add(
      fixture.id, scope: scope, environment: fixture.environment)

    #expect(added.alias == "source" && added.sourceID == fixture.id)
    #expect(added.seen == .revision(try fixture.head()))
    let declaration = try store.loadDeclaration()
    #expect(declaration.sources == ["source": source])
    #expect(declaration.watch == ["source"])
    #expect(try store.loadWatch().sources[fixture.id]?.seen == added.seen)
    #expect(try FileSnapshot.read(at: store.resolvedURL) == lock)
  }

  @Test(arguments: ["alias", "identity", "location"])
  func selectorsReplaceDeclaredRequirementAndPath(_ input: String) throws {
    let fixture = try WatchGitFixture()
    let source = SourceDeclaration(
      kind: .local, location: "./source", requirement: .exact("1.0.0"), path: "instructions",
      environment: SourceEnvironment(
        projectDirectory: fixture.environment.projectDirectory,
        homeDirectory: fixture.environment.homeDirectory))
    try fixture.store.save(
      declaration: Declaration(sources: ["source": source]), ledger: ResolvedLedger())
    let topic = try fixture.head()
    try fixture.git(["branch", "topic"])
    try fixture.git(["commit", "--allow-empty", "-m", "advance default branch"])
    let location =
      input == "alias" ? "source" : input == "identity" ? fixture.id : fixture.repo.path

    let added = try fixture.watch.add(
      location + "@branch:topic@path:rules", requirement: .branch("topic"), path: "rules",
      environment: fixture.environment)

    #expect(added.alias == "source" && added.sourceID == fixture.id)
    #expect(added.seen == .revision(topic))
    #expect(
      try fixture.store.loadDeclaration().sources == [
        "source": SourceDeclaration(
          kind: .local, location: "./source", requirement: .branch("topic"), path: "rules",
          environment: SourceEnvironment(
            projectDirectory: fixture.environment.projectDirectory,
            homeDirectory: fixture.environment.homeDirectory))
      ])
  }

  @Test(arguments: ["requirement", "path", "skill"])
  func invalidSelectorsForDeclaredIdentityStopBeforeGit(_ kind: String) throws {
    let fixture = try WatchGitFixture()
    let before = try fixture.stateBytes()
    let selector =
      kind == "requirement" ? "@branch:master" : kind == "path" ? "@path:rules" : "@skill:demo"
    let reason =
      kind == "requirement"
      ? "the source selector and option give different requirements"
      : kind == "path"
        ? "the source selector and option give different paths"
        : "@skill: selects skills; watch subscribes to whole sources"

    #expect(throws: CoreError.invalidSource(reason)) {
      try fixture.watch.add(
        fixture.id + selector, requirement: kind == "requirement" ? .branch("topic") : nil,
        path: kind == "path" ? "other" : nil, environment: fixture.environment)
    }

    #expect(try fixture.stateBytes() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.mirror.path))
  }

  @Test func declaredIdentityIsPlannedBeforeGit() throws {
    let fixture = try WatchGitFixture()
    let before = try fixture.stateBytes()
    struct PlanningFailed: Error {}
    let watch = WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") },
      declarations: DeclarationAccess(
        read: DeclarationAccess.manifest.read,
        plan: { _, _, next, _ in
          #expect(next.sources.count == 1 && next.watch == ["source"])
          throw PlanningFailed()
        }))

    #expect(throws: PlanningFailed.self) {
      try watch.add(fixture.id, environment: fixture.environment)
    }
    #expect(try fixture.stateBytes() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.mirror.path))
  }
}
