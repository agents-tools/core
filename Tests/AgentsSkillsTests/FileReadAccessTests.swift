import AgentsCore
import CPlatform
import Foundation
import Testing

@testable import AgentsSkills

@Suite(
  "Skill file read access",
  .enabled(if: geteuid() != 0, "Permission-denial checks require an unprivileged user"),
  .timeLimit(.minutes(1)))
struct SkillFileReadAccessTests {
  @Test func unreadableCachedArtifactStopsRestoreWithoutFetching() throws {
    let fixture = try SkillFixture()
    let store = fixture.store()
    let cache = SourceCache(store: store)
    let bytes = Data("---\nname: demo\ndescription: Test skill\n---\n".utf8)
    let digest = "sha256:" + FileHash.sha256Hex(data: bytes)
    let cached = try store.withLock { try cache.storeArtifact(bytes, digest: digest) }
    let artifact = LockedArtifact(
      type: .skillMD, url: "https://example.test/SKILL.md", digest: digest)
    let provider = WellKnownProvider { _ in
      Issue.record("An unreadable cached artifact must not trigger a fetch")
      return bytes
    }
    try withUnreadableFile(cached) {
      _ = try provider.restore(artifact, cache: cache)
    }
    #expect(try Data(contentsOf: cached) == bytes)
  }

  @Test func unreadableSkillFileStopsInspectionAndDiscovery() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    let directory = fixture.repo.appendingPathComponent("skills/demo")
    let file = directory.appendingPathComponent("SKILL.md")
    let lifecycle = try SkillLifecycle(store: fixture.store(), provider: WellKnownProvider())
    try withUnreadableFile(file) { _ = try lifecycle.entries(directory) }
    try withUnreadableFile(file) { _ = try Discovery.parseSkill(at: file) }
  }

  @Test(arguments: ["marketplace.json", "plugin.json"])
  func unreadablePluginMetadataStopsDiscovery(_ name: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    let directory = fixture.repo.appendingPathComponent(".claude-plugin")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appendingPathComponent(name)
    try Data("{}".utf8).write(to: file)
    try withUnreadableFile(file) { _ = try Discovery.discover(in: fixture.repo) }
  }
}

private func withUnreadableFile(_ file: URL, _ body: () throws -> Void) throws {
  let bytes = try Data(contentsOf: file)
  var original = stat()
  try #require(lstat(file.path, &original) == 0)
  try #require(chmod(file.path, 0) == 0)
  defer { chmod(file.path, original.st_mode & 0o777) }
  for _ in 0..<2 {
    #expect {
      try body()
    } throws: { error in
      guard case CoreError.invalidState(let message) = error else { return false }
      let prefix = "permission denied: "
      let suffix = "; check the directory's permissions and default ACL"
      guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return false }
      let path = String(message.dropFirst(prefix.count).dropLast(suffix.count))
      return URL(fileURLWithPath: path).resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
    }
    var current = stat()
    try #require(lstat(file.path, &current) == 0)
    #expect(current.st_mode & 0o777 == 0 && current.st_ino == original.st_ino)
  }
  try #require(chmod(file.path, original.st_mode & 0o777) == 0)
  #expect(try Data(contentsOf: file) == bytes)
}
