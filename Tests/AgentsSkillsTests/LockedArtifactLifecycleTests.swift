import AgentsCore
import Darwin
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

extension LockedArtifactLifecycleTests {
  @Test func restoresArchiveLockAfterInterruptedExpansionPublication() throws {
    let fixture = try SkillFixture()
    let project = fixture.environment.projectDirectory
    let expanded = project.appendingPathComponent("new")
    try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
    let markdown = Data("---\nname: demo\ndescription: Test skill\n---\narchive content\n".utf8)
    try markdown.write(to: expanded.appendingPathComponent("SKILL.md"))
    try Data("reference".utf8).write(to: expanded.appendingPathComponent("z-reference.md"))
    let archive = fixture.root.appendingPathComponent("demo.tar.gz")
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["tar", "-czf", archive.path, "-C", expanded.path, "."])
    let bytes = try Data(contentsOf: archive)
    let digest = "sha256:" + FileHash.sha256Hex(data: bytes)
    let base = "https://example.test"
    let url = base + "/demo.tar.gz"
    let index = try JSONSerialization.data(withJSONObject: [
      "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
      "skills": [
        [
          "name": "demo", "description": "Test skill", "type": "archive", "url": url,
          "digest": digest,
        ]
      ],
    ])
    _ = try SkillOperations.add(
      AddOptions(source: base, agents: [.codex], all: true, environment: fixture.environment),
      provider: WellKnownProvider { $0.path.hasSuffix("index.json") ? index : bytes })
    let store = fixture.store()
    let lock = try Data(contentsOf: store.resolvedURL)
    try FileManager.default.removeItem(at: store.cacheDirectory)
    try FileManager.default.removeItem(at: fixture.target("demo"))
    let child = try artifactTestProcess(root: project)
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = project.appendingPathComponent("ready")
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: marker.path))
    let final = store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + digest.dropFirst(7))
    #expect(!FileManager.default.fileExists(atPath: final.path))
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let restore = WellKnownProvider {
      guard $0.absoluteString == url else {
        throw CoreError.invalidState("restore consulted index")
      }
      return bytes
    }
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) {
      try SkillOperations.install(
        scope: .project, environment: fixture.environment, provider: restore)
    }
    _ = try SkillOperations.install(
      scope: .project, environment: fixture.environment, provider: restore)
    #expect(try FileHash.folderHash(fixture.target("demo")) == FileHash.folderHash(expanded))
    #expect(try Data(contentsOf: store.resolvedURL) == lock)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        == [final.lastPathComponent])
  }

  private func artifactTestProcess(root: URL) throws -> Process {
    var directory = Bundle(for: ArtifactTestBundle.self).bundleURL.deletingLastPathComponent()
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let process = Process()
    process.executableURL = directory.appendingPathComponent("StateTestProcess")
    process.arguments = [root.path, "cache-content", "stage.0.copy.entry"]
    try process.run()
    return process
  }
}

private final class ArtifactTestBundle: NSObject {}
