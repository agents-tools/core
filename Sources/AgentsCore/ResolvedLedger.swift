import Foundation

/// Version 2 of the scope's single resolved file. Arrays preserve contribution and render order.
package struct ResolvedLedger: Codable, Equatable, Sendable {
  package var version = 2
  package var sources: [String: LedgerSource] = [:]
  package var sourceUses: [LedgerSourceUse] = []
  package var components: [String: LedgerComponent] = [:]
  package var occurrences: [LedgerOccurrence] = []
  package var groups: [LedgerGroup] = []
  package var resources: [String: LedgerResource] = [:]
  package var deployments: [LedgerDeployment] = []
  package var lowerings: [LockedLowering] = []
  /// Digest-keyed non-secret bytes. These are authoritative; materializations are disposable.
  package var contentObjects: [String: Data] = [:]
  package init() {}
}

package struct LedgerSource: Codable, Equatable, Sendable {
  package var kind: SourceKind
  package var transport: String?
  package var location: LedgerLocation?
  package var revision: String
  package var version: String?
  package var container: String?
  package var namespace: String?

  package init(
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

package struct LedgerSourceUse: Codable, Equatable, Sendable {
  package var source: String
  package var root: String
  package var requirement: SourceRequirement?

  package init(source: String, root: String, requirement: SourceRequirement? = nil) {
    self.source = source
    self.root = root
    self.requirement = requirement
  }
}

/// Physical URLs are supplied by the caller. Absolute authored locations retain their meaning.
package struct LedgerLocation: Codable, Equatable, Hashable, Sendable {
  package enum Kind: String, Codable, Sendable { case registered, authoringRelative, absolute }
  package var kind: Kind
  package var root: String?
  package var path: String

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

  package init(kind: Kind, root: String? = nil, path: String) {
    self.kind = kind
    self.root = root
    self.path = path
  }
}

/// A closed tagged value vocabulary, independent of Swift's synthesized enum representation.
package struct LedgerValue: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable {
    case string, integer, decimal, boolean, null, array, object, literal, environment, secret
  }
  package var kind: Kind
  package var text: String?
  package var integer: Int?
  package var boolean: Bool?
  package var array: [LedgerValue]?
  package var object: [String: LedgerValue]?

  package init(_ text: String, kind: Kind = .string) {
    self.kind = kind
    self.text = text
  }
  package init(integer: Int) {
    kind = .integer
    self.integer = integer
  }
  package init(boolean: Bool) {
    kind = .boolean
    self.boolean = boolean
  }
  package init(array: [LedgerValue]) {
    kind = .array
    self.array = array
  }
  package init(object: [String: LedgerValue]) {
    kind = .object
    self.object = object
  }
  package init() { kind = .null }

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

package struct LedgerCondition: Codable, Equatable, Sendable {
  package var agents: [AgentID]?
  package var scopes: [InstallScope]?
  package var platforms: [String]?

  package init(_ condition: DeclarationCondition) {
    agents = condition.agents
    scopes = condition.scopes
    platforms = condition.platforms?.map(\.rawValue)
  }
}

package struct LedgerComponent: Codable, Equatable, Sendable {
  package var declaringSource: String
  package var source: String
  package var root: String
  package var group: String?
  package var kind: String
  package var name: String
  package var revision: String?
  package var version: String?
  package var payload: LedgerValue
  package var conditions: [LedgerCondition]
  package var recipients: [AgentID]
  package var chatGPT: Bool
  package var resources: [String]

  package init(
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

package struct LedgerOccurrence: Codable, Equatable, Sendable {
  package var declaringSource: String
  package var manifestPath: String
  package var id: Int
  package var component: String
  package var reference: Int?
  package var dependencies: [String]
  package var condition: LedgerCondition
  package var recipients: [AgentID]
  package var consumerEditable: Bool

  package init(
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

package struct LedgerGroup: Codable, Equatable, Sendable {
  package var id: Int
  package var parent: Int?
  package var source: String
  package var root: String
  package var name: String
  package var requirement: SourceRequirement?
  package var manifestHash: String
  package var children: [Int]

  package init(
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

package struct LedgerEntry: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case file, directory, symlink }
  package var path: String
  package var kind: Kind
  package var object: String?
  package var link: String?
  package var executable: Bool
  package var byteCount: Int?

  package init(
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

package struct LedgerResource: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case git, artifact, embedded, liveEdit }
  package var kind: Kind
  package var source: String
  package var path: String
  package var hash: String
  /// Single files use path "."; directory entries are relative to the selected resource.
  package var entries: [LedgerEntry]
  package var support: [LedgerEntry]
  package var artifact: LockedArtifact?
  package var location: LedgerLocation?

  package init(
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

package struct LedgerDeployment: Codable, Equatable, Sendable {
  package enum Ownership: String, Codable, Sendable { case generated, importBlock, ownedValues }
  package var id: String
  package var target: LedgerLocation
  package var route: String
  package var owners: [String]
  package var recipients: [AgentID]
  package var ownership: Ownership
  package var expectedHash: String
  package var created: Bool
  package var importReference: String?
  package var headingOffset: Int?

  package init(
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
package struct LockedLowering: Codable, Equatable, Sendable {
  package var id: String
  package var format: String
  package var inputs: [String]
  package var resources: [String]
  package var deployments: [String]
  package var layout: LedgerValue
  package var platform: String
  package var artifacts: [LedgerArtifactDigest]

  package init(
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

package struct LedgerArtifactDigest: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case file, tree, ownedValues, registration, link }
  package var name: String
  package var kind: Kind
  package var hash: String

  package init(name: String, kind: Kind, hash: String) {
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
