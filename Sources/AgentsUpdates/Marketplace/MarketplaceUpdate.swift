import AgentsCore
import AgentsManifest
import Foundation

extension VerifiedMarketplacePackage {
  /// Binds the verified release to the producer aliases created by its archive importer.
  /// The importer must check the archive's own package coordinates before building the request.
  /// Pass its full-scope update request so the transaction can replace prior package targets.
  public func bindingImport(
    _ request: UpdateRequest, as name: String, sourceAliases: [String]
  ) throws -> UpdateRequest {
    switch request.operation {
    case .update, .declaration: break
    default: throw MarketplaceError.selectionMismatch("package import requires an update")
    }
    let dependency = try MarketplaceDependency(
      name: name, catalog: release.origin, coordinate: release.coordinate)
    guard !sourceAliases.isEmpty, sourceAliases.count == Set(sourceAliases).count,
      request.marketplaceChange == nil
    else { throw MarketplaceError.contributionMismatch(name) }
    let origin = try release.policyOrigin()
    var request = request
    var aliases = sourceAliases
    if let installation = request.bundleInstallation {
      guard installation.archiveDigest == release.archiveDigest,
        Set(aliases) == Set(installation.members.map(\.alias))
      else {
        throw MarketplaceError.contributionMismatch(dependency.name)
      }
      let catalog = try BundlePackageProvenance.release(
        release.coordinate, origin: origin, root: release.origin.policyPath,
        digest: release.archiveDigest, catalogCommit: release.catalogCommit)
      let sealed = try installation.recordingCatalog(catalog, observedOrigin: origin)
      request.bundleInstallation = sealed
      aliases = sealed.members.map(\.alias)
    }
    request.marketplaceChange = .install(
      dependency, digest: release.archiveDigest, commit: release.catalogCommit,
      aliases: aliases.sorted(), origin: origin)
    return request
  }
}

extension MarketplaceOperations {
  /// Removes one dependency and its importer-owned source and group contributions.
  public static func removalRequest(for name: String) -> UpdateRequest {
    var request = UpdateRequest()
    request.marketplaceChange = .remove(name)
    return request
  }

  /// Reads package pins under the scope lock and diagnoses missing or changed intent.
  public static func installed(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [MarketplacePin] {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let declaration = try store.readDeclaration(prepared: baseline)
      let ledger = try store.readLedger(prepared: baseline)
      try MarketplaceChanges.validateInspection(
        declaration, bytes: baseline.bytes(for: store.declarationURL), ledger: ledger, store: store)
      try baseline.validate()
      return ledger.marketplacePackages ?? []
    }
  }
}

package enum MarketplaceChange: Sendable {
  case install(
    MarketplaceDependency, digest: String, commit: String?, aliases: [String], origin: SourceOrigin)
  case remove(String)
}

enum MarketplaceChanges {
  static func validateInspection(
    _ declaration: Declaration, bytes: Data?, ledger: ResolvedLedger, store: StateStore
  ) throws {
    try ledger.pendingDeployment?.requireDeclaration(bytes)
    try validate(
      declaration, matching: ledger.pendingDeployment?.desired(in: ledger) ?? ledger,
      in: store)
  }

  static func validate(
    _ declaration: Declaration, matching ledger: ResolvedLedger, in store: StateStore,
    allowingGraphReconciliation: Bool = false
  )
    throws
  {
    try MarketplaceGraphChange.validate(
      declaration, matching: ledger, store: store, allowingIntentDrift: allowingGraphReconciliation)
    let pins = ledger.marketplacePackages ?? []
    guard !declaration.packages.isEmpty || !pins.isEmpty else { return }
    let dependencies = Dictionary(uniqueKeysWithValues: declaration.packages.map { ($0.name, $0) })
    let installed = Dictionary(uniqueKeysWithValues: pins.map { ($0.dependency.name, $0) })
    for dependency in declaration.packages {
      guard let pin = installed[dependency.name] else {
        throw MarketplaceError.missingPin(dependency.name)
      }
      guard pin.dependency == dependency else {
        throw MarketplaceError.selectionMismatch(dependency.name)
      }
    }
    let closure = try PackageClosure(ledger, store: store)
    for pin in pins {
      guard dependencies[pin.dependency.name] != nil else {
        throw MarketplaceError.selectionMismatch(pin.dependency.name)
      }
      try closure.validate(pin, declaration: declaration)
    }
  }

  static func candidate(
    _ candidate: Declaration, original: Declaration, previous: ResolvedLedger,
    request: UpdateRequest, store: StateStore
  ) throws -> Declaration {
    guard candidate.packages == original.packages,
      candidate.marketplaceRoots == original.marketplaceRoots
    else {
      throw MarketplaceError.selectionMismatch("use a verified package installation or removal")
    }
    if let graph = request.marketplaceGraphChange {
      return try graph.compose(candidate, previous: previous, store: store)
    }
    guard let change = request.marketplaceChange else {
      for pin in previous.marketplacePackages ?? [] {
        if PackageClosure.intentDigest(candidate, aliases: Set(pin.sourceAliases))
          != PackageClosure.intentDigest(original, aliases: Set(pin.sourceAliases))
        {
          throw MarketplaceError.contributionMismatch(pin.dependency.name)
        }
      }
      return candidate
    }
    guard request.kinds == nil, request.names.isEmpty, request.selections.isEmpty,
      request.selectedIdentities == nil
    else { throw MarketplaceError.selectionMismatch("package changes require a full-scope update") }

    var candidate = candidate
    let pins = previous.marketplacePackages ?? []
    switch change {
    case .install(let dependency, let digest, _, let aliases, let origin):
      guard try dependency.catalog.policyOrigin(environment: store.environment) == origin else {
        throw MarketplaceError.originConflict(dependency.name)
      }
      let id = MarketplaceNodeID(
        catalog: MarketplaceCatalogID(dependency.catalog, origin: origin),
        package: dependency.coordinate.package)
      if previous.marketplaceGraph?.nodes.contains(where: { $0.id == id }) == true {
        throw MarketplaceError.selectionMismatch(dependency.name + " is in a resolved graph")
      }
      let existing = pins.first { $0.dependency.name == dependency.name }
      if let existing {
        guard existing.dependency.catalog == dependency.catalog,
          existing.dependency.coordinate.package == dependency.coordinate.package
        else { throw MarketplaceError.originConflict(dependency.name) }
        if existing.dependency.coordinate == dependency.coordinate, existing.archiveDigest != digest
        {
          throw MarketplaceError.integrityMismatch(dependency.coordinate.label)
        }
      }
      let ownedAliases = Set(existing?.sourceAliases ?? [])
      let newAliases = Set(aliases)
      for alias in newAliases {
        guard candidate.sources[alias] != nil,
          original.sources[alias] == nil || ownedAliases.contains(alias)
        else { throw MarketplaceError.contributionMismatch(dependency.name) }
      }
      dropAliases(ownedAliases.subtracting(newAliases), from: &candidate)
      if let index = candidate.packages.firstIndex(where: { $0.name == dependency.name }) {
        candidate.packages[index] = dependency
      } else {
        candidate.packages.append(dependency)
      }
    case .remove(let name):
      guard let pin = pins.first(where: { $0.dependency.name == name }) else {
        throw MarketplaceError.missingPin(name)
      }
      dropAliases(Set(pin.sourceAliases), from: &candidate)
      candidate.packages.removeAll { $0.name == name }
    }
    return candidate
  }

  static func requirePolicy(
    _ policy: EffectiveSourcePolicy, candidate: Declaration, previous: ResolvedLedger,
    change: MarketplaceChange?, graph: MarketplaceGraph?, store: StateStore
  ) throws {
    guard policy.isConfigured else { return }
    for node in graph?.nodes ?? [] {
      try policy.require(node.id.catalog.origin, reference: node.id.description)
    }
    guard !candidate.packages.isEmpty else { return }
    let installed = Dictionary(
      uniqueKeysWithValues: (previous.marketplacePackages ?? []).map { ($0.dependency.name, $0) })
    let sources = candidate.sources
    for dependency in candidate.packages {
      let origin: SourceOrigin
      let aliases: [String]
      if case .install(let selected, _, _, let selectedAliases, let selectedOrigin) = change,
        selected == dependency
      {
        origin = selectedOrigin
        aliases = selectedAliases
      } else {
        guard let pin = installed[dependency.name] else {
          throw MarketplaceError.missingPin(dependency.name)
        }
        origin = try pin.policyOrigin(environment: store.environment)
        aliases = pin.sourceAliases
      }
      try policy.require(origin, reference: dependency.name)
      // Custom importers can supply portable producer seals. A directory generated by an
      // untyped importer establishes no original producer coordinates by itself.
      for alias in aliases {
        guard let source = sources[alias], source.kind == .local,
          BundleSourceLocation.container(
            of: source.localURL(environment: store.environment), in: store) != nil
        else {
          try policy.require(.missing, reference: dependency.name + ":" + alias)
          continue
        }
      }
    }
  }

  static func pin(
    _ ledger: ResolvedLedger, declaration: Declaration, previous: ResolvedLedger,
    request: UpdateRequest, store: StateStore, sourceIDs: [SourceSnapshotID: String],
    producers: [String: BundleSourceInputs.Producer]
  ) throws -> ResolvedLedger {
    let graph: MarketplaceGraph?
    if let change = request.marketplaceGraphChange {
      graph = change.graph
    } else {
      graph = previous.marketplaceGraph
    }
    var ledger = try MarketplaceGraphChange.freeze(
      graph, in: ledger, sourceIDs: sourceIDs, producers: producers, declaration: declaration,
      store: store,
      hostedArchives: request.marketplaceGraphChange?.hostedArchives ?? previous.contentObjects)
    if request.marketplaceGraphChange == nil, ledger.marketplaceGraph != previous.marketplaceGraph {
      throw MarketplaceError.contributionMismatch(
        "use a marketplace resolution to edit package contributions")
    }
    guard !declaration.packages.isEmpty else { return ledger }
    let previous = Dictionary(
      uniqueKeysWithValues: (previous.marketplacePackages ?? []).map { ($0.dependency.name, $0) })
    let closure = try PackageClosure(ledger, store: store)
    ledger.marketplacePackages = try declaration.packages.map { dependency in
      let existing = previous[dependency.name]
      if case .install(let selected, let digest, let commit, let aliases, let origin) = request
        .marketplaceChange,
        dependency == selected
      {
        let pinnedCommit = existing?.dependency == dependency ? existing?.catalogCommit : commit
        let evidence = try closure.evidence(
          for: dependency, archiveDigest: digest, catalogCommit: pinnedCommit,
          catalogOrigin: origin, aliases: aliases, in: declaration)
        return MarketplacePin(
          dependency: dependency, archiveDigest: digest, catalogCommit: pinnedCommit,
          sourceAliases: aliases, componentRecords: evidence.components,
          contributionDigest: evidence.digest, catalogOrigin: origin)
      }
      guard let existing else { throw MarketplaceError.missingPin(dependency.name) }
      try closure.validate(existing, declaration: declaration)
      return existing
    }
    return ledger
  }

  private static func dropAliases(_ aliases: Set<String>, from declaration: inout Declaration) {
    declaration.sourceDeclarations.removeAll { aliases.contains($0.name) }
    declaration.uses.removeAll { $0.source.map(aliases.contains) ?? false }
  }
}

struct PackageClosure {
  private let ledger: ResolvedLedger
  private let store: StateStore
  private let sourceRecords: [String: [String]]
  private let groups: [String: [LedgerGroup]]
  private let byGroup: [Int: LedgerGroup]
  private let byOccurrence: [Int: LedgerOccurrence]

  init(_ ledger: ResolvedLedger, store: StateStore) throws {
    self.ledger = ledger
    self.store = store
    let roots = store.ledgerRoots(recordedIn: ledger)
    let rootGroups = ledger.groups.filter { $0.parent == nil }
    let records = Set(rootGroups.map(\.source))
    var sourceRecords: [String: [String]] = [:]
    for id in records {
      sourceRecords[try ledger.sourceIdentity(id, roots: roots), default: []].append(id)
    }
    self.sourceRecords = sourceRecords
    groups = Dictionary(grouping: rootGroups, by: \.source)
    byGroup = Dictionary(uniqueKeysWithValues: ledger.groups.map { ($0.id, $0) })
    byOccurrence = Dictionary(uniqueKeysWithValues: ledger.occurrences.map { ($0.id, $0) })
  }

  func validate(_ pin: MarketplacePin, declaration: Declaration) throws {
    let evidence = try evidence(
      for: pin.dependency, archiveDigest: pin.archiveDigest, catalogCommit: pin.catalogCommit,
      catalogOrigin: pin.catalogOrigin, aliases: pin.sourceAliases, in: declaration)
    guard evidence.digest == pin.contributionDigest, evidence.components == pin.componentRecords
    else { throw MarketplaceError.contributionMismatch(pin.dependency.name) }
  }

  func evidence(
    for dependency: MarketplaceDependency, archiveDigest: String, catalogCommit: String?,
    catalogOrigin: SourceOrigin?, aliases: [String], in declaration: Declaration
  ) throws -> (components: [String], digest: String) {
    let name = dependency.name
    var selectedGroups: [LedgerGroup] = []
    let sources = declaration.sources
    let uses = Dictionary(
      grouping: declaration.uses.compactMap { use in
        use.source.map { ($0, use.name) }
      }, by: { $0.0 })
    for alias in aliases {
      guard let source = sources[alias], source.kind == .local, source.requirement == nil,
        let selectedUses = uses[alias], !selectedUses.isEmpty,
        let records = sourceRecords[try source.identity(environment: store.environment)]
      else { throw MarketplaceError.contributionMismatch(name) }
      for (_, selected) in selectedUses {
        let matching = records.flatMap { groups[$0] ?? [] }.filter { $0.name == selected }
        guard !matching.isEmpty else { throw MarketplaceError.contributionMismatch(name) }
        selectedGroups.append(contentsOf: matching)
      }
    }

    var pending = selectedGroups.map(\.id)
    var visited = Set<Int>()
    var components = Set<String>()
    var manifests = Set<String>()
    var usedSources = Set<String>()
    while let id = pending.popLast() {
      guard visited.insert(id).inserted else { continue }
      if let group = byGroup[id] {
        manifests.insert(group.manifestHash)
        usedSources.insert(group.source)
        pending.append(contentsOf: group.children)
      } else if let occurrence = byOccurrence[id] {
        components.insert(occurrence.component)
        usedSources.formUnion(occurrence.dependencies)
      }
    }
    guard !components.isEmpty else { throw MarketplaceError.contributionMismatch(name) }
    for id in components {
      guard let component = ledger.components[id], try ResolvedLedgerCodec.digest(component) == id
      else { throw MarketplaceError.contributionMismatch(name) }
      for resourceID in component.resources {
        guard let resource = ledger.resources[resourceID],
          resource.kind == .embedded || resource.kind == .artifact,
          try ResolvedLedgerCodec.digest(resource) == resourceID
        else { throw MarketplaceError.contributionMismatch(name) }
      }
    }
    for id in usedSources {
      guard let source = ledger.sources[id], try ResolvedLedgerCodec.digest(source) == id else {
        throw MarketplaceError.contributionMismatch(name)
      }
    }
    struct Evidence: Encodable {
      let dependency: MarketplaceDependency
      let archiveDigest: String
      let catalogCommit: String?
      let catalogOrigin: SourceOrigin?
      let intent: String
      let components: [String]
      let manifests: [String]
      let sources: [String]
    }
    let ordered = components.sorted()
    return (
      ordered,
      try ResolvedLedgerCodec.digest(
        Evidence(
          dependency: dependency, archiveDigest: archiveDigest, catalogCommit: catalogCommit,
          catalogOrigin: catalogOrigin,
          intent: Self.intentDigest(declaration, aliases: Set(aliases)),
          components: ordered, manifests: manifests.sorted(), sources: usedSources.sorted()))
    )
  }

  static func intentDigest(_ declaration: Declaration, aliases: Set<String>) -> String {
    let bytes = ManifestProjection.marketplaceContributionBytes(declaration, aliases: aliases)
    return "sha256:" + FileHash.sha256Hex(data: Data(bytes))
  }
}
