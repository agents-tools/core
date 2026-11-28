import AgentsCore

/// Converts a portable exact install to root intent when a graph first shares its release.
struct MarketplaceLegacyRoot {
  let pin: MarketplacePin
  let id: MarketplaceNodeID

  init(_ pin: MarketplacePin, store: StateStore) throws {
    self.pin = pin
    let catalog = pin.dependency.catalog
    let origin =
      try pin.catalogOrigin ?? catalog.policyOrigin(environment: store.marketplaceEnvironment)
    id = MarketplaceNodeID(
      catalog: MarketplaceCatalogID(catalog, origin: origin),
      package: pin.dependency.coordinate.package)
  }

  var name: String { pin.dependency.name }

  func intent(in declaration: Declaration, ledger: ResolvedLedger, store: StateStore)
    throws -> MarketplaceRoot
  {
    let roots = store.ledgerRoots(recordedIn: ledger)
    let selections = try pin.sourceAliases.map { alias in
      guard alias.hasPrefix("bundle-"), BundleSourceLocation.isKey(String(alias.dropFirst(7))),
        let source = declaration.sources[alias],
        BundleSourceLocation.container(
          of: source.localURL(environment: store.environment), in: store)
          != nil,
        let use = declaration.uses.first(where: {
          $0.source == alias && $0.name == BundleInstallation.groupName
        }),
        let targets = use.condition?.agents
      else { throw MarketplaceError.selectionMismatch(name + " has a custom exact installation") }
      let identity = try source.identity(environment: store.environment)
      let matches = try pin.componentRecords.compactMap { record -> LedgerComponent? in
        guard let component = ledger.components[record],
          try ledger.sourceIdentity(component.declaringSource, roots: roots) == identity
        else { return nil }
        return component
      }
      guard matches.count == 1, let component = matches.first,
        let kind = DeclaredComponentKind(rawValue: component.kind)
      else { throw MarketplaceError.selectionMismatch(name + " / " + alias) }
      return try MarketplaceMemberSelection(
        package: id.package, member: .init(kind: kind, name: component.name), targets: targets)
    }
    return try MarketplaceRoot(
      name: name, catalog: pin.dependency.catalog, package: id.package,
      requirement: .exact(pin.dependency.coordinate.version), selections: selections)
  }
}
