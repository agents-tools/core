import AgentsCore
import AgentsManifest
import Components
import Foundation

struct MarketplaceGraphChange: Sendable {
  let graph: MarketplaceGraph?
  let stateDigest: String
  let policyFingerprint: String
  let directoryInputs: [MarketplaceCatalogInput]
  let promotedLegacy: Set<String>
  let hostedArchives: [String: Data]
  let hostedGeneration: [TargetPrecondition]

  static func admitHostedRegistrations(
    _ graph: MarketplaceGraph?, environment: RuntimeEnvironment
  ) throws -> TargetPrecondition? {
    let required = Set(
      (graph?.nodes ?? []).flatMap { node in
        node.dependencies.compactMap { edge -> MarketplaceOrigin? in
          guard let catalog = edge.requirement.catalog, catalog.kind == .hosted,
            catalog != node.catalog
          else { return nil }
          return catalog
        }
      })
    guard !required.isEmpty else { return nil }
    let registration = try MarketplaceDirectory.trustedHostedOrigins(environment: environment)
    guard required.isSubset(of: registration.origins) else {
      throw HostedMarketplaceError.registrationRequired
    }
    try registration.evidence.validate()
    return registration.evidence
  }

  func validateCatalogs(in store: StateStore) throws {
    for input in directoryInputs {
      try input.validate(scope: store.scope, environment: store.marketplaceEnvironment)
    }
  }

  static func stateDigest(in baseline: StatePrecondition, store: StateStore) throws -> String {
    let digests = try [store.declarationURL, store.resolvedURL, store.watchURL].map { file in
      try baseline.bytes(for: file).map(BundleArchive.digest) ?? "absent"
    }
    return try ResolvedLedgerCodec.digest(digests)
  }

  static func deploymentIdentities(
    from previous: ResolvedLedger, to next: ResolvedLedger, roots: [String: URL]
  ) throws -> Set<String> {
    var identities = Set<String>()
    let retainedLegacy = Set((next.marketplacePackages ?? []).map { $0.dependency.name })
    for ledger in [previous, next] {
      let records = ledger.marketplaceGraph?.nodes.flatMap(\.componentRecords) ?? []
      // Promotion withdraws the legacy contribution from the actual deployment.
      let promoted = (ledger.marketplacePackages ?? []).filter {
        !retainedLegacy.contains($0.dependency.name)
      }.flatMap(\.componentRecords)
      for record in records + promoted {
        if let component = ledger.components[record] {
          try identities.insert(LedgerImpact.identity(component, ledger: ledger, roots: roots))
        }
      }
    }
    return identities
  }

  func validate(
    _ baseline: StatePrecondition, policy: SourcePolicySnapshot,
    organizationPolicy: OrganizationPolicySnapshot, store: StateStore
  ) throws {
    for file in hostedGeneration { try file.validate() }
    guard try stateDigest == Self.stateDigest(in: baseline, store: store),
      policyFingerprint
        == (try ResolvedLedgerCodec.digest([policy.fingerprint, organizationPolicy.fingerprint]))
    else {
      throw CoreError.invalidState(
        "marketplace scope or source policy changed; refresh the preview")
    }
  }

  func compose(
    _ original: Declaration, previous: ResolvedLedger, store: StateStore
  ) throws -> Declaration {
    var result = original
    result.marketplaceRoots = graph?.roots.map(\.intent) ?? []
    result.packages.removeAll { promotedLegacy.contains($0.name) }
    var owned = Set(previous.marketplaceGraph?.nodes.flatMap(\.sourceAliases) ?? [])
    owned.formUnion(
      (previous.marketplacePackages ?? []).filter {
        promotedLegacy.contains($0.dependency.name)
      }.flatMap(\.sourceAliases))
    if previous.marketplaceGraph == nil, !original.marketplaceRoots.isEmpty {
      // A committed declaration may arrive before its lock. These names and paths belong
      // to the graph's generated producers and are rebuilt from the authored roots.
      for source in original.sourceDeclarations
      where source.name.hasPrefix(MarketplaceResolvedNode.sourceAliasPrefix)
        && BundleSourceLocation.isKey(
          String(source.name.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count)))
        && source.source.kind == .local && source.source.path == nil
        && source.source.requirement == nil
        && source.source.location == Self.source(for: source.name, scope: store.scope).location
      {
        owned.insert(source.name)
      }
    }
    result.sourceDeclarations.removeAll { owned.contains($0.name) }
    result.uses.removeAll { $0.source.map(owned.contains) ?? false }

    var aliases = Set(result.sourceDeclarations.map(\.name))
    for node in graph?.nodes ?? [] {
      for member in node.members {
        guard aliases.insert(member.sourceAlias).inserted else {
          throw MarketplaceError.contributionMismatch(node.id.description)
        }
        result.sourceDeclarations.append(
          .init(
            name: member.sourceAlias,
            source: Self.source(for: member.sourceAlias, scope: store.scope)))
        result.uses.append(
          .init(
            name: BundleInstallation.groupName, source: member.sourceAlias,
            condition: .init(agents: member.targets)))
      }
    }
    return result
  }

  static func validate(
    _ declaration: Declaration, matching ledger: ResolvedLedger, store: StateStore,
    allowingIntentDrift: Bool = false
  ) throws {
    let graph = ledger.marketplaceGraph
    if !allowingIntentDrift {
      let frozen = Dictionary(
        uniqueKeysWithValues: (graph?.roots ?? []).map {
          ($0.intent.name, $0.intent)
        })
      for root in declaration.marketplaceRoots {
        guard let previous = frozen[root.name] else { throw MarketplaceError.missingPin(root.name) }
        guard previous == root else { throw MarketplaceError.selectionMismatch(root.name) }
      }
      let names = Set(declaration.marketplaceRoots.map(\.name))
      if let unexpected = graph?.roots.first(where: { !names.contains($0.intent.name) }) {
        throw MarketplaceError.selectionMismatch(unexpected.intent.name)
      }
      guard (graph?.roots.map(\.intent) ?? []) == declaration.marketplaceRoots else {
        throw MarketplaceError.selectionMismatch("root order")
      }
    }
    guard let graph else { return }
    let closure = try PackageClosure(ledger, store: store)
    for node in graph.nodes {
      let evidence = try evidence(
        for: node, closure: closure, declaration: declaration, store: store)
      guard node.contributionDigest == evidence.contributionDigest,
        node.componentRecords == evidence.componentRecords
      else { throw MarketplaceError.contributionMismatch(node.id.description) }
    }
  }

  static func freeze(
    _ graph: MarketplaceGraph?, in frozen: ResolvedLedger, sourceIDs: [SourceSnapshotID: String],
    producers: [String: BundleSourceInputs.Producer], declaration: Declaration, store: StateStore,
    hostedArchives: [String: Data]
  ) throws -> ResolvedLedger {
    guard var graph else { return frozen }
    let closure = try PackageClosure(frozen, store: store)
    var ledger = frozen
    let limits = LedgerLimits.standard
    var remaining = limits.objectBytes - ledger.contentObjects.values.reduce(0) { $0 + $1.count }
    graph.nodes = try graph.nodes.map { node in
      var node = node
      if node.hostedEvidence != nil, ledger.contentObjects[node.archiveDigest] == nil {
        guard let bytes = hostedArchives[node.archiveDigest], bytes.count <= remaining else {
          throw MarketplaceError.resolutionLimit("embedded hosted archives")
        }
        ledger.contentObjects[node.archiveDigest] = bytes
        remaining -= bytes.count
      }
      node.members = try node.members.map { member in
        var member = member
        guard let producer = producers[member.sourceAlias],
          let source = sourceIDs[producer.snapshot],
          producer.seal.marketplaceNode == node.id, producer.seal.componentID == member.componentID
        else { throw MarketplaceError.contributionMismatch(node.id.description) }
        let captured = try LedgerResources.capture(
          producer.contents, embed: true, limits: limits, sourceRoot: producer.contents)
        for (id, data) in captured.objects where ledger.contentObjects[id] == nil {
          guard data.count <= remaining else {
            throw MarketplaceError.resolutionLimit("embedded producer bytes")
          }
          remaining -= data.count
          ledger.contentObjects[id] = data
        }
        let resource = LedgerResource(
          kind: .embedded, source: source, path: ".", hash: captured.hash,
          entries: captured.entries, support: captured.support)
        let digest = try ResolvedLedgerCodec.digest(resource)
        member.producerResource = digest
        ledger.resources[digest] = resource
        return member
      }
      return try evidence(for: node, closure: closure, declaration: declaration, store: store)
    }
    ledger.marketplaceGraph = graph
    return ledger
  }

  static func validateHosted(
    _ graph: MarketplaceGraph?, objects: [String: Data], policy: EffectiveSourcePolicy,
    organizationPolicy: OrganizationPolicySnapshot
  ) throws {
    for node in graph?.nodes ?? [] where node.catalog.kind == .hosted {
      try Task.checkCancellation()
      try validateHosted(
        node, archive: objects[node.archiveDigest], policy: policy,
        organizationPolicy: organizationPolicy)
    }
  }

  static func validateHosted(
    _ node: MarketplaceResolvedNode, archive bytes: Data?, policy: EffectiveSourcePolicy,
    organizationPolicy: OrganizationPolicySnapshot
  ) throws {
    guard let hosted = node.hostedEvidence, let bytes, bytes.count == hosted.archiveByteCount
    else { throw MarketplaceError.integrityMismatch(node.coordinate.label) }
    try hosted.validate(index: node.catalog.location)
    try HostedMarketplaceReader.requireRequests(
      hosted.requests, index: HostedMarketplaceLocation(node.catalog.location),
      coordinate: node.coordinate, policy: policy, organization: organizationPolicy)
    let bundle = try BundleOperations.inspect(bytes)
    guard bundle.archiveDigest == node.archiveDigest,
      bundle.package.name == node.coordinate.package,
      bundle.package.version == node.coordinate.version,
      bundle.package.dependencies ?? [] == node.dependencies.map(\.requirement)
    else { throw MarketplaceError.integrityMismatch(node.coordinate.label) }
    let members = Dictionary(
      uniqueKeysWithValues: bundle.components.map { ($0.id, $0.marketplaceKey) })
    guard node.members.allSatisfy({ members[$0.componentID] == $0.key }) else {
      throw MarketplaceError.contributionMismatch(node.id.description)
    }
    for item in bundle.archive.manifest.components {
      let sources = try item.installationSources()
      try policy.requireBundleSources(sources, reference: node.id.description)
      for origin in Set(sources.map(\.policyOrigin) + (item.mcpRegistry?.origins ?? [])) {
        try policy.require(origin, reference: node.id.description)
        try organizationPolicy.admit(
          organizationPolicy.evaluator.source(origin, path: [node.id.description]))
      }
    }
  }

  static func validateProducers(
    _ graph: MarketplaceGraph?, replayed resources: [String: URL]
  ) throws {
    for node in graph?.nodes ?? [] {
      for member in node.members {
        guard let id = member.producerResource, let contents = resources[id] else {
          throw MarketplaceError.contributionMismatch(node.id.description)
        }
        try validateProducer(contents, member: member, node: node.id)
      }
    }
  }

  private static func validateProducer(
    _ contents: URL, member: MarketplaceResolvedMember, node: MarketplaceNodeID
  ) throws {
    let key = String(member.sourceAlias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count))
    let seal = try BundleStoredSource.read(contents, expectedKey: key)
    guard seal.marketplaceNode == node, seal.componentID == member.componentID else {
      throw MarketplaceError.contributionMismatch(node.description)
    }
  }

  static func restoreProducers(
    _ graph: MarketplaceGraph?, replayed resources: [String: URL], store: StateStore
  ) throws -> [BundleSourceInputs.Publication] {
    try (graph?.nodes ?? []).flatMap { node in
      try node.members.compactMap { member in
        let container = Self.container(for: member.sourceAlias, in: store)
        let destination = try BundleSourceInputs.destination(container, in: store)
        let contents: URL
        if destination.exists {
          contents = container
        } else if let id = member.producerResource, let replayed = resources[id] {
          contents = replayed
        } else {
          throw MarketplaceError.contributionMismatch(node.id.description)
        }
        try validateProducer(contents, member: member, node: node.id)
        return destination.exists ? nil : .init(contents: contents, destination: destination)
      }
    }
  }

  static func pruneProducers(
    previous: ResolvedLedger, next: ResolvedLedger, store: StateStore, roots: [String: URL],
    declaration: Declaration, watch: WatchState
  ) throws -> [TargetPrecondition] {
    guard previous.marketplaceGraph != nil || previous.marketplacePackages != nil else { return [] }
    var containers = Set(
      try next.sources.values.compactMap { source in
        try source.location.flatMap {
          BundleSourceLocation.container(of: try $0.resolve(roots: roots), in: store)
        }
      })
    containers.formUnion(
      declaration.sourceDeclarations.compactMap { entry in
        let source = entry.source
        guard source.kind == .local else { return nil }
        return BundleSourceLocation.container(
          of: source.localURL(environment: store.environment), in: store)
      })
    func orphan(_ container: URL) throws -> TargetPrecondition? {
      guard !containers.contains(container),
        watch.sources["local:" + container.appendingPathComponent(BundleSourceLocation.tree).path]
          == nil
      else { return nil }
      let destination = try BundleSourceInputs.destination(container, in: store)
      return destination.exists ? destination : nil
    }
    let graphOrphans = try (previous.marketplaceGraph?.nodes ?? []).flatMap { node in
      try node.members.compactMap { member -> TargetPrecondition? in
        let container = Self.container(for: member.sourceAlias, in: store)
        guard let destination = try orphan(container) else { return nil }
        try validateProducer(container, member: member, node: node.id)
        return destination
      }
    }
    let legacyOrphans = try (previous.marketplacePackages ?? []).flatMap { pin in
      let aliases = Set(pin.sourceAliases.filter { $0.hasPrefix("bundle-") })
      let sources = Set(
        pin.componentRecords.compactMap { previous.components[$0]?.declaringSource })
      var seen = Set<URL>()
      return try sources.sorted().compactMap { id -> TargetPrecondition? in
        guard let location = previous.sources[id]?.location,
          let container = BundleSourceLocation.container(
            of: try location.resolve(roots: roots), in: store),
          aliases.contains("bundle-" + container.lastPathComponent),
          seen.insert(container).inserted,
          let destination = try orphan(container)
        else { return nil }
        _ = try BundleStoredSource.read(container)
        return destination
      }
    }
    return graphOrphans + legacyOrphans
  }

  private static func evidence(
    for node: MarketplaceResolvedNode, closure: PackageClosure, declaration: Declaration,
    store: StateStore
  ) throws -> MarketplaceResolvedNode {
    let sources = declaration.sources
    let aliases = Set(node.sourceAliases)
    let uses = declaration.uses.filter { $0.source.map(aliases.contains) ?? false }
    guard uses.count == aliases.count else {
      throw MarketplaceError.contributionMismatch(node.id.description)
    }
    for member in node.members {
      let source = sources[member.sourceAlias]
      let expected = Self.source(for: member.sourceAlias, scope: store.scope)
      guard source?.kind == expected.kind, source?.location == expected.location,
        source?.requirement == nil, source?.path == nil,
        uses.contains(where: {
          $0.source == member.sourceAlias && $0.name == BundleInstallation.groupName
            && $0.condition == DeclarationCondition(agents: member.targets)
        })
      else { throw MarketplaceError.contributionMismatch(node.id.description) }
    }

    var pinned = node
    if !node.members.isEmpty {
      let dependency = try MarketplaceDependency(
        name: "package-" + ResolvedLedgerCodec.digest(node.id).dropFirst(7),
        catalog: node.catalog, coordinate: node.coordinate)
      let evidence = try closure.evidence(
        for: dependency, archiveDigest: node.archiveDigest, catalogCommit: node.catalogCommit,
        catalogOrigin: node.id.catalog.origin, aliases: node.sourceAliases, in: declaration)
      pinned.componentRecords = evidence.components
      pinned.contributionDigest = evidence.digest
    } else {
      pinned.componentRecords = []
      pinned.contributionDigest = ""
    }
    pinned.contributionDigest = try ResolvedLedgerCodec.digest(pinned)
    return pinned
  }

  private static func container(for alias: String, in store: StateStore) -> URL {
    let key = String(alias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count))
    return store.directory.appendingPathComponent(BundleSourceLocation.directory)
      .appendingPathComponent(key)
  }

  static func source(for alias: String, scope: InstallScope) -> SourceDeclaration {
    let key = alias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count)
    let base = scope == .project ? ".agent/" : "~/.agents/"
    let relative = BundleSourceLocation.directory + "/" + key + "/" + BundleSourceLocation.tree
    return SourceDeclaration(kind: .local, location: base + relative)
  }
}
