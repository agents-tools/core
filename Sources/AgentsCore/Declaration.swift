import Foundation

public enum SourceKind: String, Codable, Sendable {
  case git
  case local
  case wellKnown = "well-known"
}

/// A source alias's location, requirement and discovery root in agents.json.
public struct SourceDeclaration: Codable, Equatable, Sendable {
  public var kind: SourceKind
  public var location: String
  public var requirement: SourceRequirement?
  public var path: String?

  public init(
    kind: SourceKind, location: String, requirement: SourceRequirement? = nil, path: String? = nil
  ) {
    self.kind = kind
    self.location = location
    self.requirement = requirement
    self.path = path
  }

  private enum CodingKeys: String, CodingKey {
    case git, local
    case wellKnown = "well-known"
    case path
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kinds: [(CodingKeys, SourceKind)] = [
      (.git, .git), (.local, .local), (.wellKnown, .wellKnown),
    ]
    let present = kinds.filter { container.contains($0.0) }
    guard present.count == 1, let (key, kind) = present.first else {
      throw CoreError.invalidState("a source must specify exactly one of git, local or well-known")
    }
    self.kind = kind
    location = try container.decode(String.self, forKey: key)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    requirement = try SourceRequirement.decodeIfPresent(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let key: CodingKeys = kind == .git ? .git : (kind == .local ? .local : .wellKnown)
    try container.encode(location, forKey: key)
    try container.encodeIfPresent(path, forKey: .path)
    try requirement?.encode(to: encoder)
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

public enum SkillSelection: Codable, Equatable, Sendable {
  case all
  case names([String])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self), value == "all" {
      self = .all
    } else {
      self = .names(try container.decode([String].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .all: try container.encode("all")
    case .names(let names): try container.encode(names.sorted())
    }
  }
}

public struct SkillOverride: Codable, Equatable, Sendable {
  public var agents: [AgentID]?
  public var mode: InstallMode?

  public init(agents: [AgentID]? = nil, mode: InstallMode? = nil) {
    self.agents = agents
    self.mode = mode
  }
}

public struct SkillDeclaration: Codable, Equatable, Sendable {
  public var select: SkillSelection
  public var exclude: [String]?
  public var agents: [AgentID]?
  public var mode: InstallMode?
  public var overrides: [String: SkillOverride]?

  public init(
    select: SkillSelection, exclude: [String]? = nil, agents: [AgentID]? = nil,
    mode: InstallMode? = nil, overrides: [String: SkillOverride]? = nil
  ) {
    self.select = select
    self.exclude = exclude
    self.agents = agents
    self.mode = mode
    self.overrides = overrides
  }
}

public struct PromptDeclaration: Codable, Equatable, Sendable {
  /// Source alias and section name pairs, in rendering order.
  public var sections: [String]
  public var append: String?

  public init(sections: [String], append: String? = nil) {
    self.sections = sections
    self.append = append
  }
}

public struct InstructionsDeclaration: Codable, Equatable, Sendable {
  public var agents: [AgentID]?
  public var sections: [String]
  public var chatgpt: [String: PromptDeclaration]?

  public init(
    agents: [AgentID]? = nil, sections: [String] = [], chatgpt: [String: PromptDeclaration]? = nil
  ) {
    self.agents = agents
    self.sections = sections
    self.chatgpt = chatgpt
  }
}

/// User intent. Section order is significant; other collections are emitted in identity order.
public struct Declaration: Codable, Equatable, Sendable {
  public var agents: [AgentID]?
  public var sources: [String: SourceDeclaration]
  public var skills: [String: SkillDeclaration]?
  public var instructions: InstructionsDeclaration?
  public var watch: [String]?

  public init(
    agents: [AgentID]? = nil, sources: [String: SourceDeclaration] = [:],
    skills: [String: SkillDeclaration]? = nil, instructions: InstructionsDeclaration? = nil,
    watch: [String]? = nil
  ) {
    self.agents = agents
    self.sources = sources
    self.skills = skills
    self.instructions = instructions
    self.watch = watch
  }

  /// A missing `sources` key means no declared sources, as in a project that selects only its
  /// own instructions.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agents = try container.decodeIfPresent([AgentID].self, forKey: .agents)
    sources =
      try container.decodeIfPresent([String: SourceDeclaration].self, forKey: .sources) ?? [:]
    skills = try container.decodeIfPresent([String: SkillDeclaration].self, forKey: .skills)
    instructions = try container.decodeIfPresent(
      InstructionsDeclaration.self, forKey: .instructions)
    watch = try container.decodeIfPresent([String].self, forKey: .watch)
  }

  public var defaultAgents: [AgentID] { agents ?? [.codex, .claudeCode] }

  public func validate(environment: RuntimeEnvironment) throws {
    var identities = Set<String>()
    for (alias, source) in sources {
      guard !alias.isEmpty, !alias.contains(":") else {
        throw CoreError.invalidState("invalid source alias: \(alias)")
      }
      guard try identities.insert(source.identity(environment: environment)).inserted else {
        throw CoreError.invalidState("two source aliases normalize to the same source ID")
      }
      try source.requirement?.validate()
      if let path = source.path { _ = try PathSafety.sanitizeSubpath(path) }
      if source.kind == .wellKnown, source.requirement != nil {
        throw CoreError.invalidState("well-known sources take no Git requirement")
      }
    }
    for (alias, selection) in skills ?? [:] {
      guard let source = sources[alias] else {
        throw CoreError.invalidState("unknown source alias: \(alias)")
      }
      var modes = [selection.mode ?? .link]
      modes += (selection.overrides ?? [:]).values.compactMap(\.mode)
      if modes.contains(.edit), source.kind != .local || source.requirement != nil {
        throw CoreError.invalidState("edit requires a local source with no requirement")
      }
      if case .names(let names) = selection.select { try Self.validateNames(names) }
      try Self.validateNames(selection.exclude ?? [])
      try Self.validateNames(Array((selection.overrides ?? [:]).keys))
    }
    guard Set(watch ?? []).count == (watch ?? []).count else {
      throw CoreError.invalidState("duplicate watch subscription")
    }
    for alias in watch ?? [] where sources[alias] == nil {
      throw CoreError.invalidState("unknown watch source: \(alias)")
    }
    for reference in (instructions?.sections ?? [])
      + (instructions?.chatgpt ?? [:]).values.flatMap(\.sections)
    {
      let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
      let valid =
        parts.count == 1
        ? Self.isInstructionName(reference)
        : parts.count == 2 && sources[String(parts[0])] != nil
          && Self.isInstructionName(String(parts[1]))
      guard valid else { throw CoreError.invalidState("invalid section reference: \(reference)") }
    }
    for prompt in (instructions?.chatgpt ?? [:]).values {
      if let append = prompt.append { _ = try PathSafety.sanitizeSubpath(append) }
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
    result.instructions?.agents?.sort { $0.rawValue < $1.rawValue }
    for alias in (result.skills ?? [:]).keys {
      result.skills?[alias]?.exclude?.sort()
      result.skills?[alias]?.agents?.sort { $0.rawValue < $1.rawValue }
      for name in (result.skills?[alias]?.overrides ?? [:]).keys {
        result.skills?[alias]?.overrides?[name]?.agents?.sort { $0.rawValue < $1.rawValue }
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
