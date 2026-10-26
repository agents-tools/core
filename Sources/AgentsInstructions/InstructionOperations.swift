import AgentsCore
import Foundation

/// Scope-bound instruction workflows. Consumers own argument parsing and difference presentation.
public enum InstructionOperations {
  /// A thrown callback cancels before target, declaration or lock replacements.
  public static func add(
    _ options: InstructionAddOptions,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionAddOutcome {
    var automaticSelection: (sourceID: String, name: String)?
    if options.listOnly || (options.names.isEmpty && !options.all) {
      let outcome = try add(options, apply: false, beforeApply: nil)
      if options.listOnly || outcome.available.count > 1 { return outcome }
      automaticSelection = outcome.available.first.map { (outcome.sourceID, $0.record.name) }
    }
    return try add(
      options, apply: true, automaticSelection: automaticSelection, beforeApply: beforeApply)
  }

  private static func add(
    _ options: InstructionAddOptions, apply: Bool,
    automaticSelection: (sourceID: String, name: String)? = nil,
    beforeApply: ((InstructionUpdateReport) throws -> Void)?
  ) throws -> InstructionAddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    return try operate(store, apply: apply) { previousDeclaration, previous in
      var declaration = previousDeclaration
      let selectionChanged = CoreError.invalidState(
        "automatic instruction selection changed during discovery; retry the command")
      let sources = InstructionSources(store: store)
      let id: String
      let alias: String?
      let available: [InstructionUnit]
      if options.source == InstructionSources.own {
        id = InstructionSources.own
        alias = nil
        available = try sources.own()
      } else {
        let source: SourceDeclaration
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
        let name = options.alias ?? existing ?? declaration.derivedAlias(for: source.location)
        if let current = declaration.sources[name],
          try current.identity(environment: options.environment) != id
        {
          throw CoreError.invalidSource("source alias already refers to another source: \(name)")
        }
        declaration.sources[name] = source
        try declaration.validate(environment: options.environment)
        alias = name
        available = try sources.discover(source, cacheSource: apply)
      }
      guard options.listOnly || automaticSelection != nil || !available.isEmpty else {
        throw CoreError.notFound("source provides no instructions")
      }
      if !apply {
        return InstructionAddOutcome(sourceID: id, available: available, result: nil)
      }
      let selected: [InstructionUnit]
      if let automaticSelection {
        guard let unit = available.first(where: { $0.record.name == automaticSelection.name })
        else { throw selectionChanged }
        selected = [unit]
      } else if options.names.isEmpty {
        selected = available
      } else {
        selected = try options.names.map { name in
          guard let unit = available.first(where: { $0.record.name == name }) else {
            throw CoreError.notFound("instruction section: \(name)")
          }
          return unit
        }
      }
      guard !selected.isEmpty else { throw CoreError.notFound("source provides no instructions") }
      var instructions = declaration.instructions ?? InstructionsDeclaration()
      if let agents = options.agents { instructions.agents = agents }
      let references = selected.map { (alias.map { $0 + ":" } ?? "") + $0.record.name }
      for reference in references where !instructions.sections.contains(reference) {
        instructions.sections.append(reference)
      }
      declaration.instructions = instructions
      let prepared = try prepare(
        declaration: declaration, previous: previous, sources: sources, resolving: Set(references))
      let plan = try plan(
        declaration: declaration, previousDeclaration: previousDeclaration,
        previous: previous, prepared: prepared, store: store)
      try plan.lock.validate()
      if !options.replace { try requireOwnership(plan.report) }
      try beforeApply?(plan.report)
      try Self.apply(
        declaration: declaration, next: plan.lock, report: plan.report, sources: sources)
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

  /// The project's own instructions in `.agent/instructions/`, read from the working tree.
  public static func listOwn(environment: RuntimeEnvironment = RuntimeEnvironment()) throws
    -> [InstructionUnit]
  {
    let store = StateStore(scope: .project, environment: environment)
    return try operate(store, apply: false) { _, _ in try InstructionSources(store: store).own() }
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
  /// `agents` replaces the scope's instruction recipients when applying. Applying over a file that
  /// agents did not generate requires `replace`.
  public static func updateInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(), apply: Bool = false,
    replace: Bool = false,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: apply) { previousDeclaration, previous in
      var declaration = previousDeclaration
      if let agents {
        var instructions = declaration.instructions ?? InstructionsDeclaration()
        instructions.agents = agents
        declaration.instructions = instructions
      }
      let baseline = try StatePrecondition(store: store)
      let resolutions = try SourceResolutionSession(store: store)
      let plan = try prepareUpdate(
        store: store, declaration: declaration, previousDeclaration: previousDeclaration,
        previous: previous, resolutions: resolutions, replace: replace)
      try plan.next.validate()
      if apply {
        if !replace { try requireOwnership(plan.report) }
        try beforeApply?(plan.report)
        try baseline.validate()
        try plan.validate()
        try plan.retain()
        try baseline.validate()
        try plan.validate()
        let transaction = FileTransaction(store: store)
        try plan.stage(transaction: transaction)
        try store.stageDeclaration(declaration, in: transaction)
        try transaction.replace(
          store.resolvedURL, content: nil, data: StateStore.encode(plan.next.normalized))
        try SourceCache(store: store).prune(referencedBy: plan.next, transaction: transaction)
        try transaction.commit()
      }
      return plan.report
    }
  }

  /// Prepares instruction-owned records; the caller validates the complete generation after assembly.
  /// Validation fails when the plan writes over a file agents did not generate without `replace`.
  package static func prepareUpdate(
    store: StateStore, declaration: Declaration, previousDeclaration: Declaration,
    previous: ResolvedState, resolutions: SourceResolutionSession, replace: Bool = false
  ) throws -> InstructionUpdatePlan {
    let sources = InstructionSources(store: store, resolutions: resolutions)
    let prepared = try prepare(declaration: declaration, previous: previous, sources: sources)
    let plan = try plan(
      declaration: declaration, previousDeclaration: previousDeclaration,
      previous: previous, prepared: prepared, store: store)
    return try InstructionUpdatePlan(
      next: plan.lock, report: plan.report, sources: sources, replace: replace)
  }

  /// Restores only recorded pins and targets, without changing either state file.
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
        sections: sections.map(\.section), agents: [], previous: lock.instructions,
        restoring: true)
      let report = InstructionUpdateReport(
        sections: [], targets: targets.changes, changedPrompts: [],
        lockMissing: !FileManager.default.fileExists(atPath: store.resolvedURL.path),
        hasChanges: targets.changes.contains(where: \.changed))
      try requireOwnership(report)
      try apply(
        declaration: declaration, next: lock, report: report, sources: sources, writeState: false)
      return report
    }
  }

  /// Removes selected references from file targets and named prompts. A name equal to a declared
  /// reference selects it; another bare name must match exactly one source reference.
  @discardableResult
  public static func remove(
    names: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: true) { previousDeclaration, previous in
      var declaration = previousDeclaration
      var instructions = declaration.instructions ?? InstructionsDeclaration()
      let references = Set(
        instructions.sections + (instructions.chatgpt ?? [:]).values.flatMap(\.sections))
      var removed = Set<String>()
      for name in names {
        // A declared reference matches itself, such as an own file's bare name; otherwise a bare
        // name matches a source reference with that name.
        let exact = references.filter { $0 == name }
        let matches =
          exact.isEmpty
          ? references.filter { InstructionSources.split($0)?.name == name } : exact
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
        declaration: declaration, previousDeclaration: previousDeclaration,
        previous: previous, prepared: prepared, store: store)
      try plan.lock.validate()
      try requireOwnership(plan.report)
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

  /// Creates the project's own `.agent/instructions/<name>.md` with the required front matter,
  /// without replacing an existing entry or creating a declaration or lock.
  @discardableResult
  public static func initializeInstructions(
    named name: String, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> URL {
    guard Declaration.isInstructionName(name), !name.contains("/") else {
      throw CoreError.invalidSource(
        "instruction names use lowercase letters, digits and hyphens: \(name)")
    }
    let store = StateStore(scope: .project, environment: environment)
    return try store.withLock {
      let file = environment.projectDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(InstructionSources.ownContainer)
        .appendingPathComponent(name + ".md")
      guard try InstructionTargets.read(file) == nil else {
        throw CoreError.invalidSource("instruction file already exists: \(file.path)")
      }
      let bytes = Data(
        "---\ndescription: Describe what these instructions make the agent do.\n---\n# \(name)\n\nWrite the instructions here.\n"
          .utf8)
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
        // Own instructions are never pinned, so they always resolve from the working tree.
        if let (alias, name) = InstructionSources.split(reference), let resolving,
          !resolving.contains(reference)
        {
          let id = try declaration.sources[alias]!.identity(environment: sources.store.environment)
          if let record = (locked + old).first(where: { $0.source == id && $0.name == name }) {
            return try sources.restore([record], sources: previous.sources)[0]
          }
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
    declaration: Declaration, previousDeclaration: Declaration, previous: ResolvedState,
    prepared: (lock: ResolvedState, sections: [InstructionSection]), store: StateStore
  ) throws -> (lock: ResolvedState, report: InstructionUpdateReport) {
    var next = prepared.lock
    let targets = try InstructionTargets(store: store).plan(
      sections: prepared.sections,
      agents: declaration.instructions?.agents ?? declaration.defaultAgents,
      previous: previous.instructions)
    next.instructions.targets = targets.targets
    try InstructionTargets.validateSourceDirectories(targets.changes, sources: next.sources)
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
    let lockMissing = !FileManager.default.fileExists(atPath: store.resolvedURL.path)
    let hasChanges =
      declaration.normalized != previousDeclaration.normalized
      || next.normalized != previous.normalized || targets.changes.contains(where: \.changed)
      || (lockMissing && !targets.changes.isEmpty)
    return (
      next,
      InstructionUpdateReport(
        sections: changes, targets: targets.changes, changedPrompts: prompts,
        lockMissing: lockMissing, hasChanges: hasChanges)
    )
  }

  /// Stops a write over files that agents did not generate, naming them.
  static func requireOwnership(_ report: InstructionUpdateReport) throws {
    let foreign = report.targets.filter(\.foreign).map(\.target)
    guard foreign.isEmpty else { throw InstructionError.unownedTargets(foreign) }
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
        try store.stageDeclaration(declaration, in: transaction)
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
    let argument = try SourceArgument(options.source)
    guard argument.name == nil else {
      throw CoreError.invalidSource("@skill: selects skills; pass section names separately")
    }
    let selection = try argument.selection(
      in: declaration, requirement: options.sourceRequirement, path: options.path,
      environment: options.environment)
    return selection.applied(to: selection.source)
  }
}
