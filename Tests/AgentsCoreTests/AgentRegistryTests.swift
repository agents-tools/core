import Foundation
import Testing

@testable import AgentsCore

@Suite("Agent Registry")
struct AgentRegistryTests {
  @Test func resolvesAgentDirectoriesAndLockLocations() throws {
    let project = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let home = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let codexHome = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let claudeHome = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: claudeHome) }
    let xdgConfig = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: xdgConfig) }
    let xdgCache = try behaviorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: xdgCache) }
    let environment = RuntimeEnvironment(
      projectDirectory: project,
      homeDirectory: home,
      environment: [
        "CODEX_HOME": codexHome.path,
        "CLAUDE_CONFIG_DIR": claudeHome.path,
        "XDG_CONFIG_HOME": xdgConfig.path,
        "XDG_CACHE_HOME": xdgCache.path,
      ])

    #expect(
      InstallLockStore.projectLockURL(environment: environment).standardizedFileURL.path
        == project.appendingPathComponent(".agent/skills.resolved").standardizedFileURL.path)
    #expect(
      InstallLockStore.userLockURL(environment: environment).standardizedFileURL.path
        == home.appendingPathComponent(".agents/skills.resolved").standardizedFileURL.path)
    #expect(
      AgentRegistry.skillsDirectory(for: .codex, scope: .user, environment: environment).path
        == codexHome.appendingPathComponent("skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .claudeCode, scope: .user, environment: environment).path
        == claudeHome.appendingPathComponent("skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .cursor, scope: .user, environment: environment).path
        == home.appendingPathComponent(".cursor/skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .geminiCLI, scope: .project, environment: environment).path
        == project.appendingPathComponent(".agents/skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .geminiCLI, scope: .user, environment: environment).path
        == home.appendingPathComponent(".gemini/skills").path)
    #expect(try AgentID.parse("gemini") == .geminiCLI)
    #expect(try AgentID.parse("gemini-cli") == .geminiCLI)
    #expect(
      AgentRegistry.skillsDirectory(for: .opencode, scope: .user, environment: environment).path
        == xdgConfig.appendingPathComponent("opencode/skills").path)
    #expect(
      AgentRegistry.sourceCacheDirectory(scope: .project, environment: environment).path
        == project.appendingPathComponent(".agent/cache/sources").path)
    #expect(
      AgentRegistry.sourceCacheDirectory(scope: .user, environment: environment).path
        == xdgCache.appendingPathComponent("skill-cli/sources").path)
    #expect(
      AgentRegistry.canonicalSkillsDirectory(scope: .user, environment: environment).path
        == home.appendingPathComponent(".agents/skills").path)
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .codex, scope: .user, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .cursor, scope: .user, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .geminiCLI, scope: .user, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .opencode, scope: .user, environment: environment))
    #expect(
      !AgentRegistry.usesCanonicalSkillsDirectory(
        for: .claudeCode, scope: .user, environment: environment))
  }

}

private func behaviorTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("skill-cli-behavior-tests")
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
