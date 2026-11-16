import AgentsCore
import AgentsInstructions
import AgentsManifest
import Components
import Foundation

extension InstructionOperations {
  public static func add(
    _ options: InstructionAddOptions, beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionAddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    let (declaration, digest, initial, available, id, alias) = try store.withReadLock {
      let declaration = try store.readDeclaration()
      let digest = try store.declarationDocument(prepared: nil)?.digest ?? "absent"
      var next = declaration
      let available: [InstructionUnit]
      let id: String
      let alias: String?
      if options.source == "." {
        available = try inspectOwn(
          names: options.listOnly || options.all ? [] : options.names,
          environment: options.environment)
        id = "."
        alias = nil
      } else {
        let argument = try SourceArgument(options.source)
        guard argument.name == nil else {
          throw CoreError.invalidSource("@skill: selects skills; pass section names separately")
        }
        let selection = try argument.selection(
          in: declaration, requirement: options.sourceRequirement, path: options.path,
          environment: options.environment)
        let source = selection.applied(to: selection.source)
        id = try source.identity(environment: options.environment)
        available = try inspectSource(source, store: store)
        let existing = try declaration.sources.keys.sorted().first {
          try declaration.sources[$0]!.identity(environment: options.environment) == id
        }
        let name = options.alias ?? existing ?? declaration.derivedAlias(for: source.location)
        if let prior = declaration.sources[name],
          try prior.identity(environment: options.environment) != id
        {
          throw CoreError.invalidSource("source alias already refers to another source")
        }
        next.sources[name] = source
        alias = name
      }
      return (declaration, digest, next, available, id, alias)
    }
    var next = initial
    if options.listOnly || (options.names.isEmpty && !options.all && available.count > 1) {
      return InstructionAddOutcome(sourceID: id, available: available, result: nil)
    }
    let selected =
      options.names.isEmpty
      ? available
      : try options.names.map { name in
        guard let item = available.first(where: { $0.record.name == name }) else {
          throw CoreError.notFound("instruction section: " + name)
        }
        return item
      }
    guard !selected.isEmpty else { throw CoreError.notFound("source provides no instructions") }
    let references = selected.map { SectionDeclaration(name: $0.record.name, source: alias) }
    let editable = next.components.indices.filter { index in
      if case .instructions(let selection) = next.components[index] {
        selection.condition == nil && selection.native.isEmpty
          && selection.sectionReferences.allSatisfy { $0.condition == nil }
      } else {
        false
      }
    }
    let matching = editable.filter { index in
      guard case .instructions(let selection) = next.components[index] else { return false }
      return options.agents.map { Set($0) == Set(selection.agents ?? declaration.defaultAgents) }
        ?? false
    }
    if let index = editable.count == 1
      ? editable.first : matching.count == 1 ? matching.first : nil,
      case .instructions(var instructions) = next.components[index]
    {
      if let agents = options.agents { instructions.agents = agents }
      for reference in references where !instructions.sectionReferences.contains(reference) {
        instructions.sectionReferences.append(reference)
      }
      next.components[index] = .instructions(instructions)
    } else {
      var instructions = InstructionsDeclaration(agents: options.agents)
      instructions.sectionReferences = references
      next.components.append(.instructions(instructions))
    }
    var delivered = false
    do {
      return try UpdateOperations.withDomainUpdate(
        UpdateRequest(
          operation: .declaration(next), kinds: [.instructions], replace: options.replace,
          expectedDeclarationDigest: digest), scope: options.scope, environment: options.environment
      ) { prepared in
        delivered = true
        try beforeApply?(prepared.report.instructions)
        return InstructionAddOutcome(
          sourceID: id, available: available, result: try prepared.apply().report.instructions)
      }
    } catch let error as LinkError {
      if !delivered, options.names.isEmpty, !options.all,
        case .missing(let missing, _) = error,
        missing == "instruction '\(selected[0].record.name)'"
      {
        throw CoreError.invalidState(
          "automatic instruction selection changed during discovery; retry the command")
      }
      throw error
    }
  }

  public static func updateInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(), apply: Bool = false,
    replace: Bool = false,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    var request = UpdateRequest(kinds: [.instructions], replace: replace)
    if let agents {
      var declaration = try StateStore(scope: scope, environment: environment).loadDeclaration()
      declaration.components = declaration.components.map { component in
        if case .instructions(var selection) = component {
          selection.agents = agents
          return .instructions(selection)
        }
        return component
      }
      request.operation = .declaration(declaration)
    }
    if !apply {
      return try UpdateOperations.preview(request, scope: scope, environment: environment)
        .instructions
    }
    return try UpdateOperations.withDomainUpdate(request, scope: scope, environment: environment) {
      prepared in
      try beforeApply?(prepared.report.instructions)
      return try prepared.apply().report.instructions
    }
  }

  public static func installResolvedReport(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InstructionUpdateReport {
    try UpdateOperations.withDomainUpdate(
      UpdateRequest(operation: .restore, kinds: [.instructions]), scope: scope,
      environment: environment
    ) { try $0.apply().report.instructions }
  }

  @discardableResult
  public static func remove(
    names: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    try UpdateOperations.withDomainUpdate(
      UpdateRequest(operation: .remove, kinds: [.instructions], names: names, agents: agents),
      scope: scope, environment: environment
    ) { prepared in
      try beforeApply?(prepared.report.instructions)
      return try prepared.apply().report.instructions
    }
  }
}

extension InstructionOperations {
  public static func renderChatGPT(
    prompt name: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> Data {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      _ = try store.readDeclaration()
      let ledger = try store.readLedger()
      return try LedgerReplay.withReplay(
        ledger, store: store, roots: store.ledgerRoots, limits: .standard
      ) { artifacts in
        guard let bytes = artifacts.first(where: { $0.name == "prompt:" + name })?.bytes else {
          throw InstructionError.emptyPrompt
        }
        return bytes
      }
    }
  }
}
