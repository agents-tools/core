import Foundation

extension EffectiveSourcePolicy {
  /// The admitted lock records source containers and resource dependencies even when replay
  /// uses embedded content. The consumer manifest itself is structural provenance.
  package func violations(
    in ledger: ResolvedLedger, store: StateStore, roots: [String: URL]
  ) throws -> [SourcePolicyViolation] {
    guard isConfigured else { return [] }
    let rootKey = store.scope == .project ? "project" : "state"
    let manifestRoot = LedgerLocation(kind: .registered, root: rootKey, path: ".")
    let declared = Set(ledger.sourceUses.map(\.source))
    let implicit = Set(
      ledger.sources.compactMap { id, source in
        source.kind == .local && source.revision == "live" && source.container == nil
          && source.location == manifestRoot && !declared.contains(id) ? id : nil
      })
    let packageSources = Set(
      (ledger.marketplacePackages ?? []).flatMap { pin in
        pin.componentRecords.compactMap { ledger.components[$0]?.declaringSource }
      })
    var failures: [SourcePolicyViolation] = []
    for (id, source) in ledger.sources.sorted(by: { $0.key < $1.key }) {
      try Task.checkCancellation()
      guard source.container == nil, !implicit.contains(id) else { continue }
      if source.kind == .local, let location = source.location,
        BundleSourceLocation.container(of: try location.resolve(roots: roots), in: store) != nil
      {
        failures += bundleViolations(source.bundleSources ?? [], reference: id)
        continue
      }
      let origin: SourceOrigin
      switch source.kind {
      case .git: origin = source.transport.flatMap { try? .git($0) } ?? .missing
      case .wellKnown: origin = source.transport.flatMap { try? .http($0) } ?? .missing
      case .local:
        origin =
          packageSources.contains(id)
          ? .missing
          : try source.location.map { .local(at: try $0.resolve(roots: roots)) } ?? .missing
      }
      failures += violations(for: origin, reference: id)
      if let archive = source.archive {
        let destination = try SourceOrigin.http(archive.effectiveURL.absoluteString)
        failures += violations(for: destination, reference: id)
      }
    }
    let ownRoot = store.scope == .project ? store.environment.projectDirectory : store.directory
    for (id, resource) in ledger.resources.sorted(by: { $0.key < $1.key }) {
      try Task.checkCancellation()
      if implicit.contains(resource.source) {
        failures += violations(for: .local(at: ownRoot), reference: id)
      }
      if let artifact = resource.artifact {
        let origins = EffectiveSourcePolicy.artifactOrigins(artifact)
        var seen = Set<SourceOrigin>()
        for origin in origins where seen.insert(origin).inserted {
          failures += violations(for: origin, reference: id)
        }
      }
    }
    for (id, component) in ledger.components.sorted(by: { $0.key < $1.key }) {
      try Task.checkCancellation()
      if let registry = component.mcpRegistry {
        for origin in registry.origins {
          failures += violations(for: origin, reference: id)
        }
      } else if implicit.contains(component.source),
        component.kind != DeclaredComponentKind.instructions.rawValue,
        component.kind != DeclaredComponentKind.skills.rawValue
      {
        failures += violations(for: .inline, reference: id)
      }
    }
    for pin in ledger.marketplacePackages ?? [] {
      failures += violations(
        for: try pin.policyOrigin(environment: store.environment), reference: pin.dependency.name)
    }
    for node in ledger.marketplaceGraph?.nodes ?? [] {
      let origins =
        try node.hostedEvidence.map { evidence in
          try Set(evidence.requests.map { try SourceOrigin.http($0.absoluteString) })
        } ?? [node.id.catalog.origin]
      for origin in origins.sorted(by: { $0.description < $1.description }) {
        failures += violations(for: origin, reference: node.id.description)
      }
    }
    return failures
  }

  private func bundleViolations(_ sources: [PortableSourceEvidence], reference: String)
    -> [SourcePolicyViolation]
  {
    let origins = sources.isEmpty ? [.missing] : sources.map(\.policyOrigin)
    var seen = Set<SourceOrigin>()
    return origins.filter { seen.insert($0).inserted }.flatMap {
      violations(for: $0, reference: reference)
    }
  }

  package func requireBundleSources(_ sources: [PortableSourceEvidence], reference: String) throws {
    guard isConfigured else { return }
    let failures = bundleViolations(sources, reference: reference)
    guard failures.isEmpty else { throw SourcePolicyFailure(violations: failures) }
  }

  package func require(_ ledger: ResolvedLedger, store: StateStore, roots: [String: URL]) throws {
    let failures = try violations(in: ledger, store: store, roots: roots)
    guard failures.isEmpty else { throw SourcePolicyFailure(violations: failures) }
    let environment = store.environment
    let access = try environment.resolvedSourceAccess()
    for source in ledger.sources.values where source.container == nil {
      if source.kind == .git, let transport = source.transport {
        let route = try SourceRoute(
          SourceDeclaration(kind: .git, location: transport), environment: environment, policy: self
        )
        _ = try route.requireRecordedArchive(source.archive)
      } else if source.kind == .wellKnown, let transport = source.transport,
        let url = URL(string: transport)
      {
        try access.requireDirectHTTP(url, policy: self)
      }
    }
    guard access.egress == .proxyOnly else { return }
    try environment.requireMCPRegistryRoutes(in: ledger)
    if ledger.resources.values.contains(where: { $0.artifact != nil })
      || (ledger.marketplacePackages ?? []).contains(where: {
        $0.dependency.catalog.kind != .directory
      })
      || (ledger.marketplaceGraph?.nodes ?? []).contains(where: {
        $0.id.catalog.kind != .directory
      })
    {
      throw SourceAccessError.egressDenied
    }
  }
}
