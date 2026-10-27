import Foundation

/// Fixed agent instruction destinations shared by lifecycle planning and journal validation.
package enum InstructionLocations {
  package static let projectPaths = [
    "AGENTS.md", "GEMINI.md", "CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md",
  ]

  /// Whether a project-relative path is a root instruction file, or a generated `AGENTS.md` or
  /// `GEMINI.md` in a project directory outside any `.git` and the top-level `.agent`.
  package static func isProjectTarget(_ relative: String) -> Bool {
    if projectPaths.contains(relative) { return true }
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, let name = parts.last, ["AGENTS.md", "GEMINI.md"].contains(name)
    else { return false }
    let directories = parts.dropLast()
    return directories.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" && !$0.contains("\\")
        && !$0.contains("\0")
    } && directories.first != ".agent"
  }

  package static func file(
    for agent: AgentID, scope: InstallScope, environment: RuntimeEnvironment
  ) -> URL? {
    if scope == .project {
      return environment.projectDirectory.appendingPathComponent(
        agent == .geminiCLI ? "GEMINI.md" : "AGENTS.md")
    }
    guard agent != .cursor else { return nil }
    let directory = AgentRegistry.userSkillsDirectory(for: agent, environment: environment)
      .deletingLastPathComponent()
    let name = agent == .claudeCode ? "CLAUDE.md" : agent == .geminiCLI ? "GEMINI.md" : "AGENTS.md"
    return directory.appendingPathComponent(name)
  }

  package static func physical(_ file: URL) -> URL {
    file.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(file.lastPathComponent).standardizedFileURL
  }

  package static func key(for file: URL, store: StateStore) -> String {
    let base =
      (store.scope == .project
      ? store.environment.projectDirectory : store.environment.homeDirectory)
      .resolvingSymlinksInPath()
    if PathSafety.isContained(file, in: base) {
      return (store.scope == .user ? "~/" : "") + PathSafety.relativePath(file.path, to: base.path)
    }
    return file.path
  }

  package static func file(for key: String, store: StateStore) throws -> URL {
    let file: URL
    if key.hasPrefix("/") {
      guard store.scope == .user else { throw CoreError.unsafePath("absolute project target") }
      file = URL(fileURLWithPath: key)
    } else if key.hasPrefix("~/"), store.scope == .user {
      file = try PathSafety.resolvedChild(
        base: store.environment.homeDirectory.resolvingSymlinksInPath(),
        subpath: String(key.dropFirst(2)))
    } else if store.scope == .project {
      file = try PathSafety.resolvedChild(
        base: store.environment.projectDirectory.resolvingSymlinksInPath(), subpath: key)
    } else {
      throw CoreError.unsafePath("user instruction target must be home-relative or absolute")
    }
    let allowed: [URL]
    if store.scope == .project {
      guard isProjectTarget(key) else {
        throw CoreError.unsafePath("unregistered instruction target: \(key)")
      }
      allowed = [store.environment.projectDirectory.appendingPathComponent(key)]
    } else {
      allowed = AgentID.allCases.compactMap {
        self.file(for: $0, scope: .user, environment: store.environment)
      }
    }
    guard allowed.map(physical).contains(file.standardizedFileURL) else {
      throw CoreError.unsafePath("unregistered instruction target: \(key)")
    }
    return file.standardizedFileURL
  }
}
