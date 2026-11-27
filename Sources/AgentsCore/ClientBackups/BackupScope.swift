import CPlatform
import Foundation
import TOMLSemantics

struct BackupRoots {
  let home: URL
  let client: URL
  let database: URL
  let profile: URL
  let shared: URL
  let runtime: URL
  let codexConfig: BackupPathFence?
  let configuredCodexDatabase: Bool
  let zstdPath: String?
  let projects: [String: URL]

  init(_ client: BackupClient, environment: RuntimeEnvironment, projects: [String: URL]) throws {
    home = try BackupIO.address(environment.homeDirectory)
    zstdPath = environment.environment["PATH"]
    func override(_ name: String) throws -> URL? {
      guard let value = environment.environment[name], !value.isEmpty else { return nil }
      guard value.hasPrefix("/") else { throw ClientBackupError.invalidLocation(name) }
      return try BackupIO.address(URL(fileURLWithPath: value, isDirectory: true))
    }
    switch client {
    case .codex:
      self.client = try override("CODEX_HOME") ?? home.appendingPathComponent(".codex")
      let config = try BackupPathFence.capture(self.client.appendingPathComponent("config.toml"))
      codexConfig = config
      let configured = try BackupCodexConfig.sqliteHome(config.target)
      configuredCodexDatabase = configured != nil
      if let configured {
        let path =
          configured.path.hasPrefix("~/")
          ? home.appendingPathComponent(String(configured.path.dropFirst(2))).path : configured.path
        guard BackupIO.originalPath(path) else {
          throw ClientBackupError.invalidLocation("Codex sqlite_home")
        }
        database = URL(fileURLWithPath: path, isDirectory: true)
      } else {
        database = try override("CODEX_SQLITE_HOME") ?? self.client
      }
      profile = home
      shared = home.appendingPathComponent(".agents")
      runtime = self.client
    case .claudeCode:
      let config = try override("CLAUDE_CONFIG_DIR")
      self.client = config ?? home.appendingPathComponent(".claude")
      codexConfig = nil
      configuredCodexDatabase = false
      database = self.client
      profile = config ?? home
      shared = home.appendingPathComponent(".agents")
      runtime = self.client
    case .geminiCLI:
      let geminiHome = try override("GEMINI_CLI_HOME") ?? home
      self.client = geminiHome.appendingPathComponent(".gemini")
      codexConfig = nil
      configuredCodexDatabase = false
      database = self.client
      profile = home
      shared = geminiHome.appendingPathComponent(".agents")
      if environment.environment["SANDBOX"] == "sandbox-exec" {
        runtime = geminiHome.appendingPathComponent(".cache/.gemini")
      } else {
        runtime = self.client
      }
    }
    self.projects = projects
  }

  func url(_ root: String) throws -> URL {
    if root.hasPrefix(BackupClaudeImports.archivePrefix) {
      return try url(String(root.dropFirst(BackupClaudeImports.archivePrefix.count)))
    }
    return switch root {
    case "client": client
    case "database": database
    case "profile": profile
    case "shared": shared
    case "runtime": runtime
    default:
      if let project = projects[root] { project } else { throw ClientBackupError.invalidPackage }
    }
  }
}

enum BackupScope {
  struct Route {
    let files: Set<String>
    let trees: Set<String>
    let dynamic: Bool

    init(files: Set<String> = [], trees: Set<String> = [], dynamic: Bool = false) {
      self.files = files
      self.trees = trees
      self.dynamic = dynamic
    }
  }

  static func routes(_ client: BackupClient, project: Bool) -> [String: Route] {
    if project {
      switch client {
      case .codex:
        return [
          "": Route(
            files: ["AGENTS.md", "AGENTS.override.md", ".codex/config.toml", ".codex/hooks.json"],
            trees: [
              ".agents/skills", ".codex/skills", ".codex/rules", ".codex/hooks", ".codex/agents",
            ])
        ]
      case .claudeCode:
        return [
          "": Route(
            files: [
              "CLAUDE.md", "CLAUDE.local.md", ".mcp.json", "AGENTS.md",
              ".claude/CLAUDE.md", ".claude/CLAUDE.local.md", ".claude/settings.json",
              ".claude/settings.local.json",
              ".claude/.mcp.json",
            ],
            trees: [
              ".claude/rules", ".claude/skills", ".claude/commands", ".claude/agents",
              ".claude/hooks", ".claude/scripts", ".claude/output-styles",
            ])
        ]
      case .geminiCLI:
        return [
          "": Route(
            files: [
              "GEMINI.md", "AGENTS.md", ".geminiignore", ".gemini/settings.json",
              ".gemini/.env", ".gemini/GEMINI.md",
            ],
            trees: [
              ".agents/skills", ".gemini/skills", ".gemini/policies", ".gemini/commands",
              ".gemini/agents", ".gemini/hooks", ".gemini/extensions",
            ])
        ]
      }
    }
    switch client {
    case .codex:
      return [
        "client": Route(
          files: [
            "config.toml", "auth.json", "AGENTS.md", "AGENTS.override.md", "hooks.json",
            "session_index.jsonl", "history.jsonl", ".codex-global-state.json",
          ],
          trees: [
            "sessions", "archived_sessions", "attachments", "thread-attachments",
            "artifacts", "skills", "rules", "hooks", "agents", "instructions", "memories",
          ]),
        "database": Route(dynamic: true),
        "shared": Route(trees: ["skills"]),
      ]
    case .claudeCode:
      return [
        "shared": Route(trees: ["skills"]),
        "client": Route(
          files: [
            "settings.json", "settings.local.json", "CLAUDE.md", "CLAUDE.local.md",
            ".credentials.json", ".mcp.json", "history.jsonl",
          ],
          trees: [
            "projects", "sessions", "file-history", "session-env", "tasks", "todos",
            "plans", "image-cache", "paste-cache", "skills", "rules", "commands", "agents",
            "hooks", "scripts", "output-styles",
          ]),
        "profile": Route(files: [".claude.json"]),
      ]
    case .geminiCLI:
      return [
        "client": Route(
          files: ["settings.json", ".env", "GEMINI.md", "oauth_creds.json", "keybindings.json"],
          trees: ["skills", "policies", "commands", "agents", "hooks", "extensions"]),
        "runtime": Route(
          files: [
            "projects.json", "trustedFolders.json", "google_accounts.json",
            "mcp-oauth-tokens.json", "a2a-oauth-tokens.json",
          ],
          dynamic: true),
        "shared": Route(trees: ["skills"]),
      ]
    }
  }

  static func skillUnit(_ client: BackupClient, root: String, project: Bool, path: String)
    -> String?
  {
    let trees = routes(client, project: project)[project ? "" : root]?.trees ?? []
    for prefix in trees where prefix.split(separator: "/").last == "skills" {
      guard path.hasPrefix(prefix + "/") else { continue }
      let rest = path.dropFirst(prefix.count + 1)
      if let name = rest.split(separator: "/").first { return prefix + "/" + name }
    }
    return nil
  }

  static func isSkillManifest(_ bytes: Data) -> Bool {
    guard let text = String(data: bytes, encoding: .utf8) else { return false }
    let lines = text.split(whereSeparator: \.isNewline)
    guard lines.first == "---" else { return false }
    let header = lines.dropFirst().prefix { $0 != "---" }
    return header.endIndex != lines.endIndex
      && header.contains {
        $0.hasPrefix("name:") && !$0.dropFirst(5).trimmingCharacters(in: .whitespaces).isEmpty
      }
  }

  static func isDatabase(_ name: String) -> Bool {
    name.range(
      of: #"^(state(_[0-9]+)?|goals_[0-9]+|thread_history_[0-9]+)\.sqlite$"#,
      options: .regularExpression) != nil
  }

  static func excluded(_ component: String) -> Bool {
    let name = component.lowercased()
    return [".git", ".build", ".ds_store", "node_modules", "__pycache__", ".cache", "deriveddata"]
      .contains(name) || name.hasPrefix(".agents-backup-") || name.hasSuffix(".agentsbackup")
  }

  static func allows(
    _ client: BackupClient, root: String, components: [String], projects: [String]
  ) -> Bool {
    if client == .geminiCLI, root == "runtime", BackupGeminiCheckpoints.isPack(components) {
      return !excluded(components[1])
    }
    guard !components.isEmpty, components.allSatisfy({ !excluded($0) }) else { return false }
    if client == .claudeCode, root.hasPrefix(BackupClaudeImports.archivePrefix) {
      let owner = String(root.dropFirst(BackupClaudeImports.archivePrefix.count))
      return (owner == "client" || projects.contains(owner))
        && BackupClaudeImports.allows(components)
    }
    let project = projects.contains(root)
    let routes = routes(client, project: project)
    guard let route = routes[project ? "" : root] else { return false }
    let path = components.joined(separator: "/")
    if route.files.contains(path) || route.trees.contains(where: { path.hasPrefix($0 + "/") }) {
      return true
    }
    if project, components.count > 1, let name = components.last,
      components.dropLast().allSatisfy({ !$0.hasPrefix(".") }),
      projectContextNames(client).contains(name)
    {
      return true
    }
    guard route.dynamic else { return false }
    if client == .codex {
      return components.count == 1 && isDatabase(components[0])
    }
    if components.first == "history" {
      return components.count == 3 && components[2] == ".project_root"
    }
    guard components.count >= 3, components[0] == "tmp" else { return false }
    if components.count == 3, geminiCheckpoint(components[2]) { return true }
    if BackupGeminiCheckpoints.isRecord(components) { return true }
    switch components[2] {
    case ".project_root", "logs.json": return components.count == 3
    case "chats", "attachments", "plans", "memory", "tasks", "tracker", "tool-outputs":
      return components.count > 3
    default:
      return components.count > 4 && ["plans", "tasks", "tracker"].contains(components[3])
    }
  }

  static func geminiCheckpoint(_ name: String) -> Bool {
    name.hasPrefix("checkpoint-") && name.hasSuffix(".json")
  }

  static func projectContextNames(_ client: BackupClient) -> [String] {
    switch client {
    case .codex: ["AGENTS.md", "AGENTS.override.md"]
    case .claudeCode: ["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md"]
    case .geminiCLI: ["GEMINI.md", "AGENTS.md"]
    }
  }
}

final class BackupInventory {
  private struct File {
    let root: String
    let path: String
    let location: URL
    let generation: BackupGeneration
  }

  private let client: BackupClient
  private let roots: BackupRoots
  private let output: URL
  private var observations: [URL: BackupGeneration?] = [:]
  private var files: [File] = []

  init(client: BackupClient, roots: BackupRoots, output: URL) {
    self.client = client
    self.roots = roots
    self.output = output
  }

  private func observe(_ url: URL) throws -> BackupGeneration? {
    let value: BackupGeneration?
    if let parent = try BackupIO.directory(url.deletingLastPathComponent()) {
      value = try BackupIO.generation(parent, url.lastPathComponent)
    } else {
      value = nil
    }
    if let prior = observations[url], prior != value {
      throw ClientBackupError.conflict(url.path)
    }
    observations.updateValue(value, forKey: url)
    return value
  }

  private func names(_ url: URL) throws -> [String] {
    guard let value = try observe(url) else { return [] }
    guard value.value.st_mode & S_IFMT == S_IFDIR,
      let directory = try BackupIO.directory(url)
    else { throw ClientBackupError.invalidLocation(url.path) }
    return try directory.names()
  }

  private func collect(
    _ url: URL, root: String, path: String, recursive: Bool, depth: Int = 0,
    resource: Bool = false, insideLinkedSkill: Bool = false
  ) throws {
    guard depth < 128 else { throw ClientBackupError.invalidLocation(url.path) }
    if url.path == output.path, depth != 0 { return }
    guard let state = try observe(url) else { return }
    switch state.value.st_mode & S_IFMT {
    case S_IFREG:
      let parts = try BackupIO.components(path)
      guard
        BackupScope.allows(
          client, root: root, components: parts, projects: Array(roots.projects.keys))
      else { throw ClientBackupError.invalidLocation(url.path) }
      files.append(File(root: root, path: path, location: url, generation: state))
    case S_IFDIR where recursive:
      let children = try names(url)
      if insideLinkedSkill, children.contains(where: { $0.lowercased() == ".git" }) {
        throw ClientBackupError.invalidLocation(url.path)
      }
      for name in children where !BackupScope.excluded(name) {
        guard BackupIO.safeComponent(name) else {
          throw ClientBackupError.invalidLocation(url.path)
        }
        try collect(
          url.appendingPathComponent(name), root: root, path: path + "/" + name,
          recursive: true, depth: depth + 1, resource: resource,
          insideLinkedSkill: insideLinkedSkill)
      }
    case S_IFLNK where insideLinkedSkill:
      throw ClientBackupError.invalidLocation(url.path)
    case S_IFLNK where resource:
      let target = url.resolvingSymlinksInPath()
      let owningRoot = try roots.url(root)
      let isProject = roots.projects[root] != nil
      let route = BackupScope.routes(client, project: isProject)[isProject ? "" : root]
      if BackupScope.skillUnit(client, root: root, project: isProject, path: path) == path {
        guard target.path != url.path,
          !([roots.home, roots.client, roots.shared] + Array(roots.projects.values)).contains(
            where: {
              $0.path == target.path
            }),
          try isOwnedSkill(target)
        else { throw ClientBackupError.invalidLocation(url.path) }
        try collect(
          target, root: root, path: path, recursive: true, depth: depth + 1, insideLinkedSkill: true
        )
        return
      }
      if BackupScope.skillUnit(client, root: root, project: isProject, path: path) != nil
        || (route?.trees.contains(path) == true && path.split(separator: "/").last == "skills")
      {
        throw ClientBackupError.invalidLocation(url.path)
      }
      let ownedTrees = (route?.trees ?? []).map { owningRoot.appendingPathComponent($0).path }
      guard target.path != url.path, ownedTrees.contains(where: { target.path.hasPrefix($0 + "/") })
      else { return }
      try collect(target, root: root, path: path, recursive: recursive, depth: depth + 1)
    case S_IFLNK:
      return
    default:
      throw ClientBackupError.invalidLocation(url.path)
    }
  }

  private func isOwnedSkill(_ target: URL) throws -> Bool {
    guard let directory = try BackupIO.directory(target),
      try directory.info(".git") == nil,
      let file = try directory.info("SKILL.md"), file.st_mode & S_IFMT == S_IFREG,
      file.st_size <= 1024 * 1024
    else { return false }
    let bytes = try directory.read("SKILL.md", matching: file, maximumBytes: 1024 * 1024)
    return BackupScope.isSkillManifest(bytes)
  }

  func capture(into archive: BackupArchive, in scratch: DirectoryHandle) throws {
    var routes = BackupScope.routes(client, project: false)
    for project in roots.projects.keys {
      routes[project] = BackupScope.routes(client, project: true)[""]
    }
    for key in routes.keys.sorted() {
      guard let route = routes[key] else { continue }
      let base = try roots.url(key)
      for path in route.files.sorted() {
        try collect(base.appendingPathComponent(path), root: key, path: path, recursive: false)
      }
      for tree in route.trees.sorted() {
        let resource = !["sessions", "archived_sessions", "projects", "history"].contains(tree)
        try collect(
          base.appendingPathComponent(tree), root: key, path: tree, recursive: true,
          resource: resource)
      }
      if roots.projects[key] != nil {
        try collectProjectContext(base, root: key, prefix: "", depth: 0)
      }
      if route.dynamic {
        if client == .codex {
          for db in try names(base).filter(BackupScope.isDatabase) {
            try collect(base.appendingPathComponent(db), root: key, path: db, recursive: false)
          }
        } else {
          try collectGemini(base, root: key)
        }
      }
    }
    if client == .claudeCode { try collectClaudeImports() }
    if client == .geminiCLI { try collectGeminiPacks(in: scratch) }
    for file in files {
      if file.root == "database" {
        let snapshot = try snapshot(file, in: scratch)
        guard let generation = try BackupIO.generation(scratch, snapshot) else {
          throw ClientBackupError.conflict(file.location.path)
        }
        try archive.add(
          root: file.root, path: file.path, mode: file.generation.mode & 0o777,
          parent: scratch, name: snapshot, generation: generation)
        try scratch.remove(snapshot)
      } else {
        let parent = try DirectoryHandle(at: file.location.deletingLastPathComponent())
        try archive.add(
          root: file.root, path: file.path, mode: file.generation.mode & 0o777,
          parent: parent, name: file.location.lastPathComponent, generation: file.generation)
      }
    }
    try roots.codexConfig?.validate()
    for (url, previous) in observations {
      guard try observe(url) == previous else { throw ClientBackupError.conflict(url.path) }
    }
  }

  private func collectClaudeImports() throws {
    let location = BackupClaudeImports.Locations(
      home: roots.home, client: roots.client, projects: roots.projects)
    let native = Dictionary(
      files.map { (BackupClaudeImports.File(root: $0.root, path: $0.path), $0) },
      uniquingKeysWith: { first, _ in first })
    let entries = native.keys.filter { BackupClaudeImports.isEntry($0, projects: roots.projects) }
    var captured = Set<BackupClaudeImports.File>()
    _ = try BackupClaudeImports.closure(entries: entries, locations: location) { key in
      guard let url = location.url(key) else { return nil }
      let file = native[key]
      let input = file?.location ?? url
      guard let state = try observe(input), state.value.st_mode & S_IFMT == S_IFREG,
        let parent = try BackupIO.directory(input.deletingLastPathComponent())
      else { throw ClientBackupError.invalidLocation(url.path) }
      if file == nil, captured.insert(key).inserted {
        files.append(
          File(
            root: BackupClaudeImports.archivePrefix + key.root, path: key.path,
            location: input, generation: state))
      }
      return try parent.read(input.lastPathComponent, matching: state.value)
    }
  }

  private func collectProjectContext(
    _ folder: URL, root: String, prefix: String, depth: Int
  ) throws {
    guard depth < 128, let directory = try BackupIO.directory(folder) else { return }
    for name in try directory.names()
    where !name.hasPrefix(".") && !BackupScope.excluded(name) && BackupIO.safeComponent(name) {
      let child = folder.appendingPathComponent(name)
      if child.path == output.path { continue }
      guard let info = try directory.info(name) else { continue }
      if depth > 0, BackupScope.projectContextNames(client).contains(name),
        info.st_mode & S_IFMT == S_IFREG
      {
        try collect(child, root: root, path: prefix + name, recursive: false)
      } else if info.st_mode & S_IFMT == S_IFDIR {
        try collectProjectContext(child, root: root, prefix: prefix + name + "/", depth: depth + 1)
      }
    }
  }

  private func collectGemini(_ base: URL, root: String) throws {
    let history = base.appendingPathComponent("history")
    for key in try names(history) where BackupIO.safeComponent(key) && !BackupScope.excluded(key) {
      let folder = history.appendingPathComponent(key)
      if let state = try observe(folder), state.value.st_mode & S_IFMT == S_IFDIR {
        try collect(
          folder.appendingPathComponent(".project_root"), root: root,
          path: "history/" + key + "/.project_root", recursive: false)
      }
    }
    let tmp = base.appendingPathComponent("tmp")
    for key in try names(tmp) where !BackupScope.excluded(key) {
      guard BackupIO.safeComponent(key) else { throw ClientBackupError.invalidLocation(tmp.path) }
      let folder = tmp.appendingPathComponent(key)
      guard let state = try observe(folder), state.value.st_mode & S_IFMT == S_IFDIR else {
        continue
      }
      for name in try names(folder) {
        let path = "tmp/" + key + "/" + name
        let url = folder.appendingPathComponent(name)
        if [".project_root", "logs.json"].contains(name) || BackupScope.geminiCheckpoint(name) {
          try collect(url, root: root, path: path, recursive: false)
        } else if ["chats", "attachments", "plans", "memory", "tasks", "tracker", "tool-outputs"]
          .contains(name)
        {
          try collect(url, root: root, path: path, recursive: true)
        } else if name == "checkpoints" {
          for record in try names(url) where !BackupScope.excluded(record) {
            let parts = ["tmp", key, name, record]
            if BackupGeminiCheckpoints.isRecord(parts) {
              let file = url.appendingPathComponent(record)
              guard let state = try observe(file), state.value.st_mode & S_IFMT == S_IFREG else {
                throw ClientBackupError.invalidLocation(file.path)
              }
              try collect(file, root: root, path: parts.joined(separator: "/"), recursive: false)
            }
          }
        } else if UUID(uuidString: name) != nil {
          for child in ["plans", "tasks", "tracker"] {
            try collect(
              url.appendingPathComponent(child), root: root, path: path + "/" + child,
              recursive: true)
          }
        }
      }
    }
  }

  private func collectGeminiPacks(in scratch: DirectoryHandle) throws {
    var commits: [String: [String]] = [:]
    for file in files where file.root == "runtime" {
      let parts = try BackupIO.components(file.path)
      guard BackupGeminiCheckpoints.isRecord(parts) else { continue }
      let staged = "checkpoint-" + UUID().uuidString
      guard
        try BackupIO.copy(file.location, to: scratch, named: staged).generation == file.generation
      else { throw ClientBackupError.conflict(file.location.path) }
      if let commit = try BackupGeminiCheckpoints.commit(
        in: scratch.url.appendingPathComponent(staged))
      {
        commits[parts[1], default: []].append(commit)
      }
      try scratch.remove(staged)
    }
    for (key, dependencies) in commits.sorted(by: { $0.key < $1.key }) {
      let shadow = roots.runtime.appendingPathComponent("history/" + key)
      let pack = try BackupGeminiCheckpoints.capture(
        commits: dependencies, shadow: shadow, scratch: scratch, observe: observe)
      for payload in pack {
        try collect(
          payload, root: "runtime",
          path: "history/" + key + "/.git/objects/pack/" + payload.lastPathComponent,
          recursive: false)
      }
    }
  }

  private func snapshot(_ file: File, in scratch: DirectoryHandle) throws -> String {
    let token = UUID().uuidString
    let working = token + "-native.sqlite"
    let result = token + "-snapshot.sqlite"
    let main = file.location
    let wal = main.deletingLastPathComponent().appendingPathComponent(
      main.lastPathComponent + "-wal")
    let rollback = main.deletingLastPathComponent().appendingPathComponent(
      main.lastPathComponent + "-journal")
    guard try observe(rollback) == nil else { throw ClientBackupError.conflict(main.path) }
    let walState = try observe(wal)
    guard try BackupIO.copy(main, to: scratch, named: working).generation == file.generation else {
      throw ClientBackupError.conflict(main.path)
    }
    if let walState {
      guard try BackupIO.copy(wal, to: scratch, named: working + "-wal").generation == walState
      else { throw ClientBackupError.conflict(wal.path) }
    }
    guard try observe(main) == file.generation, try observe(wal) == walState else {
      throw ClientBackupError.conflict(main.path)
    }
    try BackupIO.write(result, in: scratch) { _ in }
    do {
      let source = try BackupSQL(scratch.url.appendingPathComponent(working), writable: true)
      let destination = try BackupSQL(scratch.url.appendingPathComponent(result), writable: true)
      try source.snapshot(into: destination)
      try destination.execute("PRAGMA journal_mode=DELETE")
      try destination.verify()
    }
    for name in [working, working + "-wal", working + "-shm"] { try scratch.remove(name) }
    return result
  }
}

enum BackupCodexConfig {
  static func sqliteHome(_ url: URL) throws -> (path: String, bytes: Data, range: Range<Int>)? {
    guard let directory = try BackupIO.directory(url.deletingLastPathComponent()),
      try directory.info(url.lastPathComponent) != nil
    else { return nil }
    let bytes = try directory.read(url.lastPathComponent, maximumBytes: 4 * 1024 * 1024)
    guard let text = String(data: bytes, encoding: .utf8), text.contains("sqlite_home") else {
      return nil
    }
    let budget = SemanticBudget(
      limits: .init(
        storage: 16 * 1024 * 1024, work: 96 * 1024 * 1024, nodes: 100_000, depth: 96,
        uninterruptedBytes: 4 * 1024 * 1024))
    guard case .object(let entries) = try SemanticDocument(source: text, budget: budget).root,
      let entry = entries.first(where: { $0.key == "sqlite_home" })
    else { return nil }
    guard case .scalar(.string, let path, _, let range) = entry.value else {
      throw ClientBackupError.unsupportedLayout("Codex sqlite_home")
    }
    return (path, bytes, range)
  }

  static func relocated(
    _ file: URL, sourceHome: String, sourceDatabase: String, destination: URL,
    preserveDestinationSetting: Bool
  ) throws -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let value = try encoder.encode(destination.path)
    guard var config = try sqliteHome(file) else {
      guard preserveDestinationSetting else { return nil }
      var bytes = Data("sqlite_home = ".utf8)
      bytes.append(value)
      bytes.append(0x0a)
      bytes.append(try Data(contentsOf: file))
      return bytes
    }
    let original =
      config.path.hasPrefix("~/")
      ? sourceHome + "/" + config.path.dropFirst(2) : config.path
    guard original == sourceDatabase else {
      throw ClientBackupError.unsupportedLayout("Codex sqlite_home")
    }
    if original == destination.path { return nil }
    config.bytes.replaceSubrange(config.range, with: value)
    return config.bytes
  }
}
