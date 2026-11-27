import AgentsCore
import AgentsInstructions
import AgentsManifest
import Components
import Foundation

struct InstructionAddition: Sendable {
  let source: String
  let units: [InstructionUnit]
  let alias: String?
  let agents: [AgentID]?
}

extension InstructionOperations {
  /// Compiles the saved instruction outputs under read locks without preparing publication.
  /// Claude forwarding output includes the assembled destination file.
  public static func previewOutputs(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> CombinedUpdateReport {
    try UpdateOperations.previewInstructionOutputs(scope: scope, environment: environment)
  }

  public static func add(
    _ options: InstructionAddOptions, beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionAddOutcome {
    let store = StateStore(scope: options.scope, environment: options.environment)
    let organization = try OrganizationPolicySnapshot(store: store)
    try organization.admit()
    let (digest, initial, available, id, alias) = try store.withReadLock {
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
        var source = selection.applied(to: selection.source)
        id = try source.identity(environment: options.environment)
        let existing = try argument.existingAlias(
          in: declaration, sourceID: id, path: source.path, environment: options.environment)
        let name = options.alias ?? existing ?? declaration.derivedAlias(for: source.location)
        if let prior = declaration.sources[name] {
          let sameRoot =
            try PathSafety.sanitizeSubpath(prior.path ?? ".")
            == PathSafety.sanitizeSubpath(source.path ?? ".")
          guard try prior.identity(environment: options.environment) == id,
            sameRoot || argument.location == name
          else { throw CoreError.invalidSource("source alias already refers to another source") }
          source = selection.applied(to: prior)
          if sameRoot { source.path = prior.path }
        }
        try organization.requireSource(
          source, reference: options.alias ?? "instruction source", in: store)
        available = try inspectSource(source, store: store)
        next.sources[name] = source
        alias = name
      }
      try organization.validate()
      return (digest, next, available, id, alias)
    }
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
    var request = UpdateRequest(
      operation: .declaration(initial), kinds: [.instructions], replace: options.replace,
      expectedDeclarationDigest: digest)
    request.instructionAddition = InstructionAddition(
      source: id == "." ? "local:" + store.environment.projectDirectory.path : id,
      units: selected, alias: alias, agents: options.agents)
    var delivered = false
    do {
      return try UpdateOperations.withDomainUpdate(
        request, scope: options.scope, environment: options.environment
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

  static func addLocalRecipients(
    _ addition: InstructionAddition, scope: InstallScope, platform: DeclarationPlatform,
    groups: [LinkedComponent], to declaration: inout Declaration
  ) -> (paths: Set<String>, requested: Set<AgentID>) {
    let defaults = declaration.defaultAgents
    func canAppend(to selection: InstructionsDeclaration) -> Bool {
      selection.condition == nil && selection.native.isEmpty
    }
    let appendable = declaration.components.compactMap { component -> InstructionsDeclaration? in
      guard case .instructions(let selection) = component, canAppend(to: selection),
        selection.sectionReferences.allSatisfy({ $0.condition == nil })
      else { return nil }
      return selection
    }
    let inherited =
      appendable.count == 1 && !defaults.contains(.antigravity)
        && appendable[0].agents?.contains(.antigravity) != true ? appendable[0].agents : nil
    let configured = addition.agents ?? inherited
    let requestedAgents = configured ?? defaults
    let requested = Set(requestedAgents)
    var changedPaths = Set<String>()
    for unit in addition.units {
      let reference = SectionDeclaration(name: unit.record.name, source: addition.alias)
      let groupRoutes = groups.filter { $0.resources.first?.path == unit.record.path }
      var missing = requested
      for group in groupRoutes { missing.subtract(group.recipients) }
      let hasInactiveGroup = groupRoutes.contains { component in
        component.conditions.contains { !$0.matches(scope: scope, platform: platform) }
      }
      let scoped = DeclarationCondition(scopes: [scope], platforms: [platform])
      var assignments: [AgentID: [DeclarationCondition]] = [:]
      var matches: [(component: Int, section: Int, condition: DeclarationCondition)] = []
      for (componentIndex, component) in declaration.components.enumerated() {
        guard case .instructions(let selection) = component else { continue }
        for (index, section) in selection.sectionReferences.enumerated()
        where section.reference == reference.reference {
          let condition = (selection.condition ?? DeclarationCondition())
            .intersecting(section.condition ?? DeclarationCondition())
          let agents = section.recipients?.compactMap(\.localAgent) ?? selection.agents ?? defaults
          for agent in agents where condition.agents?.contains(agent) ?? true {
            assignments[agent, default: []].append(condition)
          }
          missing.subtract(
            condition.recipients(
              requested: agents, scope: scope, platform: platform))
          matches.append((componentIndex, index, condition))
        }
      }
      for match in matches where !missing.isEmpty {
        let allowed = match.condition.recipients(
          requested: requestedAgents, scope: scope, platform: platform)
        let additions = missing.intersection(allowed).filter { agent in
          if hasInactiveGroup, match.condition.intersecting(scoped) != match.condition {
            return false
          }
          return (assignments[agent] ?? []).allSatisfy {
            let overlap = match.condition.intersecting($0)
            return overlap.scopes?.isEmpty == true || overlap.platforms?.isEmpty == true
          }
        }.sorted { $0.rawValue < $1.rawValue }
        guard !additions.isEmpty,
          case .instructions(var selection) = declaration.components[match.component]
        else { continue }
        let existing =
          selection.sectionReferences[match.section].recipients
          ?? (selection.agents ?? defaults).map(InstructionRecipient.local)
        selection.sectionReferences[match.section].recipients =
          existing + additions.map(InstructionRecipient.local)
        declaration.components[match.component] = .instructions(selection)
        changedPaths.insert(unit.record.path)
        missing.subtract(additions)
      }
      guard !missing.isEmpty || (requested.isEmpty && matches.isEmpty && groupRoutes.isEmpty)
      else { continue }
      changedPaths.insert(unit.record.path)
      var fallback = reference
      // A fallback for an already assigned agent must stay disjoint from its other routes.
      if hasInactiveGroup || missing.contains(where: { assignments[$0] != nil }) {
        fallback.condition = scoped
      }
      if let index = declaration.components.firstIndex(where: { component in
        guard case .instructions(let selection) = component, canAppend(to: selection) else {
          return false
        }
        return Set(selection.agents ?? defaults) == missing
      }), case .instructions(var selection) = declaration.components[index] {
        selection.sectionReferences.append(fallback)
        declaration.components[index] = .instructions(selection)
      } else {
        let agents =
          missing == requested ? configured : missing.sorted { $0.rawValue < $1.rawValue }
        var selection = InstructionsDeclaration(agents: agents)
        selection.sectionReferences = [fallback]
        declaration.components.append(.instructions(selection))
      }
    }
    return (changedPaths, requested)
  }

  public static func updateInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(), apply: Bool = false,
    replace: Bool = false,
    beforeApply: ((InstructionUpdateReport) throws -> Void)? = nil
  ) throws -> InstructionUpdateReport {
    let request = try installedUpdateRequest(
      scope: scope, agents: agents, environment: environment, replace: replace)
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

  static func installedUpdateRequest(
    scope: InstallScope, agents: [AgentID]?, environment: RuntimeEnvironment, replace: Bool
  ) throws -> UpdateRequest {
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
    return request
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
    try inspectChatGPTExport(prompt: name, scope: scope, environment: environment).bytes
  }

  /// Locked ordered content plus the live consumer appendix, with the actual durable read inputs.
  public static func inspectChatGPTExport(
    prompt name: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InstructionExportInspection {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let declaration = try store.readDeclaration(prepared: baseline)
      let ledger = try store.readLedger(prepared: baseline)
      guard let lowering = ledger.lowerings.first(where: { $0.id == "prompt:" + name }) else {
        throw InstructionError.emptyPrompt
      }
      return try LedgerReplay.withLockedResources(
        ledger, store: store, roots: store.ledgerRoots, limits: .standard
      ) { _, resources, _ in
        let bytes = try LedgerReplay.exportPrompt(
          lowering, ledger: ledger, resources: resources, roots: store.ledgerRoots)
        let paths = try UpdateOperations.readLocations(
          declarations: [declaration], ledgers: [ledger], store: store)
        try baseline.validate()
        return InstructionExportInspection(bytes: bytes, readLocations: paths)
      }
    }
  }

  public static func inspectOwnInstructions(
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> OwnInstructionsInspection {
    let store = StateStore(scope: .project, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      _ = try store.readDeclaration(prepared: baseline)
      let paths = ownReadLocations(environment: environment)
      let evidence = try paths.map(TargetPrecondition.init)
      let units = try inspectOwn(names: [], environment: environment)
      for input in evidence { try input.validate() }
      try baseline.validate()
      return OwnInstructionsInspection(
        units: units,
        readLocations: ownReadLocations(names: units.map(\.record.name), environment: environment))
    }
  }
}

public struct InstructionExportInspection: Sendable {
  public let bytes: Data
  public let readLocations: [URL]
}

public struct OwnInstructionsInspection: Sendable {
  public let units: [InstructionUnit]
  public let readLocations: [URL]
}
