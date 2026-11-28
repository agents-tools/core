import Foundation

public enum SourceKind: String, Codable, Sendable {
  case git
  case local
  case wellKnown = "well-known"
}

/// A source alias's location, requirement and discovery root.
public struct SourceDeclaration: Equatable, Sendable {
  public var kind: SourceKind
  public var location: String
  public var requirement: SourceRequirement?
  public var path: String?
  public var environment: SourceEnvironment?

  public init(
    kind: SourceKind, location: String, requirement: SourceRequirement? = nil, path: String? = nil,
    environment: SourceEnvironment? = nil
  ) {
    self.kind = kind
    self.location = location
    self.requirement = requirement
    self.path = path
    self.environment = environment
  }

  public func identity(environment: RuntimeEnvironment) throws -> String {
    guard !location.isEmpty else { throw CoreError.invalidSource("empty source location") }
    switch kind {
    case .local:
      return "local:" + localURL(environment: environment).path
    case .wellKnown, .git:
      return try transportIdentity()
    }
  }

  /// Normalizes a transport location without a runtime filesystem context.
  package func transportIdentity() throws -> String {
    guard !location.isEmpty else { throw CoreError.invalidSource("empty source location") }
    switch kind {
    case .local: throw CoreError.invalidSource("local identity requires a package root")
    case .wellKnown:
      guard let components = URLComponents(string: location),
        ["http", "https"].contains(components.scheme), components.host != nil,
        components.fragment == nil, components.user == nil, components.password == nil
      else { throw CoreError.invalidSource("invalid well-known index URL: \(location)") }
      return location.hasSuffix("/") ? String(location.dropLast()) : location
    case .git:
      var value = location
      if !value.contains("://"), let colon = value.firstIndex(of: ":"),
        value[..<colon].contains("@")
      {
        value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
      } else if !value.contains("://") {
        value = "https://" + value
      }
      guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
        url.fragment == nil, url.query == nil
      else { throw CoreError.invalidSource("invalid Git URL: \(location)") }
      var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if path.hasSuffix(".git") { path.removeLast(4) }
      guard !path.isEmpty else {
        throw CoreError.invalidSource("Git source has no repository path")
      }
      return host.lowercased() + (url.port.map { ":\($0)" } ?? "") + "/" + path
    }
  }

  package func localURL(environment: RuntimeEnvironment) -> URL {
    let environment = self.environment.map { $0.runtime } ?? environment
    let expanded =
      location == "~"
      ? environment.homeDirectory.path
      : location.hasPrefix("~/")
        ? environment.homeDirectory.appendingPathComponent(String(location.dropFirst(2))).path
        : location
    return URL(
      fileURLWithPath: expanded,
      relativeTo: URL(fileURLWithPath: environment.projectDirectory.path, isDirectory: true)
    )
    .standardizedFileURL
  }

  package var gitURL: String {
    if location.contains("://") { return location }
    if let colon = location.firstIndex(of: ":"), location[..<colon].contains("@") {
      return location
    }
    return "https://" + location
  }
}

public enum SkillSelection: Equatable, Sendable {
  case all
  case names([String])
}

public struct SkillOverride: Equatable, Sendable {
  public var agents: [AgentID]?
  public var mode: InstallMode?

  public init(agents: [AgentID]? = nil, mode: InstallMode? = nil) {
    self.agents = agents
    self.mode = mode
  }
}

public struct SkillDeclaration: Equatable, Sendable {
  public var select: SkillSelection
  /// Narrows filesystem discovery relative to the source view while retaining its containment.
  public var path: String?
  public var exclude: [String]?
  public var agents: [AgentID]?
  public var mode: InstallMode?
  public var overrideDeclarations: [NamedSkillOverrideDeclaration]

  public var overrides: [String: SkillOverride]? {
    get {
      overrideDeclarations.isEmpty
        ? nil
        : Dictionary(uniqueKeysWithValues: overrideDeclarations.map { ($0.name, $0.override) })
    }
    set {
      let retained = Set(overrideDeclarations.map(\.name))
      overrideDeclarations =
        overrideDeclarations.compactMap { entry in
          newValue?[entry.name].map {
            NamedSkillOverrideDeclaration(name: entry.name, override: $0)
          }
        }
        + (newValue ?? [:]).keys.filter { !retained.contains($0) }.sorted(by: declarationNameLess)
        .map {
          NamedSkillOverrideDeclaration(name: $0, override: newValue![$0]!)
        }
    }
  }
  public var condition: DeclarationCondition?
  public var native: NativeConfiguration

  public init(
    select: SkillSelection, path: String? = nil, exclude: [String]? = nil, agents: [AgentID]? = nil,
    mode: InstallMode? = nil, overrides: [String: SkillOverride]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:]
  ) {
    self.select = select
    self.path = path
    self.exclude = exclude
    self.agents = agents
    self.mode = mode
    overrideDeclarations = (overrides ?? [:]).keys.sorted(by: declarationNameLess).map {
      NamedSkillOverrideDeclaration(name: $0, override: overrides![$0]!)
    }
    self.condition = condition
    self.native = native
  }
}

public struct PromptDeclaration: Equatable, Sendable {
  public var sectionReferences: [SectionDeclaration]
  public var append: String?
  public var condition: DeclarationCondition?

  public init(sections: [String], append: String? = nil, condition: DeclarationCondition? = nil) {
    sectionReferences = sections.map(SectionDeclaration.init(reference:))
    self.append = append
    self.condition = condition
  }

  public var sections: [String] {
    get { sectionReferences.map(\.reference) }
    set { sectionReferences = newValue.map(SectionDeclaration.init(reference:)) }
  }
}

public struct InstructionsDeclaration: Equatable, Sendable {
  public var agents: [AgentID]?
  public var sectionReferences: [SectionDeclaration]
  public var prompts: [NamedPromptDeclaration]
  public var condition: DeclarationCondition?
  public var native: NativeConfiguration

  public init(
    agents: [AgentID]? = nil, sections: [String] = [], chatgpt: [String: PromptDeclaration]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:]
  ) {
    self.agents = agents
    sectionReferences = sections.map(SectionDeclaration.init(reference:))
    prompts = (chatgpt ?? [:]).keys.sorted(by: declarationNameLess).map {
      NamedPromptDeclaration(name: $0, prompt: chatgpt![$0]!)
    }
    self.condition = condition
    self.native = native
  }

  public var sections: [String] {
    get { sectionReferences.map(\.reference) }
    set { sectionReferences = newValue.map(SectionDeclaration.init(reference:)) }
  }

  public var chatgpt: [String: PromptDeclaration]? {
    get {
      prompts.isEmpty ? nil : Dictionary(uniqueKeysWithValues: prompts.map { ($0.name, $0.prompt) })
    }
    set {
      let retained = Set(prompts.map(\.name))
      prompts =
        prompts.compactMap { entry in
          newValue?[entry.name].map { NamedPromptDeclaration(name: entry.name, prompt: $0) }
        }
        + (newValue ?? [:]).keys.filter { !retained.contains($0) }.sorted(by: declarationNameLess)
        .map {
          NamedPromptDeclaration(name: $0, prompt: newValue![$0]!)
        }
    }
  }
}

/// Complete symbolic intent. Components, sources, groups, uses and exports retain their order.
/// Source discovery and condition evaluation belong to linking, after this declaration is read.
public struct Declaration: Equatable, Sendable {
  public var agents: [AgentID]?
  public var sourceDeclarations: [NamedSourceDeclaration]
  public var components: [ComponentDeclaration]
  public var groups: [ComponentGroupDeclaration]
  public var uses: [GroupUseDeclaration]
  public var exports: [String]
  public var watch: [String]?
  public var packages: [MarketplaceDependency]
  public var marketplaceRoots: [MarketplaceRoot]
  public var lifecycle: DeclarationValue?

  public init(
    agents: [AgentID]? = nil, sources: [String: SourceDeclaration] = [:],
    skills: [String: SkillDeclaration]? = nil, instructions: InstructionsDeclaration? = nil,
    watch: [String]? = nil, components: [ComponentDeclaration] = [],
    groups: [ComponentGroupDeclaration] = [], uses: [GroupUseDeclaration] = [],
    exports: [String] = [], packages: [MarketplaceDependency] = [],
    marketplaceRoots: [MarketplaceRoot] = [], lifecycle: DeclarationValue? = nil
  ) {
    self.agents = agents
    sourceDeclarations = sources.keys.sorted(by: declarationNameLess).map {
      NamedSourceDeclaration(name: $0, source: sources[$0]!)
    }
    self.components =
      (skills ?? [:]).keys.sorted(by: declarationNameLess).map { .skills(source: $0, skills![$0]!) }
      + (instructions.map { [.instructions($0)] } ?? []) + components
    self.groups = groups
    self.uses = uses
    self.exports = exports
    self.watch = watch
    self.packages = packages
    self.marketplaceRoots = marketplaceRoots
    self.lifecycle = lifecycle
  }

  public init(
    agents: [AgentID]? = nil, sourceDeclarations: [NamedSourceDeclaration],
    components: [ComponentDeclaration] = [], groups: [ComponentGroupDeclaration] = [],
    uses: [GroupUseDeclaration] = [], exports: [String] = [], watch: [String]? = nil,
    packages: [MarketplaceDependency] = [], marketplaceRoots: [MarketplaceRoot] = [],
    lifecycle: DeclarationValue? = nil
  ) {
    self.agents = agents
    self.sourceDeclarations = sourceDeclarations
    self.components = components
    self.groups = groups
    self.uses = uses
    self.exports = exports
    self.watch = watch
    self.packages = packages
    self.marketplaceRoots = marketplaceRoots
    self.lifecycle = lifecycle
  }

  /// Alias access preserves the positions and declaration environments of retained sources.
  public var sources: [String: SourceDeclaration] {
    get { Dictionary(uniqueKeysWithValues: sourceDeclarations.map { ($0.name, $0.source) }) }
    set {
      let retained = Set(sourceDeclarations.map(\.name))
      sourceDeclarations =
        sourceDeclarations.compactMap { entry in
          newValue[entry.name].map { NamedSourceDeclaration(name: entry.name, source: $0) }
        }
        + newValue.keys.filter { !retained.contains($0) }.sorted(by: declarationNameLess).map {
          NamedSourceDeclaration(name: $0, source: newValue[$0]!)
        }
    }
  }

  public var defaultAgents: [AgentID] { agents ?? [.codex, .claudeCode] }

  /// The flat root selection used by existing skill operations. Multiple occurrences require
  /// an occurrence-addressed edit; no occurrence is selected by precedence or condition.
  public var skills: [String: SkillDeclaration]? {
    get throws {
      var result: [String: SkillDeclaration] = [:]
      for case .skills(let source, let selection) in components {
        guard result[source] == nil else {
          throw CoreError.invalidState("ambiguous skills occurrence: \(source)")
        }
        result[source] = selection
      }
      return result.isEmpty ? nil : result
    }
  }

  public mutating func setSkills(_ selections: [String: SkillDeclaration]?) throws {
    _ = try skills
    var pending = selections ?? [:]
    components = components.compactMap { component in
      guard case .skills(let source, _) = component else { return component }
      return pending.removeValue(forKey: source).map { .skills(source: source, $0) }
    }
    let additions = pending.keys.sorted(by: declarationNameLess).map {
      ComponentDeclaration.skills(source: $0, pending[$0]!)
    }
    let insertion =
      components.firstIndex {
        if case .instructions = $0 { return true }
        return false
      } ?? components.endIndex
    components.insert(contentsOf: additions, at: insertion)
  }

  public mutating func updateSkills(_ change: (inout [String: SkillDeclaration]?) throws -> Void)
    throws
  {
    var selections = try skills
    try change(&selections)
    try setSkills(selections)
  }

  public var instructions: InstructionsDeclaration? {
    get throws {
      let values = components.compactMap { component -> InstructionsDeclaration? in
        if case .instructions(let value) = component { return value }
        return nil
      }
      guard values.count <= 1 else {
        throw CoreError.invalidState("ambiguous instructions occurrence")
      }
      return values.first
    }
  }

  public mutating func setInstructions(_ value: InstructionsDeclaration?) throws {
    _ = try instructions
    if let index = components.firstIndex(where: {
      if case .instructions = $0 { return true }
      return false
    }) {
      if let value {
        components[index] = .instructions(value)
      } else {
        components.remove(at: index)
      }
    } else if let value {
      components.append(.instructions(value))
    }
  }

  public mutating func updateInstructions(_ change: (inout InstructionsDeclaration?) throws -> Void)
    throws
  {
    var value = try instructions
    try change(&value)
    try setInstructions(value)
  }

  public func validate(environment: RuntimeEnvironment) throws {
    if let lifecycle, let issue = LifecycleDeclaration(lifecycle).issues.first {
      throw CoreError.invalidState("Invalid lifecycle declaration: " + issue.message)
    }
    var dependencyNames = Set<String>()
    for dependency in packages {
      try dependency.validate()
      guard dependencyNames.insert(dependency.name).inserted else {
        throw MarketplaceError.invalidPackage("duplicate dependency: " + dependency.name)
      }
    }
    for root in marketplaceRoots {
      try root.validate()
      guard dependencyNames.insert(root.name).inserted else {
        throw MarketplaceError.invalidPackage("duplicate dependency: " + root.name)
      }
    }
    var aliases = Set<String>()
    var sourceRoots = Set<[String]>()
    for entry in sourceDeclarations {
      let (alias, source) = (entry.name, entry.source)
      guard !alias.isEmpty, alias != ".", !alias.contains(":"), aliases.insert(alias).inserted
      else {
        throw CoreError.invalidState("invalid or duplicate source alias: \(alias)")
      }
      let identity = try source.identity(environment: environment)
      let root = try PathSafety.sanitizeSubpath(source.path ?? ".")
      guard sourceRoots.insert([identity, source.kind == .wellKnown ? "." : root]).inserted else {
        throw CoreError.invalidState(
          "two source aliases normalize to the same source and discovery root")
      }
      try source.requirement?.validate()
      if source.kind == .wellKnown, source.requirement != nil {
        throw CoreError.invalidState("well-known sources take no Git requirement")
      }
    }
    for component in components + groups.flatMap(\.components) {
      switch component {
      case .skills(let alias, let selection):
        guard alias == "." || sources[alias] != nil else {
          throw CoreError.invalidState("unknown source alias: \(alias)")
        }
        let source = sources[alias]
        if let path = selection.path {
          _ = try PathSafety.sanitizeSubpath(path)
          guard source?.kind != .wellKnown else {
            throw CoreError.invalidState("skill paths require a filesystem source")
          }
        }
        let modes =
          [selection.mode ?? .link] + selection.overrideDeclarations.compactMap { $0.override.mode }
        if modes.contains(.edit), alias != ".", source?.kind != .local || source?.requirement != nil
        {
          throw CoreError.invalidState("edit requires a local source with no requirement")
        }
        if case .names(let names) = selection.select { try Self.validateNames(names) }
        try Self.validateNames(selection.exclude ?? [])
        try Self.validateNames(selection.overrideDeclarations.map(\.name))
      case .instructions(let instructions):
        for section in instructions.sectionReferences
          + instructions.prompts.flatMap({ $0.prompt.sectionReferences })
        {
          guard Self.isInstructionName(section.name),
            section.source == nil || section.source == "." || sources[section.source!] != nil
          else {
            throw CoreError.invalidState("invalid section reference: \(section.reference)")
          }
        }
        for entry in instructions.prompts {
          if let append = entry.prompt.append { _ = try PathSafety.sanitizeSubpath(append) }
        }
      case .mcpServer(_, let transport, _, _, _, let registry):
        try registry?.validate(matching: transport)
      default: break
      }
      let program: ExecutableDeclaration?
      switch component {
      case .mcpServer(_, .stdio(let value), _, _, _, _): program = value
      case .hook(_, _, let value, _, _, _, _, _), .lspServer(_, let value, _, _, _, _, _):
        program = value
      default: program = nil
      }
      if let program, let alias = program.executableSource {
        guard alias == "." || sources[alias] != nil, program.executable.contains("/") else {
          throw CoreError.invalidState(
            "executable source requires an existing alias and resource path")
        }
        _ = try PathSafety.sanitizeSubpath(program.executable)
      }
    }
    guard Set(watch ?? []).count == (watch ?? []).count else {
      throw CoreError.invalidState("duplicate watch subscription")
    }
    for alias in watch ?? [] where !aliases.contains(alias) {
      throw CoreError.invalidState("unknown watch source: \(alias)")
    }
  }

  /// Whether every `/`-separated segment of an instructions name uses lowercase letters, digits
  /// and hyphens. A reference without an alias names the project's own instructions.
  package static func isInstructionName(_ name: String) -> Bool {
    let segments = name.split(separator: "/", omittingEmptySubsequences: false)
    return !segments.isEmpty
      && segments.allSatisfy {
        $0.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
      }
  }

  package static func validateNames(_ names: [String]) throws {
    guard Set(names).count == names.count, names.allSatisfy({ $0 == PathSafety.sanitizeName($0) })
    else {
      throw CoreError.invalidState("skill names must be unique filesystem identities")
    }
  }

  package var normalized: Declaration {
    var result = self
    result.agents?.sort { $0.rawValue < $1.rawValue }
    result.watch?.sort()
    result.components = components.map { component in
      switch component {
      case .skills(let source, var selection):
        selection.exclude?.sort()
        selection.agents?.sort { $0.rawValue < $1.rawValue }
        for index in selection.overrideDeclarations.indices {
          selection.overrideDeclarations[index].override.agents?.sort { $0.rawValue < $1.rawValue }
        }
        return .skills(source: source, selection)
      case .instructions(var instructions):
        instructions.agents?.sort { $0.rawValue < $1.rawValue }
        return .instructions(instructions)
      default: return component
      }
    }
    return result
  }

}

extension Declaration {
  /// The alias a newly declared source receives: the location's last path component,
  /// prefixed by preceding components and then numbered while another source holds it.
  package func derivedAlias(for location: String) -> String {
    var candidate = PathSafety.sanitizeName(
      URL(fileURLWithPath: location).deletingPathExtension().lastPathComponent)
    var parents = location.replacingOccurrences(
      of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, with: "", options: .regularExpression
    )
    .split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init).dropLast()
    while sources[candidate] != nil, let parent = parents.popLast() {
      candidate = PathSafety.sanitizeName(parent + "-" + candidate)
    }
    let base = candidate
    var number = 2
    while sources[candidate] != nil {
      candidate = "\(base)-\(number)"
      number += 1
    }
    return candidate
  }
}

/// Canonical order for new entries supplied through alias/name dictionaries.
private func declarationNameLess(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
