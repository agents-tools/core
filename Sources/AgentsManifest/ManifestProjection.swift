import AgentsCore

/// Projects a document onto the declaration model this release deploys: root recipients,
/// sources and watch subscriptions, plus at most one skills component per source alias and one
/// instructions component, none with a condition or native configuration. Unused groups and
/// exports are inert and accepted. Every other active structure fails with
/// `manifest.unsupported` at its location; nothing is dropped.
package enum ManifestProjection {
  package static func declaration(
    of document: DeclarationDocument, environment: RuntimeEnvironment
  ) throws -> Declaration {
    let ir = document.declaration
    func unsupported(_ pointer: String, _ message: String) -> ManifestFailure {
      let span =
        document.sourceMap.locations(at: pointer).first?.span
        ?? document.source.span(0..<0)
      return ManifestFailure(
        ManifestDiagnostic(code: "manifest.unsupported", message: message, span: span))
    }
    func recipients(_ value: DeclarationValue?, at pointer: String) throws -> [AgentID]? {
      guard let values = value?.elements else { return nil }
      return try values.map {
        guard let agent = $0.string.flatMap(AgentID.init(rawValue:)) else {
          throw unsupported(pointer, "unknown recipient")
        }
        return agent
      }
    }
    func section(_ value: DeclarationValue, at pointer: String) throws -> String {
      guard let record = value.record, let name = record["name"]?.string else {
        throw unsupported(pointer, "unknown section reference")
      }
      guard record["condition"] == .null else {
        throw unsupported(pointer + "/condition", "conditional sections are not deployable")
      }
      // `.` names the declaring project, whose own sections are bare names.
      guard let alias = record["source"]?.string, alias != "." else { return name }
      return alias + ":" + name
    }
    func applicable(_ record: DeclarationRecord, at pointer: String) throws {
      guard record["condition"] == .null else {
        throw unsupported(pointer + "/condition", "conditional components are not deployable")
      }
      guard record["native"] == .dictionary([:]) else {
        throw unsupported(pointer + "/native", "native configuration is not deployable")
      }
    }

    if !ir.uses.isEmpty { throw unsupported("/uses/0", "group uses are not deployable") }
    var sources: [String: SourceDeclaration] = [:]
    for (index, record) in ir.sources.enumerated() {
      let kind: SourceKind
      let location: DeclarationValue?
      switch record.kind {
      case "git": (kind, location) = (.git, record["url"])
      case "local": (kind, location) = (.local, record["path"])
      default: (kind, location) = (.wellKnown, record["index"])
      }
      guard let alias = record["name"]?.string, let location = location?.string else {
        throw unsupported("/sources/\(index)", "unknown source form")
      }
      var requirement: SourceRequirement?
      if case .requirement(let value) = record["requirement"] { requirement = value }
      sources[alias] = SourceDeclaration(
        kind: kind, location: location, requirement: requirement,
        path: record["subpath"]?.string)
    }
    var skills: [String: SkillDeclaration] = [:]
    var instructions: InstructionsDeclaration?
    for (index, record) in ir.components.enumerated() {
      let pointer = "/components/\(index)"
      switch record.kind {
      case "skills":
        try applicable(record, at: pointer)
        guard let alias = record["source"]?.string, alias != "." else {
          throw unsupported(
            pointer + "/source", "skills of the declaring package are not deployable")
        }
        guard skills[alias] == nil else {
          throw unsupported(pointer, "a source alias has more than one skills component")
        }
        let select: SkillSelection
        if let names = record["select"]?.elements {
          select = .names(names.compactMap(\.string))
        } else {
          select = .all
        }
        let exclude = record["exclude"]?.elements?.compactMap(\.string) ?? []
        var overrides: [String: SkillOverride] = [:]
        for (position, value) in (record["overrides"]?.elements ?? []).enumerated() {
          let path = pointer + "/overrides/\(position)"
          guard let override = value.record, let name = override["name"]?.string else {
            throw unsupported(path, "unknown skill override")
          }
          overrides[name] = SkillOverride(
            agents: try recipients(override["agents"], at: path + "/agents"),
            mode: override["mode"]?.string.flatMap(InstallMode.init(rawValue:)))
        }
        skills[alias] = SkillDeclaration(
          select: select, exclude: exclude.isEmpty ? nil : exclude,
          agents: try recipients(record["agents"], at: pointer + "/agents"),
          mode: record["mode"]?.string.flatMap(InstallMode.init(rawValue:)),
          overrides: overrides.isEmpty ? nil : overrides)
      case "instructions":
        try applicable(record, at: pointer)
        guard instructions == nil else {
          throw unsupported(pointer, "the declaration has more than one instructions component")
        }
        let sections = try (record["sections"]?.elements ?? []).enumerated().map {
          try section($1, at: pointer + "/sections/\($0)")
        }
        var prompts: [String: PromptDeclaration] = [:]
        for (position, value) in (record["chatGPT"]?.elements ?? []).enumerated() {
          let path = pointer + "/chatGPT/\(position)"
          guard let prompt = value.record, let name = prompt["name"]?.string else {
            throw unsupported(path, "unknown ChatGPT prompt")
          }
          guard prompt["condition"] == .null else {
            throw unsupported(path + "/condition", "conditional prompts are not deployable")
          }
          prompts[name] = PromptDeclaration(
            sections: try (prompt["sections"]?.elements ?? []).enumerated().map {
              try section($1, at: path + "/sections/\($0)")
            }, append: prompt["append"]?.string)
        }
        instructions = InstructionsDeclaration(
          agents: try recipients(record["agents"], at: pointer + "/agents"), sections: sections,
          chatgpt: prompts.isEmpty ? nil : prompts)
      default:
        throw unsupported(pointer, "\(record.kind) components are not deployable")
      }
    }
    let declaration = Declaration(
      agents: try recipients(
        ir.defaultAgents.map { .array($0.map(DeclarationValue.string)) }, at: "/defaultAgents"),
      sources: sources, skills: skills.isEmpty ? nil : skills, instructions: instructions,
      watch: ir.watch.isEmpty ? nil : ir.watch)
    try declaration.validate(environment: environment)
    return declaration
  }

  /// Semantic declaration equality. Sources compare identity, requirement meaning and normalized
  /// subpath, so equivalent spellings stay unchanged. Recipients compare as sets and keep `nil`
  /// distinct from `[]`; absent and empty exclusions, overrides, prompts, watch subscriptions and
  /// skills are equal. Sections compare in order.
  package static func equivalent(
    _ lhs: Declaration, _ rhs: Declaration, environment: RuntimeEnvironment
  ) -> Bool {
    guard sameRecipients(lhs.agents, rhs.agents), Set(lhs.watch ?? []) == Set(rhs.watch ?? []),
      lhs.sources.keys == rhs.sources.keys,
      lhs.sources.allSatisfy({ equivalent($1, rhs.sources[$0]!, environment: environment) })
    else { return false }
    let left = lhs.skills ?? [:]
    let right = rhs.skills ?? [:]
    guard left.keys == right.keys, left.allSatisfy({ equivalent($1, right[$0]!) }) else {
      return false
    }
    switch (lhs.instructions, rhs.instructions) {
    case (nil, nil): return true
    case (let left?, let right?): return equivalent(left, right)
    default: return false
    }
  }

  static func equivalent(
    _ lhs: SourceDeclaration, _ rhs: SourceDeclaration, environment: RuntimeEnvironment
  ) -> Bool {
    func identity(_ source: SourceDeclaration) -> String {
      (try? source.identity(environment: environment)) ?? source.location
    }
    func subpath(_ source: SourceDeclaration) -> String {
      source.path.map { (try? PathSafety.sanitizeSubpath($0)) ?? $0 } ?? "."
    }
    let requirements: Bool
    switch (lhs.requirement, rhs.requirement) {
    case (nil, nil): requirements = true
    case (let left?, let right?): requirements = left.declarationEquivalent(to: right)
    default: requirements = false
    }
    return lhs.kind == rhs.kind && requirements && identity(lhs) == identity(rhs)
      && subpath(lhs) == subpath(rhs)
  }

  static func equivalent(_ lhs: SkillDeclaration, _ rhs: SkillDeclaration) -> Bool {
    let selections: Bool
    switch (lhs.select, rhs.select) {
    case (.all, .all): selections = true
    case (.names(let left), .names(let right)): selections = Set(left) == Set(right)
    default: selections = false
    }
    let left = lhs.overrides ?? [:]
    let right = rhs.overrides ?? [:]
    return selections && Set(lhs.exclude ?? []) == Set(rhs.exclude ?? [])
      && lhs.mode == rhs.mode && sameRecipients(lhs.agents, rhs.agents) && left.keys == right.keys
      && left.allSatisfy { equivalent($1, right[$0]!) }
  }

  static func equivalent(_ lhs: SkillOverride, _ rhs: SkillOverride) -> Bool {
    lhs.mode == rhs.mode && sameRecipients(lhs.agents, rhs.agents)
  }

  static func equivalent(_ lhs: InstructionsDeclaration, _ rhs: InstructionsDeclaration) -> Bool {
    sameRecipients(lhs.agents, rhs.agents) && lhs.sections == rhs.sections
      && lhs.chatgpt ?? [:] == rhs.chatgpt ?? [:]
  }

  static func sameRecipients(_ lhs: [AgentID]?, _ rhs: [AgentID]?) -> Bool {
    lhs.map(Set.init) == rhs.map(Set.init)
  }
}
