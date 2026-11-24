import AgentsCore
import Foundation

extension SourceCatalog {
  /// Combines member recipes by container, preserving typed exclusions and byte-exact selectors.
  package func additions(
    _ ids: [ID], agents: [AgentID]?, condition: DeclarationCondition?, mode: InstallMode?
  ) throws -> Declaration {
    guard let selected = try selected(ids) else { return Declaration() }
    var result = Declaration(sources: [alias: source])
    var plugins: [(Data, ComponentDeclaration, [ComponentReferenceDeclaration]?)] = []
    for choice in selected {
      switch choice.unit {
      case .skill(let name):
        result.components.append(
          .skills(
            source: alias,
            .init(
              select: .names([name]), agents: agents, mode: mode, condition: condition)))
      case .instruction(let name):
        result.components.append(
          .instructions(
            .init(
              agents: agents, sections: [alias + ":" + name], condition: condition)))
      case .group(var use):
        var restriction = condition
        if let agents {
          restriction = restriction ?? .init()
          let existingAgents = restriction?.agents
          restriction?.agents =
            existingAgents.map { existing in agents.filter { existing.contains($0) } } ?? agents
        }
        use.condition = restriction
        result.uses.append(use)
      case .nativePlugin(let declaration), .componentsPlugin(let declaration):
        try addPlugin(declaration, member: nil)
      case .pluginMember(let declaration, let selector):
        try addPlugin(declaration, member: selector)
      case .importer:
        throw CoreError.invalidState("importer choices require adapter conversion")
      }
    }
    for (_, declaration, members) in plugins {
      guard
        case .plugin(
          let name, let path, let source, let strategy, _, _, let defaults, _, let native) =
          declaration
      else { continue }
      let recipients = agents ?? defaults
      if strategy == .native, recipients?.count != 1 {
        throw CoreError.invalidState("native registration requires exactly one recipient")
      }
      var kinds: [DeclaredComponentKind]? = nil
      var exclusions: [ComponentReferenceDeclaration] = []
      if let members {
        let identities = try Set(members.map(Self.referenceIdentity))
        let recipes = choices.compactMap {
          choice -> (ComponentDeclaration, ComponentReferenceDeclaration)? in
          if case .pluginMember(let recipe, let selector) = choice.unit {
            return (recipe, selector)
          }
          return nil
        }
        kinds = []
        for (recipe, selector) in recipes {
          guard case .plugin(_, let p, let s, _, let select, _, let a, _, _) = recipe,
            try containerIdentity(path: p, source: s, agents: a)
              == containerIdentity(path: path, source: source, agents: defaults)
          else { continue }
          if try identities.contains(Self.referenceIdentity(selector)) {
            for kind in select ?? [] where !kinds!.contains(kind) { kinds!.append(kind) }
          }
        }
        for (recipe, selector) in recipes {
          guard case .plugin(_, let p, let s, _, let select, _, let a, _, _) = recipe,
            try containerIdentity(path: p, source: s, agents: a)
              == containerIdentity(path: path, source: source, agents: defaults),
            select?.contains(where: { kinds!.contains($0) }) == true,
            try !identities.contains(Self.referenceIdentity(selector))
          else { continue }
          exclusions.append(selector)
        }
      }
      result.components.append(
        .plugin(
          name: name, path: path, source: source, mode: strategy,
          select: kinds, exclude: exclusions, agents: recipients, condition: condition,
          native: native))
    }
    return result

    func addPlugin(_ declaration: ComponentDeclaration, member: ComponentReferenceDeclaration?)
      throws
    {
      guard
        case .plugin(_, let path, let source, let strategy, _, _, let agents, _, _) = declaration
      else { return }
      let key = try containerIdentity(path: path, source: source, agents: agents)
      if let index = plugins.firstIndex(where: { $0.0 == key }) {
        guard case .plugin(_, _, _, let existing, _, _, _, _, _) = plugins[index].1,
          existing == strategy
        else { throw CoreError.invalidState("incompatible plugin strategies") }
        if let member, plugins[index].2 != nil {
          plugins[index].2!.append(member)
        } else {
          plugins[index].2 = nil
        }
      } else {
        plugins.append((key, declaration, member.map { [$0] }))
      }
    }
    func containerIdentity(path: String, source: String, agents: [AgentID]?) throws -> Data {
      try JSONEncoder().encode([source, path] + (agents ?? []).map(\.rawValue))
    }
  }

  private static func referenceIdentity(_ value: ComponentReferenceDeclaration) throws -> Data {
    Data(try ResolvedLedgerCodec.bytes(LedgerPayload.reference(value)))
  }

  /// Runs the adapter inside an owned, freshly verified snapshot. No borrowed path is returned.
  package func conversion(
    keys: Set<String>, bindings: [String: RuntimeBinding], sources: [String: SourceDeclaration],
    content: [String: String], store: StateStore
  ) throws -> (Declaration, SourceImportProposal) {
    guard let imported = importDocument else {
      throw CoreError.invalidState("not an importer catalog")
    }
    let budget = LinkBudget()
    return try SourceResolutionSession.withTemporaryRead(store: store) { session in
      let view: SourceSnapshot
      if try source.requirement != nil || session.isGitSource(source) {
        guard
          let pin = try session.candidates(
            for: source, requirements: [source.requirement], spending: budget.step
          ).first
        else {
          throw CoreError.invalidSource("source has no matching revision")
        }
        view = try session.snapshot(source, at: pin)
      } else {
        view = try session.localSnapshot(source)
      }
      try budget.snapshot(view.snapshot)
      guard view.snapshot == snapshot, try FileHash.folderHash(view.directory()) == contentHash
      else {
        throw CoreError.invalidState("catalog source changed; refresh inspection")
      }
      let document = try view.relativePath(
        PathSafety.resolvedChild(base: view.directory(), subpath: imported.document))
      var input = SourceImportInput(
        profile: imported.profile, root: view.root, document: document,
        selection: keys, sourceDeclarations: sources, installedSkills: content)
      input.bindingReferences = bindings
      var proposal = try SourceImport.preview(input)
      guard proposal.diagnostics.isEmpty, proposal.bindings.isEmpty,
        !proposal.resources.contains(where: {
          $0.selected
            && ($0.requiresBindingRewrite
              || ($0.producerIntegrity != nil && $0.observedHash == nil))
        })
      else {
        throw CoreError.invalidState(
          "import has unresolved conversion, binding or preserved resource requirements")
      }
      var declaration = Declaration()
      for index in proposal.sources.indices {
        let imported = proposal.sources[index]
        guard var coordinate = imported.declaration else {
          throw CoreError.invalidSource("import lacks canonical source coordinates")
        }
        if coordinate.kind == .local {
          let local = coordinate.localURL(
            environment: .init(
              projectDirectory: view.root, homeDirectory: view.root, environment: [:]))
          let relative = try view.relativePath(local)
          coordinate = source
          coordinate.path = relative
          if let pin = view.pin { coordinate.requirement = .revision(pin.revision) }
          coordinate.environment = source.environment
        }
        declaration.sourceDeclarations.append(.init(name: imported.alias, source: coordinate))
        proposal.sources[index] = .init(
          alias: imported.alias, origin: imported.origin, declaration: coordinate,
          pin: imported.pin, requestedRef: imported.requestedRef, producerPath: nil,
          producerIdentity: imported.producerIdentity, registry: imported.registry,
          resolvedRef: imported.resolvedRef, resolvedURL: imported.resolvedURL,
          developmentOnly: imported.developmentOnly)
      }
      declaration.components = proposal.components.map(\.declaration)
      return (declaration, proposal)
    }
  }
}
