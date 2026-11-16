import AgentsCore
import AgentsManifest
import AgentsSkills
import Foundation

extension SkillOperations {
  public static func add(_ options: AddOptions) throws -> AddOutcome {
    try add(options, checkpoint: { _ in })
  }

  package static func add(_ supplied: AddOptions, checkpoint: @escaping (String) throws -> Void)
    throws -> AddOutcome
  {
    var options = supplied
    if let name = try SourceArgument(options.source).name {
      guard !options.all else {
        throw CoreError.invalidSource("a named skill cannot be combined with all")
      }
      if !options.skillNames.contains(name) { options.skillNames.append(name) }
    }
    let store = StateStore(scope: options.scope, environment: options.environment)
    let (declaration, digest, source, id, available) = try store.withReadLock {
      let declaration = try store.readDeclaration()
      let digest = try store.declarationDocument(prepared: nil)?.digest ?? "absent"
      let (source, id, available) = try SkillOperations.inspect(options, declaration: declaration)
      return (declaration, digest, source, id, available)
    }
    if options.listOnly || (options.skillNames.isEmpty && !options.all && available.count > 1) {
      return AddOutcome(source: source, sourceID: id, availableSkills: available, installed: [])
    }
    guard !available.isEmpty else {
      throw CoreError.notFound("no skills found in " + source.location)
    }
    var next = declaration
    let existing = try declaration.sources.keys.sorted().first {
      try declaration.sources[$0]!.identity(environment: options.environment) == id
    }
    let alias = options.alias ?? existing ?? declaration.derivedAlias(for: source.location)
    if let prior = declaration.sources[alias],
      try prior.identity(environment: options.environment) != id
    {
      throw CoreError.invalidSource("source alias already refers to another source")
    }
    next.sources[alias] = source
    let names = available.map { PathSafety.sanitizeName($0.name) }
    var updated = false
    for index in next.components.indices {
      guard case .skills(let selectedAlias, var selection) = next.components[index],
        selectedAlias == alias
      else { continue }
      guard !updated else {
        throw CoreError.invalidState(
          "skill selection is ambiguous; edit the specific YAML occurrence")
      }
      updated = true
      if options.all {
        selection.select = .all
      } else if case .names(let old) = selection.select {
        selection.select = .names(Array(Set(old + names)).sorted())
      }
      selection.exclude = selection.exclude?.filter { !names.contains($0) }
      var overrides = selection.overrides ?? [:]
      for name in names {
        overrides[name] = SkillOverride(
          agents: options.agents ?? overrides[name]?.agents ?? selection.agents, mode: options.mode)
      }
      selection.overrides = overrides
      next.components[index] = .skills(source: alias, selection)
    }
    if !updated {
      next.components.append(
        .skills(
          source: alias,
          SkillDeclaration(
            select: options.all ? .all : .names(names), agents: options.agents, mode: options.mode))
      )
    }
    var request = UpdateRequest(
      operation: .declaration(next), kinds: [.skills], names: names,
      expectedDeclarationDigest: digest)
    if options.skillNames.isEmpty && !options.all {
      request.automaticSkill = (id, available[0].name)
    }
    return try UpdateOperations.withDomainUpdate(
      request, scope: options.scope, environment: options.environment, checkpoint: checkpoint
    ) { prepared in
      let result = try prepared.apply()
      return AddOutcome(
        source: source, sourceID: id, availableSkills: available, installed: result.installedSkills)
    }
  }

  public static func updateInstalled(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    skillNames: [String] = [], apply: Bool = false,
    beforeApply: (([UpdateResult]) throws -> Void)? = nil
  ) throws -> [UpdateResult] {
    let request = UpdateRequest(kinds: [.skills], names: skillNames)
    if !apply {
      return try UpdateOperations.preview(request, scope: scope, environment: environment).skills
    }
    return try UpdateOperations.withDomainUpdate(request, scope: scope, environment: environment) {
      prepared in
      try beforeApply?(prepared.report.skills)
      let applied = try prepared.apply()
      return applied.report.skills.map { item in
        var item = item
        item.installed = applied.installedSkills.filter { $0.skill == item.skill }
        return item
      }
    }
  }

  public static func installResolvedReport(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ResolvedInstallReport {
    try UpdateOperations.withDomainUpdate(
      UpdateRequest(operation: .restore, kinds: [.skills]), scope: scope, environment: environment
    ) {
      ResolvedInstallReport(installed: try $0.apply().installedSkills)
    }
  }

  @discardableResult
  public static func remove(
    skillNames: [String], scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [String] {
    let names = skillNames.map(PathSafety.sanitizeName)
    return try UpdateOperations.withDomainUpdate(
      UpdateRequest(operation: .remove, kinds: [.skills], names: names, agents: agents),
      scope: scope, environment: environment
    ) {
      guard Set(names).isSubset(of: Set($0.report.skills.map(\.skill))) else {
        throw CoreError.notFound("skill is not installed")
      }
      _ = try $0.apply()
      return names.sorted()
    }
  }
}
