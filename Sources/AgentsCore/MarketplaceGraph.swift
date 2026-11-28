import Foundation

/// A dependency authored in a portable bundle. An omitted catalog means the publishing catalog.
public struct MarketplacePackageRequirement: Codable, Equatable, Sendable {
  public let package: String
  public let requirement: SourceRequirement
  public let catalog: MarketplaceOrigin?

  public init(package: String, requirement: SourceRequirement, catalog: MarketplaceOrigin? = nil)
    throws
  {
    self.package = package
    self.requirement = try requirement.canonicalized()
    self.catalog = catalog
    try validate()
  }

  package func validate() throws {
    guard MarketplaceCoordinate.isName(package) else {
      throw MarketplaceError.invalidPackage(package)
    }
    try requirement.validateMarketplaceVersion()
    try catalog?.validatePortable()
  }

  package static func validate(_ dependencies: [Self]) throws {
    guard dependencies.count <= MarketplaceGraph.maximumEdgesPerNode else {
      throw MarketplaceError.resolutionLimit("dependencies per release")
    }
    for dependency in dependencies { try dependency.validate() }
  }
}

/// A package-local member identity that can survive content and provenance changes.
public struct MarketplaceMemberKey: Codable, Equatable, Hashable, Sendable {
  public let kind: DeclaredComponentKind
  public let name: String

  public init(kind: DeclaredComponentKind, name: String) {
    self.kind = kind
    self.name = name
  }

  package func validate() throws {
    guard [.skills, .instructions, .mcpServer].contains(kind), !name.isEmpty,
      name.utf8.count <= 1024, !name.utf8.contains(0)
    else { throw MarketplaceError.invalidPackage("invalid member: " + name) }
  }
}

/// One root's recipients for one logical member of a reachable package. An omitted catalog
/// selects a package in the root's catalog. An explicit catalog uses its portable catalog identity.
public struct MarketplaceMemberSelection: Codable, Equatable, Sendable {
  public let package: String
  public let catalog: MarketplaceOrigin?
  public let member: MarketplaceMemberKey
  public let targets: [AgentID]

  public init(
    package: String, catalog: MarketplaceOrigin? = nil, member: MarketplaceMemberKey,
    targets: [AgentID]
  ) throws {
    self.package = package
    self.catalog = catalog
    self.member = member
    self.targets = targets.sorted { $0.rawValue < $1.rawValue }
    try validate()
  }

  package func validate() throws {
    guard MarketplaceCoordinate.isName(package), !targets.isEmpty,
      targets.count == Set(targets).count
    else { throw MarketplaceError.selectionMismatch(package + " / " + member.name) }
    try member.validate()
    try catalog?.validatePortable()
  }
}

/// Authored root intent. The catalog locator is supplied by the caller after registration lookup.
public struct MarketplaceRoot: Codable, Equatable, Sendable {
  public let name: String
  public let catalog: MarketplaceOrigin
  public let package: String
  public let requirement: SourceRequirement
  public let selections: [MarketplaceMemberSelection]

  public init(
    name: String, catalog: MarketplaceOrigin, package: String, requirement: SourceRequirement,
    selections: [MarketplaceMemberSelection] = []
  ) throws {
    self.name = name
    self.catalog = catalog
    self.package = package
    self.requirement = try requirement.canonicalized()
    self.selections = selections
    try validate()
  }

  package func validate() throws {
    guard MarketplaceCoordinate.isName(name), MarketplaceCoordinate.isName(package),
      selections.count <= MarketplaceGraph.maximumSelectionsPerRoot
    else { throw MarketplaceError.invalidPackage(name) }
    try catalog.validate()
    try requirement.validateMarketplaceVersion()
    for selection in selections { try selection.validate() }
  }
}

/// Canonical catalog identity, independent of discovery ref and Git transport spelling.
public struct MarketplaceCatalogID: Codable, Equatable, Hashable, Sendable {
  public let kind: MarketplaceOrigin.Kind
  public let origin: SourceOrigin
  public let subpath: String?
  public let hostedIndex: URL?

  package var policyPath: String? {
    hostedIndex.map { String($0.path.dropFirst()) } ?? subpath
  }

  package init(_ catalog: MarketplaceOrigin, origin: SourceOrigin) {
    kind = catalog.kind
    self.origin = origin
    subpath = catalog.subpath
    hostedIndex = catalog.hostedIndex
  }

  package var sortKey: [String] {
    [kind.rawValue, origin.description, policyPath ?? ""]
  }
}

/// One version can be selected for each catalog and package pair in a consumer scope.
public struct MarketplaceNodeID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  public let catalog: MarketplaceCatalogID
  public let package: String

  public var description: String {
    catalog.origin.description + (catalog.policyPath.map { " / " + $0 } ?? "") + " / " + package
  }

  package init(catalog: MarketplaceCatalogID, package: String) {
    self.catalog = catalog
    self.package = package
  }

  package static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
    (lhs.catalog.sortKey + [lhs.package]).lexicographicallyPrecedes(
      rhs.catalog.sortKey + [rhs.package])
  }
}

public struct MarketplaceResolvedEdge: Codable, Equatable, Sendable {
  public let requirement: MarketplacePackageRequirement
  public let target: MarketplaceNodeID

  package init(requirement: MarketplacePackageRequirement, target: MarketplaceNodeID) {
    self.requirement = requirement
    self.target = target
  }
}

public struct MarketplaceResolvedRoot: Codable, Equatable, Sendable {
  public let intent: MarketplaceRoot
  public let node: MarketplaceNodeID

  package init(intent: MarketplaceRoot, node: MarketplaceNodeID) {
    self.intent = intent
    self.node = node
  }
}

public struct MarketplaceResolvedMember: Codable, Equatable, Sendable {
  public let key: MarketplaceMemberKey
  public let componentID: String
  public let sourceAlias: String
  /// Embedded seal and producer tree for catalog-free recovery and subsequent reconciliation.
  public package(set) var producerResource: String?
  /// Effective recipients, unioned over all requesting roots.
  public let targets: [AgentID]

  package init(
    key: MarketplaceMemberKey, componentID: String, sourceAlias: String, targets: [AgentID],
    producerResource: String? = nil
  ) {
    self.key = key
    self.componentID = componentID
    self.sourceAlias = sourceAlias
    self.producerResource = producerResource
    self.targets = targets
  }
}

/// A verified immutable release plus its selected component contributions.
public struct MarketplaceResolvedNode: Codable, Equatable, Sendable {
  public let id: MarketplaceNodeID
  public let catalog: MarketplaceOrigin
  public let coordinate: MarketplaceCoordinate
  public let archiveDigest: String
  public let catalogCommit: String?
  public package(set) var hostedEvidence: HostedMarketplaceEvidence?
  public let dependencies: [MarketplaceResolvedEdge]
  /// A recorded version override still needs matching trusted policy before restore or publication.
  package var organizationRequirements: [SourceRequirement]?
  public package(set) var members: [MarketplaceResolvedMember]
  public package(set) var componentRecords: [String]
  package var contributionDigest: String

  package init(
    id: MarketplaceNodeID, catalog: MarketplaceOrigin, coordinate: MarketplaceCoordinate,
    archiveDigest: String, catalogCommit: String?, dependencies: [MarketplaceResolvedEdge],
    members: [MarketplaceResolvedMember] = [], componentRecords: [String] = [],
    contributionDigest: String = "", organizationRequirements: [SourceRequirement]? = nil,
    hostedEvidence: HostedMarketplaceEvidence? = nil
  ) {
    self.id = id
    self.catalog = catalog
    self.coordinate = coordinate
    self.archiveDigest = archiveDigest
    self.catalogCommit = catalogCommit
    self.hostedEvidence = hostedEvidence
    self.dependencies = dependencies
    self.organizationRequirements = organizationRequirements
    self.members = members
    self.componentRecords = componentRecords
    self.contributionDigest = contributionDigest
  }

  package var sourceAliases: [String] { members.map(\.sourceAlias) }

  package static let sourceAliasPrefix = "marketplace-"
}

/// One admitted graph. Edges preserve each incoming constraint, and roots own recipient intent.
public struct MarketplaceGraph: Codable, Equatable, Sendable {
  public let roots: [MarketplaceResolvedRoot]
  public package(set) var nodes: [MarketplaceResolvedNode]

  package static let maximumNodes = 256
  package static let maximumDepth = 64
  package static let maximumEdgesPerNode = 64
  package static let maximumSelectionsPerRoot = 1024
  private static let maximumSelections = 4096
  package static let maximumEdges = 2048

  package init(roots: [MarketplaceResolvedRoot], nodes: [MarketplaceResolvedNode]) {
    self.roots = roots
    self.nodes = nodes
  }

  /// All roots that require a node, irrespective of which roots enable its components.
  public func rootsRequiring(_ node: MarketplaceNodeID) -> [String] {
    let edges = Dictionary(
      nodes.map { ($0.id, $0.dependencies.map(\.target)) },
      uniquingKeysWith: { first, _ in first })
    return roots.filter { Self.reachable(from: $0.node, edges: edges).contains(node) }
      .map(\.intent.name)
  }

  /// Immediate parents and their constraints. Together with roots and outgoing edges, this
  /// describes every reason for a node without expanding exponentially many paths.
  public func incoming(to node: MarketplaceNodeID) -> [MarketplaceIncomingRequirement] {
    nodes.flatMap { parent in
      parent.dependencies.filter { $0.target == node }.map {
        MarketplaceIncomingRequirement(parent: parent.id, requirement: $0.requirement)
      }
    }
  }

  /// Recipients attributed to each root for one member in an admitted graph.
  public func recipientsByRoot(
    for member: MarketplaceMemberKey, in node: MarketplaceNodeID
  ) -> [String: [AgentID]] {
    var result: [String: [AgentID]] = [:]
    for root in roots {
      for selection in root.intent.selections
      where selection.member == member && (try? Self.node(for: selection, from: root)) == node {
        result[root.intent.name] = selection.targets
      }
    }
    return result
  }

  /// Longest known path to each node. Equal-length paths retain authored root/edge order.
  /// The solver also calls this on partial DAGs before observing any next node.
  package func policyPaths() -> [MarketplaceNodeID: [MarketplaceNodeID]] {
    let edges = Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.id, $0.dependencies.map(\.target)) })
    var paths: [MarketplaceNodeID: [MarketplaceNodeID]] = [:]
    var pending = roots.reversed().map { [$0.node] }
    while let path = pending.popLast() {
      guard let last = path.last, path.count > (paths[last]?.count ?? 0),
        path.count <= Self.maximumNodes
      else { continue }
      paths[last] = path
      for child in (edges[last] ?? []).reversed() where !path.contains(child) {
        pending.append(path + [child])
      }
    }
    return paths
  }

  package func reachable(from node: MarketplaceNodeID) -> Set<MarketplaceNodeID> {
    Self.reachable(
      from: node,
      edges: Dictionary(
        uniqueKeysWithValues:
          nodes.map { ($0.id, $0.dependencies.map(\.target)) }))
  }

  private static func reachable(
    from node: MarketplaceNodeID, edges: [MarketplaceNodeID: [MarketplaceNodeID]]
  ) -> Set<MarketplaceNodeID> {
    var seen = Set<MarketplaceNodeID>()
    var pending = [node]
    while let current = pending.popLast() {
      if seen.insert(current).inserted { pending += edges[current] ?? [] }
    }
    return seen
  }

  package func selectedTargets() throws -> [MarketplaceNodeID: [MarketplaceMemberKey: Set<AgentID>]]
  {
    guard roots.count <= Self.maximumNodes,
      roots.reduce(0, { $0 + $1.intent.selections.count }) <= Self.maximumSelections
    else { throw MarketplaceError.resolutionLimit("root selections") }
    let edges = Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.id, $0.dependencies.map(\.target)) })
    var targets: [MarketplaceNodeID: [MarketplaceMemberKey: Set<AgentID>]] = [:]
    for root in roots {
      let reachable = Self.reachable(from: root.node, edges: edges)
      var selected: [MarketplaceNodeID: Set<MarketplaceMemberKey>] = [:]
      for selection in root.intent.selections {
        let id = try Self.node(for: selection, from: root)
        guard reachable.contains(id), selected[id, default: []].insert(selection.member).inserted
        else {
          throw MarketplaceError.selectionMismatch(root.intent.name + " / " + selection.member.name)
        }
        targets[id, default: [:]][selection.member, default: []].formUnion(selection.targets)
      }
    }
    return targets
  }

  private static func node(
    for selection: MarketplaceMemberSelection, from root: MarketplaceResolvedRoot
  ) throws -> MarketplaceNodeID {
    let catalog: MarketplaceCatalogID
    if let explicit = selection.catalog {
      catalog = try MarketplaceCatalogID(explicit, origin: explicit.remotePolicyOrigin())
    } else {
      catalog = root.node.catalog
    }
    return MarketplaceNodeID(catalog: catalog, package: selection.package)
  }

  package func validate(
    components: [String: LedgerComponent], resources: [String: LedgerResource],
    objects: [String: Data], aliases: inout Set<String>
  ) throws {
    guard !roots.isEmpty, roots.count <= Self.maximumNodes, nodes.count <= Self.maximumNodes,
      nodes.reduce(0, { $0 + $1.dependencies.count }) <= Self.maximumEdges,
      Set(roots.map(\.intent.name)).count == roots.count,
      Set(nodes.map(\.id)).count == nodes.count
    else { throw MarketplaceError.invalidPackage("invalid frozen graph") }
    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let targets = try selectedTargets()
    var refs: [MarketplaceCatalogID: MarketplaceOrigin] = [:]
    for node in nodes {
      try node.catalog.validate()
      try node.coordinate.validate()
      try StateValidation.digest(node.archiveDigest)
      try StateValidation.digest(node.contributionDigest)
      try validate(node.id, catalog: node.catalog)
      guard node.coordinate.package == node.id.package,
        (node.catalog.kind == .git) == (node.catalogCommit != nil),
        node.catalogCommit.map(SourceCache.isObjectID) ?? true,
        node.componentRecords == Array(Set(node.componentRecords)).sorted(),
        node.componentRecords.allSatisfy({ components[$0] != nil }),
        node.members.isEmpty == node.componentRecords.isEmpty,
        Set(node.members.map(\.key)).count == node.members.count,
        node.members.count == (targets[node.id]?.count ?? 0)
      else { throw MarketplaceError.contributionMismatch(node.id.description) }
      if let hosted = node.hostedEvidence {
        guard node.catalog.kind == .hosted,
          objects[node.archiveDigest]?.count == hosted.archiveByteCount
        else { throw MarketplaceError.integrityMismatch(node.coordinate.label) }
        try hosted.validate(index: node.catalog.location)
      } else if node.catalog.kind == .hosted {
        throw MarketplaceError.integrityMismatch(node.coordinate.label)
      }
      if let other = refs[node.id.catalog], other.ref != node.catalog.ref {
        throw MarketplaceError.originConflict(node.id.description)
      }
      refs[node.id.catalog] = node.catalog
      let sources = Set(node.componentRecords.compactMap { components[$0]?.declaringSource })
      for member in node.members {
        try member.key.validate()
        try StateValidation.digest(member.componentID)
        guard let selected = targets[node.id]?[member.key],
          member.targets == selected.sorted(by: { $0.rawValue < $1.rawValue }),
          let id = member.producerResource, let resource = resources[id],
          resource.kind == .embedded, resource.path == ".",
          try ResolvedLedgerCodec.digest(resource) == id,
          sources.contains(resource.source),
          member.sourceAlias.hasPrefix(MarketplaceResolvedNode.sourceAliasPrefix),
          aliases.insert(member.sourceAlias).inserted
        else { throw MarketplaceError.contributionMismatch(node.id.description) }
        try StateValidation.digest(
          "sha256:" + member.sourceAlias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count))
      }
      if let overrides = node.organizationRequirements {
        guard !overrides.isEmpty, overrides.count <= LedgerLimits.standard.entries else {
          throw MarketplaceError.invalidPackage("invalid organization version override")
        }
        for requirement in overrides {
          try requirement.validateMarketplaceVersion()
          guard requirement.admitsMarketplaceVersion(node.coordinate.version) else {
            throw MarketplaceError.contributionMismatch(node.id.description)
          }
        }
      }
      try MarketplacePackageRequirement.validate(node.dependencies.map(\.requirement))
      for edge in node.dependencies {
        var catalog = node.id.catalog
        if let portable = edge.requirement.catalog {
          catalog = try MarketplaceCatalogID(portable, origin: portable.remotePolicyOrigin())
          guard byID[edge.target]?.catalog.ref == portable.ref else {
            throw MarketplaceError.originConflict(edge.target.description)
          }
        }
        guard edge.target == MarketplaceNodeID(catalog: catalog, package: edge.requirement.package),
          let target = byID[edge.target],
          target.organizationRequirements != nil
            || edge.requirement.requirement.admitsMarketplaceVersion(target.coordinate.version)
        else { throw MarketplaceError.contributionMismatch(node.id.description) }
      }
    }
    var heights: [MarketplaceNodeID: Int] = [:]
    var visiting = Set<MarketplaceNodeID>()
    func visit(_ id: MarketplaceNodeID, depth: Int) throws -> Int {
      if let height = heights[id] { return height }
      guard depth < Self.maximumDepth else { throw MarketplaceError.resolutionLimit("graph depth") }
      guard visiting.insert(id).inserted else {
        throw MarketplaceError.dependencyCycle(id.description)
      }
      guard let node = byID[id] else { throw MarketplaceError.missingPin(id.description) }
      let height =
        try 1 + (node.dependencies.map { try visit($0.target, depth: depth + 1) }.max() ?? 0)
      visiting.remove(id)
      heights[id] = height
      return height
    }
    for root in roots {
      try root.intent.validate()
      try validate(root.node, catalog: root.intent.catalog)
      guard let node = byID[root.node], node.catalog.ref == root.intent.catalog.ref,
        root.node.package == root.intent.package,
        node.organizationRequirements != nil
          || root.intent.requirement.admitsMarketplaceVersion(node.coordinate.version),
        try visit(root.node, depth: 0) <= Self.maximumDepth
      else { throw MarketplaceError.selectionMismatch(root.intent.name) }
    }
    guard heights.count == nodes.count else {
      throw MarketplaceError.invalidPackage("unreachable frozen package")
    }
  }

  private func validate(_ node: MarketplaceNodeID, catalog: MarketplaceOrigin) throws {
    guard catalog.kind == node.catalog.kind, catalog.subpath == node.catalog.subpath,
      catalog.hostedIndex == node.catalog.hostedIndex
    else {
      throw MarketplaceError.originConflict(node.description)
    }
    if catalog.isLocal {
      guard node.catalog.origin.kind == .local, node.catalog.origin.identity != nil else {
        throw MarketplaceError.originConflict(node.description)
      }
    } else if try node.catalog.origin != catalog.remotePolicyOrigin() {
      throw MarketplaceError.originConflict(node.description)
    }
  }
}

public struct MarketplaceIncomingRequirement: Equatable, Sendable {
  public let parent: MarketplaceNodeID
  public let requirement: MarketplacePackageRequirement
}
