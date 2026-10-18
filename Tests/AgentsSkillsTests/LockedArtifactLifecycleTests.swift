import AgentsCore
import Foundation
import Testing

@testable import AgentsSkills

@Suite("Locked artifacts")
struct LockedArtifactLifecycleTests {
  @Test(arguments: [false, true])
  func restoresWithoutIndexAndVerifiesDigests(_ filesArtifact: Bool) throws {
    let fixture = try SkillFixture()
    let content = Data("---\nname: demo\ndescription: Test skill\n---\nA\n".utf8)
    let digest = "sha256:" + FileHash.sha256Hex(data: content)
    let base = "https://example.test"
    let artifactURL = base + "/demo/SKILL.md"
    let fileURL = base + "/.well-known/agent-skills/demo/SKILL.md"
    let index =
      filesArtifact
      ? Data(#"{"skills":[{"name":"demo","description":"Test skill","files":["SKILL.md"]}]}"#.utf8)
      : Data(
        "{\"$schema\":\"https://schemas.agentskills.io/discovery/0.2.0/schema.json\",\"skills\":[{\"name\":\"demo\",\"description\":\"Test skill\",\"type\":\"skill-md\",\"url\":\"\(artifactURL)\",\"digest\":\"\(digest)\"}]}"
          .utf8)
    let provider = WellKnownProvider { url in
      if url.path.hasSuffix("index.json") { return index }
      if [artifactURL, fileURL].contains(url.absoluteString) { return content }
      throw CoreError.notFound("URL")
    }
    _ = try SkillOperations.add(
      AddOptions(
        source: base, agents: [.codex], mode: .copy, all: true, environment: fixture.environment),
      provider: provider)
    let locked = try fixture.store().loadResolved()
    let artifact = try #require(locked.skills["demo"]?.artifact)
    #expect(artifact.type == (filesArtifact ? .files : .skillMD))
    if filesArtifact {
      #expect(artifact.files?.first?.url == fileURL)
      #expect(artifact.files?.first?.digest == digest)
    }
    let lockBytes = try Data(contentsOf: fixture.store().resolvedURL)
    try FileManager.default.removeItem(at: fixture.store().cacheDirectory)
    try FileManager.default.removeItem(at: fixture.target("demo"))
    let restore = WellKnownProvider { url in
      guard [artifactURL, fileURL].contains(url.absoluteString) else {
        throw CoreError.invalidState("restore consulted index")
      }
      return content
    }
    _ = try SkillOperations.install(
      scope: .project, environment: fixture.environment, provider: restore)
    #expect(
      try Data(contentsOf: fixture.target("demo").appendingPathComponent("SKILL.md")) == content)
    #expect(try Data(contentsOf: fixture.store().resolvedURL) == lockBytes)
    try FileManager.default.removeItem(at: fixture.store().cacheDirectory)
    let before = try fixture.stateAndTargetBytes()
    let mismatch = WellKnownProvider { _ in Data("different content".utf8) }
    #expect(throws: (any Error).self) {
      try SkillOperations.install(
        scope: .project, environment: fixture.environment, provider: mismatch)
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }

  @Test func cachedArtifactCorruptionStopsRestore() throws {
    let fixture = try SkillFixture()
    let content = Data("---\nname: demo\ndescription: Test skill\n---\nA\n".utf8)
    let url = "https://example.test/demo/SKILL.md"
    let provider = WellKnownProvider { _ in content }
    _ = try SkillOperations.add(
      AddOptions(source: url, agents: [.codex], mode: .copy, environment: fixture.environment),
      provider: provider)
    let locked = try fixture.store().loadResolved()
    let digest = try #require(locked.skills["demo"]?.artifact?.digest)
    let cached = try SourceCache(store: fixture.store()).artifactURL(digest: digest)
    try Data("corrupt".utf8).write(to: cached)
    let before = try fixture.stateAndTargetBytes()
    #expect(throws: (any Error).self) {
      try SkillOperations.install(
        scope: .project, environment: fixture.environment, provider: provider)
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }
}

extension LockedArtifactLifecycleTests {
  @Test func namedUpdateFetchesOnlySelectedArtifactAndAllFollowsEmptyIndex() throws {
    let fixture = try SkillFixture()
    let first = Data("---\nname: one\ndescription: Test\n---\nA\n".utf8)
    let second = Data("---\nname: two\ndescription: Test\n---\nA\n".utf8)
    let index = Data(
      #"{"skills":[{"name":"one","description":"Test","files":["SKILL.md"]},{"name":"two","description":"Test","files":["SKILL.md"]}]}"#
        .utf8)
    let provider = WellKnownProvider { url in
      if url.path.hasSuffix("index.json") { return index }
      return url.path.contains("/one/") ? first : second
    }
    _ = try SkillOperations.add(
      AddOptions(
        source: "https://example.test", agents: [.codex], all: true,
        environment: fixture.environment), provider: provider)
    let old = try fixture.store().loadResolved().skills["two"]
    let changed = Data("---\nname: one\ndescription: Test\n---\nB\n".utf8)
    let selectedOnly = WellKnownProvider { url in
      if url.path.hasSuffix("index.json") { return index }
      guard url.path.contains("/one/") else {
        throw CoreError.invalidState("unselected artifact fetched")
      }
      return changed
    }
    _ = try SkillOperations.update(
      scope: .project, environment: fixture.environment, skillNames: ["one"], apply: true,
      provider: selectedOnly)
    #expect(try fixture.store().loadResolved().skills["two"] == old)
    let empty = WellKnownProvider { _ in Data(#"{"skills":[]}"#.utf8) }
    _ = try SkillOperations.update(
      scope: .project, environment: fixture.environment, skillNames: [], apply: true,
      provider: empty)
    #expect(try fixture.store().loadResolved().skills.isEmpty)
  }
}
