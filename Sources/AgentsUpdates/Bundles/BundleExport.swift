import AgentsCore
import AgentsInstructions
import AgentsManifest
import Components
import Foundation

public enum BundleOperations {
  /// Exports selections from one committed inspection. Locked inputs are read without rendering,
  /// executing programs or calling a binding provider.
  public static func export(
    _ package: BundlePackage, selections: [ComponentSelection], scope: InstallScope,
    environment: RuntimeEnvironment, registrySchemas: [MCPRegistryServer] = []
  ) throws -> Data {
    try package.validate()
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let policy = try SourcePolicySnapshot(store: store)
      let organization = try OrganizationPolicySnapshot(store: store)
      try organization.admit()
      let document = try store.declarationDocument(prepared: baseline)
      let ledger = try store.readLedger(prepared: baseline)
      let roots = store.ledgerRoots(recordedIn: ledger)
      if organization.evaluator.active {
        let evaluation = try OrganizationInstallEvaluation(
          policy: organization, store: store,
          declaration: store.readDeclaration(prepared: baseline),
          bytes: try baseline.bytes(for: store.declarationURL))
        let known = try (evaluation.beforeAcquisition() + evaluation.closure(ledger, roots: roots))
          .filter { $0.rule == "package-deny" || $0.rule == "dependency-policy-override" }
        try organization.admit(
          known
            + organization.evaluator.packageIdentity(
              .localBundle(package.name), requireAllow: false))
      }
      let generation = try ResolvedLedgerCodec.digest([
        ResolvedLedgerCodec.digest(ledger), document?.digest ?? "absent",
      ])
      guard !selections.isEmpty, selections.allSatisfy({ $0.generation == generation }) else {
        throw CoreError.invalidState("select bundle components from the current scope inspection")
      }
      let inspections = try UpdateOperations.componentInspections(
        ledger, roots: roots, generation: generation)
      let byIdentity = Dictionary(grouping: inspections, by: { $0.selection.identity })
      var selected = Set<String>()
      for selection in selections {
        let matches = (byIdentity[selection.identity] ?? []).filter { component in
          selection.occurrence.map { occurrence in
            component.occurrences.contains { $0.selection.occurrence == occurrence }
          } ?? true
        }
        guard matches.count == 1, let component = matches.first,
          BundleItem.Kind(rawValue: component.kind.rawValue) != nil
        else { throw CoreError.invalidState("ambiguous or unsupported bundle component selection") }
        selected.insert(component.record)
      }
      // The lock's occurrence order is the instruction render order.
      var ordered: [String] = []
      for occurrence in ledger.occurrences where selected.remove(occurrence.component) != nil {
        ordered.append(occurrence.component)
      }
      guard selected.isEmpty else {
        throw CoreError.invalidState("selected bundle member has no occurrence")
      }
      let packageSources = try BundlePackageProvenance.locked(
        for: Set(ordered), ledger: ledger, store: store, policy: policy.effective,
        organization: organization)
      let resources = Set(ordered.flatMap { ledger.components[$0]!.resources })
      let captured = try LedgerReplay.captureBundleResources(
        resources, ledger: ledger, store: store, roots: roots, sourcePolicy: policy.effective)
      var items: [BundleItem] = []
      var itemIDs = Set<String>()
      for id in ordered {
        let component = ledger.components[id]!
        let resources = component.resources.map { captured.resources[$0]! }
        let declaringSource = try ledger.sources[component.declaringSource]?.location?.resolve(
          roots: roots)
        let alreadyPortable =
          declaringSource.flatMap { BundleSourceLocation.container(of: $0, in: store) } != nil
        let producers = try portableSources(
          for: id, captured: resources, ledger: ledger, roots: roots, store: store)
        let item = try BundleItem(
          component: component, resources: resources,
          sources: sortedSources(producers + (packageSources[id] ?? [])),
          alreadyPortable: alreadyPortable)
        try AuthorContentAudit.validatePaths(item.entries)
        let shared = try item.forSharing(registrySchemas: registrySchemas)
        guard shared.omissions == 0 else {
          throw CoreError.invalidSource(
            "MCP \(item.name) has credential-like arguments or overrides; use symbolic bindings before export"
          )
        }
        if itemIDs.insert(try shared.item.id).inserted { items.append(shared.item) }
      }
      let archive = try BundleArchive(
        package: package, components: items, objects: captured.objects)
      let bytes = try ResolvedLedgerCodec.bytes(archive)
      try LedgerAdmission.check(bytes, limits: .standard)
      try baseline.validate()
      try policy.validate()
      try organization.validate()
      return bytes
    }
  }

  /// Validates the complete archive in memory and returns its importable inventory.
  public static func inspect(_ archive: Data) throws -> BundleInspection {
    let wire = try BundleArchive.read(archive)
    return try BundleInspection(
      package: wire.manifest.package, formatVersion: wire.version,
      archiveDigest: BundleArchive.digest(archive),
      components: wire.manifest.components.map { item in
        BundleComponent(
          id: try item.id, kind: DeclaredComponentKind(rawValue: item.kind.rawValue)!,
          name: item.name, sources: item.sources, entries: item.entries,
          configuration: item.configuration.map(UpdateOperations.symbolicValue),
          mcpRegistry: item.mcpRegistry,
          transport: item.kind == .mcpServer ? try item.transport() : nil,
          native: try item.native())
      },
      archive: wire)
  }

  static func portableSources(
    for id: String, captured: [LedgerResource], ledger: ResolvedLedger, roots: [String: URL],
    store: StateStore, lockedOnly: Bool = false
  ) throws -> [BundleSourceEvidence] {
    let component = ledger.components[id]!
    let resourceRecords = component.resources.map { ledger.resources[$0]! }
    let resourceSources = Set(resourceRecords.map(\.source))
    var pending = resourceSources.union([component.source, component.declaringSource])
    for occurrence in ledger.occurrences where occurrence.component == id {
      pending.formUnion(occurrence.dependencies)
    }
    var visited = Set<String>()
    var result = Set<BundleSourceEvidence>()
    if let registry = component.mcpRegistry {
      let revision = try ResolvedLedgerCodec.digest(registry)
      for origin in registry.origins {
        result.insert(try .init(origin: origin, revision: revision, version: registry.version))
      }
    }
    for resource in resourceRecords {
      if let artifact = resource.artifact {
        for origin in EffectiveSourcePolicy.artifactOrigins(artifact) {
          result.insert(try .init(origin: origin, revision: artifact.digest))
        }
      }
    }
    let manifestRoot = LedgerLocation(
      kind: .registered, root: store.scope == .project ? "project" : "state", path: ".")
    let declared = Set(ledger.sourceUses.map(\.source))
    while let id = pending.popFirst() {
      guard visited.insert(id).inserted else { continue }
      let source = ledger.sources[id]!
      if let container = source.container {
        pending.insert(container)
        continue
      }
      if let location = source.location,
        let container = BundleSourceLocation.container(
          of: try location.resolve(roots: roots), in: store)
      {
        // Keep the original producer claims when forwarding a previously imported member.
        if lockedOnly, source.bundleSources == nil {
          throw CoreError.invalidState("missing locked bundle producer evidence: " + component.name)
        }
        let producers = try source.bundleSources ?? BundleStoredSource.read(container).sources
        result.formUnion(producers)
        continue
      }
      let identity: String?
      switch source.kind {
      case .local:
        if component.mcpRegistry != nil, source.revision == "live", source.location == manifestRoot,
          !declared.contains(id), !resourceSources.contains(id)
        {
          continue
        }
        identity = nil
      case .git, .wellKnown: identity = try ledger.sourceIdentity(id, roots: roots)
      }
      let revision: String
      if source.revision == "live" {
        var content = [component.kind, component.name]
        if !lockedOnly, component.kind != BundleItem.Kind.mcpServer.rawValue {
          content.append(try ResolvedLedgerCodec.digest(component.payload))
        }
        revision = try ResolvedLedgerCodec.digest(content + captured.map(\.hash))
      } else {
        revision = source.revision
      }
      let origin: SourceOrigin?
      switch source.kind {
      case .git: origin = try source.transport.map(SourceOrigin.git)
      case .wellKnown:
        origin = try source.transport.map(SourceOrigin.http)
      case .local:
        if component.kind == BundleItem.Kind.mcpServer.rawValue, source.location == manifestRoot,
          !declared.contains(id), !resourceSources.contains(id)
        {
          origin = .inline
        } else {
          if lockedOnly, let location = source.location {
            origin = .local(at: try location.resolve(roots: roots))
          } else {
            origin = .missing
          }
        }
      }
      let version =
        id == component.source && component.mcpRegistry == nil
        ? component.version ?? source.version : source.version
      let root =
        lockedOnly && id == component.source && component.root != "." ? component.root : nil
      if source.kind == .wellKnown,
        identity.flatMap({ URLComponents(string: $0)?.query }) != nil,
        let origin
      {
        result.insert(try .init(origin: origin, revision: revision, version: version, root: root))
      } else {
        result.insert(
          .init(
            kind: source.kind, identity: identity, revision: revision, version: version,
            origin: origin, root: root))
      }
    }
    if let url = component.payload.object?["transport"]?.object?["url"]?.text {
      let origin = (try? SourceOrigin.http(url)) ?? .missing
      if !result.contains(where: { $0.policyOrigin == origin }) {
        result.insert(try .init(origin: origin, revision: ResolvedLedgerCodec.digest(origin)))
      }
    }
    return try sortedSources(result)
  }

  static func sortedSources<S: Sequence>(_ sources: S) throws -> [BundleSourceEvidence]
  where S.Element == BundleSourceEvidence {
    try Set(sources).map { (try ResolvedLedgerCodec.bytes($0), $0) }
      .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 }
  }
}

extension BundleItem {
  init(
    component: LedgerComponent, resources: [LedgerResource], sources: [BundleSourceEvidence],
    alreadyPortable: Bool
  ) throws {
    let kind = Kind(rawValue: component.kind)!
    let name = component.name
    var tree = BundleTree()
    var discovery: String?
    var configuration: LedgerValue?
    let root = alreadyPortable ? "." : "payload"
    switch kind {
    case .instructions:
      guard !component.chatGPT, component.payload.object?["prompt"] == nil,
        let first = resources.first
      else { throw CoreError.invalidSource("select an installed instruction section") }
      let section = try tree.add(first, under: root)
      for resource in resources.dropFirst() { _ = try tree.add(resource, under: root) }
      discovery = InstructionSnapshotReader.searchRoots(of: section, name: name).first(where: {
        $0 == "payload" || $0.hasPrefix("payload/")
      })
    case .skills:
      guard resources.count == 1, let skill = resources.first else {
        throw CoreError.invalidSource("bundle skill must have one complete tree")
      }
      discovery = try tree.add(skill, under: root)
    case .mcpServer:
      let transport = try MCPConnectionOperations.managedTransport(component.payload)
      guard var fields = component.payload.object?["transport"]?.object,
        let native = component.payload.object?["native"]
      else { throw CoreError.invalidSource("missing locked MCP configuration") }
      var index = 0
      func addResource() throws -> String {
        guard index < resources.count else {
          throw CoreError.invalidSource("missing bundle MCP resource")
        }
        defer { index += 1 }
        let prefix = alreadyPortable ? "." : "payload/resource-\(index)"
        return try tree.add(resources[index], under: prefix)
      }
      if case .stdio(let run) = transport {
        var invocation = fields["run"]!.object!
        invocation.removeValue(forKey: "executableSource")
        if run.executable.contains("/") { invocation["executable"] = try .init(addResource()) }
        if run.workingDirectory != nil {
          invocation["workingDirectory"] = try .init(object: ["path": .init(addResource())])
        }
        fields["run"] = .init(object: invocation)
      }
      guard index == resources.count else {
        throw CoreError.invalidSource("unexpected MCP resources in bundle")
      }
      configuration = .init(object: ["transport": .init(object: fields), "native": native])
    }
    self.init(
      kind: kind, name: name, sources: sources,
      entries: tree.entries.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
      discovery: discovery, configuration: configuration, mcpRegistry: component.mcpRegistry)
  }
}

struct BundleTree: Sendable {
  var entries = [".": LedgerEntry(path: ".", kind: .directory, executable: false)]

  var sortedEntries: [LedgerEntry] {
    entries.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
  }

  mutating func insert(_ entry: LedgerEntry) throws {
    if entry.path != "." { try BundleItem.validatePath(entry.path) }
    let parts = entry.path.split(separator: "/")
    for depth in 1..<parts.count {
      let path = parts.prefix(depth).joined(separator: "/")
      if let existing = entries[path] {
        guard existing.kind == .directory, existing.path.utf8.elementsEqual(path.utf8) else {
          throw CoreError.invalidSource("conflicting bundle resource directories")
        }
      } else {
        entries[path] = .init(path: path, kind: .directory, executable: false)
      }
    }
    guard
      entries[entry.path].map({
        $0 == entry && $0.path.utf8.elementsEqual(entry.path.utf8)
      }) ?? true
    else { throw CoreError.invalidSource("conflicting bundle resource paths") }
    entries[entry.path] = entry
  }

  mutating func add(_ resource: LedgerResource, under prefix: String) throws -> String {
    func joined(_ root: String, _ path: String) -> String {
      if root == "." { return path }
      return path == "." ? root : root + "/" + path
    }
    let selected = joined(prefix, resource.path)
    let base = resource.support.isEmpty ? selected : prefix
    for original in try LedgerResources.validatedEntries(resource).values {
      var entry = original
      entry.path = joined(base, original.path)
      try insert(entry)
    }
    return selected
  }
}
