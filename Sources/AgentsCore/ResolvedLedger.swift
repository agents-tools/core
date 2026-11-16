import Foundation

/// Version 2 of the scope's single resolved file. Arrays preserve contribution and render order.
public struct ResolvedLedger: Codable, Equatable, Sendable {
  public var version = 2
  public var sources: [String: LedgerSource] = [:]
  public var sourceUses: [LedgerSourceUse] = []
  public var components: [String: LedgerComponent] = [:]
  public var occurrences: [LedgerOccurrence] = []
  public var groups: [LedgerGroup] = []
  public var resources: [String: LedgerResource] = [:]
  public var deployments: [LedgerDeployment] = []
  public var lowerings: [LockedLowering] = []
  /// Digest-keyed non-secret bytes. These are authoritative; materializations are disposable.
  public var contentObjects: [String: Data] = [:]
  public init() {}
}

public struct LedgerSource: Codable, Equatable, Sendable {
  public var kind: SourceKind
  public var transport: String?
  public var location: LedgerLocation?
  public var revision: String
  public var version: String?
  public var container: String?
  public var namespace: String?

  public init(
    kind: SourceKind, transport: String? = nil, location: LedgerLocation? = nil, revision: String,
    version: String? = nil, container: String? = nil, namespace: String? = nil
  ) {
    self.kind = kind
    self.transport = transport
    self.location = location
    self.revision = revision
    self.version = version
    self.container = container
    self.namespace = namespace
  }
}

public struct LedgerSourceUse: Codable, Equatable, Sendable {
  public var source: String
  public var root: String
  public var requirement: SourceRequirement?

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.root == rhs.root
      && ledgerRequirementsEqual(lhs.requirement, rhs.requirement)
  }

  public init(source: String, root: String, requirement: SourceRequirement? = nil) {
    self.source = source
    self.root = root
    self.requirement = requirement
  }
}

/// Physical URLs are supplied by the caller. Absolute authored locations retain their meaning.
public struct LedgerLocation: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case registered, authoringRelative, absolute }
  public var kind: Kind
  public var root: String?
  public var path: String

  package func resolve(roots: [String: URL]) throws -> URL {
    try validate()
    if kind == .absolute { return URL(fileURLWithPath: path) }
    guard let root, let directory = roots[root] else {
      throw CoreError.invalidState("missing registered ledger root")
    }
    if kind == .authoringRelative {
      return directory.appendingPathComponent(path).standardizedFileURL
    }
    return try PathSafety.resolvedChild(base: directory, subpath: path)
  }

  package func validate() throws {
    switch kind {
    case .absolute:
      guard root == nil, path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else {
        throw CoreError.invalidState("invalid absolute ledger location")
      }
    case .authoringRelative:
      guard let root, !root.isEmpty, !path.isEmpty, !path.hasPrefix("/"),
        !path.hasPrefix("~"), !path.contains("\0"), !path.contains("\\"),
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty })
      else {
        throw CoreError.invalidState("invalid authoring-relative location")
      }
    case .registered:
      guard let root, !root.isEmpty else { throw CoreError.invalidState("missing ledger root") }
      try ledgerPath(path)
    }
  }

  public init(kind: Kind, root: String? = nil, path: String) {
    self.kind = kind
    self.root = root
    self.path = path
  }
}

/// A closed tagged value vocabulary, independent of Swift's synthesized enum representation.
public struct LedgerValue: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case string, integer, decimal, boolean, null, array, object, literal, environment, secret
  }
  public var kind: Kind
  public var text: String?
  public var integer: Int?
  public var boolean: Bool?
  public var array: [LedgerValue]?
  public var object: [String: LedgerValue]?

  public init(_ text: String, kind: Kind = .string) {
    self.kind = kind
    self.text = text
  }
  public init(integer: Int) {
    kind = .integer
    self.integer = integer
  }
  public init(boolean: Bool) {
    kind = .boolean
    self.boolean = boolean
  }
  public init(array: [LedgerValue]) {
    kind = .array
    self.array = array
  }
  public init(object: [String: LedgerValue]) {
    kind = .object
    self.object = object
  }
  public init() { kind = .null }

  package func validate() throws {
    let fields = [text != nil, integer != nil, boolean != nil, array != nil, object != nil]
    let expected: Int?
    switch kind {
    case .string, .decimal, .literal, .environment, .secret: expected = 0
    case .integer: expected = 1
    case .boolean: expected = 2
    case .array: expected = 3
    case .object: expected = 4
    case .null: expected = nil
    }
    guard fields.enumerated().allSatisfy({ $0.element == ($0.offset == expected) }) else {
      throw CoreError.invalidState("invalid tagged ledger value")
    }
    for value in array ?? [] { try value.validate() }
    for value in object?.values ?? [String: LedgerValue]().values { try value.validate() }
  }
}

public struct LedgerCondition: Codable, Equatable, Sendable {
  public var agents: [AgentID]?
  public var scopes: [InstallScope]?
  public var platforms: [String]?

  public init(_ condition: DeclarationCondition) {
    agents = condition.agents
    scopes = condition.scopes
    platforms = condition.platforms?.map(\.rawValue)
  }
}

public struct LedgerComponent: Codable, Equatable, Sendable {
  public var declaringSource: String
  public var source: String
  public var root: String
  public var group: String?
  public var kind: String
  public var name: String
  public var revision: String?
  public var version: String?
  public var payload: LedgerValue
  public var conditions: [LedgerCondition]
  public var recipients: [AgentID]
  public var chatGPT: Bool
  public var resources: [String]

  public init(
    declaringSource: String, source: String, root: String, group: String? = nil, kind: String,
    name: String, revision: String? = nil, version: String? = nil, payload: LedgerValue,
    conditions: [LedgerCondition], recipients: [AgentID], chatGPT: Bool, resources: [String]
  ) {
    self.source = source
    self.root = root
    self.declaringSource = declaringSource
    self.group = group
    self.kind = kind
    self.name = name
    self.revision = revision
    self.version = version
    self.payload = payload
    self.conditions = conditions
    self.recipients = recipients
    self.chatGPT = chatGPT
    self.resources = resources
  }
}

public struct LedgerOccurrence: Codable, Equatable, Sendable {
  public var declaringSource: String
  public var manifestPath: String
  public var id: Int
  public var component: String
  public var reference: Int?
  public var dependencies: [String]
  public var condition: LedgerCondition
  public var recipients: [AgentID]
  public var consumerEditable: Bool

  public init(
    declaringSource: String, manifestPath: String, id: Int, component: String,
    reference: Int? = nil, dependencies: [String], condition: LedgerCondition,
    recipients: [AgentID], consumerEditable: Bool
  ) {
    self.id = id
    self.declaringSource = declaringSource
    self.manifestPath = manifestPath
    self.component = component
    self.reference = reference
    self.dependencies = dependencies
    self.condition = condition
    self.recipients = recipients
    self.consumerEditable = consumerEditable
  }
}

public struct LedgerGroup: Codable, Equatable, Sendable {
  public var id: Int
  public var parent: Int?
  public var source: String
  public var root: String
  public var name: String
  public var requirement: SourceRequirement?
  public var manifestHash: String
  public var children: [Int]

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.parent == rhs.parent && lhs.source == rhs.source && lhs.root == rhs.root
      && lhs.name == rhs.name && lhs.manifestHash == rhs.manifestHash
      && lhs.children == rhs.children && ledgerRequirementsEqual(lhs.requirement, rhs.requirement)
  }

  public init(
    id: Int, parent: Int? = nil, source: String, root: String, name: String,
    requirement: SourceRequirement? = nil, manifestHash: String, children: [Int]
  ) {
    self.id = id
    self.parent = parent
    self.source = source
    self.root = root
    self.name = name
    self.requirement = requirement
    self.manifestHash = manifestHash
    self.children = children
  }
}

public struct LedgerEntry: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case file, directory, symlink }
  public var path: String
  public var kind: Kind
  public var object: String?
  public var link: String?
  public var executable: Bool
  public var byteCount: Int?

  public init(
    path: String, kind: Kind, object: String? = nil, link: String? = nil, executable: Bool,
    byteCount: Int? = nil
  ) {
    self.path = path
    self.kind = kind
    self.object = object
    self.link = link
    self.executable = executable
    self.byteCount = byteCount
  }
}

public struct LedgerResource: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case git, artifact, embedded, liveEdit }
  public var kind: Kind
  public var source: String
  public var path: String
  public var hash: String
  /// Single files use path "."; directory entries are relative to the selected resource.
  public var entries: [LedgerEntry]
  public var support: [LedgerEntry]
  public var artifact: LockedArtifact?
  public var location: LedgerLocation?

  public init(
    kind: Kind, source: String, path: String, hash: String, entries: [LedgerEntry],
    support: [LedgerEntry] = [], artifact: LockedArtifact? = nil, location: LedgerLocation? = nil
  ) {
    self.kind = kind
    self.source = source
    self.path = path
    self.hash = hash
    self.entries = entries
    self.support = support
    self.artifact = artifact
    self.location = location
  }
}

public struct LedgerDeployment: Codable, Equatable, Sendable {
  public enum Ownership: String, Codable, Sendable { case generated, importBlock, ownedValues }
  public var id: String
  public var target: LedgerLocation
  public var route: String
  public var owners: [String]
  public var recipients: [AgentID]
  public var ownership: Ownership
  public var expectedHash: String
  public var created: Bool
  public var importReference: String?
  public var headingOffset: Int?

  public init(
    id: String, target: LedgerLocation, route: String, owners: [String], recipients: [AgentID],
    ownership: Ownership, expectedHash: String, created: Bool, importReference: String? = nil,
    headingOffset: Int? = nil
  ) {
    self.id = id
    self.target = target
    self.route = route
    self.owners = owners
    self.recipients = recipients
    self.ownership = ownership
    self.expectedHash = expectedHash
    self.created = created
    self.importReference = importReference
    self.headingOffset = headingOffset
  }
}

/// Format identity fixes schema, ordering, paths, resource mappings and serialization semantics.
public struct LockedLowering: Codable, Equatable, Sendable {
  public var id: String
  public var format: String
  public var inputs: [String]
  public var resources: [String]
  public var deployments: [String]
  public var layout: LedgerValue
  public var platform: String
  public var artifacts: [LedgerArtifactDigest]

  public init(
    id: String, format: String, inputs: [String], resources: [String], deployments: [String],
    layout: LedgerValue, platform: String, artifacts: [LedgerArtifactDigest]
  ) {
    self.id = id
    self.format = format
    self.inputs = inputs
    self.resources = resources
    self.deployments = deployments
    self.layout = layout
    self.platform = platform
    self.artifacts = artifacts
  }
}

public struct LedgerArtifactDigest: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case file, tree, ownedValues, registration, link }
  public var name: String
  public var kind: Kind
  public var hash: String

  public init(name: String, kind: Kind, hash: String) {
    self.name = name
    self.kind = kind
    self.hash = hash
  }
}

package func ledgerPath(_ path: String) throws {
  guard !path.hasPrefix("/"), !path.hasPrefix("~"),
    try PathSafety.sanitizeSubpath(path) == path
  else {
    throw CoreError.invalidState("noncanonical ledger path")
  }
}

private func ledgerRequirementsEqual(_ lhs: SourceRequirement?, _ rhs: SourceRequirement?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil): true
  case (.some(let left), .some(let right)): left == right || left.declarationEquivalent(to: right)
  default: false
  }
}
