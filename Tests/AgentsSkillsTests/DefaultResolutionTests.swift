import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Unqualified skill resolution")
struct DefaultResolutionTests {
  @Test(arguments: ["revision", "branch", "exact", "range"])
  func warmMirrorMatchesColdAddThroughDefaultChanges(_ requirementKind: String) throws {
    let fixture = try SkillFixture()
    func git(_ arguments: [String]) throws {
      try ProcessRunner.run(
        "/usr/bin/env", arguments: ["git", "-C", fixture.repo.path] + arguments)
    }
    func commit(_ body: String) throws -> String {
      for name in ["pinned", "tagged", "default", "switched"] {
        try fixture.skill(name, body: body)
      }
      try fixture.commit()
      return try fixture.head()
    }
    let first = try commit("1.0.0")
    try git(["tag", "v1.0.0"])
    let minor = try commit("1.2.0")
    try git(["tag", "v1.2.0"])
    try git(["branch", "selected"])
    let latest = try commit("2.0.0")
    try git(["tag", "v2.0.0"])
    let defaultHead = try commit("default branch")
    try git(["checkout", "-b", "next"])
    let nextHead = try commit("new default branch")
    try git(["checkout", "master"])

    let requirement: SourceRequirement
    let selectedRevision: String
    switch requirementKind {
    case "revision":
      requirement = .revision(first)
      selectedRevision = first
    case "branch":
      requirement = .branch("selected")
      selectedRevision = minor
    case "exact":
      requirement = .exact("1.0.0")
      selectedRevision = first
    default:
      requirement = .upToNextMajor(from: "1.0.0")
      selectedRevision = minor
    }
    let declaration = Declaration(sources: [
      "upstream": SourceDeclaration(kind: .git, location: "file://localhost" + fixture.repo.path)
    ])
    try fixture.store().save(declaration: declaration, resolved: ResolvedState())
    _ = try SkillOperations.add(
      AddOptions(
        source: "upstream", agents: [.codex], skillNames: ["pinned"],
        sourceRequirement: requirement, environment: fixture.environment))
    let pinned = try #require(fixture.store().loadResolved().skills["pinned"])
    #expect(pinned.revision == selectedRevision)
    let pinnedBody = try fixture.body(fixture.target("pinned"))
    let pinnedLink = try FileManager.default.destinationOfSymbolicLink(
      atPath: fixture.target("pinned").path)
    let mirror = SourceCache(store: fixture.store()).mirrorURL(sourceID: pinned.source)
    #expect(FileManager.default.fileExists(atPath: mirror.path))
    var unqualified = try fixture.store().loadDeclaration()
    unqualified.sources["upstream"]?.requirement = nil
    try fixture.store().save(declaration: unqualified, resolved: fixture.store().loadResolved())

    func expectDefault(_ name: String, revision: String, version: String?, body: String) throws {
      let cold = RuntimeEnvironment(
        projectDirectory: fixture.root.appendingPathComponent("cold-\(name)"),
        homeDirectory: fixture.environment.homeDirectory, environment: [:])
      let coldStore = StateStore(scope: .project, environment: cold)
      try coldStore.save(declaration: declaration, resolved: ResolvedState())
      #expect(!FileManager.default.fileExists(atPath: coldStore.cacheDirectory.path))
      let warm = try SkillOperations.add(
        AddOptions(
          source: "upstream", agents: [.codex], skillNames: [name], environment: fixture.environment
        ))
      let fresh = try SkillOperations.add(
        AddOptions(source: "upstream", agents: [.codex], skillNames: [name], environment: cold))
      let warmSkill = try #require(fixture.store().loadResolved().skills[name])
      let coldSkill = try #require(coldStore.loadResolved().skills[name])
      #expect(warmSkill == coldSkill)
      #expect(warmSkill.revision == revision)
      #expect(warmSkill.version == version)
      #expect(try fixture.store().loadDeclaration().sources["upstream"]?.requirement == nil)
      let warmTarget = URL(fileURLWithPath: try #require(warm.installed.first).path)
      let coldTarget = URL(fileURLWithPath: try #require(fresh.installed.first).path)
      #expect(try fixture.body(warmTarget) == fixture.body(coldTarget))
      #expect(try fixture.body(warmTarget).hasSuffix("\n\(body)\n"))
      #expect(try fixture.store().loadResolved().skills["pinned"] == pinned)
      #expect(try fixture.body(fixture.target("pinned")) == pinnedBody)
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: fixture.target("pinned").path)
          == pinnedLink)
    }

    try expectDefault("tagged", revision: latest, version: "2.0.0", body: "2.0.0")
    try git(["tag", "--delete", "v1.0.0", "v1.2.0", "v2.0.0"])
    try expectDefault("default", revision: defaultHead, version: nil, body: "default branch")
    try git(["symbolic-ref", "HEAD", "refs/heads/next"])
    try expectDefault("switched", revision: nextHead, version: nil, body: "new default branch")
  }
}
