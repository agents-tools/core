import AgentsCore
import AgentsDescription

/// Constructs the complete symbolic declaration without linking or evaluating conditions.
package enum DeclarationConstruction {
  package static func root(_ declaration: Declaration) throws -> Agents {
    Agents(
      defaultAgents: declaration.agents.map { $0.map(agent) }, exports: declaration.exports,
      sources: try declaration.sourceDeclarations.map { try source(alias: $0.name, $0.source) },
      components: declaration.components.map(component), groups: declaration.groups.map(group),
      uses: declaration.uses.map(use), watch: declaration.watch ?? [])
  }

  /// Git sources use complete transport URLs. Version ranges are checked before construction.
  package static func source(alias: String, _ source: SourceDeclaration) throws -> Source {
    let subpath = source.path
    guard source.kind != .wellKnown else {
      guard source.requirement == nil else {
        throw CoreError.invalidState("well-known sources take no Git requirement")
      }
      return .source(name: alias, index: source.location, subpath: subpath)
    }
    let git = source.kind == .git
    let location = git ? source.gitURL : source.location
    guard let requirement = source.requirement else {
      return git
        ? .source(name: alias, url: location, subpath: subpath)
        : .source(name: alias, path: location, subpath: subpath)
    }
    switch requirement {
    case .branch(let branch):
      return git
        ? .source(name: alias, url: location, branch: branch, subpath: subpath)
        : .source(name: alias, path: location, branch: branch, subpath: subpath)
    case .revision(let revision):
      return git
        ? .source(name: alias, url: location, revision: revision, subpath: subpath)
        : .source(name: alias, path: location, revision: revision, subpath: subpath)
    case .exact(let version):
      let exact = Version(stringLiteral: version)
      return git
        ? .source(name: alias, url: location, exact: exact, subpath: subpath)
        : .source(name: alias, path: location, exact: exact, subpath: subpath)
    case .upToNextMajor(let lower):
      let from = Version(stringLiteral: lower)
      return git
        ? .source(name: alias, url: location, from: from, subpath: subpath)
        : .source(name: alias, path: location, from: from, subpath: subpath)
    case .upToNextMinor(let lower), .range(let lower, _):
      let range: Range<Version>
      if case .range(_, let upper) = requirement {
        let (from, to) = (Version(stringLiteral: lower), Version(stringLiteral: upper))
        guard from < to else { throw CoreError.invalidState("invalid version range") }
        range = from..<to
      } else {
        range = .upToNextMinor(from: Version(stringLiteral: lower))
      }
      return git
        ? .source(name: alias, url: location, range, subpath: subpath)
        : .source(name: alias, path: location, range, subpath: subpath)
    }
  }

  package static func skills(alias: String, _ skills: SkillDeclaration) -> Component {
    return .skills(
      source: alias, select: selection(skills.select),
      exclude: skills.exclude ?? [], mode: skills.mode.map(mode),
      overrides: skills.overrideDeclarations.map { override(name: $0.name, $0.override) },
      agents: skills.agents.map { $0.map(agent) }, condition: condition(skills.condition),
      native: native(skills.native))
  }

  package static func selection(
    _ selection: AgentsCore.SkillSelection
  ) -> AgentsDescription.SkillSelection {
    switch selection {
    case .all: return .all
    case .names(let names):
      return AgentsDescription.SkillSelection(
        value: .construct(
          type: "SkillSelection", member: "names",
          fields: ["names": names.constructionValue]))
    }
  }

  package static func override(
    name: String, _ override: AgentsCore.SkillOverride
  ) -> AgentsDescription.SkillOverride {
    .skill(name: name, mode: override.mode.map(mode), agents: override.agents.map { $0.map(agent) })
  }

  package static func instructions(_ instructions: InstructionsDeclaration) -> Component {
    .instructions(
      sections: instructions.sectionReferences.map(section),
      chatGPT: instructions.prompts.map { prompt(name: $0.name, $0.prompt) },
      agents: instructions.agents.map { $0.map(agent) },
      condition: condition(instructions.condition), native: native(instructions.native))
  }

  package static func prompt(name: String, _ prompt: PromptDeclaration) -> ChatGPTPrompt {
    .prompt(
      name: name, sections: prompt.sectionReferences.map(section), append: prompt.append,
      condition: condition(prompt.condition))
  }

  package static func section(_ section: SectionDeclaration) -> SectionReference {
    .section(name: section.name, source: section.source, condition: condition(section.condition))
  }

  /// `alias:name` names a source section; a bare name is the declaring project's own section.
  package static func section(_ reference: String) -> SectionReference {
    guard let colon = reference.firstIndex(of: ":") else {
      return SectionReference(stringLiteral: reference)
    }
    return .section(
      name: String(reference[reference.index(after: colon)...]),
      source: String(reference[..<colon]))
  }

  package static func recipients(_ agents: [AgentID]?) -> [Agent]? {
    agents.map { Set($0).sorted { utf8Less($0.rawValue, $1.rawValue) }.map(agent) }
  }

  package static func agent(_ agent: AgentID) -> Agent {
    switch agent {
    case .claudeCode: .claudeCode
    case .codex: .codex
    case .cursor: .cursor
    case .geminiCLI: .geminiCLI
    case .opencode: .openCode
    }
  }

  package static func mode(_ mode: AgentsCore.InstallMode) -> AgentsDescription.InstallMode {
    switch mode {
    case .link: .link
    case .copy: .copy
    case .edit: .edit
    }
  }
}
