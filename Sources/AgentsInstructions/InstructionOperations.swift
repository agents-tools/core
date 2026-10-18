import AgentsCore
import Foundation

/// Scope-bound instruction workflows. Consumers own argument parsing and difference presentation.
public enum InstructionOperations {
  /// A thrown callback cancels before target, declaration or lock replacements.
  public static func add(
    _ options: InstructionAddOptions,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionAddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    return try operate(store, apply: !options.listOnly) { declaration, previous in
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
      let sources = InstructionSources(store: store)
      let available = try sources.discover(source)
      if options.listOnly || (options.names.isEmpty && available.count > 1 && !options.all) {
        return InstructionAddOutcome(sourceID: id, available: available, result: nil)
      }
      let selected =
        try options.names.isEmpty
        ? available
        : options.names.map { name in
          guard let unit = available.first(where: { $0.record.name == name }) else {
            throw CoreError.notFound("instruction section: \(name)")
          }
          return unit
        }
      guard !selected.isEmpty else { throw CoreError.notFound("source provides no instructions") }
      var instructions = declaration.instructions ?? InstructionsDeclaration()
      if let agents = options.agents { instructions.agents = agents }
      let references = selected.map { alias + ":" + $0.record.name }
      for reference in references where !instructions.sections.contains(reference) {
        instructions.sections.append(reference)
      }
      declaration.instructions = instructions
      let prepared = try prepare(
        declaration: declaration, previous: previous, sources: sources, resolving: Set(references))
      let plan = try plan(
        declaration: declaration, previous: previous, prepared: prepared, store: store,
        replace: options.replace)
      try beforeApply?(plan.report)
      try apply(declaration: declaration, next: plan.lock, report: plan.report, sources: sources)
      return InstructionAddOutcome(sourceID: id, available: available, result: plan.report)
    }
  }

  /// Returns committed, validated units. Inspection may fetch mirror objects but never publishes pins.
  public static func list(
    source: SourceDeclaration, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstructionUnit] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: false) { _, _ in
      try InstructionSources(store: store).discover(source)
    }
  }

  /// Includes missing targets; doctor supplies their disk status.
  public static func listManaged(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LockedInstructions {
    try operate(StateStore(scope: scope, environment: environment), apply: false) { _, lock in
      lock.instructions
    }
  }

  /// Resolves declared content and reports every affected target before any replacement.
  /// `agents` replaces the scope's instruction recipients when applying.
  public static func updateInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(), apply: Bool = false,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: apply) { declaration, previous in
      var declaration = declaration
      if let agents {
        var instructions = declaration.instructions ?? InstructionsDeclaration()
        instructions.agents = agents
        declaration.instructions = instructions
      }
      let sources = InstructionSources(store: store)
      let prepared = try prepare(declaration: declaration, previous: previous, sources: sources)
      let plan = try plan(
        declaration: declaration, previous: previous, prepared: prepared, store: store,
        replace: true)
      if apply {
        try beforeApply?(plan.report)
        try self.apply(
          declaration: declaration, next: plan.lock, report: plan.report, sources: sources)
      }
      return plan.report
    }
  }

  /// Restores only recorded pins, targets and heading offsets, without changing either state file.
  public static func installResolvedReport(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InstructionUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { declaration, lock in
      let sources = InstructionSources(store: store)
      let sections = try sources.restore(lock.instructions.sections, sources: lock.sources)
      for prompt in lock.instructions.chatgpt.values {
        _ = try Instructions.renderChatGPT(
          sections: sources.restore(prompt.sections, sources: lock.sources).map(\.section))
      }
      let targets = try InstructionTargets(store: store).plan(
        sections: sections.map(\.section), agents: [], previous: lock.instructions, replace: false,
        restoring: true)
      let report = InstructionUpdateReport(
        sections: [], targets: targets.changes, changedPrompts: [],
        lockMissing: !FileManager.default.fileExists(atPath: store.resolvedURL.path))
      try apply(
        declaration: declaration, next: lock, report: report, sources: sources, writeState: false)
      return report
    }
  }

  /// Removes selected identities from file targets and named prompts. Bare names must be unambiguous.
  @discardableResult
  public static func remove(
    names: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { declaration, previous in
      var declaration = declaration
      var instructions = declaration.instructions ?? InstructionsDeclaration()
      let references = Set(
        instructions.sections + (instructions.chatgpt ?? [:]).values.flatMap(\.sections))
      var removed = Set<String>()
      for name in names {
        let matches = references.filter {
          $0 == name || $0.split(separator: ":").last.map(String.init) == name
        }
        guard matches.count == 1, let reference = matches.first else {
          throw CoreError.notFound("instruction name is missing or ambiguous: \(name)")
        }
        removed.insert(reference)
      }
      instructions.sections.removeAll { removed.contains($0) }
      for name in (instructions.chatgpt ?? [:]).keys {
        instructions.chatgpt?[name]?.sections.removeAll { removed.contains($0) }
        if instructions.chatgpt?[name]?.sections.isEmpty == true {
          instructions.chatgpt?[name] = nil
        }
      }
      if let agents { instructions.agents = agents }
      declaration.instructions = instructions
      let sources = InstructionSources(store: store)
      let prepared = try prepare(
        declaration: declaration, previous: previous, sources: sources, resolving: [])
      let plan = try plan(
        declaration: declaration, previous: previous, prepared: prepared, store: store,
        replace: false)
      try beforeApply?(plan.report)
      try apply(declaration: declaration, next: plan.lock, report: plan.report, sources: sources)
      return plan.report
    }
  }

  /// Appends the current custom file to verified locked sections; never resolves declared requirements.
  public static func renderChatGPT(
    prompt name: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> Data {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: false) { _, lock in
      guard let prompt = lock.instructions.chatgpt[name], !prompt.sections.isEmpty else {
        throw InstructionError.emptyPrompt
      }
      let sections = try InstructionSources(store: store).restore(
        prompt.sections, sources: lock.sources)
      var custom: Data?
      if let append = prompt.append {
        let root = scope == .project ? environment.projectDirectory : environment.homeDirectory
        let file = try PathSafety.resolvedChild(base: root, subpath: append)
        try InstructionSources.contained(file, in: root)
        custom = try Data(contentsOf: file)
      }
      return try Instructions.renderChatGPT(
        sections: sections.map(\.section), customContent: custom)
    }
  }

  /// Creates `<name>.md` in the supplied directory without replacing an existing entry.
  @discardableResult
  public static func initializeInstructions(named name: String, directory: URL) throws -> URL {
    guard name == PathSafety.sanitizeName(name) else {
      throw CoreError.invalidSource("instruction name must be a filesystem identity")
    }
    let environment = RuntimeEnvironment(
      projectDirectory: directory, homeDirectory: directory, environment: [:])
    let store = StateStore(scope: .project, environment: environment)
    return try store.withLock {
      let file = directory.resolvingSymlinksInPath().appendingPathComponent(name + ".md")
      guard try InstructionTargets.read(file) == nil else {
        throw CoreError.invalidSource("instruction file already exists: \(file.path)")
      }
      let bytes = Data("# \(name)\n\nWrite the instructions here.\n".utf8)
      _ = try Instructions.validateSource(bytes, id: name)
      let transaction = FileTransaction(store: store)
      try transaction.replace(file, content: nil, data: bytes)
      try transaction.commit()
      return file
    }
  }

  private static func prepare(
    declaration: Declaration, previous: ResolvedState, sources: InstructionSources,
    resolving: Set<String>? = nil
  ) throws -> (lock: ResolvedState, sections: [InstructionSection]) {
    try declaration.validate(environment: sources.store.environment)
    var next = previous
    next.instructions = LockedInstructions()
    let old =
      previous.instructions.sections + previous.instructions.chatgpt.values.flatMap(\.sections)
    func units(_ references: [String], locked: [LockedSection]) throws -> [InstructionUnit] {
      try references.map { reference in
        let parts = reference.split(separator: ":").map(String.init)
        let id = try declaration.sources[parts[0]]!.identity(environment: sources.store.environment)
        if let resolving, !resolving.contains(reference),
          let record = (locked + old).first(where: { $0.source == id && $0.name == parts[1] })
        {
          return try sources.restore([record], sources: previous.sources)[0]
        }
        return try sources.resolve(references: [reference], declaration: declaration, lock: &next)[
          0]
      }
    }
    let sections = try units(
      declaration.instructions?.sections ?? [], locked: previous.instructions.sections)
    next.instructions.sections = sections.map(\.record)
    for (name, prompt) in (declaration.instructions?.chatgpt ?? [:]).sorted(by: { $0.key < $1.key })
    {
      let selected = try units(
        prompt.sections, locked: previous.instructions.chatgpt[name]?.sections ?? [])
      _ = try Instructions.renderChatGPT(sections: selected.map(\.section))
      next.instructions.chatgpt[name] = LockedPrompt(
        sections: selected.map(\.record), append: prompt.append)
    }
    return (next, sections.map(\.section))
  }

  private static func plan(
    declaration: Declaration, previous: ResolvedState,
    prepared: (lock: ResolvedState, sections: [InstructionSection]), store: StateStore,
    replace: Bool
  ) throws -> (lock: ResolvedState, report: InstructionUpdateReport) {
    var next = prepared.lock
    if !prepared.sections.isEmpty {
      _ = try Instructions.renderChatGPT(sections: prepared.sections)
    }
    let targets = try InstructionTargets(store: store).plan(
      sections: prepared.sections,
      agents: declaration.instructions?.agents ?? declaration.defaultAgents,
      previous: previous.instructions, replace: replace)
    next.instructions.targets = targets.targets
    try InstructionTargets.validateSourceDirectories(targets.changes, sources: next.sources)
    try next.validate()
    let before = previous.instructions.sections
    let after = next.instructions.sections
    let identities = Set((before + after).map(InstructionSources.identity))
    let changes = identities.sorted().compactMap { id -> InstructionSectionChange? in
      let old = before.first { InstructionSources.identity($0) == id }
      let new = after.first { InstructionSources.identity($0) == id }
      return old == new ? nil : InstructionSectionChange(before: old, after: new)
    }
    let prompts = Set(previous.instructions.chatgpt.keys).union(next.instructions.chatgpt.keys)
      .sorted().filter { name in
        let old = previous.instructions.chatgpt[name]
        let new = next.instructions.chatgpt[name]
        return old?.append != new?.append
          || old?.sections.map { InstructionSources.identity($0) + $0.hash }
            != new?.sections.map { InstructionSources.identity($0) + $0.hash }
      }
    return (
      next,
      InstructionUpdateReport(
        sections: changes, targets: targets.changes, changedPrompts: prompts,
        lockMissing: !FileManager.default.fileExists(atPath: store.resolvedURL.path))
    )
  }

  private static func apply(
    declaration: Declaration, next: ResolvedState, report: InstructionUpdateReport,
    sources: InstructionSources, writeState: Bool = true
  ) throws {
    let store = sources.store
    try declaration.validate(environment: store.environment)
    try next.validate()
    // User callbacks can inspect or cancel, but cannot silently invalidate the prepared differences.
    for change in report.targets {
      guard try InstructionTargets.read(change.url) == change.before else {
        throw CoreError.invalidState(
          "instruction target changed during preparation: \(change.target)")
      }
    }
    try InstructionTargets.validateSourceDirectories(report.targets, sources: next.sources)
    do {
      try sources.retain(next)
      let transaction = FileTransaction(store: store)
      for change in report.targets {
        guard try InstructionTargets.read(change.url) == change.before else {
          throw CoreError.invalidState(
            "instruction target changed during preparation: \(change.target)")
        }
        if change.changed { try transaction.replace(change.url, content: nil, data: change.after) }
      }
      if writeState {
        try transaction.replace(
          store.declarationURL, content: nil, data: StateStore.encode(declaration.normalized))
        try transaction.replace(
          store.resolvedURL, content: nil, data: StateStore.encode(next.normalized))
      }
      try sources.cache.prune(referencedBy: next, transaction: transaction)
      try transaction.commit()
    } catch {
      if let recovered = try? store.readResolved() {
        try? sources.cache.prune(referencedBy: recovered)
      }
      throw error
    }
  }

  static func operate<T>(
    _ store: StateStore, apply: Bool, _ body: (Declaration, ResolvedState) throws -> T
  ) throws -> T {
    if apply {
      return try store.withLock { try body(store.readDeclaration(), store.readResolved()) }
    }
    return try store.withReadLock { try body(store.readDeclaration(), store.readResolved()) }
  }

  private static func sourceDeclaration(_ options: InstructionAddOptions, declaration: Declaration)
    throws -> SourceDeclaration
  {
    var source: SourceDeclaration
    if let existing = declaration.sources[options.source] {
      source = existing
    } else {
      let parsed = try SourceParser.parse(
        options.source, currentDirectory: options.environment.projectDirectory,
        homeDirectory: options.environment.homeDirectory)
      source = SourceDeclaration(
        kind: parsed.type, location: parsed.localPath ?? parsed.url,
        requirement: parsed.requirement, path: parsed.subpath)
    }
    if let path = options.path { source.path = try PathSafety.sanitizeSubpath(path) }
    if let requirement = options.sourceRequirement { source.requirement = requirement }
    return source
  }
}
