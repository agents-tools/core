import AgentsCore
import Foundation

public enum SkillOperations {
  public static func add(_ options: AddOptions) throws -> AddOutcome {
    try add(options, provider: WellKnownProvider())
  }

  static func add(_ options: AddOptions, provider: WellKnownProvider) throws -> AddOutcome {
    var options = options
    if let name = try SourceArgument(options.source).name {
      guard !options.all else {
        throw CoreError.invalidSource("@skill: names one skill and cannot be combined with all")
      }
      if !options.skillNames.contains(name) { options.skillNames.append(name) }
    }
    var automaticSelection: (sourceID: String, name: String)?
    if options.listOnly || (options.skillNames.isEmpty && !options.all) {
      let outcome = try add(options, provider: provider, apply: false)
      if options.listOnly || outcome.availableSkills.count > 1 { return outcome }
      automaticSelection = outcome.availableSkills.first.map { (outcome.sourceID, $0.name) }
    }
    return try add(options, provider: provider, apply: true, automaticSelection: automaticSelection)
  }

  private static func add(
    _ options: AddOptions, provider: WellKnownProvider, apply: Bool,
    automaticSelection: (sourceID: String, name: String)? = nil
  ) throws -> AddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    return try operate(store, apply: apply) { declaration, lock, baseline in
      let lifecycle = try SkillLifecycle(store: store, provider: provider)
      var declaration = declaration
      let selectionChanged = CoreError.invalidState(
        "automatic skill selection changed during discovery; retry the command")
      let source: SourceDeclaration
      let id: String
      do {
        source = try sourceDeclaration(options, declaration: declaration)
        id = try source.identity(environment: options.environment)
      } catch {
        if automaticSelection != nil { throw selectionChanged }
        throw error
      }
      if let automaticSelection, automaticSelection.sourceID != id { throw selectionChanged }
      let existing = try declaration.sources.keys.sorted().first {
        try declaration.sources[$0]?.identity(environment: options.environment) == id
      }
      let alias = options.alias ?? existing ?? declaration.derivedAlias(for: source.location)
      if let current = declaration.sources[alias],
        try current.identity(environment: options.environment) != id
      {
        throw CoreError.invalidSource("source alias already refers to another source: \(alias)")
      }
      declaration.sources[alias] = source
      try declaration.validate(environment: options.environment)
      let available = try lifecycle.discover(
        source,
        live: options.mode == .edit
          || (options.listOnly && source.kind == .local && source.requirement == nil),
        fullDepth: options.fullDepth, cacheSource: apply)
      let selected: [Skill]
      if let automaticSelection {
        guard let skill = available.skills.first(where: { $0.name == automaticSelection.name })
        else { throw selectionChanged }
        selected = [skill]
      } else {
        selected = try lifecycle.select(available.skills, names: options.skillNames)
      }
      guard options.listOnly || !selected.isEmpty else {
        throw CoreError.notFound("no skills found in \(options.source)")
      }
      if !apply {
        return AddOutcome(source: source, sourceID: id, availableSkills: selected, installed: [])
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
          let ownerAlias = try declaration.sources.keys.sorted().first {
            try declaration.sources[$0]?.identity(environment: options.environment)
              == current.source
          }
          let owner = ownerAlias.map { "'\($0)' (\(current.source))" } ?? current.source
          let locations = AgentID.allCases.filter { current.installs[$0.rawValue] != nil }.map {
            "\($0.rawValue) at \(SkillLifecycle.target(name: name, agent: $0, store: store).path)"
          }.joined(separator: ", ")
          throw CoreError.invalidSkill(
            "skill '\(name)' in \(options.scope.rawValue) scope already belongs to source \(owner); "
              + "cannot add from source '\(alias)' (\(id)). Existing installations: \(locations)")
        }
        let item = try lifecycle.prepare(
          skill, in: available, declaration: selection, defaultAgents: declaration.defaultAgents)
        prepared[name] = item
        next.skills[name] = item.lock
      }
      try next.validate()
      let installed = try lifecycle.apply(
        declaration: declaration, previous: lock, next: next, prepared: prepared, names: Set(names),
        baseline: baseline)
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
    return try operate(store, apply: apply) { declaration, previous, baseline in
      let resolutions = try SourceResolutionSession(store: store)
      let plan = try prepareUpdate(
        store: store, declaration: declaration, previous: previous, resolutions: resolutions,
        skillNames: skillNames, provider: provider)
      try plan.next.validate()
      try baseline.validate()
      var results = plan.results
      if apply {
        try plan.validateOwnership()
        try beforeApply?(results)
        try baseline.validate()
        try plan.validate()
        let retained = try plan.retain()
        let transaction = FileTransaction(store: store)
        transaction.validateBeforePublication = { [unowned transaction] in
          try baseline.validate(excludingTargets: transaction.targetPaths)
          try plan.validate(excludingTargets: transaction.targetPaths)
        }
        try plan.stage(retained: retained, transaction: transaction)
        try store.stageDeclaration(
          declaration, in: transaction, prepared: baseline)
        if let data = try plan.next.replacementData(
          comparedTo: baseline.bytes(for: store.resolvedURL))
        {
          try transaction.replace(
            store.resolvedURL, content: nil, data: data,
            expecting: baseline.evidence(for: store.resolvedURL))
        }
        try SourceCache(store: store).prune(
          referencedBy: plan.next, watch: store.readWatch(prepared: baseline),
          transaction: transaction)
        try transaction.commit()
        let installed = plan.receipts
        for index in results.indices {
          results[index].installed = installed.filter { $0.skill == results[index].skill }
        }
      }
      return results
    }
  }

  /// Prepares skill-owned records; the caller validates the complete generation after assembly.
  package static func prepareUpdate(
    store: StateStore, declaration: Declaration, previous: ResolvedState,
    resolutions: SourceResolutionSession, skillNames: [String] = []
  ) throws -> SkillUpdatePlan {
    try prepareUpdate(
      store: store, declaration: declaration, previous: previous, resolutions: resolutions,
      skillNames: skillNames, provider: WellKnownProvider())
  }

  private static func prepareUpdate(
    store: StateStore, declaration: Declaration, previous: ResolvedState,
    resolutions: SourceResolutionSession, skillNames: [String], provider: WellKnownProvider
  ) throws -> SkillUpdatePlan {
    let environment = store.environment
    let lifecycle = try SkillLifecycle(store: store, provider: provider, resolutions: resolutions)
    let requested = Set(skillNames.map(PathSafety.sanitizeName))
    var next = previous
    var prepared: [String: PreparedSkill] = [:]
    for alias in (declaration.skills ?? [:]).keys.sorted() {
      guard let selection = declaration.skills?[alias], let source = declaration.sources[alias]
      else { continue }
      let id = try source.identity(environment: environment)
      let requestedHere = requested.filter { name in
        if let installed = previous.skills[name] { return installed.source == id }
        if case .names(let names) = selection.select { return names.contains(name) }
        return !(selection.exclude ?? []).contains(name)
      }
      if !requested.isEmpty && requestedHere.isEmpty { continue }
      if case .names(let names) = selection.select, names.isEmpty { continue }
      func mode(_ name: String) -> InstallMode {
        selection.overrides?[name]?.mode ?? selection.mode ?? .link
      }
      let explicit: [String]?
      if !requested.isEmpty {
        explicit = requestedHere.sorted()
      } else if case .names(let names) = selection.select {
        explicit = names
      } else {
        explicit = nil
      }
      let primaryLive =
        explicit.map { $0.allSatisfy { mode($0) == .edit } } ?? (selection.mode == .edit)
      var liveSource: DiscoveredSource?
      var pinnedSource: DiscoveredSource?
      func discover(live: Bool) throws -> DiscoveredSource {
        if live, let liveSource { return liveSource }
        if !live, let pinnedSource { return pinnedSource }
        let result = try lifecycle.discover(
          source, live: live, fullDepth: explicit != nil, names: explicit,
          exclude: selection.exclude ?? [])
        if live { liveSource = result } else { pinnedSource = result }
        return result
      }
      let primary = try discover(live: primaryLive)
      var names = explicit ?? primary.skills.map { PathSafety.sanitizeName($0.name) }
      if explicit == nil {
        let overrides = (selection.overrides ?? [:]).keys.filter {
          (mode($0) == .edit) != primaryLive
        }
        for name in overrides {
          let alternate = try discover(live: mode(name) == .edit)
          if !Discovery.filter(alternate.skills, names: [name]).isEmpty { names.append(name) }
        }
        names = Array(Set(names)).filter { !(selection.exclude ?? []).contains($0) }.sorted()
      }
      for name in names {
        let discovered = try discover(live: mode(name) == .edit)
        let matches = Discovery.filter(discovered.skills, names: [name])
        if matches.isEmpty, explicit == nil { continue }
        if matches.isEmpty, previous.skills[name] == nil, !requested.isEmpty,
          !selection.hasNamedSelection
        {
          continue
        }
        let skill = try lifecycle.select(discovered.skills, names: [name])[0]
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
    let affected = requested.isEmpty ? Set(previous.skills.keys).union(prepared.keys) : requested
    let results = try affected.sorted().map { name in
      let old = previous.skills[name]
      let new = next.skills[name]
      let changes = try lifecycle.changes(name: name, old: old, new: prepared[name])
      return UpdateResult(
        skill: name, sourceIdentity: new?.source ?? old?.source ?? "",
        changed: old != new || !changes.isEmpty, oldRevision: old?.revision,
        newRevision: new?.revision, oldVersion: old?.version, newVersion: new?.version,
        oldHash: old?.hash, newHash: new?.hash,
        lockMissing: !FileManager.default.fileExists(atPath: store.resolvedURL.path),
        membership: lifecycle.membership(name: name, old: old, new: new), changes: changes,
        installed: [])
    }
    return try SkillUpdatePlan(
      lifecycle: lifecycle, previous: previous, next: next, prepared: prepared,
      names: affected, results: results)
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
    return try operate(store, apply: true) { declaration, lock, baseline in
      let lifecycle = try SkillLifecycle(store: store, provider: provider)
      var prepared: [String: PreparedSkill] = [:]
      for (name, skill) in lock.skills {
        prepared[name] = try lifecycle.restore(name: name, skill: skill, sources: lock.sources)
      }
      return ResolvedInstallReport(
        installed: try lifecycle.apply(
          declaration: declaration, previous: lock, next: lock, prepared: prepared,
          names: Set(lock.skills.keys), baseline: baseline, writeState: false))
    }
  }

  @discardableResult
  public static func remove(
    skillNames: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [String] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { declaration, lock, baseline in
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
        declaration: declaration, previous: lock, next: next, prepared: [:], names: names,
        baseline: baseline)
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
    return try operate(store, apply: false) { _, lock in
      try managedInventory(store: store, lock: lock, agents: agents)
    }
  }

  private static func managedInventory(store: StateStore, lock: ResolvedState, agents: [AgentID]?)
    throws -> [InstalledSkill]
  {
    try lock.skills.keys.sorted().flatMap { name in
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
          name: name, agent: agent, scope: store.scope, path: target.path,
          sourceIdentity: skill.source,
          isInstalled: present, status: status, mode: mode)
      }
    }
  }

  public static func listInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstalledSkill] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: false) { _, lock in
      var result = try managedInventory(store: store, lock: lock, agents: agents).filter {
        $0.isInstalled
          && (try? Discovery.parseSkill(
            at: URL(fileURLWithPath: $0.path).appendingPathComponent("SKILL.md"),
            includeInternal: true)) != nil
      }
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
              (try? Discovery.parseSkill(
                at: path.appendingPathComponent("SKILL.md"), includeInternal: true)) != nil,
              !result.contains(where: {
                $0.agent == agent
                  && SkillLifecycle.physicalTarget(URL(fileURLWithPath: $0.path)).path
                    == SkillLifecycle.physicalTarget(path).path
              })
            else { continue }
            result.append(
              InstalledSkill(
                name: path.lastPathComponent, agent: agent, scope: scope,
                path: path.standardizedFileURL.path,
                sourceIdentity: nil, isInstalled: true, status: .installedOnly, mode: nil))
          }
        }
      }
      return result.sorted {
        ($0.name, $0.agent.rawValue, $0.path) < ($1.name, $1.agent.rawValue, $1.path)
      }
    }
  }

  /// Audits state and upstream refs without fetching, creating locks or recovering transactions.
  public static func doctor(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> DoctorReport {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock(
      onPendingRecovery: {
        let recovery = FileTransaction.recoveryDiagnostic(store: store)
        return DoctorReport(checks: [
          DoctorCheck(
            id: recovery.requiresOwner ? "unresolved-transaction" : "pending-recovery",
            status: .warning,
            message: recovery.message,
            path: store.directory.path)
        ])
      },
      {
        let declaration = try store.readDeclaration()
        let lock = try store.readResolved()
        var checks = try managedInventory(store: store, lock: lock, agents: agents).filter {
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
            let output = try? ProcessRunner.git(
              [
                "--no-optional-locks", "-C", source.localURL(environment: environment).path,
                "status", "--porcelain",
                "--",
              ] + paths, operation: .readStatus, source: source.location
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
              let current = try cache.inspectRevision(source)
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
                  id: "source-unavailable", status: .warning, message: "\(alias): \(error)",
                  path: nil
                ))
            }
          }
        }
        return DoctorReport(checks: checks)
      })
  }

  public static func initializeSkill(named name: String?, directory: URL) throws -> URL {
    let store = StateStore(
      scope: .project, environment: RuntimeEnvironment(projectDirectory: directory))
    return try store.withLock(createIfMissing: false) {
      _ = try store.readDeclaration()
      _ = try store.readResolved()
      let name = name.map(PathSafety.sanitizeName)
      let root = name.map { directory.appendingPathComponent($0) } ?? directory
      let file = root.appendingPathComponent("SKILL.md")
      if FileManager.default.fileExists(atPath: file.path) {
        try FileSystem.requireWritableFile(at: file)
        throw CoreError.invalidSkill("SKILL.md already exists at \(file.path)")
      }
      try FileSystem.createDirectory(at: root)
      let title = name ?? PathSafety.sanitizeName(root.lastPathComponent)
      try FileSystem.withAccessErrors(at: file) {
        try
          "---\nname: \(title)\ndescription: Describe when to use this skill\n---\n\n# \(title)\n\nWrite the skill instructions here.\n"
          .write(to: file, atomically: true, encoding: .utf8)
      }
      try FileSystem.requireWritableFile(at: file)
      return root
    }
  }

  private static func operate<T>(_ store: StateStore, apply: Bool, _ body: () throws -> T) throws
    -> T
  {
    if apply { return try store.withLock(body) }
    return try store.withReadLock(body)
  }

  private static func operate<T>(
    _ store: StateStore, apply: Bool, _ body: (Declaration, ResolvedState) throws -> T
  ) throws -> T {
    if apply {
      return try store.withLock { try body(store.readDeclaration(), store.readResolved()) }
    }
    return try store.withReadLock { try body(store.readDeclaration(), store.readResolved()) }
  }

  private static func operate<T>(
    _ store: StateStore, apply: Bool,
    _ body: (Declaration, ResolvedState, StatePrecondition) throws -> T
  ) throws -> T {
    try operate(store, apply: apply) {
      let baseline = try StatePrecondition(store: store)
      return try body(
        store.readDeclaration(prepared: baseline), store.readResolved(prepared: baseline), baseline)
    }
  }

  private static func sourceDeclaration(_ options: AddOptions, declaration: Declaration) throws
    -> SourceDeclaration
  {
    let selection = try SourceArgument(options.source).selection(
      in: declaration, requirement: options.sourceRequirement, path: options.path,
      environment: options.environment)
    let source = selection.applied(to: selection.source)
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
