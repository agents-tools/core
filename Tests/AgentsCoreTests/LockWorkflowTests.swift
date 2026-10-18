import Foundation
import Testing

@testable import AgentsCore

extension InstallLockTests {
  @Test func migratesLocalLockEntriesFromCompatibilityFormat() throws {
    let project = try temporaryDirectory()
    let environment = RuntimeEnvironment(
      projectDirectory: project, homeDirectory: try temporaryDirectory(), environment: [:])
    try FileManager.default.createDirectory(
      at: InstallLockStore.projectLockURL(environment: environment).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try """
    {
      "version": 1,
      "skills": {
        "demo-skill": {
          "source": "owner/repo",
          "ref": "main",
          "sourceType": "github",
          "skillPath": "skills/demo-skill/SKILL.md",
          "computedHash": "abc123"
        }
      }
    }
    """.write(
      to: InstallLockStore.projectLockURL(environment: environment), atomically: true,
      encoding: .utf8
    )

    let lock = try InstallLockStore.load(scope: .project, environment: environment)
    #expect(lock.pins.count == 1)
    #expect(lock.pins[0].identity == "owner/repo")
    #expect(lock.pins[0].location == "https://github.com/owner/repo.git")
    #expect(lock.pins[0].skills[0].path == "skills/demo-skill/SKILL.md")
    #expect(lock.pins[0].skills[0].contentHash == "abc123")
  }
}
