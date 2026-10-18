import Foundation
import Testing

@testable import AgentsCore

@Suite("Agent Registry")
struct AgentRegistryTests {
  @Test func resolvesAgentDirectoriesAndLockLocations() throws {
    let project = try behaviorTemporaryDirectory()
    let home = try behaviorTemporaryDirectory()
    let codexHome = try behaviorTemporaryDirectory()
    let claudeHome = try behaviorTemporaryDirectory()
    let xdgConfig = try behaviorTemporaryDirectory()
    let xdgCache = try behaviorTemporaryDirectory()
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
      InstallLockStore.globalLockURL(environment: environment).standardizedFileURL.path
        == home.appendingPathComponent(".agents/skills.resolved").standardizedFileURL.path)
    #expect(
      AgentRegistry.skillsDirectory(for: .codex, scope: .global, environment: environment).path
        == codexHome.appendingPathComponent("skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .claudeCode, scope: .global, environment: environment).path
        == claudeHome.appendingPathComponent("skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .cursor, scope: .global, environment: environment).path
        == home.appendingPathComponent(".cursor/skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .geminiCLI, scope: .project, environment: environment).path
        == project.appendingPathComponent(".agents/skills").path)
    #expect(
      AgentRegistry.skillsDirectory(for: .geminiCLI, scope: .global, environment: environment).path
        == home.appendingPathComponent(".gemini/skills").path)
    #expect(try AgentID.parse("gemini") == .geminiCLI)
    #expect(try AgentID.parse("gemini-cli") == .geminiCLI)
    #expect(
      AgentRegistry.skillsDirectory(for: .opencode, scope: .global, environment: environment).path
        == xdgConfig.appendingPathComponent("opencode/skills").path)
    #expect(
      AgentRegistry.sourceCacheDirectory(scope: .project, environment: environment).path
        == project.appendingPathComponent(".agent/cache/sources").path)
    #expect(
      AgentRegistry.sourceCacheDirectory(scope: .global, environment: environment).path
        == xdgCache.appendingPathComponent("skill-cli/sources").path)
    #expect(
      AgentRegistry.canonicalSkillsDirectory(scope: .global, environment: environment).path
        == home.appendingPathComponent(".agents/skills").path)
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .codex, scope: .global, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .cursor, scope: .global, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .geminiCLI, scope: .global, environment: environment))
    #expect(
      AgentRegistry.usesCanonicalSkillsDirectory(
        for: .opencode, scope: .global, environment: environment))
    #expect(
      !AgentRegistry.usesCanonicalSkillsDirectory(
        for: .claudeCode, scope: .global, environment: environment))
  }

}

private func behaviorTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("skill-cli-behavior-tests")
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
