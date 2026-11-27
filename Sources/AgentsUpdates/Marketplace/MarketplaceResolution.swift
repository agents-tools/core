import AgentsCore
import AgentsManifest
import Foundation

public enum MarketplaceResolutionRequest: Sendable {
  /// Resolve authored roots, including an edited declaration or a missing lock.
  case reconcile
  /// Add or edit a root, retaining locked versions that satisfy the resulting graph.
  case install(MarketplaceRoot)
  /// Prefer newer releases within the named root's constraints and reachable packages.
  /// Supplied intent replaces the corresponding part of the existing root in the same preview.
  case upgrade(
    String, requirement: SourceRequirement? = nil,
    selections: [MarketplaceMemberSelection]? = nil
  )
  /// Drop one root and its selected recipients, using the installed graph.
  case remove(String)
}

public struct MarketplaceNodeVersions: Equatable, Sendable {
  public let node: MarketplaceNodeID
  public let locked: MarketplaceCoordinate?
  /// The jointly eligible release selected by this resolution's lock and upgrade preferences.
  public let eligible: MarketplaceCoordinate
  /// Highest published precedence, including versions outside the incoming constraints.
  public let latest: MarketplaceCoordinate?
}

public struct MarketplaceResolutionNode: Sendable {
  public let versions: MarketplaceNodeVersions
  public let catalog: MarketplaceOrigin
  public let dependencies: [MarketplaceResolvedEdge]
  /// Available members of the selected release. Nil means its archive was unavailable or
  /// the operation uses only the frozen installation.
  public let availableMembers: [BundleComponent]?
}

/// Read-only release and member discovery. Select members using their logical kind and name.
public struct MarketplaceResolution: Sendable {
  public let roots: [MarketplaceResolvedRoot]
  public let nodes: [MarketplaceResolutionNode]
}

public struct MarketplaceResolutionPreview: Sendable {
  public let resolution: MarketplaceResolution
  public let report: CombinedUpdateReport
  public let ownershipConflict: String?
  fileprivate let request: MarketplaceResolutionRequest
  fileprivate let environment: RuntimeEnvironment
  fileprivate let replace: Bool
  fileprivate let captured: MarketplacePreparation?
  fileprivate let observationDigest: String
  fileprivate let stateDigest: String
  fileprivate let policyFingerprint: String
  fileprivate let organization: OrganizationPolicySnapshot
  fileprivate let routes: Set<NativeTargetRoute>
  fileprivate let installations: [String: SkillInstallationTarget]
}

extension MarketplaceOperations {
  /// Discovers the dependency graph and available members without preparing native outputs.
  public static func resolve(
    _ request: MarketplaceResolutionRequest = .reconcile, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> MarketplaceResolution {
    try MarketplacePreparation(
      request, store: StateStore(scope: scope, environment: environment),
      usingPendingResolution: true, hostedAccess: hostedAccess
    ).resolution
  }

  /// Composes a scoped update for every selected member and root in the resolution.
  public static func previewResolution(
    _ request: MarketplaceResolutionRequest = .reconcile, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(), replace: Bool = false,
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> MarketplaceResolutionPreview {
    let store = StateStore(scope: scope, environment: environment)
    let plan = try MarketplacePreparation(request, store: store, hostedAccess: hostedAccess)
    return try plan.withUpdateRequest(store: store, replace: replace) { update in
      let (report, conflict, routes, installations) = try UpdateOperations.previewWithOwnership(
        update, scope: scope, environment: environment, organizationPolicy: plan.organizationPolicy)
      return MarketplaceResolutionPreview(
        resolution: plan.resolution, report: report, ownershipConflict: conflict,
        request: request, environment: environment, replace: replace,
        captured: plan.usesHostedCatalog ? plan : nil,
        observationDigest: plan.solution.observationDigest, stateDigest: plan.stateDigest,
        policyFingerprint: plan.policyFingerprint, organization: plan.organizationPolicy,
        routes: routes,
        installations: installations)
    }
  }

  public static func previewResolutionLifecycle(
    _ request: MarketplaceResolutionRequest = .reconcile, intent: LifecycleOperationIntent,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    replace: Bool = false, hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> LifecyclePackageReview<MarketplaceResolutionPreview, UpdateApplyResult> {
    let context = LifecycleContext(scope: scope, environment: environment)
    let (discovery, root) = try context.capturePackageRoot()
    let preview = try previewResolution(
      request, scope: scope, environment: environment, replace: replace, hostedAccess: hostedAccess)
    let plan = try context.packagePlan(
      intent: intent, discovery: discovery, snapshot: preview.organization,
      findings: preview.report.organizationPolicy, ownershipConflict: preview.ownershipConflict
    ) { snapshot in
      let current = try previewResolution(
        request, scope: scope, environment: environment, replace: replace,
        hostedAccess: hostedAccess)
      try snapshot.requireSameLifecyclePolicy(as: current.organization)
      if let conflict = current.ownershipConflict { throw CoreError.invalidState(conflict) }
    }
    return LifecyclePackageReview(
      report: preview, lifecycle: plan.inspection, ownershipConflict: preview.ownershipConflict,
      plan: plan
    ) { provider in
      performResolution(preview, bindingProvider: provider, existingRoot: root) {
        try $0.apply(ifUnchangedFrom: preview.report.displayedFingerprint)
      }
    }
  }

  /// Re-prepares the displayed candidate and runs the scope's recoverable transaction in
  /// the same-thread closure. Hosted resolutions use the verified bytes captured by the preview.
  public static func withPreparedResolution<Result>(
    _ preview: MarketplaceResolutionPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try prepareResolution(preview, bindingProvider: bindingProvider, checkpoint: { _ in }, body)
  }

  /// Reports the durable outcome after publication, recovery and scope cleanup have returned.
  public static func performResolution<Value>(
    _ preview: MarketplaceResolutionPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    performResolution(preview, bindingProvider: bindingProvider, existingRoot: nil, body)
  }

  static func performResolution<Value>(
    _ preview: MarketplaceResolutionPreview, bindingProvider: (any RuntimeBindingProvider)?,
    existingRoot: ExistingProjectRoot?, _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    var outcome = TransactionOutcome()
    var delivered = false
    let result = Result {
      try prepareResolution(
        preview, bindingProvider: bindingProvider, checkpoint: { _ in },
        completion: { outcome = $0 }, existingRoot: existingRoot
      ) { update in
        delivered = true
        return try body(update)
      }
    }
    var recovered = false
    if !delivered, case .failure(let error) = result,
      case CoreError.transactionRecovered = (error as? UpdateApplyError)?.underlyingError ?? error
    {
      recovered = true
    }
    return UpdateOperations.completion(
      result, outcome: outcome, recovered: recovered,
      store: StateStore(scope: preview.report.scope, environment: preview.environment))
  }

  package static func prepareResolution<Result>(
    _ preview: MarketplaceResolutionPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    checkpoint: @escaping (String) throws -> Void,
    completion: ((TransactionOutcome) -> Void)? = nil, existingRoot: ExistingProjectRoot? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    if let conflict = preview.ownershipConflict { throw CoreError.invalidState(conflict) }
    let environment = preview.environment
    let scope = preview.report.scope
    let store = StateStore(scope: scope, environment: environment)
    let plan: MarketplacePreparation
    do {
      if let captured = preview.captured {
        plan = try captured.revalidating(in: store)
      } else {
        plan = try MarketplacePreparation(preview.request, store: store)
      }
    } catch let error as CoreError {
      guard case .recoveryPending = error else { throw error }
      try store.withLock(checkpoint: checkpoint, existingRoot: existingRoot) {}
      throw error
    }
    guard plan.stateDigest == preview.stateDigest,
      plan.policyFingerprint == preview.policyFingerprint
    else {
      throw CoreError.invalidState(
        "marketplace scope or source policy changed; refresh the preview")
    }
    guard plan.solution.observationDigest == preview.observationDigest else {
      throw CoreError.invalidState("marketplace catalog changed; refresh the preview")
    }
    return try plan.withUpdateRequest(store: store, replace: preview.replace) { update in
      try UpdateOperations.prepare(
        update, scope: scope, environment: environment, checkpoint: checkpoint,
        provider: bindingProvider ?? RequiredBindingProvider(), completion: completion,
        admittedRoutes: preview.routes, admittedInstallations: preview.installations,
        admittedOrganizationPolicy: plan.organizationPolicy, existingRoot: existingRoot
      ) { prepared in
        guard prepared.report.displayedFingerprint == preview.report.displayedFingerprint else {
          throw CoreError.invalidState("marketplace destination changed; refresh the preview")
        }
        return try body(prepared)
      }
    }
  }
}

struct MarketplacePreparation: Sendable {
  let solution: MarketplaceSolution
  let stateDigest: String
  let policyFingerprint: String
  let organizationPolicy: OrganizationPolicySnapshot
  private let priorDesired: ResolvedLedger?
  let usesHostedCatalog: Bool
  private let generation: [TargetPrecondition]

  private init(captured: Self, organizationPolicy: OrganizationPolicySnapshot) {
    priorDesired = captured.priorDesired
    solution = captured.solution
    stateDigest = captured.stateDigest
    policyFingerprint = captured.policyFingerprint
    usesHostedCatalog = captured.usesHostedCatalog
    generation = captured.generation
    self.organizationPolicy = organizationPolicy
  }

  func revalidating(in store: StateStore) throws -> Self {
    let organization = try OrganizationPolicySnapshot(
      store: store, offlineObservations: organizationPolicy)
    try organization.admit()
    try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let sourcePolicy = try SourcePolicySnapshot(store: store)
      try MarketplaceGraphChange(
        graph: nil, stateDigest: stateDigest, policyFingerprint: policyFingerprint,
        directoryInputs: [], promotedLegacy: [], hostedArchives: [:], hostedGeneration: generation
      ).validate(baseline, policy: sourcePolicy, organizationPolicy: organization, store: store)
      try baseline.validate()
      try sourcePolicy.validate()
    }
    return Self(captured: self, organizationPolicy: organization)
  }

  init(
    _ request: MarketplaceResolutionRequest, store: StateStore,
    usingPendingResolution: Bool = false, hostedAccess: HostedMarketplaceAccess? = nil
  ) throws {
    organizationPolicy = try OrganizationPolicySnapshot(store: store)
    try organizationPolicy.admit()
    let (declaration, deployed, policy, starting, stateDigest, declarationBytes) =
      try store.withReadLock {
        let baseline = try StatePrecondition(store: store)
        let declaration = try store.readDeclaration(prepared: baseline)
        let previous = try store.readLedger(prepared: baseline)
        if previous.pendingDeployment != nil, !usingPendingResolution {
          throw MarketplaceError.pendingDeployment
        }
        try MarketplaceChanges.validate(
          declaration, matching: previous.pendingDeployment?.desired(in: previous) ?? previous,
          in: store, allowingGraphReconciliation: true)
        let generation = try MarketplaceGraphChange.stateDigest(in: baseline, store: store)
        let policy = try SourcePolicySnapshot(store: store)
        try baseline.validate()
        let starting = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
          try baseline.evidence(for: $0)
        }
        return (
          declaration, previous, policy, starting, generation,
          try baseline.bytes(for: store.declarationURL)
        )
      }
    priorDesired = try deployed.pendingDeployment?.desired(in: deployed)
    let previous = priorDesired ?? deployed
    self.stateDigest = stateDigest
    self.generation = starting
    policyFingerprint = try ResolvedLedgerCodec.digest([
      policy.fingerprint, organizationPolicy.fingerprint,
    ])

    var roots = declaration.marketplaceRoots
    var upgrading: String?
    switch request {
    case .install(let root):
      if let index = roots.firstIndex(where: { $0.name == root.name }) {
        roots[index] = root
      } else {
        roots.append(root)
      }
    case .upgrade(let name, let requirement, let selections):
      let existing: MarketplaceRoot
      let index = roots.firstIndex(where: { $0.name == name })
      if let index {
        existing = roots[index]
      } else if let pin = previous.marketplacePackages?.first(where: { $0.dependency.name == name })
      {
        existing = try MarketplaceLegacyRoot(pin, store: store).intent(
          in: declaration, ledger: previous, store: store)
      } else {
        throw MarketplaceError.missingPin(name)
      }
      let root = try MarketplaceRoot(
        name: name, catalog: existing.catalog, package: existing.package,
        requirement: requirement ?? existing.requirement,
        selections: selections ?? existing.selections)
      if let index {
        roots[index] = root
      } else {
        roots.append(root)
      }
      upgrading = name
    case .remove(let name):
      try MarketplaceGraphChange.validate(declaration, matching: previous, store: store)
      guard let graph = previous.marketplaceGraph,
        graph.roots.contains(where: { $0.intent.name == name })
      else { throw MarketplaceError.missingPin(name) }
      let roots = graph.roots.filter { $0.intent.name != name }
      var retained = Set<MarketplaceNodeID>()
      for root in roots { retained.formUnion(graph.reachable(from: root.node)) }
      let remaining = MarketplaceGraph(
        roots: roots,
        nodes: graph.nodes.filter {
          retained.contains($0.id)
        })
      usesHostedCatalog = graph.nodes.contains { $0.hostedEvidence != nil }
      solution = MarketplaceSolution(
        graph: remaining, bundles: [:],
        versions: remaining.nodes.map {
          MarketplaceNodeVersions(
            node: $0.id, locked: $0.coordinate, eligible: $0.coordinate, latest: nil)
        }, observationDigest: "",
        hostedArchives: Dictionary(
          remaining.nodes.compactMap { node in
            guard node.hostedEvidence != nil,
              let bytes = previous.contentObjects[node.archiveDigest]
            else { return nil }
            return (node.archiveDigest, bytes)
          }, uniquingKeysWith: { first, _ in first }))
      return
    case .reconcile:
      break
    }

    if organizationPolicy.evaluator.active {
      var prospective = declaration
      prospective.marketplaceRoots = roots
      let bytes = try DeclarationEditPlan.bytes(
        replacing: declaration, with: prospective, in: declarationBytes.map { Array($0) },
        identity: .init(store.declarationURL.path), environment: store.environment)
      let evaluation = try OrganizationInstallEvaluation(
        policy: organizationPolicy, store: store, declaration: prospective,
        bytes: bytes.map { Data($0) } ?? declarationBytes)
      try organizationPolicy.admit(evaluation.beforeAcquisition())
    }
    solution = try MarketplaceSolver(
      store: store, policy: policy, organizationPolicy: organizationPolicy,
      declaration: declaration, previous: previous,
      updatingRoot: upgrading, hostedAccess: hostedAccess
    ).solve(roots, previous: previous.marketplaceGraph)
    usesHostedCatalog =
      !solution.hostedArchives.isEmpty
      || previous.marketplaceGraph?.nodes.contains { $0.hostedEvidence != nil } == true
  }

  var resolution: MarketplaceResolution {
    let versions = Dictionary(uniqueKeysWithValues: solution.versions.map { ($0.node, $0) })
    return MarketplaceResolution(
      roots: solution.graph.roots,
      nodes: solution.graph.nodes.map {
        MarketplaceResolutionNode(
          versions: versions[$0.id]!, catalog: $0.catalog, dependencies: $0.dependencies,
          availableMembers: solution.bundles[$0.id]?.components)
      })
  }

  func withUpdateRequest<T>(
    store: StateStore, replace: Bool, _ body: (UpdateRequest) throws -> T
  ) throws -> T {
    if usesHostedCatalog {
      _ = try MarketplaceGraphChange.admitHostedRegistrations(
        solution.graph, environment: store.environment)
      try MarketplaceGraphChange.validateHosted(
        solution.graph, objects: solution.hostedArchives,
        policy: SourcePolicySnapshot(store: store).effective, organizationPolicy: organizationPolicy
      )
    }
    let targets = try solution.graph.selectedTargets()
    let inputs: [BundleInstallation.Input] = try solution.graph.nodes.compactMap { node in
      let selected = targets[node.id] ?? [:]
      let retained = Dictionary(uniqueKeysWithValues: node.members.map { ($0.key, $0) })
      guard
        selected.contains(where: { key, targets in
          guard let member = retained[key] else { return true }
          // A skill or MCP producer that predates this selection may omit Antigravity.
          return key.kind != .instructions && targets.contains(.antigravity)
            && !member.targets.contains(.antigravity)
        })
      else { return nil }
      guard let bundle = solution.bundles[node.id] else {
        throw MarketplaceError.releaseNotFound(node.coordinate.label)
      }
      let groups = Dictionary(grouping: bundle.components, by: \.marketplaceKey)
      for member in selected.keys where groups[member]?.count != 1 {
        let issue = groups[member] == nil ? "missing member" : "ambiguous member"
        throw MarketplaceError.selectionMismatch(
          node.coordinate.label + " / " + member.name + " (" + issue + ")")
      }
      let selections = bundle.components.compactMap { component -> BundleImportSelection? in
        selected[component.marketplaceKey].map {
          BundleImportSelection(
            componentID: component.id, targets: $0.sorted { $0.rawValue < $1.rawValue })
        }
      }
      return BundleInstallation.Input(bundle: bundle, selections: selections, node: node)
    }
    return try BundleInstallation.withStagedSources(
      inputs, store: store, organizationPolicy: organizationPolicy
    ) { installation in
      var graph = solution.graph
      let members = Dictionary(grouping: installation.members, by: \.marketplaceNode)
      graph.nodes = try graph.nodes.map { node in
        var next = node
        guard let staged = members[node.id] else {
          next.members = node.members.compactMap { member in
            targets[node.id]?[member.key].map {
              MarketplaceResolvedMember(
                key: member.key, componentID: member.componentID, sourceAlias: member.sourceAlias,
                targets: $0.sorted { $0.rawValue < $1.rawValue },
                producerResource: member.producerResource)
            }
          }
          return next
        }
        next.members = try staged.map {
          MarketplaceResolvedMember(
            key: MarketplaceMemberKey(
              kind: DeclaredComponentKind(rawValue: $0.item.kind.rawValue)!, name: $0.item.name),
            componentID: try $0.item.id, sourceAlias: $0.alias,
            targets: $0.targets.sorted { $0.rawValue < $1.rawValue })
        }
        return next
      }
      var request = UpdateRequest(replace: replace)
      request.bundleInstallation = installation
      request.marketplaceGraphChange = MarketplaceGraphChange(
        graph: graph.roots.isEmpty ? nil : graph, stateDigest: stateDigest,
        policyFingerprint: policyFingerprint, directoryInputs: solution.directoryInputs,
        promotedLegacy: solution.promotedLegacy, hostedArchives: solution.hostedArchives,
        hostedGeneration: usesHostedCatalog ? generation : [])
      return try withFrozenProducers(for: graph, store: store) { retained in
        request.marketplaceFrozenProducers = retained
        return try body(request)
      }
    }
  }

  private func withFrozenProducers<T>(
    for graph: MarketplaceGraph, store: StateStore, _ body: ([String: URL]) throws -> T
  ) throws -> T {
    guard let ledger = priorDesired else { return try body([:]) }
    let members = graph.nodes.flatMap(\.members).filter { $0.producerResource != nil }
    guard !members.isEmpty else { return try body([:]) }
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-marketplace-lock-" + UUID().uuidString)
    try FileSystem.createDirectory(at: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }
    var staged: [String: URL] = [:]
    for member in members {
      guard let id = member.producerResource, let resource = ledger.resources[id] else {
        throw MarketplaceError.contributionMismatch(member.sourceAlias)
      }
      let source = MarketplaceGraphChange.source(for: member.sourceAlias, scope: store.scope)
      let container = workspace.appendingPathComponent(
        String(member.sourceAlias.dropFirst(MarketplaceResolvedNode.sourceAliasPrefix.count)))
      try LedgerResources.materialize(resource, objects: ledger.contentObjects, at: container)
      staged[try source.identity(environment: store.environment)] = container
    }
    return try body(staged)
  }
}
