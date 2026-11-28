import AgentsCore
import Components
import Foundation

struct ContentAuditProfile: Sendable {
  enum Format: Equatable, Sendable {
    case text
    case native(NativePromptAudit.Format)
  }

  struct Pattern: Sendable {
    let directory: String
    let selector: Selector
    let format: Format

    func matches(_ name: String) -> Bool {
      switch selector {
      case .named(let value): name.utf8.elementsEqual(value.utf8)
      case .suffix(let value): name.utf8.suffix(value.utf8.count).elementsEqual(value.utf8)
      }
    }
  }

  enum Selector: Hashable, Sendable {
    case named(String)
    case suffix(String)
  }

  let root: URL
  private let otherRoot: String?
  var files: [String: Format] = [:]
  var directories: [Pattern] = []
  var outsideScope: Set<String> = []
  var nestedInstructions: Set<String> = []

  init(
    scope: InstallScope, environment: RuntimeEnvironment, agents: Set<AgentID>
  ) {
    root =
      (scope == .project ? environment.projectDirectory : environment.homeDirectory)
      .standardizedFileURL
    let other = scope == .project ? environment.homeDirectory : environment.projectDirectory
    otherRoot = Self.relative(other, to: root).flatMap { $0 == "." ? nil : $0 }

    func relative(_ url: URL) -> String? { Self.relative(url, to: root) }
    let native = NativeTargetRoute.clientLocations(scope: scope, environment: environment)
    func registered(_ name: String) -> URL? {
      guard let location = native.first(where: { $0.identity == name + "." + scope.rawValue })
      else { return nil }
      return try? location.location.get()
    }
    func base(_ agent: AgentID) -> URL {
      switch agent {
      case .codex:
        registered("codex.hooks")?.deletingLastPathComponent()
          ?? root.appendingPathComponent(".codex")
      case .claudeCode:
        registered("claude.settings")?.deletingLastPathComponent()
          ?? root.appendingPathComponent(".claude")
      case .cursor: root.appendingPathComponent(".cursor")
      case .geminiCLI:
        registered("gemini.mcp")?.deletingLastPathComponent()
          ?? root.appendingPathComponent(".gemini")
      case .antigravity:
        AgentRegistry.installSkillsDirectory(for: agent, scope: scope, environment: environment)
          .deletingLastPathComponent()
      case .opencode:
        scope == .project
          ? root.appendingPathComponent(".opencode")
          : (try? native.first { $0.identity == "opencode.mcp.user.json" }?.location.get())?
            .deletingLastPathComponent()
            ?? AgentRegistry.userSkillsDirectory(for: .opencode, environment: environment)
            .deletingLastPathComponent()
      }
    }
    func addFile(_ url: URL, _ format: Format = .text) {
      if let path = relative(url), path != ".", !excludes(path) {
        files[path] = format
      } else {
        outsideScope.insert(url.lastPathComponent)
      }
    }
    func addDirectory(_ url: URL, _ selector: Selector, _ format: Format = .text) {
      guard let path = relative(url), path != ".", !excludes(path) else {
        outsideScope.insert(url.lastPathComponent + "/")
        return
      }
      guard
        !directories.contains(where: {
          $0.directory == path && $0.selector == selector && $0.format == format
        })
      else { return }
      directories.append(.init(directory: path, selector: selector, format: format))
    }

    for agent in AgentID.allCases where agents.contains(agent) {
      for (role, url) in InstructionLocations.clientFiles(
        for: agent, scope: scope, environment: environment)
      {
        if role == "instructions.rules" {
          addDirectory(url, .suffix(".md"))
        } else {
          addFile(url)
        }
      }
      for (_, url) in AgentRegistry.clientSkillLocations(
        for: agent, scope: scope, environment: environment)
      {
        addDirectory(url, .named("SKILL.md"))
      }

      let directory = base(agent)
      switch agent {
      case .codex:
        addDirectory(
          registered("codexAgent") ?? directory.appendingPathComponent("agents"),
          .suffix(".toml"), .native(.codexAgent))
        addFile(directory.appendingPathComponent("hooks.json"), .native(.commandHooks))
        addFile(
          (scope == .project ? root : directory).appendingPathComponent("AGENTS.override.md"))
        if scope == .project { nestedInstructions.formUnion(["AGENTS.md", "AGENTS.override.md"]) }
      case .claudeCode:
        addDirectory(directory.appendingPathComponent("rules"), .suffix(".md"))
        addDirectory(
          registered("claudeAgent") ?? directory.appendingPathComponent("agents"),
          .suffix(".md"))
        addDirectory(
          registered("claudeCommand") ?? directory.appendingPathComponent("commands"),
          .suffix(".md"))
        addDirectory(
          directory.appendingPathComponent("hooks"), .suffix(".json"), .native(.claudeHooks))
        addFile(directory.appendingPathComponent("settings.json"), .native(.claudeHooks))
        if scope == .project {
          addFile(directory.appendingPathComponent("settings.local.json"), .native(.claudeHooks))
          nestedInstructions.formUnion(["AGENTS.md", "CLAUDE.md"])
        }
      case .cursor:
        addDirectory(directory.appendingPathComponent("rules"), .suffix(".mdc"))
        addDirectory(
          registered("cursorAgent") ?? directory.appendingPathComponent("agents"),
          .suffix(".md"))
        if scope == .project {
          addDirectory(
            registered("cursorCommand") ?? directory.appendingPathComponent("commands"),
            .suffix(".md"))
          addFile(root.appendingPathComponent(".cursorrules"))
          nestedInstructions.insert("AGENTS.md")
        } else {
          addFile(directory.appendingPathComponent("AGENTS.md"))
        }
        addDirectory(
          directory.appendingPathComponent("hooks"), .suffix(".json"), .native(.cursorHooks))
        addFile(directory.appendingPathComponent("hooks.json"), .native(.cursorHooks))
      case .geminiCLI:
        addDirectory(
          registered("geminiCommand") ?? directory.appendingPathComponent("commands"),
          .suffix(".toml"), .native(.geminiCommand))
        addDirectory(
          registered("geminiAgent") ?? directory.appendingPathComponent("agents"),
          .suffix(".md"))
        addDirectory(
          directory.appendingPathComponent("hooks"), .suffix(".json"), .native(.commandHooks))
        addFile(directory.appendingPathComponent("settings.json"), .native(.commandHooks))
        if scope == .project {
          nestedInstructions.insert("GEMINI.md")
        } else {
          addFile(directory.appendingPathComponent("GEMINI.md"))
          addDirectory(directory.appendingPathComponent("skills"), .named("SKILL.md"))
        }
      case .opencode:
        addDirectory(directory.appendingPathComponent("agents"), .suffix(".md"))
        addDirectory(directory.appendingPathComponent("commands"), .suffix(".md"))
        let prefix = "opencode.mcp." + scope.rawValue
        for (suffix, format) in [
          ("json", NativePromptAudit.Format.openCodeJSON), ("jsonc", .openCodeJSONC),
        ] {
          let location = native.first { $0.identity == prefix + "." + suffix }
          if let url = try? location?.location.get() { addFile(url, .native(format)) }
        }
        if scope == .project {
          nestedInstructions.insert("AGENTS.md")
        } else {
          addFile(directory.appendingPathComponent("AGENTS.md"))
          addDirectory(directory.appendingPathComponent("skills"), .named("SKILL.md"))
        }
      case .antigravity:
        if let hooks = registered("antigravity.hooks") {
          addFile(hooks, .native(.antigravityHooks))
        }
        if scope == .project { nestedInstructions.insert("AGENTS.md") }
      }
    }
    if scope == .project && !agents.isEmpty {
      addDirectory(root.appendingPathComponent(".agent/instructions"), .suffix(".md"))
    }
  }

  func format(at path: String) -> Format? {
    if let exact = files[path] { return exact }
    let name = String(path.split(separator: "/").last ?? "")
    for pattern in directories
    where path.utf8.starts(with: (pattern.directory + "/").utf8) && pattern.matches(name) {
      return pattern.format
    }
    if nestedInstructions.contains(name),
      path.split(separator: "/").dropLast().allSatisfy({
        !$0.hasPrefix(".")
      })
    {
      return .text
    }
    return nil
  }

  func explicitFormat(at path: String) -> Format? {
    if let known = format(at: path) { return known }
    let suffix = (path as NSString).pathExtension.lowercased()
    return ["md", "mdc", "txt", "prompt"].contains(suffix) ? .text : nil
  }

  static func isLocalFileURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return url.isFileURL && (host.isEmpty || host == "localhost") && url.path.hasPrefix("/")
      && !url.path.contains("\0") && !url.path.contains("\\")
  }

  static func relative(_ url: URL, to root: URL) -> String? {
    guard isLocalFileURL(url), isLocalFileURL(root) else { return nil }
    let target = url.standardizedFileURL.path
    let base = root.path
    if target.utf8.elementsEqual(base.utf8) { return "." }
    let prefix = base == "/" ? "/" : base + "/"
    guard target.utf8.starts(with: prefix.utf8) else { return nil }
    return String(decoding: target.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
  }

  func excludes(_ path: String, admittedCache: Bool = false) -> Bool {
    if let otherRoot,
      path.utf8.elementsEqual(otherRoot.utf8)
        || path.utf8.starts(with: (otherRoot + "/").utf8)
    {
      return true
    }
    return Self.excludesName(in: path, admittedCache: admittedCache)
  }

  static func excludesName(in path: String, admittedCache: Bool = false) -> Bool {
    path.split(separator: "/").contains { component in
      let name = component.lowercased()
      if [
        ".git", ".hg", ".svn", ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".envrc",
        "auth", "credentials", "secrets", "tokens", "session", "sessions", "transcripts",
        "history", ".history", "logs", "worktrees", ".worktrees", "node_modules", ".build",
        "dist", "vendor", "deriveddata",
      ].contains(name) {
        return true
      }
      if !admittedCache && ["cache", "caches", ".cache"].contains(name) { return true }
      if name == ".env" || name.hasPrefix(".env.") { return true }
      let stem = name.split(separator: ".").first.map(String.init) ?? name
      return [
        "auth", "credential", "credentials", "secret", "secrets", "token", "tokens",
        "history", "transcript", "id_rsa", "id_ed25519", "api-key", "apikey",
      ].contains(stem)
        || [".pem", ".key", ".p12", ".pfx", ".kdbx"].contains { name.hasSuffix($0) }
    }
  }
}

struct ContentAuditTree {
  let directory: DirectoryHandle

  init(profile: ContentAuditProfile) throws {
    guard ContentAuditProfile.isLocalFileURL(profile.root), profile.root.path != "/" else {
      throw ContentAuditProblem.outsideScope
    }
    directory = try DirectoryHandle.readDirectory(at: profile.root)
  }

  func open(_ path: String, admittedRepository: String? = nil) throws -> DirectoryHandle? {
    if path == "." { return directory }
    var parent = directory
    var prefix = ""
    for component in path.split(separator: "/") {
      guard let child = try parent.directory(String(component)) else { return nil }
      if !prefix.isEmpty { prefix.append("/") }
      prefix.append(contentsOf: component)
      if try ContentAuditFiles.kind(".git", in: child) != nil,
        admittedRepository?.utf8.elementsEqual(prefix.utf8) != true
      {
        throw ContentAuditProblem.unrelatedRepository
      }
      parent = child
    }
    return parent
  }

  func parent(of path: String) throws -> (DirectoryHandle, String)? {
    let parts = path.split(separator: "/")
    guard let name = parts.last else { return nil }
    let parent = parts.count == 1 ? "." : parts.dropLast().joined(separator: "/")
    return try open(parent).map { ($0, String(name)) }
  }
}
