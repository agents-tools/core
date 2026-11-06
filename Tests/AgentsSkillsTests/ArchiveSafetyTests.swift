import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Archive path safety")
struct ArchiveSafetyTests {
  @Test(arguments: [
    "../escape", "../escape/", "nested/../../escape", "nested\\..\\..\\escape", "/absolute",
    "/absolute/", "link",
  ])
  func rejectsZipTraversalAbsolutePathsAndSymlinks(_ path: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let before = try fixture.stateAndTargetBytes()
    let archive = zipArchive(entries: [
      ("SKILL.md", Data("---\nname: zip-skill\ndescription: Test\n---".utf8), 0o100644),
      (
        path, path.hasSuffix("/") ? Data() : Data("payload".utf8),
        path == "link" ? 0o120777 : path.hasSuffix("/") ? 0o040755 : 0o100644
      ),
    ])
    let digest = "sha256:" + FileHash.sha256Hex(data: archive)
    let index = Data(
      "{\"$schema\":\"https://schemas.agentskills.io/discovery/0.2.0/schema.json\",\"skills\":[{\"name\":\"zip-skill\",\"type\":\"archive\",\"description\":\"Test\",\"url\":\"skill.zip\",\"digest\":\"\(digest)\"}]}"
        .utf8)
    let provider = WellKnownProvider { url in url.path.hasSuffix("index.json") ? index : archive }
    let expected: CoreError =
      path == "link"
      ? .invalidSource("well-known archive contains unsupported entry type")
      : .unsafePath(
        path.hasPrefix("/")
          ? "subpath must be relative: \(path)" : "subpath contains path traversal segment: \(path)"
      )
    #expect(throws: expected) {
      try SkillOperations.add(
        AddOptions(
          source: "https://zip.test", agents: [.codex], all: true, environment: fixture.environment),
        provider: provider)
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }

  @Test func rejectsAbsoluteTarPaths() throws {
    let fixture = try SkillFixture()
    let file = fixture.root.appendingPathComponent("absolute")
    try Data("sentinel".utf8).write(to: file)
    let archive = fixture.root.appendingPathComponent("absolute.tar.gz")
    try ProcessRunner.run("/usr/bin/env", arguments: ["tar", "-czPf", archive.path, file.path])
    let data = try Data(contentsOf: archive)
    let artifact = LockedArtifact(
      type: .archive, url: "https://archive.test/absolute.tar.gz",
      digest: "sha256:" + FileHash.sha256Hex(data: data))
    let provider = WellKnownProvider { _ in data }
    #expect(throws: CoreError.unsafePath("subpath must be relative: \(file.path)")) {
      try provider.restore(artifact, cache: SourceCache(store: fixture.store()))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "sentinel")
  }

  @Test func generatedZipFixtureIsAValidArchive() throws {
    let fixture = try SkillFixture()
    let skill = Data("---\nname: demo\ndescription: Test\n---".utf8)
    let data = zipArchive(entries: [("SKILL.md", skill, 0o100644)])
    let provider = WellKnownProvider { _ in data }
    let artifact = LockedArtifact(
      type: .archive, url: "https://archive.test/skill.zip",
      digest: "sha256:" + FileHash.sha256Hex(data: data))
    let restored = try provider.restore(artifact, cache: SourceCache(store: fixture.store()))
    #expect(restored.files["SKILL.md"] == skill)
  }
}
