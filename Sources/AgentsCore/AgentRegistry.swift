import Foundation

public enum AgentID: String, Codable, CaseIterable, Sendable {
  case codex
  case claudeCode = "claude-code"
  case cursor
  case geminiCLI = "gemini-cli"
  case opencode

  public var displayName: String {
    switch self {
    case .codex:
      return "Codex"
    case .claudeCode:
      return "Claude Code"
    case .cursor:
      return "Cursor"
    case .geminiCLI:
      return "Gemini CLI"
    case .opencode:
      return "OpenCode"
    }
  }

  public static func parse(_ raw: String) throws -> AgentID {
    if raw == "claude" || raw == "claude-code" {
      return .claudeCode
    }
    if raw == "gemini" || raw == "gemini-cli" {
      return .geminiCLI
    }
    guard let id = AgentID(rawValue: raw) else {
      throw CoreError.unsupported(
        "unsupported agent '\(raw)'. Supported agents: \(AgentID.supportedList)")
    }
    return id
  }

  public static var supportedList: String {
    AgentID.allCases.map(\.rawValue).joined(separator: ", ")
  }
}

public enum InstallScope: String, Codable, Sendable {
  case project
  case user
}

public enum InstallMode: String, Codable, Sendable {
  case link
  case copy
  case edit
}

public struct RuntimeEnvironment: Sendable {
  public var projectDirectory: URL
  public var homeDirectory: URL
  public var environment: [String: String]

  public init(
    projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    homeDirectory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.projectDirectory = projectDirectory.standardizedFileURL
    let resolvedHome =
      homeDirectory
      ?? environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    self.homeDirectory = resolvedHome.standardizedFileURL
    self.environment = environment
  }
}

package enum AgentRegistry {
  package static func canonicalSkillsDirectory(
    scope: InstallScope, environment: RuntimeEnvironment
  ) -> URL {
    switch scope {
    case .project:
      return environment.projectDirectory.appendingPathComponent(".agents/skills")
    case .user:
      return environment.homeDirectory.appendingPathComponent(".agents/skills")
    }
  }

  package static func usesCanonicalSkillsDirectory(
    for agent: AgentID, scope: InstallScope, environment: RuntimeEnvironment
  ) -> Bool {
    switch scope {
    case .project:
      let canonical = canonicalSkillsDirectory(scope: scope, environment: environment)
        .standardizedFileURL.path
      return projectSkillsDirectory(for: agent, environment: environment).standardizedFileURL.path
        == canonical
    case .user:
      return usesUniversalProjectSkillsDirectory(for: agent, environment: environment)
    }
  }

  package static func installSkillsDirectory(
    for agent: AgentID, scope: InstallScope, environment: RuntimeEnvironment
  ) -> URL {
    if usesCanonicalSkillsDirectory(for: agent, scope: scope, environment: environment) {
      return canonicalSkillsDirectory(scope: scope, environment: environment)
    }
    return skillsDirectory(for: agent, scope: scope, environment: environment)
  }

  package static func projectSkillsDirectory(for agent: AgentID, environment: RuntimeEnvironment)
    -> URL
  {
    switch agent {
    case .claudeCode:
      return environment.projectDirectory.appendingPathComponent(".claude/skills")
    case .codex, .cursor, .geminiCLI, .opencode:
      return environment.projectDirectory.appendingPathComponent(".agents/skills")
    }
  }

  package static func userSkillsDirectory(for agent: AgentID, environment: RuntimeEnvironment)
    -> URL
  {
    switch agent {
    case .claudeCode:
      let base = environment.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      return URL(
        fileURLWithPath: base ?? environment.homeDirectory.appendingPathComponent(".claude").path
      )
      .appendingPathComponent("skills")
    case .codex:
      let codexHome = environment.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      return URL(
        fileURLWithPath: codexHome
          ?? environment.homeDirectory.appendingPathComponent(".codex").path
      )
      .appendingPathComponent("skills")
    case .cursor:
      return environment.homeDirectory.appendingPathComponent(".cursor/skills")
    case .geminiCLI:
      return environment.homeDirectory.appendingPathComponent(".gemini/skills")
    case .opencode:
      let configHome =
        environment.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? environment.homeDirectory.appendingPathComponent(".config").path
      return URL(fileURLWithPath: configHome).appendingPathComponent("opencode/skills")
    }
  }

  package static func nativeUserScanDirectories(
    for agent: AgentID, environment: RuntimeEnvironment
  ) -> [URL] {
    switch agent {
    case .codex, .cursor, .geminiCLI, .opencode:
      return [
        userSkillsDirectory(for: agent, environment: environment),
        environment.homeDirectory.appendingPathComponent(".agents/skills"),
      ]
    case .claudeCode:
      return [userSkillsDirectory(for: agent, environment: environment)]
    }
  }

  package static func projectScanDirectories(
    for agent: AgentID, environment: RuntimeEnvironment
  ) -> [URL] {
    let primary = projectSkillsDirectory(for: agent, environment: environment)
    let additional: [URL]
    switch agent {
    case .geminiCLI:
      additional = [environment.projectDirectory.appendingPathComponent(".gemini/skills")]
    case .codex, .claudeCode, .cursor, .opencode:
      additional = []
    }
    return uniqueDirectories([primary] + additional)
  }

  package static func skillsDirectory(
    for agent: AgentID, scope: InstallScope, environment: RuntimeEnvironment
  ) -> URL {
    switch scope {
    case .project:
      return projectSkillsDirectory(for: agent, environment: environment)
    case .user:
      return userSkillsDirectory(for: agent, environment: environment)
    }
  }

  private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
    var seen = Set<String>()
    return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private static func usesUniversalProjectSkillsDirectory(
    for agent: AgentID, environment: RuntimeEnvironment
  ) -> Bool {
    projectSkillsDirectory(for: agent, environment: environment).standardizedFileURL.path
      == environment.projectDirectory.appendingPathComponent(".agents/skills")
      .standardizedFileURL.path
  }

}

extension AgentRegistry {
  package struct ClientCommand: Sendable {
    package let name: String
    package let role: String
  }

  package static func clientCommands(for agent: AgentID) -> [ClientCommand] {
    switch agent {
    case .codex: [.init(name: "codex", role: "agentCLI")]
    case .claudeCode: [.init(name: "claude", role: "agentCLI")]
    case .geminiCLI: [.init(name: "gemini", role: "agentCLI")]
    case .opencode: [.init(name: "opencode", role: "agentCLI")]
    case .cursor:
      [
        .init(name: "cursor", role: "editorLauncher"),
        .init(name: "cursor-agent", role: "agentCLI"),
      ]
    }
  }

  // Registered editor bundle identity; the agent CLI has independent metadata.
  package static func clientBundleIdentifier(for agent: AgentID) -> String? {
    agent == .cursor ? "com.todesktop.230313mzl4w4u92" : nil
  }

  package static func clientSkillLocations(
    for agent: AgentID, scope: InstallScope, environment: RuntimeEnvironment
  ) -> [(String, URL)] {
    let scans =
      scope == .user
      ? nativeUserScanDirectories(for: agent, environment: environment)
      : projectScanDirectories(for: agent, environment: environment)
    return [
      ("skills.install", installSkillsDirectory(for: agent, scope: scope, environment: environment))
    ]
      + scans.enumerated().map { ("skills.scan.\($0.offset)", $0.element) }
  }
}

extension AgentRegistry {
  /// Only the bundled editor launcher carries this bundle metadata association.
  package static func clientBundle(for command: String, resolvedExecutable: URL) -> URL? {
    guard command == "cursor",
      resolvedExecutable.path.hasSuffix("/Contents/Resources/app/bin/cursor")
    else { return nil }
    var bundle = resolvedExecutable
    for _ in 0..<5 { bundle.deleteLastPathComponent() }
    return bundle
  }
}
