import Foundation

public struct LockedSource: Codable, Equatable, Sendable {
  public var kind: SourceKind
  public var url: String?
  public var requirement: SourceRequirement?
  public var path: String?

  public init(
    kind: SourceKind, url: String? = nil, requirement: SourceRequirement? = nil, path: String? = nil
  ) {
    self.kind = kind
    self.url = url
    self.requirement = requirement
    self.path = path
  }
}

public struct ArtifactFile: Codable, Equatable, Sendable {
  public var url: String
  public var path: String
  public var digest: String

  public init(url: String, path: String, digest: String) {
    self.url = url
    self.path = path
    self.digest = digest
  }
}

/// Immutable download coordinates. Files artifacts hash their sorted per-file records.
public struct LockedArtifact: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case archive
    case skillMD = "skill-md"
    case files
  }

  public var type: Kind
  public var url: String
  public var digest: String
  public var files: [ArtifactFile]?

  public init(type: Kind, url: String, digest: String, files: [ArtifactFile]? = nil) {
    self.type = type
    self.url = url
    self.digest = digest
    self.files = files
  }

  package func validate() throws {
    try StateValidation.digest(digest)
    try StateValidation.downloadURL(url)
    if type == .files {
      guard let files, !files.isEmpty, Set(files.map(\.path)).count == files.count else {
        throw CoreError.invalidState("files artifact needs unique per-file entries")
      }
      for file in files {
        _ = try PathSafety.sanitizeSubpath(file.path)
        try StateValidation.digest(file.digest)
        try StateValidation.downloadURL(file.url)
      }
    } else if files != nil {
      throw CoreError.invalidState("only files artifacts have file entries")
    }
  }

  package static func filesDigest(_ files: [ArtifactFile]) throws -> String {
    "sha256:" + FileHash.sha256Hex(data: try StateStore.encode(files.sorted { $0.path < $1.path }))
  }
}

/// A skill's own pin and recipients. Live edit links have neither pin nor hash.
public struct LockedSkill: Codable, Equatable, Sendable {
  public var source: String
  public var revision: String?
  public var version: String?
  public var artifact: LockedArtifact?
  public var path: String?
  public var hash: String?
  public var installs: [String: InstallMode]

  public init(
    source: String, revision: String? = nil, version: String? = nil,
    artifact: LockedArtifact? = nil, path: String? = nil, hash: String? = nil,
    installs: [String: InstallMode]
  ) {
    self.source = source
    self.revision = revision
    self.version = version
    self.artifact = artifact
    self.path = path
    self.hash = hash
    self.installs = installs
  }
}

public struct LockedSection: Codable, Equatable, Sendable {
  public var name: String
  public var source: String
  public var revision: String?
  public var version: String?
  public var artifact: LockedArtifact?
  public var path: String
  public var hash: String

  public init(
    name: String, source: String, revision: String? = nil, version: String? = nil,
    artifact: LockedArtifact? = nil, path: String, hash: String
  ) {
    self.name = name
    self.source = source
    self.revision = revision
    self.version = version
    self.artifact = artifact
    self.path = path
    self.hash = hash
  }
}

public struct LockedPrompt: Codable, Equatable, Sendable {
  public var sections: [LockedSection]
  public var append: String?

  public init(sections: [LockedSection], append: String? = nil) {
    self.sections = sections
    self.append = append
  }
}

/// A physical target's rendering metadata; `created` controls removal ownership.
public struct LockedTarget: Codable, Equatable, Sendable {
  public var agents: [AgentID]
  public var headingOffset: Int?
  public var `import`: String?
  public var blockHash: String
  public var created: Bool

  public init(
    agents: [AgentID], headingOffset: Int? = nil, import: String? = nil, blockHash: String,
    created: Bool
  ) {
    self.agents = agents
    self.headingOffset = headingOffset
    self.import = `import`
    self.blockHash = blockHash
    self.created = created
  }
}

public struct LockedInstructions: Codable, Equatable, Sendable {
  public var sections: [LockedSection]
  public var chatgpt: [String: LockedPrompt]
  public var targets: [String: LockedTarget]

  public init(
    sections: [LockedSection] = [], chatgpt: [String: LockedPrompt] = [:],
    targets: [String: LockedTarget] = [:]
  ) {
    self.sections = sections
    self.chatgpt = chatgpt
    self.targets = targets
  }
}

/// Version 1 of agents.resolved. Every item carries its independent immutable pin.
public struct ResolvedState: Codable, Equatable, Sendable {
  public var version: Int
  public var sources: [String: LockedSource]
  public var skills: [String: LockedSkill]
  public var instructions: LockedInstructions

  public init(
    version: Int = 1, sources: [String: LockedSource] = [:], skills: [String: LockedSkill] = [:],
    instructions: LockedInstructions = LockedInstructions()
  ) {
    self.version = version
    self.sources = sources
    self.skills = skills
    self.instructions = instructions
  }

  public func validate() throws {
    guard version == 1 else {
      throw CoreError.invalidState("unsupported agents.resolved version: \(version)")
    }
    for (id, source) in sources {
      guard !id.isEmpty else { throw CoreError.invalidState("empty source ID") }
      if source.kind == .git, source.url == nil {
        throw CoreError.invalidState("Git source needs its URL")
      }
      if source.kind == .local, !id.hasPrefix("local:/") {
        throw CoreError.invalidState("local source needs an absolute ID")
      }
      let location =
        source.kind == .git
        ? source.url! : source.kind == .local ? String(id.dropFirst("local:".count)) : id
      let normalized = try SourceDeclaration(kind: source.kind, location: location).identity(
        environment: RuntimeEnvironment())
      guard normalized == id else {
        throw CoreError.invalidState("source ID does not match its location")
      }
      if source.kind == .wellKnown, source.requirement != nil {
        throw CoreError.invalidState("well-known sources take no Git requirement")
      }
      try source.requirement?.validate()
      if let path = source.path { _ = try PathSafety.sanitizeSubpath(path) }
    }
    try Declaration.validateNames(Array(skills.keys))
    for skill in skills.values {
      guard let source = sources[skill.source], !skill.installs.isEmpty,
        skill.installs.keys.allSatisfy({ AgentID(rawValue: $0) != nil })
      else {
        throw CoreError.invalidState("skill has unknown source or invalid installs")
      }
      if let path = skill.path { _ = try PathSafety.sanitizeSubpath(path) }
      if skill.installs.values.contains(.edit) {
        guard skill.installs.values.allSatisfy({ $0 == .edit }), source.kind == .local,
          source.requirement == nil, skill.path != nil, skill.revision == nil,
          skill.version == nil, skill.artifact == nil, skill.hash == nil
        else {
          throw CoreError.invalidState("edit installs must be local, unpinned live links")
        }
      } else {
        try validatePin(
          source: source, revision: skill.revision, artifact: skill.artifact, path: skill.path)
        guard let hash = skill.hash else {
          throw CoreError.invalidState("pinned skill needs a content hash")
        }
        try StateValidation.digest(hash)
      }
    }
    for section in instructions.sections + instructions.chatgpt.values.flatMap(\.sections) {
      guard let source = sources[section.source], !section.name.isEmpty else {
        throw CoreError.invalidState("invalid section source or name")
      }
      try validatePin(
        source: source, revision: section.revision, artifact: section.artifact, path: section.path)
      _ = try PathSafety.sanitizeSubpath(section.path)
      try StateValidation.digest(section.hash)
    }
    for prompt in instructions.chatgpt.values {
      if let append = prompt.append { _ = try PathSafety.sanitizeSubpath(append) }
    }
    for (path, target) in instructions.targets {
      _ = try PathSafety.sanitizeSubpath(path.hasPrefix("~/") ? String(path.dropFirst(2)) : path)
      guard target.headingOffset.map({ (0...5).contains($0) }) ?? (target.import != nil) else {
        throw CoreError.invalidState("target needs a heading offset or import")
      }
      try StateValidation.digest(target.blockHash)
    }
  }

  private func validatePin(
    source: LockedSource, revision: String?, artifact: LockedArtifact?, path: String?
  ) throws {
    if source.kind == .wellKnown {
      guard let artifact, revision == nil else {
        throw CoreError.invalidState("well-known item needs an artifact pin")
      }
      try artifact.validate()
    } else {
      guard let revision,
        revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil,
        artifact == nil, path != nil
      else { throw CoreError.invalidState("Git item needs an exact revision and path") }
    }
  }

  package var normalized: ResolvedState {
    var result = self
    for name in result.skills.keys {
      result.skills[name]?.artifact?.files?.sort { $0.path < $1.path }
    }
    for index in result.instructions.sections.indices {
      result.instructions.sections[index].artifact?.files?.sort { $0.path < $1.path }
    }
    for name in result.instructions.chatgpt.keys {
      guard var prompt = result.instructions.chatgpt[name] else { continue }
      for index in prompt.sections.indices {
        prompt.sections[index].artifact?.files?.sort { $0.path < $1.path }
      }
      result.instructions.chatgpt[name] = prompt
    }
    for path in result.instructions.targets.keys {
      result.instructions.targets[path]?.agents.sort { $0.rawValue < $1.rawValue }
    }
    return result
  }
}

package enum StateValidation {
  package static func digest(_ value: String) throws {
    guard value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
      throw CoreError.invalidState("invalid SHA-256 digest: \(value)")
    }
  }

  package static func downloadURL(_ value: String) throws {
    guard let url = URL(string: value), ["http", "https"].contains(url.scheme), url.host != nil
    else {
      throw CoreError.invalidState("invalid artifact URL: \(value)")
    }
  }
}
