import AgentsCore
import Foundation

public enum SkillOperations {
  public static func add(_ options: AddOptions) throws -> AddOutcome {
    try add(options, provider: WellKnownProvider())
  }

  static func add(_ options: AddOptions, provider: WellKnownProvider) throws -> AddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    return try operate(store, apply: !options.listOnly) { declaration, lock in
      let lifecycle = try SkillLifecycle(store: store, provider: provider)
      var declaration = declaration
      let source = try sourceDeclaration(options, declaration: declaration)
      let id = try source.identity(environment: options.environment)
      let existing = try declaration.sources.keys.sorted().first {
        try declaration.sources[$0]?.identity(environment: options.environment) == id
      }
      let alias =
        options.alias ?? existing
        ?? PathSafety.sanitizeName(
          URL(fileURLWithPath: source.location).deletingPathExtension().lastPathComponent)
      if let current = declaration.sources[alias],
        try current.identity(environment: options.environment) != id
      {
        throw CoreError.invalidState("source alias already refers to another source: \(alias)")
      }
      declaration.sources[alias] = source
      try declaration.validate(environment: options.environment)
      let available = try lifecycle.discover(
        source,
        live: options.mode == .edit
          || (options.listOnly && source.kind == .local && source.requirement == nil),
        fullDepth: options.fullDepth)
      let selected = try lifecycle.select(available.skills, names: options.skillNames)
      if options.listOnly || (selected.count > 1 && options.skillNames.isEmpty && !options.all) {
        return AddOutcome(source: source, sourceID: id, availableSkills: selected, installed: [])
      }
      guard !selected.isEmpty else {
        throw CoreError.notFound("no skills found in \(options.source)")
      }
      var selection = declaration.skills?[alias] ?? SkillDeclaration(select: .names([]))
      let names = selected.map { PathSafety.sanitizeName($0.name) }
      if options.all {
        selection.select = .all
      } else if case .names(let previous) = selection.select {
        selection.select = .names(Array(Set(previous + names)).sorted())
      }
      selection.exclude = selection.exclude?.filter { !names.contains($0) }
      if declaration.skills?[alias] == nil || options.all {
        selection.agents = options.agents
        selection.mode = options.mode
      } else {
        for name in names {
          selection.overrides = selection.overrides ?? [:]
          let recipients = options.agents ?? selection.overrides?[name]?.agents ?? selection.agents
          selection.overrides?[name] = SkillOverride(agents: recipients, mode: options.mode)
        }
      }
      declaration.skills = declaration.skills ?? [:]
      declaration.skills?[alias] = selection
      try declaration.validate(environment: options.environment)
      var next = lock
      next.sources[id] = lifecycle.lockedSource(source)
      var prepared: [String: PreparedSkill] = [:]
      for skill in selected {
        let name = PathSafety.sanitizeName(skill.name)
        if let current = lock.skills[name], current.source != id {
          throw CoreError.invalidSkill("skill '\(name)' already belongs to \(current.source)")
        }
        let item = try lifecycle.prepare(
          skill, in: available, declaration: selection, defaultAgents: declaration.defaultAgents)
        prepared[name] = item
        next.skills[name] = item.lock
      }
      try next.validate()
      let installed = try lifecycle.apply(
        declaration: declaration, previous: lock, next: next, prepared: prepared, names: Set(names))
      return AddOutcome(
        source: source, sourceID: id, availableSkills: selected, installed: installed)
    }
  }

  /// Resolves declared intent. The callback runs before any target or state replacement.
  public static func updateInstalled(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    skillNames: [String] = [], apply: Bool = false,
    beforeApply: (([UpdateResult]) throws -> Void)? = nil
  ) throws -> [UpdateResult] {
    try update(
      scope: scope, environment: environment, skillNames: skillNames, apply: apply,
      beforeApply: beforeApply, provider: WellKnownProvider())
  }

  static func update(
    scope: InstallScope, environment: RuntimeEnvironment, skillNames: [String], apply: Bool,
    beforeApply: (([UpdateResult]) throws -> Void)? = nil, provider: WellKnownProvider
  ) throws -> [UpdateResult] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: apply) { declaration, previous in
      let lifecycle = try SkillLifecycle(store: store, provider: provider)
      let requested = Set(skillNames.map(PathSafety.sanitizeName))
      var next = previous
      var prepared: [String: PreparedSkill] = [:]
      for alias in (declaration.skills ?? [:]).keys.sorted() {
        guard let selection = declaration.skills?[alias], let source = declaration.sources[alias]
        else { continue }
        let id = try source.identity(environment: environment)
        let requestedHere = requested.filter { name in
          if previous.skills[name]?.source == id { return true }
          if case .names(let names) = selection.select { return names.contains(name) }
          return false
        }
        if !requested.isEmpty && requestedHere.isEmpty { continue }
        let live =
          selection.mode == .edit
          && (selection.overrides ?? [:]).values.allSatisfy { $0.mode == nil || $0.mode == .edit }
        let discovered = try lifecycle.discover(
          source, live: live, fullDepth: !requested.isEmpty || selection.hasNamedSelection)
        let selectedNames: [String]
        if !requested.isEmpty {
          selectedNames = requestedHere.sorted()
        } else if case .names(let names) = selection.select {
          selectedNames = names
        } else {
          selectedNames = discovered.skills.map { PathSafety.sanitizeName($0.name) }.filter {
            !(selection.exclude ?? []).contains($0)
          }
        }
        let selected =
          selectedNames.isEmpty ? [] : try lifecycle.select(discovered.skills, names: selectedNames)
        for skill in selected {
          let name = PathSafety.sanitizeName(skill.name)
          if let current = prepared[name], current.lock.source != id {
            throw CoreError.invalidSkill("duplicate skill name: \(name)")
          }
          if let current = previous.skills[name], current.source != id {
            throw CoreError.invalidSkill("skill '\(name)' already belongs to \(current.source)")
          }
          let item = try lifecycle.prepare(
            skill, in: discovered, declaration: selection, defaultAgents: declaration.defaultAgents)
          prepared[name] = item
          next.skills[name] = item.lock
        }
        next.sources[id] = lifecycle.lockedSource(source)
      }
      guard requested.isSubset(of: Set(prepared.keys)) else {
        throw CoreError.notFound("requested skill is not declared or is missing upstream")
      }
      if requested.isEmpty { next.skills = prepared.mapValues(\.lock) }
      try next.validate()
      let affected = requested.isEmpty ? Set(previous.skills.keys).union(prepared.keys) : requested
      var results = try affected.sorted().map { name in
        let old = previous.skills[name]
        let new = next.skills[name]
        let changes = try lifecycle.changes(name: name, old: old, new: prepared[name])
        return UpdateResult(
          skill: name, sourceIdentity: new?.source ?? old?.source ?? "",
          changed: old != new || !changes.isEmpty, oldRevision: old?.revision,
          newRevision: new?.revision, oldHash: old?.hash, newHash: new?.hash, changes: changes,
          installed: [])
      }
      if apply {
        try beforeApply?(results)
        let installed = try lifecycle.apply(
          declaration: declaration, previous: previous, next: next, prepared: prepared,
          names: affected)
        for index in results.indices {
          results[index].installed = installed.filter { $0.skill == results[index].skill }
        }
      }
      return results
    }
  }

  /// Restores each locked pin and recipient. Never resolves requirements or consults an index.
  public static func installResolvedReport(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ResolvedInstallReport {
    try install(scope: scope, environment: environment, provider: WellKnownProvider())
  }

  static func install(
    scope: InstallScope, environment: RuntimeEnvironment, provider: WellKnownProvider
  ) throws -> ResolvedInstallReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { declaration, lock in
      let lifecycle = try SkillLifecycle(store: store, provider: provider)
      var prepared: [String: PreparedSkill] = [:]
      for (name, skill) in lock.skills {
        prepared[name] = try lifecycle.restore(name: name, skill: skill, sources: lock.sources)
      }
      return ResolvedInstallReport(
        installed: try lifecycle.apply(
          declaration: declaration, previous: lock, next: lock, prepared: prepared,
          names: Set(lock.skills.keys), writeState: false))
    }
  }

  @discardableResult
  public static func remove(
    skillNames: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [String] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { declaration, lock in
      var declaration = declaration
      var next = lock
      let names = Set(skillNames.map(PathSafety.sanitizeName))
      guard names.isSubset(of: Set(lock.skills.keys)) else {
        throw CoreError.notFound("skill is not installed")
      }
      for name in names {
        guard var skill = next.skills[name] else { continue }
        if let agents {
          for agent in agents { skill.installs.removeValue(forKey: agent.rawValue) }
        } else {
          skill.installs = [:]
        }
        next.skills[name] = skill.installs.isEmpty ? nil : skill
        for alias in (declaration.skills ?? [:]).keys {
          guard let source = declaration.sources[alias],
            try source.identity(environment: environment) == skill.source,
            var selection = declaration.skills?[alias]
          else { continue }
          if skill.installs.isEmpty {
            if case .all = selection.select {
              selection.exclude = Array(Set((selection.exclude ?? []) + [name])).sorted()
            } else if case .names(let members) = selection.select {
              selection.select = .names(members.filter { $0 != name })
            }
            selection.overrides?.removeValue(forKey: name)
          } else {
            selection.overrides = selection.overrides ?? [:]
            let mode = selection.overrides?[name]?.mode
            selection.overrides?[name] = SkillOverride(
              agents: skill.installs.keys.compactMap(AgentID.init(rawValue:)), mode: mode)
          }
          declaration.skills?[alias] = selection
        }
      }
      let lifecycle = try SkillLifecycle(store: store, provider: WellKnownProvider())
      _ = try lifecycle.apply(
        declaration: declaration, previous: lock, next: next, prepared: [:], names: names)
      return names.sorted()
    }
  }

  public static func removableSkillNames(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [String] {
    Array(Set(try listManaged(scope: scope, agents: agents, environment: environment).map(\.name)))
      .sorted()
  }

  public static func listManaged(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstalledSkill] {
    let store = StateStore(scope: scope, environment: environment)
    _ = try store.loadDeclaration()
    let lock = try store.loadResolved()
    return try lock.skills.keys.sorted().flatMap { name in
      guard let skill = lock.skills[name] else { return [InstalledSkill]() }
      return try skill.installs.keys.sorted().compactMap { raw in
        guard let agent = AgentID(rawValue: raw), let mode = skill.installs[raw],
          agents?.contains(agent) ?? true
        else { return nil }
        let target = SkillLifecycle.target(name: name, agent: agent, store: store)
        let present = FileManager.default.fileExists(
          atPath: target.appendingPathComponent("SKILL.md").path)
        var status: InstalledSkillStatus =
          present ? (mode == .edit ? .editLinked : .installed) : .missing
        if present, mode != .edit, let hash = skill.hash,
          try "sha256:" + FileHash.folderHash(target) != hash
        {
          status = .copyDrift
        }
        if !present,
          (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
        {
          status = .brokenLink
        }
        return InstalledSkill(
          name: name, agent: agent, scope: scope, path: target.path, sourceIdentity: skill.source,
          isInstalled: present, status: status, mode: mode)
      }
    }
  }

  public static func listInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstalledSkill] {
    var result = try listManaged(scope: scope, agents: agents, environment: environment)
    for agent in agents ?? AgentID.allCases {
      let roots =
        scope == .project
        ? AgentRegistry.projectScanDirectories(for: agent, environment: environment)
        : AgentRegistry.nativeUserScanDirectories(for: agent, environment: environment)
      for root in roots {
        for path
          in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        {
          guard
            FileManager.default.fileExists(atPath: path.appendingPathComponent("SKILL.md").path),
            !result.contains(where: { $0.agent == agent && $0.path == path.path })
          else { continue }
          result.append(
            InstalledSkill(
              name: path.lastPathComponent, agent: agent, scope: scope, path: path.path,
              sourceIdentity: nil, isInstalled: true, status: .installedOnly, mode: nil))
        }
      }
    }
    return result.sorted {
      ($0.name, $0.agent.rawValue, $0.path) < ($1.name, $1.agent.rawValue, $1.path)
    }
  }

  public static func doctor(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> DoctorReport {
    let store = StateStore(scope: scope, environment: environment)
    let declaration = try store.loadDeclaration()
    let lock = try store.loadResolved()
    var checks = try listManaged(scope: scope, agents: agents, environment: environment).filter {
      $0.status != .installed && $0.status != .editLinked
    }.map {
      DoctorCheck(
        id: $0.status.rawValue, status: .warning, message: "\($0.name): \($0.status.rawValue)",
        path: $0.path)
    }
    let cache = SourceCache(store: store)
    for (alias, source) in declaration.sources.sorted(by: { $0.key < $1.key }) {
      let id = try source.identity(environment: environment)
      let skills = lock.skills.values.filter { $0.source == id }
      guard !skills.isEmpty else { continue }
      if source.kind == .local {
        let paths = skills.compactMap(\.path)
        let output = try? ProcessRunner.run(
          "/usr/bin/env",
          arguments: [
            "git", "-C", source.localURL(environment: environment).path, "status", "--porcelain",
            "--",
          ] + paths
        ).stdout
        if let output, !output.isEmpty {
          checks.append(
            DoctorCheck(
              id: "uncommitted-source", status: .warning,
              message: "\(alias) has uncommitted changes in selected paths",
              path: source.localURL(environment: environment).path))
        }
      }
      if source.kind != .wellKnown, skills.contains(where: { $0.revision != nil }) {
        do {
          let current = try cache.resolve(source)
          if skills.contains(where: { $0.revision != nil && $0.revision != current.revision }) {
            checks.append(
              DoctorCheck(
                id: "source-update", status: .warning,
                message:
                  "\(alias) has a newer matching revision\(current.version.map { " (\($0))" } ?? "")",
                path: nil))
          }
        } catch {
          checks.append(
            DoctorCheck(
              id: "source-unavailable", status: .warning, message: "\(alias): \(error)", path: nil))
        }
      }
    }
    return DoctorReport(checks: checks)
  }

  public static func initializeSkill(named name: String?, directory: URL) throws -> URL {
    let name = name.map(PathSafety.sanitizeName)
    let root = name.map { directory.appendingPathComponent($0) } ?? directory
    let file = root.appendingPathComponent("SKILL.md")
    guard !FileManager.default.fileExists(atPath: file.path) else {
      throw CoreError.invalidSkill("SKILL.md already exists at \(file.path)")
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let title = name ?? PathSafety.sanitizeName(root.lastPathComponent)
    try
      "---\nname: \(title)\ndescription: Describe when to use this skill\n---\n\n# \(title)\n\nWrite the skill instructions here.\n"
      .write(to: file, atomically: true, encoding: .utf8)
    return root
  }

  private static func operate<T>(
    _ store: StateStore, apply: Bool, _ body: (Declaration, ResolvedState) throws -> T
  ) throws -> T {
    let declaration = try store.loadDeclaration()
    let lock = try store.loadResolved()
    if !apply { return try body(declaration, lock) }
    return try store.withLock { try body(store.loadDeclaration(), store.loadResolved()) }
  }

  private static func sourceDeclaration(_ options: AddOptions, declaration: Declaration) throws
    -> SourceDeclaration
  {
    var source: SourceDeclaration
    if let existing = declaration.sources[options.source] {
      source = existing
    } else {
      let parsed = try SourceParser.parse(
        options.source, currentDirectory: options.environment.projectDirectory)
      source = SourceDeclaration(
        kind: parsed.type == .local ? .local : parsed.type == .wellKnown ? .wellKnown : .git,
        location: parsed.localPath ?? parsed.url, requirement: parsed.requirement,
        path: parsed.subpath)
    }
    if let path = options.path { source.path = try PathSafety.sanitizeSubpath(path) }
    if let requirement = options.sourceRequirement { source.requirement = requirement }
    if options.mode == .edit, source.kind != .local || source.requirement != nil {
      throw CoreError.invalidSource("edit requires a local source with no requirement")
    }
    return source
  }
}

extension SkillDeclaration {
  fileprivate var hasNamedSelection: Bool {
    if case .names = select { return true }
    return false
  }
}
