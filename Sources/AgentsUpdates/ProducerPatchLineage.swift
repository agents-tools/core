import AgentsCore
import Foundation

final class ProducerPatchLineage {
  struct Context {
    let producer: ProducerPatchProducer
    let selectors: [String]
    let gitSource: String?
    let releaseEntries: [Data: LedgerEntry]?
  }

  enum Decision {
    case owned(Context)
    case skip(ProducerPatchSkip.Reason)
  }

  private let inputs: ProducerPatchInputs
  private let members: [String: [(MarketplaceResolvedNode, MarketplaceResolvedMember)]]
  private let sourceRoots: [String: [String]]
  private var archives: [MarketplaceNodeID: [String: BundleItem]] = [:]

  init(_ inputs: ProducerPatchInputs) {
    self.inputs = inputs
    let ledger = inputs.ledger
    var members: [String: [(MarketplaceResolvedNode, MarketplaceResolvedMember)]] = [:]
    for node in ledger.marketplaceGraph?.nodes ?? [] where node.catalog.kind == .hosted {
      for member in node.members {
        if let id = member.producerResource, let resource = ledger.resources[id] {
          members[resource.source, default: []].append((node, member))
        }
      }
    }
    self.members = members
    self.sourceRoots = Dictionary(grouping: ledger.sourceUses, by: \.source).mapValues {
      $0.map(\.root)
    }
  }

  private func rootSource(_ id: String) -> String {
    var root = id
    while let parent = inputs.ledger.sources[root]?.container { root = parent }
    return root
  }

  func isLocallyOwned(_ id: String) -> Bool {
    let root = rootSource(id)
    let source = inputs.ledger.sources[root]!
    guard source.kind == .local, members[root] == nil else { return false }
    if let evidence = source.bundleSources {
      return evidence.allSatisfy(Self.localClaim)
    }
    guard let location = source.location, let url = try? location.resolve(roots: inputs.roots)
    else {
      return false
    }
    return BundleSourceLocation.container(of: url, in: inputs.store) == nil
  }

  private static func localClaim(_ evidence: PortableSourceEvidence) -> Bool {
    evidence.kind == .local && evidence.packageName == nil && evidence.origin?.kind != .missing
  }

  func hostedProducerResources(for resources: Set<String>) -> Set<String> {
    Set(
      resources.flatMap { id in
        let source = rootSource(inputs.ledger.resources[id]!.source)
        return (members[source] ?? []).compactMap { $0.1.producerResource }
      })
  }

  func resource(_ id: String) -> LedgerResource { inputs.ledger.resources[id]! }

  /// Claims without a resource-to-source mapping can be classified before any replay.
  func unattributed(_ resource: LedgerResource) -> ProducerPatchSkip.Reason? {
    let id = rootSource(resource.source)
    let source = inputs.ledger.sources[id]!
    if isLocallyOwned(resource.source) { return .locallyOwned }
    if source.kind == .git {
      guard let transport = source.transport, (try? SourceOrigin.git(transport)) != nil else {
        return .missingProducerIdentity
      }
      return resource.kind == .git ? nil : .missingPathAttribution
    }
    if members[id] != nil { return nil }
    if let claims = source.bundleSources {
      let origins = Set(
        claims.lazy.filter { !Self.localClaim($0) }.map(\.policyOrigin).filter { $0 != .missing })
      if origins.count > 1 { return .ambiguousProducer }
      if !origins.isEmpty { return .missingPathAttribution }
    }
    return source.kind == .wellKnown ? .missingPathAttribution : .missingProducerIdentity
  }

  func verifyGit(
    _ source: String, commit: String, _ body: ((String, Data, Bool) throws -> Bool) throws -> Void
  ) throws {
    try SourceCache(store: inputs.store).withPinnedGitBlobCheck(
      sourceID: source, revision: commit, body)
  }

  func origin(
    for copy: ProducerPatchRoutes.Copy, replayed: [String: URL]
  ) throws -> Decision {
    let ledger = inputs.ledger
    let resource = ledger.resources[copy.resource]!
    let id = rootSource(resource.source)
    let source = ledger.sources[id]!
    let owners = copy.owners.compactMap { ledger.components[$0] }
    if let reason = unattributed(resource) { return .skip(reason) }
    if source.kind == .git, let transport = source.transport,
      let origin = try? SourceOrigin.git(transport), let identity = origin.identity
    {
      guard resource.kind == .git, SourceCache.isObjectID(source.revision) else {
        return .skip(.missingPathAttribution)
      }
      let declaredRoots = sourceRoots[id] ?? []
      let matchingRoots = declaredRoots.filter { Self.contains(resource.path, in: $0) }
      let ownerRoots = owners.compactMap { component -> String? in
        guard rootSource(component.declaringSource) == id,
          Self.contains(resource.path, in: component.root)
        else { return nil }
        return component.root
      }
      let roots = ownerRoots.isEmpty ? matchingRoots : ownerRoots
      let root = roots.min(by: Self.ordered) ?? "."
      let selectors = owners.map { Self.selector($0, root: $0.root) }
      return .owned(
        .init(
          producer: .init(
            source: identity, package: nil, root: root, base: .git(commit: source.revision)),
          selectors: selectors, gitSource: try ledger.sourceIdentity(id, roots: inputs.roots),
          releaseEntries: nil))
    }

    if let hosted = members[id] {
      let candidates = hosted.filter { node, member in
        let records = Set(node.componentRecords)
        return zip(copy.owners, owners).contains { ownerID, component in
          records.contains(ownerID) && component.declaringSource == id
            && component.kind == member.key.kind.rawValue
            && PathSafety.sanitizeName(member.key.name) == component.name
            && !Set(copy.recipients).isDisjoint(with: member.targets)
        }
      }
      guard let (node, member) = candidates.first else { return .skip(.missingPathAttribution) }
      guard candidates.count == 1 else { return .skip(.ambiguousProducer) }
      return try hostedOrigin(
        node, member: member, source: source, resource: resource,
        recipients: copy.recipients, replayed: replayed)
    }

    return .skip(.missingProducerIdentity)
  }

  private func hostedOrigin(
    _ node: MarketplaceResolvedNode, member: MarketplaceResolvedMember, source: LedgerSource,
    resource: LedgerResource, recipients: [AgentID], replayed: [String: URL]
  ) throws -> Decision {
    let ledger = inputs.ledger
    let index = try HostedMarketplaceLocation(node.catalog.location)
    guard let id = member.producerResource, let container = replayed[id],
      let location = try source.location?.resolve(roots: inputs.roots),
      let registered = BundleSourceLocation.container(of: location, in: inputs.store),
      registered.lastPathComponent
        == String(member.sourceAlias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count))
    else { throw ProducerPatchError.lockedInputUnavailable }
    let seal = try BundleStoredSource.read(container, expectedKey: registered.lastPathComponent)
    guard seal.marketplaceNode == node.id, seal.componentID == member.componentID,
      seal.package.name == node.coordinate.package, seal.package.version == node.coordinate.version,
      seal.sources == source.bundleSources
    else { throw ProducerPatchError.lockedInputUnavailable }

    let items: [String: BundleItem]
    if let known = archives[node.id] {
      items = known
    } else {
      guard let evidence = node.hostedEvidence,
        let bytes = ledger.contentObjects[node.archiveDigest],
        bytes.count == evidence.archiveByteCount, BundleArchive.digest(bytes) == node.archiveDigest
      else { throw ProducerPatchError.lockedInputUnavailable }
      try evidence.validate(index: node.catalog.location)
      try HostedMarketplaceReader.requireRequests(
        evidence.requests, index: index, coordinate: node.coordinate,
        policy: inputs.sourcePolicy.effective, organization: inputs.organization)
      let archive = try BundleArchive.read(bytes)
      guard archive.manifest.package.name == node.coordinate.package,
        archive.manifest.package.version == node.coordinate.version,
        archive.manifest.package.dependencies ?? [] == node.dependencies.map(\.requirement)
      else { throw ProducerPatchError.lockedInputUnavailable }
      items = try Dictionary(
        uniqueKeysWithValues: archive.manifest.components.map { (try $0.id, $0) })
      archives[node.id] = items
    }

    guard let item = items[member.componentID],
      item.kind.rawValue == member.key.kind.rawValue, item.name == member.key.name
    else { throw ProducerPatchError.lockedInputUnavailable }
    // The archive's path can establish the release's own contents. A forwarded dependency's
    // provenance does not identify that dependency's original file or authorize relabeling it.
    let external = item.sources.filter { !Self.localClaim($0) }
    guard external.isEmpty else {
      return .skip(external.count > 1 ? .ambiguousProducer : .missingPathAttribution)
    }
    guard item.kind == .skills, item.discovery?.utf8.elementsEqual(resource.path.utf8) == true
    else { return .skip(.missingPathAttribution) }
    let selectors = ledger.marketplaceGraph?.recipientsByRoot(for: member.key, in: node.id) ?? [:]
    let labels = selectors.keys.sorted().filter {
      !Set(selectors[$0] ?? []).isDisjoint(with: recipients)
    }.map { $0 + ":" + member.key.kind.rawValue + "/" + member.key.name }
    guard !labels.isEmpty else { return .skip(.missingPathAttribution) }
    return .owned(
      .init(
        producer: .init(
          source: index.url.absoluteString, package: node.coordinate.package, root: ".",
          base: .release(version: node.coordinate.version, contentDigest: node.archiveDigest)),
        selectors: labels, gitSource: nil,
        releaseEntries: Dictionary(
          uniqueKeysWithValues: item.entries.map {
            (Data($0.path.utf8), $0)
          })))
  }

  private static func contains(_ path: String, in root: String) -> Bool {
    root == "." || path.utf8.elementsEqual(root.utf8) || path.utf8.starts(with: (root + "/").utf8)
  }

  private static func ordered(_ first: String, _ second: String) -> Bool {
    first.utf8.lexicographicallyPrecedes(second.utf8)
  }

  private static func selector(_ component: LedgerComponent, root: String) -> String {
    [root, component.group, component.kind + "/" + component.name].compactMap { $0 }
      .joined(separator: ":")
  }
}
