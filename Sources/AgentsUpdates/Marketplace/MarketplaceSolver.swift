import AgentsCore
import AgentsManifest
import Foundation

struct MarketplaceSolution {
  let graph: MarketplaceGraph
  let bundles: [MarketplaceNodeID: BundleInspection]
  let versions: [MarketplaceNodeVersions]
  let observationDigest: String
  var directoryInputs: [MarketplaceCatalogInput] = []
  var promotedLegacy: Set<String> = []
  var hostedArchives: [String: Data] = [:]
}

/// Deterministic backtracking over candidate-specific constraints. Catalog handles and verified
/// archives are reused across branches, including branches failing before composition.
final class MarketplaceSolver {
  private struct CatalogNeeded: Error {
    let id: MarketplaceCatalogID
    let origin: MarketplaceOrigin
  }

  private struct Demand {
    let requirement: SourceRequirement
    let path: [MarketplaceNodeID]
    let root: String
    let updating: Bool

    var description: String {
      ([root] + path.map(\.package)).joined(separator: " → ")
        + " (" + requirement.marketplaceDescription + ")"
    }
  }

  private struct Choice {
    let node: MarketplaceResolvedNode
    let release: MarketplaceRelease?
  }

  private struct ObservedRelease: Encodable {
    let coordinate: MarketplaceCoordinate
    let digest: String
    let bytes: Int
    let summary: String?
    let commit: String?
  }

  private struct Observation: Encodable {
    let id: MarketplaceCatalogID
    let origin: MarketplaceOrigin
    let commit: String?
    let releases: [ObservedRelease]
  }

  private let store: StateStore
  private let policy: SourcePolicySnapshot
  private let organizationPolicy: OrganizationPolicySnapshot
  private let preferred: [MarketplaceNodeID: MarketplaceResolvedNode]
  private let updatingRoot: String?
  private let legacy: [MarketplaceNodeID: [MarketplaceLegacyRoot]]
  private let declaration: Declaration
  private let previous: ResolvedLedger
  private let hostedAccess: HostedMarketplaceAccess?
  private var hostedTrust: (origins: Set<MarketplaceOrigin>, evidence: TargetPrecondition)?
  private var hostedPackages: [MarketplaceReleaseKey: VerifiedMarketplacePackage] = [:]

  private struct MarketplaceReleaseKey: Hashable {
    let node: MarketplaceNodeID
    let version: String
  }
  private var observations: [MarketplaceCatalogID: ObservedMarketplaceCatalog] = [:]
  private var observedOrigins: [MarketplaceCatalogID: MarketplaceOrigin] = [:]
  private var bundles: [MarketplaceNodeID: [String: BundleInspection]] = [:]
  private var packageCandidates: [MarketplaceNodeID: [MarketplaceRelease]] = [:]
  private var archivedBytes = 0
  private var releaseCount = 0
  private var attempts = 0

  private static let maximumCatalogs = 32
  static let maximumMetadataReleases = 4096
  private static let maximumAttempts = 8192

  init(
    store: StateStore, policy: SourcePolicySnapshot, organizationPolicy: OrganizationPolicySnapshot,
    declaration: Declaration,
    previous: ResolvedLedger, updatingRoot: String?, hostedAccess: HostedMarketplaceAccess?
  ) throws {
    self.store = store
    self.policy = policy
    self.organizationPolicy = organizationPolicy
    self.declaration = declaration
    self.previous = previous
    self.hostedAccess = hostedAccess
    preferred = Dictionary(
      uniqueKeysWithValues: (previous.marketplaceGraph?.nodes ?? []).map {
        ($0.id, $0)
      })
    self.updatingRoot = updatingRoot
    legacy = Dictionary(
      grouping: try (previous.marketplacePackages ?? []).map {
        try MarketplaceLegacyRoot($0, store: store)
      },
      by: \.id)
  }

  func solve(_ intents: [MarketplaceRoot], previous: MarketplaceGraph?) throws
    -> MarketplaceSolution
  {
    guard intents.count <= MarketplaceGraph.maximumNodes else {
      throw MarketplaceError.resolutionLimit("root count")
    }
    let oldRoots = Dictionary(
      uniqueKeysWithValues: (previous?.roots ?? []).map {
        ($0.intent.name, ($0.node, $0.intent.catalog.ref))
      }
        + legacy.values.flatMap { $0.map { ($0.name, ($0.id, $0.pin.dependency.catalog.ref)) } })
    let roots = try intents.map { root in
      try root.validate()
      let id = try identifier(package: root.package, from: root.catalog)
      if let (previousID, ref) = oldRoots[root.name], previousID != id || ref != root.catalog.ref {
        throw MarketplaceError.originConflict(root.name)
      }
      return MarketplaceResolvedRoot(intent: root, node: id)
    }
    var locators: [MarketplaceCatalogID: MarketplaceOrigin] = [:]
    var demands: [MarketplaceNodeID: [Demand]] = [:]
    for root in roots {
      try bind(root.intent.catalog, id: root.node.catalog, in: &locators)
      demands[root.node, default: []].append(
        Demand(
          requirement: root.intent.requirement, path: [root.node], root: root.intent.name,
          updating: root.intent.name == updatingRoot))
    }
    return try observing {
      let choices = try search(roots: roots, demands: demands, locators: locators, choices: [:])
      let promoted = promotedRoots(for: Set(choices.keys))
      let roots = try includingLegacy(in: roots, promoted: promoted)
      let ordered = choices.keys.sorted(by: MarketplaceNodeID.ordered)
      var selectedBundles: [MarketplaceNodeID: BundleInspection] = [:]
      var hostedArchives: [String: Data] = [:]
      for id in ordered {
        let choice = choices[id]!
        if let release = choice.release {
          selectedBundles[id] = try bundle(for: release, id: id)
        }
        if choice.node.hostedEvidence != nil {
          let key = MarketplaceReleaseKey(node: id, version: choice.node.coordinate.version)
          guard
            let bytes = hostedPackages[key]?.archive
              ?? self.previous.contentObjects[choice.node.archiveDigest]
          else { throw MarketplaceError.integrityMismatch(choice.node.coordinate.label) }
          hostedArchives[choice.node.archiveDigest] = bytes
          if selectedBundles[id] == nil {
            selectedBundles[id] = try BundleOperations.inspect(bytes)
          }
        }
      }
      try hostedTrust?.evidence.validate()
      let graph = MarketplaceGraph(roots: roots, nodes: ordered.map { choices[$0]!.node })
      let versions = ordered.map { id in
        MarketplaceNodeVersions(
          node: id,
          locked: preferred[id]?.coordinate ?? legacy[id]?.first?.pin.dependency.coordinate,
          eligible: choices[id]!.node.coordinate,
          latest: packageCandidates[id]?.first?.coordinate)
      }
      let observed = observations.keys.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
      let evidence = observed.map { id in
        let catalog = observations[id]!
        return Observation(
          id: id, origin: observedOrigins[id]!, commit: catalog.commit,
          releases: catalog.releases.map {
            ObservedRelease(
              coordinate: $0.coordinate, digest: $0.archiveDigest, bytes: $0.archiveByteCount,
              summary: $0.summary, commit: $0.catalogCommit)
          })
      }
      let directories = observed.filter { $0.kind == .directory }.map { id in
        let releases = observations[id]!.releases
        return MarketplaceCatalogInput(
          origin: observedOrigins[id]!, source: id.origin, releases: releases,
          archives: Set(
            releases.compactMap { release in
              let node = MarketplaceNodeID(catalog: id, package: release.coordinate.package)
              return bundles[node]?[release.coordinate.version] == nil ? nil : release.coordinate
            }))
      }
      try policy.validate()
      try organizationPolicy.validate()
      return MarketplaceSolution(
        graph: graph, bundles: selectedBundles, versions: versions,
        observationDigest: try ResolvedLedgerCodec.digest(evidence), directoryInputs: directories,
        promotedLegacy: Set(promoted.map(\.name)), hostedArchives: hostedArchives)
    }
  }

  private func observing<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let needed as CatalogNeeded {
      guard observations.count < Self.maximumCatalogs else {
        throw MarketplaceError.resolutionLimit("catalog count")
      }
      return try MarketplaceOperations.withObservedCatalog(
        needed.origin, scope: store.scope, environment: catalogEnvironment,
        maximumReleases: Self.maximumMetadataReleases - releaseCount,
        expectedOrigin: needed.id.origin,
        requireRecordedTransport: organizationPolicy.evaluator.requiresRecordedGitOrigin,
        hostedAccess: hostedAccess, organizationPolicy: organizationPolicy,
        trustedRegistration: hostedTrust?.evidence
      ) { observation in
        releaseCount += observation.releases.count
        observations[needed.id] = observation
        observedOrigins[needed.id] = needed.origin
        for (package, releases) in Dictionary(
          grouping: observation.releases,
          by: {
            $0.coordinate.package
          })
        {
          packageCandidates[MarketplaceNodeID(catalog: needed.id, package: package)] = releases
        }
        return try observing(body)
      }
    }
  }

  private func search(
    roots: [MarketplaceResolvedRoot], demands: [MarketplaceNodeID: [Demand]],
    locators: [MarketplaceCatalogID: MarketplaceOrigin], choices: [MarketplaceNodeID: Choice]
  ) throws -> [MarketplaceNodeID: Choice] {
    try Task.checkCancellation()
    guard demands.count <= MarketplaceGraph.maximumNodes else {
      throw MarketplaceError.resolutionLimit("node count")
    }
    guard
      let id = demands.keys.filter({ choices[$0] == nil }).sorted(by: {
        let left = demands[$0]!.contains(where: \.updating)
        let right = demands[$1]!.contains(where: \.updating)
        return left == right ? MarketplaceNodeID.ordered($0, $1) : left
      }).first
    else {
      try validateBranch(roots: roots, choices: choices)
      try admitOrganizationPaths(roots: roots, choices: choices)
      return choices
    }
    let evaluator = organizationPolicy.evaluator
    try admitOrganizationPaths(roots: roots, choices: choices)
    let origin = locators[id.catalog]!
    guard observations[id.catalog] != nil else {
      throw CatalogNeeded(id: id.catalog, origin: origin)
    }
    guard observedOrigins[id.catalog]?.ref == origin.ref else {
      throw MarketplaceError.originConflict(id.description)
    }

    let priorExact = legacy[id] ?? []
    let rootNames = Set(roots.map(\.intent.name))
    let incoming =
      demands[id]!
      + priorExact.filter { !rootNames.contains($0.name) }.map {
        Demand(
          requirement: .exact($0.pin.dependency.coordinate.version), path: [id],
          root: $0.name, updating: false)
      }
    for leaf in priorExact where leaf.pin.dependency.catalog.ref != origin.ref {
      throw MarketplaceError.originConflict(leaf.name)
    }
    let locked = preferred[id]
    let published = packageCandidates[id] ?? []
    for leaf in priorExact {
      if let release = published.first(where: { $0.coordinate == leaf.pin.dependency.coordinate }),
        release.archiveDigest != leaf.pin.archiveDigest
      {
        throw MarketplaceError.integrityMismatch(release.coordinate.label)
      }
    }
    let current = published.first { $0.coordinate == locked?.coordinate }
    if let current, current.archiveDigest != locked?.archiveDigest {
      throw MarketplaceError.integrityMismatch(current.coordinate.label)
    }
    let updating = incoming.contains(where: \.updating)
    let fixed = updatingRoot != nil && !updating && locked != nil
    let required = evaluator.marketplaceRequirements(for: id)
    let authored = incoming.map(\.requirement)
    let constraints = (required.overrides ? [] : authored) + required.constraints
    func satisfies(_ version: String) -> Bool {
      constraints.allSatisfy { $0.admitsMarketplaceVersion(version) }
    }
    func recordingOverride(_ node: MarketplaceResolvedNode) -> MarketplaceResolvedNode {
      var node = node
      node.organizationRequirements = required.overrides ? required.constraints : nil
      return node
    }

    let lockedChoice = locked.flatMap { node in
      satisfies(node.coordinate.version)
        ? Choice(node: recordingOverride(node), release: node.hostedEvidence == nil ? current : nil)
        : nil
    }
    let releases =
      fixed
      ? []
      : published.filter {
        $0.coordinate != locked?.coordinate && satisfies($0.coordinate.version)
      }
    var options: [(choice: Choice?, release: MarketplaceRelease?)] = []
    if let lockedChoice, !updating { options.append((lockedChoice, nil)) }
    options += releases.map { (nil, $0) }
    if let lockedChoice, updating {
      let position =
        options.firstIndex {
          !MarketplaceCoordinate.newer($0.release!.coordinate, than: lockedChoice.node.coordinate)
        } ?? options.endIndex
      options.insert((lockedChoice, nil), at: position)
    }
    let conflict = MarketplaceError.unsatisfiable(
      id.description + ": " + incoming.map(\.description).joined(separator: "; "))
    if options.isEmpty && !required.constraints.isEmpty {
      try organizationPolicy.admit(
        evaluator.version(
          nil, identity: .init(id), authored: authored, available: false,
          path: incoming[0].path.map { OrganizationPolicyIdentity($0).description }))
    }
    var failure: any Error = conflict
    for option in options {
      attempts += 1
      guard attempts <= Self.maximumAttempts else {
        throw MarketplaceError.resolutionLimit("candidate attempts")
      }
      do {
        var nextLocators = locators
        let choice: Choice
        if let locked = option.choice {
          choice = locked
          for edge in locked.node.dependencies {
            let edgeOrigin = edge.requirement.catalog ?? origin
            if edgeOrigin != origin { try requireTrustedHostedCatalog(edgeOrigin) }
            try bind(edgeOrigin, id: edge.target.catalog, in: &nextLocators)
          }
        } else {
          let release = option.release!
          let archive = try bundle(for: release, id: id)
          let edges = try (archive.package.dependencies ?? []).map { requirement in
            let edgeOrigin = requirement.catalog ?? origin
            if edgeOrigin != origin { try requireTrustedHostedCatalog(edgeOrigin) }
            let target = try identifier(package: requirement.package, from: edgeOrigin)
            try bind(edgeOrigin, id: target.catalog, in: &nextLocators)
            return MarketplaceResolvedEdge(requirement: requirement, target: target)
          }
          choice = Choice(
            node: MarketplaceResolvedNode(
              id: id, catalog: release.origin, coordinate: release.coordinate,
              archiveDigest: release.archiveDigest,
              catalogCommit: priorExact.first(where: {
                $0.pin.dependency.coordinate == release.coordinate
              })?.pin.catalogCommit ?? release.catalogCommit,
              dependencies: edges,
              organizationRequirements: required.overrides ? required.constraints : nil,
              hostedEvidence: hostedPackages[
                MarketplaceReleaseKey(node: id, version: release.coordinate.version)
              ]?.hostedEvidence),
            release: release)
        }
        var nextChoices = choices
        nextChoices[id] = choice
        guard
          nextChoices.values.reduce(0, { $0 + $1.node.dependencies.count })
            <= MarketplaceGraph.maximumEdges
        else { throw MarketplaceError.resolutionLimit("edge count") }
        var nextDemands = demands
        let parent = incoming.first(where: \.updating) ?? incoming[0]
        for edge in choice.node.dependencies {
          let path = parent.path + [edge.target]
          if parent.path.contains(edge.target) {
            throw MarketplaceError.dependencyCycle(path.map(\.description).joined(separator: " → "))
          }
          guard path.count <= MarketplaceGraph.maximumDepth else {
            throw MarketplaceError.resolutionLimit("graph depth")
          }
          let demand = Demand(
            requirement: edge.requirement.requirement, path: path,
            root: parent.root, updating: updating)
          nextDemands[edge.target, default: []].append(demand)
          if let existing = nextChoices[edge.target],
            existing.node.organizationRequirements == nil,
            !demand.requirement.admitsMarketplaceVersion(existing.node.coordinate.version)
          {
            let reasons = nextDemands[edge.target]!.map(\.description).joined(separator: "; ")
            throw MarketplaceError.unsatisfiable(edge.target.description + ": " + reasons)
          }
        }
        return try search(
          roots: roots, demands: nextDemands, locators: nextLocators, choices: nextChoices)
      } catch let error as MarketplaceError {
        switch error {
        case .unsatisfiable, .dependencyCycle:
          if !(failure is OrganizationPolicyFailure) { failure = error }
        default: throw error
        }
      } catch let error as OrganizationPolicyFailure {
        failure = error
      }
    }
    throw failure
  }

  private func promotedRoots(for ids: Set<MarketplaceNodeID>) -> [MarketplaceLegacyRoot] {
    ids.flatMap { legacy[$0] ?? [] }.sorted { $0.name < $1.name }
  }

  private func includingLegacy(
    in roots: [MarketplaceResolvedRoot], promoted: [MarketplaceLegacyRoot]
  ) throws -> [MarketplaceResolvedRoot] {
    let names = Set(roots.map(\.intent.name))
    return try roots
      + promoted.filter { !names.contains($0.name) }.map {
        MarketplaceResolvedRoot(
          intent: try $0.intent(in: declaration, ledger: previous, store: store), node: $0.id)
      }
  }

  private func admitOrganizationPaths(
    roots: [MarketplaceResolvedRoot], choices: [MarketplaceNodeID: Choice]
  ) throws {
    let evaluator = organizationPolicy.evaluator
    guard evaluator.active else { return }
    let partial = MarketplaceGraph(roots: roots, nodes: choices.values.map(\.node))
    let paths = partial.policyPaths()
    let findings = paths.keys.sorted(by: MarketplaceNodeID.ordered).flatMap { node in
      let path = paths[node]!.map { OrganizationPolicyIdentity($0).description }
      return evaluator.depth(path.count, path: path) + evaluator.marketplace(node, path: path)
    }
    try organizationPolicy.admit(findings)
  }

  private func validateBranch(
    roots: [MarketplaceResolvedRoot], choices: [MarketplaceNodeID: Choice]
  )
    throws
  {
    var heights: [MarketplaceNodeID: Int] = [:]
    var path: [MarketplaceNodeID] = []
    var visiting = Set<MarketplaceNodeID>()
    func walk(_ id: MarketplaceNodeID) throws -> Int {
      if let height = heights[id] { return height }
      guard visiting.insert(id).inserted else {
        throw MarketplaceError.dependencyCycle(
          (path + [id]).map(\.description).joined(separator: " → "))
      }
      guard path.count < MarketplaceGraph.maximumDepth else {
        throw MarketplaceError.resolutionLimit("graph depth")
      }
      path.append(id)
      let height = try 1 + (choices[id]!.node.dependencies.map { try walk($0.target) }.max() ?? 0)
      path.removeLast()
      visiting.remove(id)
      heights[id] = height
      return height
    }
    for root in roots where try walk(root.node) > MarketplaceGraph.maximumDepth {
      throw MarketplaceError.resolutionLimit("graph depth from " + root.intent.name)
    }
  }

  private var catalogEnvironment: RuntimeEnvironment { store.marketplaceEnvironment }

  private func identifier(package: String, from origin: MarketplaceOrigin) throws
    -> MarketplaceNodeID
  {
    let source = try origin.policyOrigin(environment: catalogEnvironment)
    try policy.effective.require(source, reference: package)
    return MarketplaceNodeID(
      catalog: MarketplaceCatalogID(origin, origin: source), package: package)
  }

  private func bind(
    _ locator: MarketplaceOrigin, id: MarketplaceCatalogID,
    in locators: inout [MarketplaceCatalogID: MarketplaceOrigin]
  ) throws {
    try policy.effective.require(id.origin)
    if let other = locators[id], other.ref != locator.ref {
      throw MarketplaceError.originConflict(id.origin.description)
    }
    if locators[id] == nil { locators[id] = locator }
  }

  private func requireTrustedHostedCatalog(_ origin: MarketplaceOrigin) throws {
    guard origin.kind == .hosted else { return }
    if hostedTrust == nil {
      hostedTrust = try MarketplaceDirectory.trustedHostedOrigins(environment: store.environment)
    }
    guard let trust = hostedTrust, trust.origins.contains(origin) else {
      throw HostedMarketplaceError.registrationRequired
    }
    try trust.evidence.validate()
  }

  private func bundle(for release: MarketplaceRelease, id: MarketplaceNodeID) throws
    -> BundleInspection
  {
    if let bundle = bundles[id]?[release.coordinate.version] { return bundle }
    guard release.archiveByteCount <= LedgerLimits.standard.encodedBytes - archivedBytes else {
      throw MarketplaceError.resolutionLimit("verified archive bytes")
    }
    archivedBytes += release.archiveByteCount
    try hostedTrust?.evidence.validate()
    let verified = try observations[id.catalog]!.acquire(release)
    let bundle = try verified.inspectBundle()
    if verified.hostedEvidence != nil {
      hostedPackages[MarketplaceReleaseKey(node: id, version: release.coordinate.version)] =
        verified
    }
    bundles[id, default: [:]][release.coordinate.version] = bundle
    return bundle
  }
}
