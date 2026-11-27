import AgentsCore
import Foundation

/// The declaration wire format read from agents.json.
struct ExistingGlobalConfigurationJSON: Codable {
  let agents: [AgentID]?
  let sources: [String: Source]?
  let skills: [String: Skill]?
  let instructions: InstructionSelection?
  let watch: [String]?

  func declaration(environment: RuntimeEnvironment) throws -> Declaration {
    let sources = (sources ?? [:]).mapValues { $0.declaration(environment: environment) }
    // Installation records name a source by normalized identity, with one discovery root
    // per identity in agents.json and agents.resolved.
    var aliases: [String: String] = [:]
    for alias in sources.keys.sorted() {
      let identity = try sources[alias]!.identity(environment: environment)
      if let existing = aliases.updateValue(alias, forKey: identity) {
        throw CoreError.invalidState(
          "Source aliases '\(existing)' and '\(alias)' in agents.json identify the same source. "
            + "Use one alias per source and reconcile its selections before previewing again.")
      }
    }
    let declaration = Declaration(
      agents: agents, sources: sources, skills: skills?.mapValues(\.declaration),
      instructions: instructions?.declaration, watch: watch)
    try declaration.validate(environment: environment)
    if let instructions = try declaration.instructions {
      let sections =
        instructions.sectionReferences
        + instructions.prompts.flatMap { $0.prompt.sectionReferences }
      guard sections.allSatisfy({ $0.source != nil && $0.source != "." }) else {
        throw CoreError.invalidState("global instruction selections need a named source")
      }
    }
    return declaration
  }

  struct Source: Codable {
    private enum CodingKeys: String, CodingKey {
      case git, local, path
      case wellKnown = "well-known"
    }

    let kind: SourceKind
    let location: String
    let requirement: SourceRequirement?
    let path: String?

    init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      let kinds: [(CodingKeys, SourceKind)] = [
        (.git, .git), (.local, .local), (.wellKnown, .wellKnown),
      ]
      let present = kinds.filter { fields.contains($0.0) }
      guard present.count == 1, let (key, kind) = present.first else {
        throw CoreError.invalidState("a source in agents.json must specify one location")
      }
      self.kind = kind
      location = try fields.decode(String.self, forKey: key)
      path = try fields.decodeIfPresent(String.self, forKey: .path)
      requirement = try SourceRequirement.decodeIfPresent(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(
        location, forKey: kind == .git ? .git : kind == .local ? .local : .wellKnown)
      try fields.encodeIfPresent(path, forKey: .path)
      try requirement?.encode(to: encoder)
    }

    func declaration(environment: RuntimeEnvironment) -> SourceDeclaration {
      var source = SourceDeclaration(
        kind: kind, location: location, requirement: requirement, path: path)
      if kind == .local, !location.hasPrefix("/"), location != "~", !location.hasPrefix("~/") {
        source.location = source.localURL(environment: environment).path
      }
      return source
    }
  }

  struct Skill: Codable {
    let select: Selection
    let exclude: [String]?
    let agents: [AgentID]?
    let mode: InstallMode?
    let overrides: [String: Override]?

    private enum CodingKeys: String, CodingKey { case select, exclude, agents, mode, overrides }
    private enum UnsupportedKeys: String, CodingKey { case path }

    init(from decoder: any Decoder) throws {
      let unsupported = try decoder.container(keyedBy: UnsupportedKeys.self)
      if unsupported.contains(.path) {
        let alias = decoder.codingPath.last?.stringValue ?? "unknown"
        throw CoreError.invalidState(
          "skills.\(alias).path is unsupported in agents.json. "
            + "Set the discovery path on sources.\(alias).path before previewing again.")
      }
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      select = try fields.decode(Selection.self, forKey: .select)
      exclude = try fields.decodeIfPresent([String].self, forKey: .exclude)
      agents = try fields.decodeIfPresent([AgentID].self, forKey: .agents)
      mode = try fields.decodeIfPresent(InstallMode.self, forKey: .mode)
      overrides = try fields.decodeIfPresent([String: Override].self, forKey: .overrides)
    }

    var declaration: SkillDeclaration {
      .init(
        select: select.value, exclude: exclude, agents: agents, mode: mode,
        overrides: overrides?.mapValues { .init(agents: $0.agents, mode: $0.mode) })
    }
  }

  struct Override: Codable {
    let agents: [AgentID]?
    let mode: InstallMode?
  }

  struct Selection: Codable {
    let value: SkillSelection

    init(from decoder: any Decoder) throws {
      let field = try decoder.singleValueContainer()
      if (try? field.decode(String.self)) == "all" {
        value = .all
      } else {
        value = .names(try field.decode([String].self))
      }
    }

    func encode(to encoder: any Encoder) throws {
      var field = encoder.singleValueContainer()
      switch value {
      case .all: try field.encode("all")
      case .names(let names): try field.encode(names)
      }
    }
  }

  struct InstructionSelection: Codable {
    let agents: [AgentID]?
    let sections: [String]
    let chatgpt: [String: Prompt]?

    var declaration: InstructionsDeclaration {
      .init(
        agents: agents, sections: sections,
        chatgpt: chatgpt?.mapValues { .init(sections: $0.sections, append: $0.append) })
    }
  }

  struct Prompt: Codable {
    let sections: [String]
    let append: String?
  }
}
