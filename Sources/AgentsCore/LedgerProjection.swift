import Foundation

extension ResolvedLedger {
  /// Bundled producers use the package revision recorded with their content.
  package func bundledSourceIdentities(in store: StateStore, roots: [String: URL]) throws -> Set<
    String
  > {
    try Set(
      sources.compactMap { key, source in
        guard source.bundleSources != nil, let location = source.location,
          BundleSourceLocation.container(of: try location.resolve(roots: roots), in: store) != nil
        else { return nil }
        return try sourceIdentity(key, roots: roots)
      })
  }

  /// Domain inventory views are derived from the ledger; they are never persisted as state.
  package func domainProjection(roots: [String: URL]) throws -> ResolvedState {
    var result = ResolvedState()
    let contentSources = Set(
      components.values.filter { ["skills", "instructions"].contains($0.kind) }.map(\.source))
    for (id, source) in sources where contentSources.contains(id) {
      let identity = try sourceIdentity(id, roots: roots)
      result.sources[identity] = LockedSource(
        kind: source.kind, url: source.kind == .git ? source.transport : nil,
        requirement: sourceUses.first(where: { $0.source == id })?.requirement,
        path: sourceUses.first(where: { $0.source == id }).flatMap {
          $0.root == "." ? nil : $0.root
        })
    }
    var seen = Set<String>()
    for occurrence in occurrences {
      guard let component = components[occurrence.component] else { continue }
      let id = occurrence.component
      let source = try sourceIdentity(component.source, roots: roots)
      let resource = component.resources.first.flatMap { resources[$0] }
      if component.kind == DeclaredComponentKind.skills.rawValue, let resource {
        let mode = component.payload.object?["mode"]?.text.flatMap(InstallMode.init) ?? .copy
        let name = PathSafety.sanitizeName(component.name)
        var skill =
          result.skills[name]
          ?? LockedSkill(
            source: source, revision: component.revision, version: component.version,
            artifact: resource.artifact,
            path: resource.artifact != nil && resource.path == "." ? nil : resource.path,
            hash: mode == .edit ? nil : resource.hash, installs: [:])
        for agent in component.recipients { skill.installs[agent.rawValue] = mode }
        result.skills[name] = skill
      } else if component.kind == DeclaredComponentKind.instructions.rawValue, let resource {
        let own =
          resource.path.hasPrefix(".agent/instructions/")
          && sources[component.source]?.revision == "live"
          && sources[component.source]?.location?.root == "project"
        let section = LockedSection(
          name: component.name, source: own ? "." : source,
          revision: component.revision, version: component.version,
          artifact: resource.artifact, path: resource.path,
          hash: component.payload.object?["sourceHash"]?.text ?? resource.hash)
        if component.chatGPT, let prompt = component.payload.object?["prompt"]?.text {
          result.instructions.chatgpt[prompt, default: LockedPrompt(sections: [])].sections.append(
            section)
          if let value = component.payload.object?["localAppend"] {
            result.instructions.chatgpt[prompt]?.append = try LedgerLocation(ledgerValue: value)
              .path
          } else if let append = component.resources.dropFirst().first.flatMap({ resources[$0] }) {
            result.instructions.chatgpt[prompt]?.append = append.path
          }
        } else if !component.recipients.isEmpty {
          result.instructions.sections.append(section)
        }
      }
      seen.insert(id)
    }
    for deployment in deployments
    where InstructionLocations.isInstructionFormat(deployment.route) {
      let key = try instructionTargetKey(deployment.target, roots: roots)
      result.instructions.targets[key] = LockedTarget(
        agents: deployment.recipients, headingOffset: deployment.headingOffset,
        import: deployment.importReference, blockHash: deployment.expectedHash,
        created: deployment.created)
    }
    return result
  }

  package func instructionTargetKey(_ target: LedgerLocation, roots: [String: URL]) throws -> String
  {
    let file = try target.resolve(roots: roots)
    if target.root == "project" || target.root == InstructionLocations.antigravityProjectRoot,
      let project = roots["project"]
    {
      return PathSafety.relativePath(file.path, to: project.path)
    }
    if let home = roots["home"], PathSafety.isContained(file, in: home) {
      return "~/" + PathSafety.relativePath(file.path, to: home.path)
    }
    return file.path
  }

  package func rootSource(_ id: String) throws -> LedgerSource {
    guard var source = sources[id] else { throw CoreError.invalidState("missing source authority") }
    var visited = Set<String>()
    while let parent = source.container {
      guard visited.insert(parent).inserted, let container = sources[parent] else {
        throw CoreError.invalidState("invalid source container")
      }
      source = container
    }
    return source
  }

  package func sourceIdentity(_ id: String, roots: [String: URL]) throws -> String {
    guard let source = sources[id] else { throw CoreError.invalidState("missing ledger source") }
    if let parent = source.container {
      return try sourceIdentity(parent, roots: roots) + (source.namespace ?? "")
    }
    if let location = source.location {
      return "local:" + (try location.resolve(roots: roots).path)
    }
    if let transport = source.transport {
      return try SourceDeclaration(kind: source.kind, location: transport).identity(
        environment: RuntimeEnvironment(environment: [:]))
    }
    throw CoreError.invalidState("missing source identity coordinates")
  }
}
