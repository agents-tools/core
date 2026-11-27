import AgentsCore
import Foundation

enum BundlePackageProvenance {
  static func locked(
    for selected: Set<String>, ledger: ResolvedLedger, store: StateStore,
    policy: EffectiveSourcePolicy, organization: OrganizationPolicySnapshot
  ) throws -> [String: [BundleSourceEvidence]] {
    var result: [String: [BundleSourceEvidence]] = [:]
    if let graph = ledger.marketplaceGraph {
      let byNode = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
      var recorded: [MarketplaceNodeID: [BundleSourceEvidence]] = [:]
      for node in graph.nodes where node.componentRecords.contains(where: selected.contains) {
        var sources: [BundleSourceEvidence] = []
        for id in graph.reachable(from: node.id).sorted(by: MarketplaceNodeID.ordered) {
          if let evidence = recorded[id] {
            sources += evidence
            continue
          }
          let dependency = byNode[id]!
          let evaluator = organization.evaluator
          try policy.require(id.catalog.origin, reference: id.package)
          try organization.admit(evaluator.marketplace(id))
          if let override = dependency.organizationRequirements {
            let active = evaluator.marketplaceRequirements(for: id)
            guard active.overrides, active.constraints == override else {
              throw CoreError.invalidState(
                "locked dependency needs matching organization policy: " + id.package)
            }
          }
          if dependency.catalog.kind == .hosted {
            try MarketplaceGraphChange.validateHosted(
              dependency, archive: ledger.contentObjects[dependency.archiveDigest], policy: policy,
              organizationPolicy: organization)
          }
          let evidence = try capture(dependency)
          recorded[id] = evidence
          sources += evidence
        }
        for record in node.componentRecords where selected.contains(record) {
          result[record, default: []] += sources
        }
      }
    }
    for pin in ledger.marketplacePackages ?? []
    where pin.componentRecords.contains(where: selected.contains) {
      let origin = try pin.policyOrigin(environment: store.marketplaceEnvironment)
      let name = pin.dependency.coordinate.package
      let root = pin.dependency.catalog.policyPath
      try policy.require(origin, reference: name)
      try organization.admit(
        organization.evaluator.packageIdentity(
          .init(origin, suffix: name, root: root), catalog: .init(origin, root: root)))
      let sources = try release(
        pin.dependency.coordinate, origin: origin, root: root, digest: pin.archiveDigest,
        catalogCommit: pin.catalogCommit)
      for record in pin.componentRecords where selected.contains(record) {
        result[record, default: []] += sources
      }
    }
    return result
  }

  static func capture(_ node: MarketplaceResolvedNode) throws -> [BundleSourceEvidence] {
    var evidence = try release(
      node.coordinate, origin: node.id.catalog.origin, root: node.id.catalog.policyPath,
      digest: node.archiveDigest, catalogCommit: node.catalogCommit)
    if let hosted = node.hostedEvidence {
      let index = try HostedMarketplaceLocation(node.catalog.location)
      for request in hosted.requests where request != index.url {
        let route = try HostedMarketplaceLocation(request.absoluteString)
        evidence.append(
          try .init(
            origin: route.origin, revision: node.archiveDigest, root: route.policyPath))
      }
    }
    return evidence
  }

  static func release(
    _ coordinate: MarketplaceCoordinate, origin: SourceOrigin, root: String?, digest: String,
    catalogCommit: String?
  ) throws -> [BundleSourceEvidence] {
    let catalog = origin == .missing ? .local : origin
    var sources: [BundleSourceEvidence] = [
      try .init(
        origin: catalog, revision: digest, version: coordinate.version,
        packageName: coordinate.package, root: root)
    ]
    if let catalogCommit {
      sources.append(
        try .init(origin: catalog, revision: catalogCommit, version: coordinate.version, root: root)
      )
    }
    return sources
  }
}
