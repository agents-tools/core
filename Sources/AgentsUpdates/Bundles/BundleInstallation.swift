import AgentsCore
import AgentsManifest
import Components
import Foundation

struct BundleInstallation: Sendable {
  struct Member: Sendable {
    let key: String
    let item: BundleItem
    let targets: Set<AgentID>
    let stagedContainer: URL
    let container: URL
    var marketplaceNode: MarketplaceNodeID? = nil

    var source: URL { container.appendingPathComponent(BundleSourceLocation.tree) }
    var identity: String { "local:" + source.path }
    var alias: String {
      (marketplaceNode == nil ? "bundle-" : MarketplaceResolvedNode.sourceAliasPrefix) + key
    }
  }

  static let groupName = "bundle"
  let members: [Member]
  let archiveDigest: String?
  let policyFindings: [OrganizationPolicyFinding]
  let organizationPolicy: OrganizationPolicySnapshot
  private let store: StateStore

  static func withStagedSources<T>(
    _ bundle: BundleInspection, selections: [BundleImportSelection], store: StateStore,
    marketplace: VerifiedMarketplacePackage? = nil, _ body: (Self) throws -> T
  ) throws -> T {
    let legacy = try marketplace.map { item in
      MarketplaceNodeID(
        catalog: MarketplaceCatalogID(item.release.origin, origin: try item.release.policyOrigin()),
        package: item.release.coordinate.package)
    }
    return try withStagedSources(
      [.init(bundle: bundle, selections: selections, legacyCatalogPackage: legacy)],
      store: store, archiveDigest: bundle.archiveDigest, body)
  }

  struct Input {
    let bundle: BundleInspection
    let selections: [BundleImportSelection]
    var node: MarketplaceResolvedNode? = nil
    var legacyCatalogPackage: MarketplaceNodeID? = nil
  }

  static func withStagedSources<T>(
    _ inputs: [Input], store: StateStore, archiveDigest: String? = nil,
    organizationPolicy: OrganizationPolicySnapshot? = nil,
    _ body: (Self) throws -> T
  ) throws -> T {
    let policy = try SourcePolicySnapshot(store: store)
    let organization = try organizationPolicy ?? OrganizationPolicySnapshot(store: store)
    let findings = try inputs.flatMap { try policyFindings($0, evaluator: organization.evaluator) }
    try organization.admit(findings)
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-bundle-" + UUID().uuidString)
    if !inputs.isEmpty { try FileSystem.createDirectory(at: workspace) }
    defer { try? FileManager.default.removeItem(at: workspace) }
    let members = try inputs.flatMap {
      try stage($0, workspace: workspace, store: store, policy: policy, organization: organization)
    }
    guard Set(members.map(\.identity)).count == members.count else {
      throw CoreError.invalidSource("duplicate bundle producer")
    }
    try policy.validate()
    return try body(
      Self(
        members: members, archiveDigest: archiveDigest, policyFindings: findings,
        organizationPolicy: organization, store: store))
  }

  private static func policyFindings(
    _ input: Input, evaluator: OrganizationPolicyEvaluator
  ) throws -> [OrganizationPolicyFinding] {
    guard evaluator.active else { return [] }
    let bundle = input.bundle
    let catalogPackage = input.node?.id ?? input.legacyCatalogPackage
    let identity =
      catalogPackage.map(OrganizationPolicyIdentity.init) ?? .localBundle(bundle.package.name)
    let selected = Set(input.selections.map(\.componentID))
    var findings =
      catalogPackage.map { evaluator.marketplace($0) }
      ?? evaluator.packageIdentity(identity, requireAllow: false)
    for item in bundle.archive.manifest.components {
      let sources = try item.installationSources()
      for source in sources {
        findings += evaluator.source(
          source.policyOrigin, root: source.root, path: [identity.description, item.name])
        if source.packageName != nil {
          findings += evaluator.recordedBundlePackage(source, path: [identity.description])
        } else if catalogPackage == nil, source.policyOrigin != .inline {
          findings += evaluator.packageIdentity(
            .init(source.policyOrigin, root: source.root), path: [identity.description])
        }
      }
      if try selected.contains(item.id), item.entries.contains(where: \.executable) {
        findings += evaluator.executable(identity, name: item.name)
      }
    }
    return findings
  }

  private static func stage(
    _ input: Input, workspace: URL, store: StateStore, policy: SourcePolicySnapshot,
    organization: OrganizationPolicySnapshot
  ) throws -> [Member] {
    let bundle = input.bundle
    let catalog: [BundleSourceEvidence] =
      try input.node.map { node in
        try policy.effective.require(node.id.catalog.origin, reference: node.id.description)
        if let hosted = node.hostedEvidence {
          try HostedMarketplaceReader.requireRequests(
            hosted.requests, index: HostedMarketplaceLocation(node.catalog.location),
            coordinate: node.coordinate, policy: policy.effective, organization: organization)
        }
        return try BundlePackageProvenance.capture(node)
      } ?? []
    let inventory = Dictionary(uniqueKeysWithValues: bundle.components.map { ($0.id, $0) })
    var requested: [String: Set<AgentID>] = [:]
    for selection in input.selections {
      guard let component = inventory[selection.componentID],
        requested[selection.componentID] == nil, !selection.targets.isEmpty,
        Set(selection.targets).count == selection.targets.count
      else { throw CoreError.invalidSource("select each bundle member and its targets once") }
      let supported = Set(component.supportedTargets(in: store.scope))
      for agent in selection.targets {
        guard supported.contains(agent) else {
          throw CoreError.unsupported(
            "bundle member \(component.name) cannot target \(agent.rawValue)")
        }
      }
      requested[selection.componentID] = Set(selection.targets)
    }
    guard !requested.isEmpty else {
      throw CoreError.invalidSource("select at least one bundle member")
    }
    for item in bundle.archive.manifest.components where try requested[item.id] != nil {
      try policy.effective.requireBundleSources(item.installationSources(), reference: item.name)
      for origin in item.mcpRegistry?.origins ?? [] {
        try policy.effective.require(origin, reference: item.name)
      }
    }
    let stored = store.directory.appendingPathComponent(BundleSourceLocation.directory)
    var members: [Member] = []
    for item in bundle.archive.manifest.components {
      try Task.checkCancellation()
      let id = try item.id
      guard let targets = requested[id] else { continue }
      let staging = workspace.appendingPathComponent(UUID().uuidString)
      let tree = staging.appendingPathComponent(BundleSourceLocation.tree)
      try LedgerResources.materialize(
        item.resource, objects: bundle.archive.contentObjects, at: tree)
      let declaration = try item.producerDeclaration(targets: targets)
      let manifest = tree.appendingPathComponent(".agent/agents.yaml")
      let bytes = try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: declaration, in: nil, identity: .init(manifest.path),
        environment: RuntimeEnvironment(projectDirectory: tree, environment: [:]))
      guard let bytes else { throw CoreError.invalidSource("empty bundled declaration") }
      try FileSystem.createDirectory(at: manifest.deletingLastPathComponent())
      try FileSystem.write(Data(bytes), to: manifest)
      var sources = try item.installationSources()
      sources += catalog.filter { !sources.contains($0) }
      let seal = try BundleStoredSource(
        package: .init(name: bundle.package.name, version: bundle.package.version),
        componentID: id, sources: sources, treeDigest: BundleStoredSource.digest(tree),
        marketplaceNode: input.node?.id)
      let marker = try ResolvedLedgerCodec.bytes(seal)
      let key = String(BundleArchive.digest(marker).dropFirst(7))
      try FileSystem.write(marker, to: staging.appendingPathComponent(BundleStoredSource.filename))
      let staged = workspace.appendingPathComponent(key)
      try FileManager.default.moveItem(at: staging, to: staged)
      members.append(
        Member(
          key: key, item: item, targets: targets, stagedContainer: staged,
          container: stored.appendingPathComponent(key), marketplaceNode: input.node?.id))
    }
    return members
  }

  /// The seal binds marketplace provenance to the tree even if the installed package is
  /// subsequently exported or the stored producer is selected outside the dependency.
  func recordingCatalog(_ catalog: [PortableSourceEvidence], observedOrigin: SourceOrigin) throws
    -> Self
  {
    let policy = try SourcePolicySnapshot(store: store)
    try policy.effective.require(observedOrigin)
    let sealed = try members.map { member in
      let original = try BundleStoredSource.read(member.stagedContainer)
      try policy.effective.requireBundleSources(original.sources, reference: member.item.name)
      let additions = catalog.filter { !original.sources.contains($0) }
      guard !additions.isEmpty else { return member }
      let marker = try ResolvedLedgerCodec.bytes(additions.reduce(original) { $0.recording($1) })
      let key = FileHash.sha256Hex(data: marker)
      let parent = member.stagedContainer.deletingLastPathComponent()
      let staged = parent.appendingPathComponent(key)
      if FileManager.default.fileExists(atPath: staged.path) {
        _ = try BundleStoredSource.read(staged)
      } else {
        let temporary = parent.appendingPathComponent(UUID().uuidString)
        try FileSystem.createDirectory(at: temporary)
        let tree = BundleSourceLocation.tree
        try FileManager.default.copyItem(
          at: member.stagedContainer.appendingPathComponent(tree),
          to: temporary.appendingPathComponent(tree))
        try FileSystem.write(
          marker, to: temporary.appendingPathComponent(BundleStoredSource.filename))
        try FileManager.default.moveItem(at: temporary, to: staged)
      }
      return Member(
        key: key, item: member.item, targets: member.targets, stagedContainer: staged,
        container: member.container.deletingLastPathComponent().appendingPathComponent(key))
    }
    try policy.validate()
    return Self(
      members: sealed, archiveDigest: archiveDigest, policyFindings: policyFindings,
      organizationPolicy: organizationPolicy, store: store)
  }

  var stagedContainers: [String: URL] {
    Dictionary(
      uniqueKeysWithValues: members.map {
        ($0.identity, $0.stagedContainer)
      })
  }

  func adding(to declaration: Declaration, store: StateStore) throws -> Declaration {
    var candidate = declaration
    for member in members {
      let relative =
        BundleSourceLocation.directory + "/" + member.key + "/" + BundleSourceLocation.tree
      let location = store.scope == .project ? ".agent/" + relative : "~/.agents/" + relative
      if let existing = candidate.sources[member.alias] {
        guard existing.kind == .local, existing.path == nil, existing.requirement == nil,
          try existing.identity(environment: store.environment) == member.identity
        else { throw CoreError.invalidState("bundle source alias conflicts: " + member.alias) }
      } else {
        candidate.sourceDeclarations.append(
          .init(name: member.alias, source: .init(kind: .local, location: location)))
      }
      if let index = candidate.uses.firstIndex(where: {
        $0.name == Self.groupName && $0.source == member.alias
      }) {
        var use = candidate.uses[index]
        var condition = use.condition ?? DeclarationCondition()
        if let existing = condition.agents {
          condition.agents = Set(existing).union(member.targets).sorted {
            $0.rawValue < $1.rawValue
          }
          use.condition = condition
          candidate.uses[index] = use
        }
      } else {
        candidate.uses.append(
          .init(
            name: Self.groupName, source: member.alias,
            condition: .init(agents: member.targets.sorted { $0.rawValue < $1.rawValue })))
      }
    }
    return candidate
  }

  func selectedIdentities(_ ledger: ResolvedLedger, roots: [String: URL]) throws -> Set<String> {
    let identities = Set(members.map(\.identity))
    var bySource: [String: Set<AgentID>] = [:]
    var selected = Set<String>()
    for component in ledger.components.values {
      let identity = try ledger.sourceIdentity(component.declaringSource, roots: roots)
      guard identities.contains(identity) else { continue }
      bySource[identity, default: []].formUnion(component.recipients)
      selected.insert(try LedgerImpact.identity(component, ledger: ledger, roots: roots))
    }
    for member in members where !member.targets.isSubset(of: bySource[member.identity] ?? []) {
      throw CoreError.unsupported(
        "producer conditions exclude a selected target for " + member.item.name)
    }
    return selected
  }
}

extension BundleItem {
  fileprivate func producerDeclaration(targets: Set<AgentID>) throws -> Declaration {
    // The sealed tree digest includes the producer manifest. Preserve the existing producer
    // bytes for installs that use the original skill and MCP targets.
    let agents = AgentID.allCases.filter { $0 != .antigravity || targets.contains(.antigravity) }
    let component: ComponentDeclaration
    var sources: [String: SourceDeclaration] = [:]
    switch kind {
    case .instructions:
      sources["unit"] = .init(kind: .local, location: ".", path: discovery!)
      component = .instructions(
        InstructionsDeclaration(agents: AgentID.allCases, sections: ["unit:" + name]))
    case .skills:
      component = .skills(
        source: ".",
        SkillDeclaration(
          select: .names([PathSafety.sanitizeName(name)]), path: discovery,
          agents: agents.filter(\.supportsSkills), mode: .link))
    case .mcpServer:
      component = try .mcpServer(
        name: name, transport: transport(), agents: agents,
        native: native(), registry: mcpRegistry)
    }
    return Declaration(
      sources: sources,
      groups: [.init(name: BundleInstallation.groupName, components: [component])],
      exports: [BundleInstallation.groupName])
  }
}

struct BundleSourceInputs {
  let preconditions: [TargetPrecondition]
  let publications: [Publication]
  let producers: [String: Producer]

  struct Producer {
    let snapshot: SourceSnapshotID
    let contents: URL
    let seal: BundleStoredSource
  }

  struct Publication {
    let contents: URL
    let destination: TargetPrecondition

    func stage(in transaction: FileTransaction) throws {
      try transaction.replace(destination.url, with: .copy(contents), expecting: destination)
    }
  }

  static func capture(
    _ linked: LinkedComponents, session: SourceResolutionSession, store: StateStore,
    staged: [String: URL]
  ) throws -> Self {
    var seen = Set<SourceSnapshotID>()
    var preconditions: [TargetPrecondition] = []
    var publications: [Publication] = []
    var producers: [String: Producer] = [:]
    for item in linked.sourceSnapshots + linked.declaringSnapshots
    where item.container == nil && item.snapshot.source.hasPrefix("local:")
      && seen.insert(item.snapshot).inserted
    {
      let source = URL(fileURLWithPath: String(item.snapshot.source.dropFirst(6)))
      guard let container = BundleSourceLocation.container(of: source, in: store) else { continue }
      let destination = try destination(container, in: store)
      let snapshot = try session.resource(snapshot: item.snapshot, path: ".")
      let producer: BundleStoredSource
      if let selected = staged[item.snapshot.source] {
        let stagedInput = try TargetPrecondition(selected)
        producer = try BundleStoredSource.read(selected, snapshot: snapshot)
        try stagedInput.validate()
        preconditions.append(stagedInput)
        if destination.exists {
          _ = try BundleStoredSource.read(container)
        } else {
          publications.append(.init(contents: selected, destination: destination))
        }
      } else {
        producer = try BundleStoredSource.read(container, snapshot: snapshot)
      }
      guard producer.sources == session.bundleSources[item.snapshot] else {
        throw CoreError.invalidState("bundle source evidence changed during preparation")
      }
      if producer.marketplaceNode != nil {
        let alias = MarketplaceResolvedNode.sourceAliasPrefix + container.lastPathComponent
        producers[alias] = Producer(
          snapshot: item.snapshot,
          contents: staged[item.snapshot.source] ?? container,
          seal: producer)
      }
      try destination.validate()
      preconditions.append(destination)
    }
    return Self(preconditions: preconditions, publications: publications, producers: producers)
  }

  static func destination(_ container: URL, in store: StateStore) throws -> TargetPrecondition {
    let base = store.directory.deletingLastPathComponent()
    let physicalBase = PathSafety.realPath(base.path) ?? base.path
    let expectedParent = URL(fileURLWithPath: physicalBase, isDirectory: true)
      .appendingPathComponent(store.directory.lastPathComponent)
      .appendingPathComponent(BundleSourceLocation.directory)
    let expectedContainer = expectedParent.appendingPathComponent(container.lastPathComponent)
    let destination = try TargetPrecondition(container)
    if destination.exists {
      guard PathSafety.realPath(container.path) == expectedContainer.path,
        PathSafety.realPath(container.appendingPathComponent(BundleSourceLocation.tree).path)
          == expectedContainer.appendingPathComponent(BundleSourceLocation.tree).path
      else { throw CoreError.unsafePath("bundle source storage is not a real scope-owned tree") }
    } else if PathSafety.realPath(container.deletingLastPathComponent().path)
      .map({ $0 != expectedParent.path }) == true
    {
      throw CoreError.unsafePath("bundle source storage escapes the scope")
    }
    return destination
  }
}
