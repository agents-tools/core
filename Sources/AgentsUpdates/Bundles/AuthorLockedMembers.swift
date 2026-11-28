import AgentsCore
import AgentsManifest
import Components
import Foundation

extension AuthorCapture {
  mutating func addLocked(
    _ selection: [MarketplaceMemberKey], store: StateStore, policy: AuthorPackagePolicy
  ) throws {
    guard let bytes = try store.configurationInputBytes(StateStore.resolvedFileName) else {
      throw CoreError.notFound("agents.resolved for selected package dependencies")
    }
    let ledger = try ResolvedLedgerCodec.decode(bytes, limits: .standard)
    let roots = store.ledgerRoots(recordedIn: ledger)
    let bundleRecords = ledger.components.keys.filter { record in
      let component = ledger.components[record]!
      return !component.chatGPT && component.payload.object?["prompt"] == nil
    }
    let available = Dictionary(grouping: bundleRecords) { record in
      let component = ledger.components[record]!
      return MarketplaceMemberKey(
        kind: DeclaredComponentKind(rawValue: component.kind) ?? .plugin,
        name: component.name)
    }
    var requested = Set<String>()
    for member in selection {
      try member.validate()
      guard let matches = available[member], matches.count == 1, let record = matches.first,
        requested.insert(record).inserted
      else {
        throw CoreError.invalidSource(
          "expected one selected locked " + member.kind.rawValue + ": " + member.name)
      }
    }
    let selected = requested
    let ordered = ledger.occurrences.compactMap { occurrence in
      requested.remove(occurrence.component)
    }
    guard requested.isEmpty else {
      throw CoreError.invalidState("selected dependency has no locked occurrence")
    }
    let packageSources = try BundlePackageProvenance.locked(
      for: selected, ledger: ledger, store: store, policy: policy.source.effective,
      organization: policy.organization)
    var resourceIDs = Set<String>()
    var evidence: [String: [BundleSourceEvidence]] = [:]
    for record in ordered {
      let component = ledger.components[record]!
      let resources = component.resources.map { ledger.resources[$0]! }
      for resource in resources {
        guard resource.kind != .liveEdit else {
          throw CoreError.invalidState("cannot pack live dependency: " + component.name)
        }
        try AuthorContentAudit.requirePublishable(resource.path)
        for entry in resource.entries + resource.support {
          try AuthorContentAudit.requirePublishable(entry.path)
        }
      }
      resourceIDs.formUnion(component.resources)
      let sources = try BundleOperations.portableSources(
        for: record, captured: resources, ledger: ledger, roots: roots, store: store,
        lockedOnly: true)
      try policy.admit(sources, member: component.name)
      let portable = try Set(sources + (packageSources[record] ?? [])).map { source in
        if source.policyOrigin.kind == .local, source.policyOrigin.identity != nil {
          return try BundleSourceEvidence(
            origin: source.packageName == nil ? .missing : .local, revision: source.revision,
            version: source.version,
            packageName: source.packageName, root: source.root)
        }
        return source
      }
      let sorted = try BundleOperations.sortedSources(portable)
      try policy.admit(sorted, member: component.name)
      evidence[record] = sorted
    }
    let captured = try LedgerReplay.captureBundleResources(
      resourceIDs, ledger: ledger, store: store, roots: roots, offline: true)
    try absorb(captured.objects)
    for record in ordered {
      let component = ledger.components[record]!
      let directory = try ledger.sources[component.declaringSource]?.location?.resolve(roots: roots)
      let alreadyPortable =
        directory.flatMap { BundleSourceLocation.container(of: $0, in: store) } != nil
      let item = try BundleItem(
        component: component, resources: component.resources.map { captured.resources[$0]! },
        sources: evidence[record]!, alreadyPortable: alreadyPortable)
      let shared = try item.forSharing(registrySchemas: policy.registrySchemas)
      noteOmissions(shared.omissions, name: component.name)
      try append(shared.item)
    }
  }
}
