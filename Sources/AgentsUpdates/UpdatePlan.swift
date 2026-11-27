import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Components
import Foundation

struct RequiredRoutes: Error {
  let routes: Set<NativeTargetRoute>
  var installations: [String: SkillInstallationTarget] = [:]
}

/// The composition plan borrows both source/replay resources and the admitted writer scope.
final class UpdatePlan {
  func requireOwnership() throws { try aggregation.requireOwnership() }

  let report: CombinedUpdateReport
  private let store: StateStore
  private let baseline: StatePrecondition
  private let sourcePolicy: SourcePolicySnapshot
  private let organization: OrganizationInstallEvaluation
  private let workspacePolicy: OrganizationWorkspaceInspection

  struct Admission {
    let fingerprint: String
    let baseline: StatePrecondition
    let sourcePolicy: SourcePolicySnapshot
    let organizationPolicy: OrganizationPolicySnapshot
    let workspacePolicy: OrganizationWorkspaceInspection

    func validate() throws {
      try baseline.validate()
      try sourcePolicy.validate()
      try organizationPolicy.validate()
      try workspacePolicy.validate()
    }
  }

  var admission: Admission {
    .init(
      fingerprint: report.displayedFingerprint, baseline: baseline, sourcePolicy: sourcePolicy,
      organizationPolicy: organization.policy,
      workspacePolicy: workspacePolicy)
  }
  private let previous: ResolvedLedger
  private let next: ResolvedLedger
  private let watch: WatchState
  private let declarationChange: DeclarationChange?
  private let aggregation: ArtifactAggregation
  private let checkpoint: (String) throws -> Void
  private let provider: any RuntimeBindingProvider
  private let inputs: UpdateInputs
  private let receipts: [InstallResult]
  private let bundlePublications: [BundleSourceInputs.Publication]
  private let bundleRemovals: [TargetPrecondition]
  private let marketplaceGraphChange: MarketplaceGraphChange?
  private let deployPendingMarketplace: Bool
  private let restoresOffline: Bool
  private let acquisitions: GitAcquisitionCaptures
  private let resources: [String: URL]

  static func withPlan<T>(
    request: UpdateRequest, store: StateStore, admitted: Set<NativeTargetRoute>,
    installations: [String: SkillInstallationTarget],
    checkpoint: @escaping (String) throws -> Void, provider: any RuntimeBindingProvider,
    organizationPolicy: OrganizationPolicySnapshot, acquisitions: GitAcquisitionCaptures,
    marketplaceLock: ((MarketplaceLockPlan) throws -> T)? = nil,
    instructionPreview: ((CombinedUpdateReport) throws -> T)? = nil,
    _ body: (UpdatePlan) throws -> T
  ) throws -> T {
    var request = request
    let sourcePolicy = try SourcePolicySnapshot(store: store)
    try organizationPolicy.admit()
    try organizationPolicy.validate()
    try request.capturedAddition?.validate(request, in: store)
    try request.importPreparation?.requireSourcePolicy(sourcePolicy.effective)
    let catalogInputs = try request.catalogPreparation?.validate() ?? []
    var importInputs = try (request.importPreparation?.capture() ?? []) + catalogInputs
    let baseline = try StatePrecondition(store: store)
    let previous = try store.readLedger(prepared: baseline)
    let roots = store.ledgerRoots(recordedIn: previous)
    let instructionReferences = try resolveSelection(
      &request, ledger: previous, store: store, roots: roots, baseline: baseline)
    let restoringRequest: Bool
    if case .restore = request.operation {
      restoringRequest = true
    } else {
      restoringRequest = false
    }
    let declaration: Declaration
    do {
      declaration = try store.readDeclaration(prepared: baseline)
    } catch is ManifestFailure
      where restoringRequest
      && previous.pendingDeployment == nil && previous.marketplaceGraph == nil
      && (previous.marketplacePackages ?? []).isEmpty && !organizationPolicy.evaluator.active
    {
      // Standalone components restore from their locked inputs. Package and
      // organization admission still require a readable declaration.
      declaration = Declaration()
    }
    let pending = previous.pendingDeployment
    if pending != nil, !request.deployPendingMarketplace, marketplaceLock == nil {
      throw MarketplaceError.pendingDeployment
    }
    let lockedIntent = try pending?.desired(in: previous) ?? previous
    try request.marketplaceGraphChange?.validate(
      baseline, policy: sourcePolicy, organizationPolicy: organizationPolicy, store: store)
    try MarketplaceChanges.validate(
      declaration, matching: lockedIntent, in: store,
      allowingGraphReconciliation: request.marketplaceGraphChange != nil)
    if restoringRequest, request.marketplaceChange != nil || request.marketplaceGraphChange != nil {
      throw MarketplaceError.selectionMismatch("package change requires an update")
    }
    let watch = try store.readWatch(prepared: baseline)
    let original = try restoringRequest ? nil : store.declarationDocument(prepared: baseline)
    if request.declarationYAML != nil, request.expectedDeclarationDigest == nil {
      throw CoreError.invalidState("a YAML edit requires an expected declaration digest")
    }
    if let expected = request.expectedDeclarationDigest, expected != (original?.digest ?? "absent")
    {
      throw CoreError.invalidState("declaration changed during discovery; retry the command")
    }
    if let installation = request.bundleInstallation, request.marketplaceGraphChange == nil {
      request.operation = try .declaration(installation.adding(to: declaration, store: store))
    }
    var candidate = declaration
    var change: DeclarationChange?
    var addedInstructions: (paths: Set<String>, requested: Set<AgentID>)?
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    let restoring: Bool
    switch request.operation {
    case .restore: restoring = true
    case .update: restoring = false
    case .edit(let edits):
      restoring = false
      let bytes: [UInt8]
      if let yaml = request.declarationYAML {
        bytes = yaml
      } else {
        guard let original else { throw CoreError.notFound("declaration document") }
        bytes = try original.preparing(edits).bytes
      }
      candidate = try ManifestProjection.declaration(
        of: DeclarationDocument(
          bytes: bytes, identity: DocumentIdentity(store.declarationURL.path)),
        environment: store.environment)
      change = bytes == original?.bytes ? nil : DeclarationChange(bytes: Data(bytes))
    case .declaration(let replacement):
      restoring = false
      candidate = replacement
      if let addition = request.instructionAddition {
        let hasUses = !candidate.uses.isEmpty
        let groups =
          try hasUses
          ? instructionGroups(
            addition, candidate: candidate, original: declaration, document: original,
            store: store, baseline: baseline, previous: previous, roots: roots, platform: platform,
            sourcePolicy: sourcePolicy, organizationPolicy: organizationPolicy,
            acquisitions: acquisitions) : []
        let selection = InstructionOperations.addLocalRecipients(
          addition, scope: store.scope, platform: platform, groups: groups, to: &candidate)
        if hasUses {
          addedInstructions = selection
          if selection.paths.isEmpty, let alias = addition.alias, declaration.sources[alias] == nil
          {
            candidate.sources[alias] = nil
          }
        }
      }
      if request.marketplaceChange == nil {
        change = try store.planDeclaration(candidate, replacing: declaration, prepared: baseline)
      }
    case .remove:
      restoring = false
      try LedgerImpact.requireEditable(
        previous, kinds: request.kinds ?? Set(DeclaredComponentKind.allCases),
        names: Set(request.names), roots: roots,
        selectedIdentities: request.selectedIdentities)
      candidate = try removing(
        request, from: declaration, ledger: previous, store: store, roots: roots,
        selectedInstructionReferences: instructionReferences)
      change = try store.planDeclaration(candidate, replacing: declaration, prepared: baseline)
    }
    if !restoring {
      candidate = try MarketplaceChanges.candidate(
        candidate, original: declaration, previous: lockedIntent, request: request, store: store)
      if request.marketplaceChange != nil || request.marketplaceGraphChange != nil {
        change = try store.planDeclaration(candidate, replacing: declaration, prepared: baseline)
      }
    }
    let retargetedInstructions: Set<String>
    if case .remove = request.operation, request.agents != nil,
      request.kinds?.contains(.instructions) ?? true
    {
      retargetedInstructions = try Set(
        previous.occurrences.filter { $0.consumerEditable }.compactMap {
          guard let component = previous.components[$0.component], component.kind == "instructions",
            component.group == nil
          else { return nil }
          return try LedgerImpact.identity(component, ledger: previous, roots: roots)
        })
    } else {
      retargetedInstructions = []
    }
    let organization = try OrganizationInstallEvaluation(
      policy: organizationPolicy, store: store, declaration: candidate,
      bytes: change?.bytes ?? baseline.bytes(for: store.declarationURL))
    let initialFindings =
      organization.beforeAcquisition() + (request.bundleInstallation?.policyFindings ?? [])
    try organizationPolicy.admit(initialFindings)
    if restoring {
      let next: ResolvedLedger
      if request.deployPendingMarketplace {
        guard let pending else { throw CoreError.notFound("pending marketplace deployment") }
        try pending.requireDeclaration(baseline.bytes(for: store.declarationURL))
        next = lockedIntent
        request.selectedIdentities = try MarketplaceGraphChange.deploymentIdentities(
          from: previous, to: next, roots: roots)
      } else {
        next = previous
      }
      try MarketplaceGraphChange.validateHosted(
        next.marketplaceGraph, objects: next.contentObjects, policy: sourcePolicy.effective,
        organizationPolicy: organizationPolicy)
      try sourcePolicy.effective.require(next, store: store, roots: roots)
      try organizationPolicy.admit(
        initialFindings
          + organization.closure(
            baseline.bytes(for: store.resolvedURL) == nil ? nil : next, roots: roots))
      let routes = try DeploymentConstruction.routes(previous).union(
        DeploymentConstruction.routes(next))
      let required = try SkillLifecycle.installationTargets(previous, store: store).merging(
        SkillLifecycle.installationTargets(next, store: store),
        uniquingKeysWith: { _, next in next })
      guard routes.isSubset(of: admitted), Set(required.keys).isSubset(of: Set(installations.keys))
      else { throw RequiredRoutes(routes: routes, installations: required) }
      return try LedgerReplay.withLockedResources(
        next, store: store, roots: roots, limits: .standard,
        offline: request.restoresOffline,
        sourcePolicy: sourcePolicy.effective,
        requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin,
        acquisitions: acquisitions
      ) { artifacts, resources, workspace in
        let publications = try MarketplaceGraphChange.restoreProducers(
          next.marketplaceGraph, replayed: resources, store: store)
        let removals =
          try request.deployPendingMarketplace
          ? MarketplaceGraphChange.pruneProducers(
            previous: previous, next: next, store: store, roots: roots,
            declaration: declaration, watch: watch) : []
        return try body(
          UpdatePlan(
            request: request, store: store, roots: roots, baseline: baseline,
            sourcePolicy: sourcePolicy, organization: organization,
            initialFindings: initialFindings,
            previous: previous,
            next: next,
            watch: watch, change: nil, artifacts: artifacts, resources: resources,
            workspace: workspace,
            decisionInputs: [], originalInputs: [],
            checkpoint: checkpoint, provider: provider, installations: Array(installations.values),
            retargetedInstructions: retargetedInstructions, bundlePublications: publications,
            bundleRemovals: removals, acquisitions: acquisitions))
      }
    }
    var document: DeclarationDocument
    if let change {
      document = try DeclarationDocument(
        bytes: Array(change.bytes), identity: DocumentIdentity(store.declarationURL.path))
    } else if let original {
      document = original
    } else {
      document = try DeclarationDocument(
        bytes: Array("version: 1\n".utf8), identity: DocumentIdentity(store.declarationURL.path))
    }
    let updating: Bool
    if case .update = request.operation {
      updating = request.marketplaceGraphChange == nil
    } else {
      updating = request.expectedDiscoveryFingerprint != nil && request.capturedAddition == nil
    }
    let removing: Bool
    if case .remove = request.operation { removing = true } else { removing = false }
    if removing || (updating && !request.names.isEmpty), request.kinds?.contains(.skills) ?? true {
      var linkingDeclaration = candidate
      for index in linkingDeclaration.components.indices {
        guard case .skills(let alias, var selection) = linkingDeclaration.components[index],
          case .all = selection.select, let source = linkingDeclaration.sources[alias]
        else { continue }
        let identity = try source.identity(environment: store.environment)
        let existing = try previous.components.values.filter { component in
          guard component.kind == "skills", component.group == nil else { return false }
          return try previous.sourceIdentity(component.source, roots: roots) == identity
        }.map { PathSafety.sanitizeName($0.name) }.sorted()
        let selected = request.names.filter { name in
          !previous.components.values.contains { $0.kind == "skills" && $0.name == name }
            || existing.contains(name)
        }
        selection.select = .names(
          removing
            ? existing.filter { !(selection.exclude ?? []).contains($0) }
            : Array(Set(existing + selected)).sorted())
        linkingDeclaration.components[index] = .skills(source: alias, selection)
      }
      if removing {
        linkingDeclaration.components.removeAll {
          if case .skills(_, let selection) = $0, case .names(let names) = selection.select {
            return names.isEmpty
          }
          return false
        }
      }
      if let bytes = try store.planDeclaration(
        linkingDeclaration, replacing: declaration, prepared: baseline)?.bytes
      {
        document = try DeclarationDocument(
          bytes: Array(bytes), identity: DocumentIdentity(store.declarationURL.path))
      }
    }
    let impact = try LedgerImpact(
      ledger: previous, roots: roots,
      kinds: request.kinds ?? Set(DeclaredComponentKind.allCases), names: Set(request.names),
      updating: updating, selectedIdentities: request.selectedIdentities)
    let marketplace = request.marketplaceGraphChange
    if let registration = try MarketplaceGraphChange.admitHostedRegistrations(
      marketplace?.graph, environment: store.environment)
    {
      importInputs.append(registration)
    }
    try MarketplaceGraphChange.validateHosted(
      marketplace.map(\.graph) ?? previous.marketplaceGraph,
      objects: marketplace?.hostedArchives ?? previous.contentObjects,
      policy: sourcePolicy.effective,
      organizationPolicy: organizationPolicy)
    try MarketplaceChanges.requirePolicy(
      sourcePolicy.effective, candidate: candidate, previous: previous,
      change: request.marketplaceChange,
      graph: request.marketplaceGraphChange.map(\.graph) ?? previous.marketplaceGraph,
      store: store)
    let admitOrganization: @Sendable ([OrganizationPolicyFinding]) throws -> Void = {
      try organizationPolicy.admit(initialFindings + $0)
    }
    let staged = request.marketplaceFrozenProducers.merging(
      request.bundleInstallation?.stagedContainers ?? [:], uniquingKeysWith: { _, new in new })
    return try ComponentLinker.withLinkedComponents(
      document: document, store: store, platform: platform,
      preserving: impact.pins, directPins: impact.directPins, retaining: previous,
      sourcePolicy: sourcePolicy.effective, organization: organization.evaluator,
      admitOrganization: admitOrganization,
      stagedLocalSources: staged.mapValues { $0.appendingPathComponent(BundleSourceLocation.tree) },
      acquisitions: acquisitions, instructionsOnly: instructionPreview != nil
    ) { linked, session in
      let bundleSources = try BundleSourceInputs.capture(
        linked, session: session, store: store, staged: staged)
      if let expected = request.automaticSkill {
        guard
          linked.components.contains(where: { component in
            if case .skill(let skill, _, _) = component.payload {
              return skill.name == expected.name && component.snapshot.source == expected.source
            }
            return false
          })
        else {
          throw CoreError.invalidState(
            "automatic skill selection changed during discovery; retry the command")
        }
      }
      let locations = try sourceLocations(linked, declaration: candidate, store: store)
      for component in linked.components {
        if case .skill(let skill, .copy, _) = component.payload {
          try DeploymentConstruction.validateCopiedSkill(
            session.resource(snapshot: component.snapshot, path: skill.path))
        }
      }
      let frozen = try LedgerFreeze.freezeWithSources(
        linked, session: session, locations: .init(sources: locations), limits: .standard)
      try sourcePolicy.effective.require(frozen.ledger, store: store, roots: roots)
      if let instructionPreview {
        let complete = try DeploymentConstruction.complete(
          frozen.ledger, linked: linked, store: store, previous: previous, platform: platform,
          roots: roots, session: session)
        return try instructionPreview(
          InstructionOutputPreview.report(
            complete, previous: previous, store: store, baseline: baseline, roots: roots,
            sourcePolicy: sourcePolicy, organization: organization,
            initialFindings: initialFindings,
            acquisitions: acquisitions))
      }
      if let addition = request.instructionAddition, let selection = addedInstructions {
        // A fresh scope can publish the requested group routes. An existing lock already
        // owns those routes, so re-adding them leaves their deployed files alone.
        let initialGroupPaths =
          try baseline.bytes(for: store.resolvedURL) == nil
          ? Set(addition.units.map { $0.record.path }) : []
        var selected = Set<String>()
        var unrequested = Set<String>()
        for item in frozen.ledger.components.values where item.kind == "instructions" {
          guard item.payload.object?["prompt"] == nil,
            let resource = item.resources.first.flatMap({ frozen.ledger.resources[$0] }),
            try frozen.ledger.sourceIdentity(item.source, roots: roots) == addition.source
          else { continue }
          if item.group == nil, selection.paths.contains(resource.path) {
            selected.insert(try LedgerImpact.identity(item, ledger: frozen.ledger, roots: roots))
          } else if item.group != nil, initialGroupPaths.contains(resource.path),
            !item.recipients.isEmpty
          {
            let identity = try LedgerImpact.identity(item, ledger: frozen.ledger, roots: roots)
            if selection.requested.isSuperset(of: item.recipients) {
              selected.insert(identity)
            } else {
              unrequested.insert(identity)
            }
          }
        }
        // Several conditioned occurrences can share an identity.
        request.selectedIdentities = selected.subtracting(unrequested)
      }
      if let expected = request.expectedDiscoveryFingerprint,
        expected != (try LedgerImpact.discoveryFingerprint(frozen.ledger, roots: roots))
      {
        throw CoreError.invalidState("discovered source content changed; refresh discovery")
      }
      let lowered = try DeploymentConstruction.lowerNative(
        linked: linked, frozen: frozen, scope: store.scope, platform: platform)
      let native = try MarketplaceChanges.pin(
        lowered, declaration: candidate, previous: previous, request: request, store: store,
        sourceIDs: frozen.sources, producers: bundleSources.producers)
      if marketplaceLock != nil {
        let identities = try MarketplaceGraphChange.deploymentIdentities(
          from: previous, to: native, roots: roots)
        try LedgerImpact.requireProtected(
          previous: previous, next: native, kinds: Set(DeclaredComponentKind.allCases),
          roots: roots,
          selectedIdentities: identities)
      }
      if let installation = request.bundleInstallation {
        let selected = try installation.selectedIdentities(native, roots: roots)
        if request.marketplaceChange == nil, request.marketplaceGraphChange == nil {
          request.selectedIdentities = selected
        }
      }
      let routes = try DeploymentConstruction.routes(native).union(
        DeploymentConstruction.routes(previous))
      guard routes.isSubset(of: admitted) else { throw RequiredRoutes(routes: routes) }
      if request.kinds != nil || !request.names.isEmpty || request.selectedIdentities != nil {
        let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
        try LedgerImpact.requireProtected(
          previous: previous, next: native, kinds: kinds, names: Set(request.names),
          roots: roots, selectedIdentities: request.selectedIdentities,
          retargetedInstructions: retargetedInstructions)
      }
      let complete = try DeploymentConstruction.complete(
        native, linked: linked, store: store, previous: previous, platform: platform, roots: roots,
        session: session)
      if marketplaceLock == nil {
        let required = try SkillLifecycle.installationTargets(previous, store: store).merging(
          SkillLifecycle.installationTargets(complete.ledger, store: store),
          uniquingKeysWith: { _, next in next })
        guard Set(required.keys).isSubset(of: Set(installations.keys)) else {
          throw RequiredRoutes(routes: routes, installations: required)
        }
      }
      let originals = try linked.components.flatMap { c -> [TargetPrecondition] in
        if case .skill(_, .edit, _) = c.payload { return [] }
        return try c.resources.filter { $0.snapshot.revision == "live" }.map {
          try TargetPrecondition(session.resource(snapshot: $0.snapshot, path: $0.path))
        }
      }
      try checkpoint("plan.skills")
      let roots = store.ledgerRoots(recordedIn: previous)
      return try LedgerReplay.withPreparedLowerings(
        complete.ledger, store: store, roots: roots, limits: .standard,
        sourcePolicy: sourcePolicy.effective,
        requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin,
        acquisitions: session.acquisitions
      ) { next, artifacts, resources, workspace in
        try MarketplaceGraphChange.validateProducers(next.marketplaceGraph, replayed: resources)
        if let marketplaceLock, let graphChange = request.marketplaceGraphChange {
          return try marketplaceLock(
            MarketplaceLockPlan(
              store: store, baseline: baseline, sourcePolicy: sourcePolicy,
              organization: organization, initialFindings: initialFindings,
              graphChange: graphChange, previous: previous, desired: next, declaration: change,
              roots: roots, resources: resources,
              decisionInputs: complete.inputs,
              originalInputs: originals + importInputs + bundleSources.preconditions,
              acquisitions: session.acquisitions))
        }
        let removals = try MarketplaceGraphChange.pruneProducers(
          previous: previous, next: next, store: store, roots: roots,
          declaration: candidate, watch: watch)
        return try body(
          UpdatePlan(
            request: request, store: store, roots: roots, baseline: baseline,
            sourcePolicy: sourcePolicy, organization: organization,
            initialFindings: initialFindings,
            previous: previous,
            next: next,
            watch: watch, change: change, artifacts: artifacts, resources: resources,
            workspace: workspace,
            decisionInputs: complete.inputs,
            originalInputs: originals + importInputs + bundleSources.preconditions,
            checkpoint: checkpoint, provider: provider, installations: Array(installations.values),
            retargetedInstructions: retargetedInstructions,
            bundlePublications: bundleSources.publications, bundleRemovals: removals,
            acquisitions: session.acquisitions))
      }
    }
  }

  private static func instructionGroups(
    _ addition: InstructionAddition, candidate: Declaration, original: Declaration,
    document originalDocument: DeclarationDocument?, store: StateStore, baseline: StatePrecondition,
    previous: ResolvedLedger, roots: [String: URL], platform: DeclarationPlatform,
    sourcePolicy: SourcePolicySnapshot, organizationPolicy: OrganizationPolicySnapshot,
    acquisitions: GitAcquisitionCaptures
  ) throws -> [LinkedComponent] {
    let change = try store.planDeclaration(candidate, replacing: original, prepared: baseline)
    let document: DeclarationDocument
    if let change {
      document = try DeclarationDocument(
        bytes: Array(change.bytes), identity: DocumentIdentity(store.declarationURL.path))
    } else if let originalDocument {
      document = originalDocument
    } else {
      throw CoreError.missingDeclaration(store.declarationURL.path)
    }
    let impact = try LedgerImpact(
      ledger: previous, roots: roots, kinds: [.instructions], names: [], updating: false)
    let organization = try OrganizationInstallEvaluation(
      policy: organizationPolicy, store: store, declaration: candidate, bytes: Data(document.bytes))
    let initial = organization.beforeAcquisition()
    try organizationPolicy.admit(initial)
    let admitOrganization: @Sendable ([OrganizationPolicyFinding]) throws -> Void = {
      try organizationPolicy.admit(initial + $0)
    }
    return try ComponentLinker.withLinkedComponents(
      document: document, store: store, platform: platform,
      preserving: impact.pins, directPins: impact.directPins, retaining: previous,
      sourcePolicy: sourcePolicy.effective, organization: organization.evaluator,
      admitOrganization: admitOrganization,
      acquisitions: acquisitions
    ) { linked, _ in
      linked.components.filter { component in
        guard component.key.group != nil, component.snapshot.source == addition.source,
          case .instruction(_, prompt: nil, _) = component.payload
        else { return false }
        return true
      }
    }
  }

  private init(
    request: UpdateRequest, store: StateStore, roots: [String: URL], baseline: StatePrecondition,
    sourcePolicy: SourcePolicySnapshot, organization: OrganizationInstallEvaluation,
    initialFindings: [OrganizationPolicyFinding], previous: ResolvedLedger, next: ResolvedLedger,
    watch: WatchState,
    change: DeclarationChange?, artifacts: [ReplayedArtifact], resources: [String: URL],
    workspace: URL,
    decisionInputs: [TargetPrecondition], originalInputs: [TargetPrecondition],
    checkpoint: @escaping (String) throws -> Void, provider: any RuntimeBindingProvider,
    installations: [SkillInstallationTarget], retargetedInstructions: Set<String>,
    bundlePublications: [BundleSourceInputs.Publication] = [],
    bundleRemovals: [TargetPrecondition] = [], acquisitions: GitAcquisitionCaptures
  ) throws {
    self.store = store
    self.baseline = baseline
    self.sourcePolicy = sourcePolicy
    self.organization = organization
    self.previous = previous
    self.watch = watch
    declarationChange = change
    self.checkpoint = checkpoint
    self.provider = provider
    self.bundlePublications = bundlePublications
    self.bundleRemovals = bundleRemovals
    marketplaceGraphChange = request.marketplaceGraphChange
    deployPendingMarketplace = request.deployPendingMarketplace
    restoresOffline = request.restoresOffline
    self.acquisitions = acquisitions
    self.resources = resources
    inputs = try UpdateInputs(
      ledger: next, roots: roots, resources: resources, decisions: decisionInputs,
      originals: originalInputs + bundlePublications.map(\.destination) + bundleRemovals)
    aggregation = try ArtifactAggregation(
      ledger: next, previous: previous, artifacts: artifacts,
      resources: resources, workspace: workspace, store: store, roots: roots,
      replace: request.replace,
      changingAccess: request.changingAccess, kinds: request.kinds,
      names: Set(request.names), selectedIdentities: request.selectedIdentities,
      installations: installations, retargetedInstructions: retargetedInstructions,
      offlineBaseline: restoresOffline || sourcePolicy.effective.isConfigured,
      sourcePolicy: sourcePolicy.effective, verifyPriorSkillLinks: deployPendingMarketplace)
    try request.catalogPreparation?.validateStandalone(replacing: aggregation.changes.map(\.url))
    if let imported = request.importPreparation {
      for resource in imported.proposal.resources
      where resource.selected && resource.requiresStandaloneSource {
        guard
          let source = imported.proposal.sources.first(where: { $0.alias == resource.sourceAlias })?
            .declaration,
          source.kind == .local
        else { continue }
        let sourceEnvironment = source.environment?.runtime ?? store.environment
        let identity = try source.identity(environment: sourceEnvironment)
        let root = URL(fileURLWithPath: String(identity.dropFirst(6)))
        if aggregation.changes.contains(where: {
          PathSafety.isContained(root, in: $0.url) || PathSafety.isContained($0.url, in: root)
        }) {
          throw CoreError.invalidState(
            "import requires an independent authoring source before replacing its installed content"
          )
        }
      }
    }
    self.next = aggregation.ledger
    try self.next.validate()
    workspacePolicy = try OrganizationWorkspaceInspection(
      evaluator: organization.evaluator, store: store, ledger: self.next, previous: previous,
      roots: roots, inspectDrift: false)
    let policyReport = try organization.policy.report(
      initialFindings + organization.closure(self.next, roots: roots) + workspacePolicy.findings)
    try policyReport.requireAdmission()
    let lockMissing = try baseline.bytes(for: store.resolvedURL) == nil
    let before = try previous.domainProjection(roots: roots)
    let after = try self.next.domainProjection(roots: roots)
    let allResults = try UpdateReporting.skills(
      previous: previous, next: self.next, resources: resources,
      changes: aggregation.changes, store: store, roots: roots, lockMissing: lockMissing,
      included: request.kinds == nil || request.kinds!.contains(.skills),
      selectedIdentities: request.selectedIdentities, names: Set(request.names))
    let results =
      request.names.isEmpty ? allResults : allResults.filter { request.names.contains($0.skill) }
    receipts = results.flatMap(\.installed)
    let publicResults = results.map {
      var result = $0
      result.installed = []
      return result
    }
    func instructionArtifacts(_ ledger: ResolvedLedger) -> [String: String] {
      var result: [String: String] = [:]
      for lowering in ledger.lowerings
      where InstructionLocations.isInstructionFormat(lowering.format)
        || lowering.format == "agents/chatgpt@1"
        || lowering.format == LockedLowering.instructionCopyFormat
      {
        for artifact in lowering.artifacts {
          result[lowering.format + ":" + artifact.name] = artifact.hash
        }
      }
      return result
    }
    let instructions = try UpdateReporting.instructions(
      before: before.instructions, after: after.instructions,
      changes: aggregation.changes, ledger: self.next, artifacts: artifacts,
      lockMissing: lockMissing,
      included: request.kinds == nil || request.kinds!.contains(.instructions), store: store,
      stateChanged: instructionArtifacts(previous) != instructionArtifacts(self.next)
        || (change != nil && request.kinds == [.instructions]),
      conflicts: aggregation.antigravityConflicts)
    let operation: String
    switch request.operation {
    case .update: operation = "update"
    case .restore: operation = deployPendingMarketplace ? "marketplace-frozen-deploy" : "restore"
    case .remove: operation = "remove"
    case .edit, .declaration: operation = "edit"
    }
    struct Fingerprint: Encodable {
      let version = 1
      let operation: String
      let scope: InstallScope
      let kinds: [String]?
      let names: [String]
      let selectedIdentities: [String]?
      let replace: Bool
      let changingAccess: Bool
      let candidate: ResolvedLedger
      let baseline: ResolvedLedger
      let declaration: String?
      let marketplaceState: String?
      let targets: [String]
      let instructionOutputs: [String: String]
      let sourcePolicy: String?
      let organizationPolicy: String?
      let organizationFindings: [OrganizationPolicyFinding]?
    }
    var semanticCandidate = self.next
    semanticCandidate.nativeAuthorities = nil
    var semanticBaseline = previous
    semanticBaseline.nativeAuthorities = nil
    let fingerprint = try ResolvedLedgerCodec.digest(
      Fingerprint(
        operation: operation, scope: store.scope, kinds: request.kinds?.map(\.rawValue).sorted(),
        names: request.names.sorted(), selectedIdentities: request.selectedIdentities?.sorted(),
        replace: request.replace,
        changingAccess: request.changingAccess,
        candidate: semanticCandidate, baseline: semanticBaseline,
        declaration: try (change?.bytes ?? baseline.bytes(for: store.declarationURL)).map {
          "sha256:" + FileHash.sha256Hex(data: $0)
        },
        marketplaceState: deployPendingMarketplace
          ? try MarketplaceGraphChange.stateDigest(in: baseline, store: store) : nil,
        targets: (aggregation.fingerprints
          + (try decisionInputs.map { try $0.displayEvidence(includeContent: false) })).sorted(),
        instructionOutputs: Dictionary(
          uniqueKeysWithValues: instructions.outputs.map {
            ($0.id, FileHash.sha256Hex(data: $0.content))
          }),
        sourcePolicy: sourcePolicy.isConfigured ? sourcePolicy.fingerprint : nil,
        organizationPolicy: policyReport.policies.isEmpty ? nil : organization.policy.fingerprint,
        organizationFindings: policyReport.findings.isEmpty ? nil : policyReport.findings))
    var readDeclarations: [Declaration] = []
    if case .restore = request.operation {
    } else {
      readDeclarations.append(try store.readDeclaration(prepared: baseline))
    }
    if let change {
      readDeclarations.append(
        try ManifestProjection.declaration(
          of: DeclarationDocument(
            bytes: Array(change.bytes), identity: DocumentIdentity(store.declarationURL.path)),
          environment: store.environment))
    }
    let readPaths =
      try UpdateOperations.readLocations(
        declarations: readDeclarations, ledgers: [previous, self.next], store: store, roots: roots)
      + decisionInputs.map(\.url) + installations.map(\.url)
      + aggregation.instructionDecisionLocations + sourcePolicy.readDependencies.map(\.url)
      + organization.policy.readDependencies.map(\.url)
      + (marketplaceGraphChange?.directoryInputs.flatMap(\.readLocations) ?? [])
    let finalNext = self.next
    report = CombinedUpdateReport(
      scope: store.scope, skills: publicResults, instructions: instructions,
      lockMissing: lockMissing,
      hasChanges: self.next != previous || change != nil
        || !bundlePublications.isEmpty || !bundleRemovals.isEmpty
        || aggregation.needsRetainedArtifactPublication
        || aggregation.changes.contains(where: \.changed),
      displayedFingerprint: fingerprint,
      marketplaceChanges: MarketplacePackageUpdate.between(previous, finalNext),
      marketplaceGraphChange: MarketplaceGraphUpdate.between(previous, finalNext),
      organizationPolicy: policyReport.policies.isEmpty ? nil : policyReport,
      archiveRepresentationChanges: SourceArchiveRepresentationChange.between(previous, finalNext),
      readLocations: Set(readPaths.map(\.path)).sorted().map {
        URL(fileURLWithPath: $0, isDirectory: false)
      },
      components: try aggregation.changes.filter { change in
        guard change.native else { return false }
        guard let identities = request.selectedIdentities else { return true }
        return try change.deployment.owners.contains { owner in
          let ledger = finalNext.components[owner] == nil ? previous : finalNext
          return try identities.contains(
            LedgerImpact.identity(
              ledger.components[owner]!, ledger: ledger, roots: roots))
        }
      }.map { change in
        let owner = change.deployment.owners[0]
        let ledger = finalNext.components[owner] == nil ? previous : finalNext
        let component = ledger.components[owner]!
        return ComponentUpdateChange(
          sourceIdentity: try ledger.sourceIdentity(component.source, roots: roots),
          revision: component.revision, version: component.version,
          format: change.deployment.route, ownership: change.deployment.ownership.rawValue,
          resources: component.resources.compactMap { ledger.resources[$0] }.map { resource in
            ComponentResourceInfo(
              path: resource.path, hash: resource.hash,
              executableFiles: Dictionary(
                uniqueKeysWithValues: resource.entries.filter { $0.kind == .file }.map {
                  ($0.path, $0.executable)
                }))
          }, requiredBindings: change.requiredBindings, effectiveReaders: change.effectiveReaders,
          privateMaterialization: change.privateMaterialization,
          permissionChange: change.accessChange.map { access in
            ComponentPermissionChange(
              beforeOwner: access.before.owner, beforeGroup: access.before.group,
              beforeMode: UInt32(access.before.mode), afterOwner: access.owner,
              afterMode: access.mode, ownerOnly: true,
              members: change.memberAccessChanges.map {
                ComponentMemberPermissionChange(
                  path: $0.path, beforeOwner: $0.before.owner, beforeGroup: $0.before.group,
                  beforeMode: UInt32($0.before.mode), afterOwner: $0.owner, afterMode: $0.mode)
              })
          },
          symbolicBefore: try change.configurationBefore
            ?? change.symbolicBefore.map {
              try UpdateOperations.symbolicConfigurationText($0)
            },
          symbolicAfter: try change.configurationAfter
            ?? change.symbolicAfter.map {
              try UpdateOperations.symbolicConfigurationText($0)
            },
          kind: component.kind, name: component.name, path: change.url.path,
          agents: change.deployment.recipients, changed: change.changed)
      })
    try admission.validate()
  }

  func apply(outcome: TransactionOutcome) throws -> UpdateApplyResult {
    try admission.validate()
    let roots = store.ledgerRoots(recordedIn: previous)
    try sourcePolicy.effective.require(next, store: store, roots: roots)
    try baseline.validate()
    try aggregation.validate()
    try aggregation.requireOwnership()
    try inputs.validate()
    if report.hasChanges {
      let ledgerReferences = try RetentionReferences(ledger: next, roots: roots)
      var references = ledgerReferences
      try references.include(watch: watch)
      let cache = SourceCache(
        store: store, sourcePolicy: sourcePolicy.effective,
        requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin,
        acquisitions: acquisitions, checkpoint: checkpoint)
      let priorReferences = try RetentionReferences(ledger: previous, roots: roots)
      try cache.withArchivePublication(
        previous: priorReferences, next: ledgerReferences, offline: restoresOffline
      ) {
        // A watch subscription is independent from install policy and already owns its own pins.
        if !deployPendingMarketplace {
          try cache.retain(
            references: sourcePolicy.effective.isConfigured ? ledgerReferences : references,
            offline: restoresOffline)
        }
        try checkpoint("apply.retained")
        try admission.validate()
        try aggregation.validate()
        try inputs.validate()
        try marketplaceGraphChange?.validateCatalogs(in: store)
        let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
        transaction.requireUnchanged(
          since: baseline, aggregation, inputs, sourcePolicy, organization.policy, workspacePolicy)
        for publication in bundlePublications { try publication.stage(in: transaction) }
        for removal in bundleRemovals { try transaction.delete(removal.url, expecting: removal) }
        try aggregation.stage(
          transaction: transaction, provider: provider,
          roots: store.ledgerRoots(recordedIn: previous)
        )
        try store.stageDeclaration(declarationChange, in: transaction, prepared: baseline)
        // Empty scopes need no lock file; a declaration edit always accompanies first deployment.
        if try store.declarationBytes(prepared: baseline) != nil || declarationChange != nil {
          try store.stageLedger(
            producing: { self.aggregation.ledger }, limits: .standard, transaction: transaction,
            prepared: baseline)
        }
        try cache.prune(references: references, transaction: transaction)
        try transaction.commit()
      }
      rememberDeployedBytes(roots: roots)
    }
    organization.policy.rememberVerifiedPolicies()
    return UpdateApplyResult(report: report, installedSkills: receipts)
  }

  /// Only direct Git skill payloads are eligible. Whole-file configuration rewrites,
  /// renderer-generated bytes and runtime bindings do not carry this provenance.
  private func rememberDeployedBytes(roots: [String: URL]) {
    let cache = AcquisitionCache(environment: store.environment)
    let ledger = aggregation.ledger
    for change in aggregation.changes
    where change.changed
      && change.deployment.route == "agents/skill@1"
    {
      for owner in change.deployment.owners {
        guard let component = ledger.components[owner] else { continue }
        for id in component.resources {
          guard let resource = ledger.resources[id], resource.kind == .git,
            let source = ledger.sources[resource.source], let transport = source.transport,
            source.container == nil, source.kind == .git,
            acquisitions.containsAnonymousCommit(
              .init(kind: .git, location: transport), revision: source.revision,
              environment: store.environment),
            let verifiedRoot = resources[id]
          else { continue }
          let installed: URL
          if change.afterLink != nil {
            guard
              let expected = try? ArtifactAggregation.resourceDestination(
                id, ledger: ledger, store: store, roots: roots),
              let retained = PathSafety.realPath(expected.path),
              let target = PathSafety.realPath(change.url.path),
              retained.utf8.elementsEqual(target.utf8)
            else { continue }
            installed = URL(fileURLWithPath: retained)
          } else {
            installed = change.url
          }
          for file in resource.entries
          where file.kind == .file
            && file.byteCount.map({ $0 <= AcquisitionCache.deployedFileLimit }) == true
          {
            guard let expected = try? readDeployedFile(at: verifiedRoot, path: file.path),
              let bytes = try? readDeployedFile(at: installed, path: file.path),
              bytes.count == file.byteCount, bytes == expected
            else { continue }
            try? cache.rememberDeployedBytes(bytes)
          }
        }
      }
    }
  }

  private func readDeployedFile(at root: URL, path: String) throws -> Data {
    if path == "." {
      let directory = try DirectoryHandle.readDirectory(at: root.deletingLastPathComponent())
      return try directory.readRegularFile(
        root.lastPathComponent, maximumBytes: AcquisitionCache.deployedFileLimit)
    }
    let components = path.split(separator: "/")
    guard let file = components.last else { throw AcquisitionCacheError.invalidEntry }
    var directory = try DirectoryHandle.readDirectory(at: root)
    for name in components.dropLast() {
      guard let child = try directory.directory(String(name)) else {
        throw AcquisitionCacheError.invalidEntry
      }
      directory = child
    }
    return try directory.readRegularFile(
      String(file), maximumBytes: AcquisitionCache.deployedFileLimit)
  }

  func recover(outcome: TransactionOutcome) {
    do { _ = try FileTransaction.recover(store: store, outcome: outcome) } catch {
      outcome.disposition = .recoveryRequired
    }
  }

  static func sourceLocations(
    _ linked: LinkedComponents, declaration: Declaration, store: StateStore
  ) throws -> [String: LedgerLocation] {
    var locations: [String: LedgerLocation] = [:]
    let packageRoot =
      store.scope == .project ? store.environment.projectDirectory : store.directory
    for evidence in linked.sourceSnapshots + linked.declaringSnapshots
    where evidence.container == nil && evidence.snapshot.source.hasPrefix("local:") {
      let path = String(evidence.snapshot.source.dropFirst(6))
      if path == packageRoot.path {
        locations[evidence.snapshot.source] = .init(
          kind: .registered, root: store.scope == .project ? "project" : "state", path: ".")
      } else if let authored = try declaration.sources.values.first(where: {
        try $0.identity(environment: store.environment) == evidence.snapshot.source
      }),
        !authored.location.hasPrefix("/")
      {
        if authored.location == "~" || authored.location.hasPrefix("~/") {
          locations[evidence.snapshot.source] = .init(
            kind: .authoringRelative, root: "home",
            path: authored.location == "~" ? "." : String(authored.location.dropFirst(2)))
        } else if authored.environment?.projectDirectory.path
          == store.environment.projectDirectory.path || authored.environment == nil
        {
          locations[evidence.snapshot.source] = .init(
            kind: .authoringRelative, root: "project", path: authored.location)
        } else {
          locations[evidence.snapshot.source] = .init(kind: .absolute, path: path)
        }
      } else {
        locations[evidence.snapshot.source] = .init(kind: .absolute, path: path)
      }
    }
    return locations
  }

  private static func resolveSelection(
    _ request: inout UpdateRequest, ledger: ResolvedLedger, store: StateStore,
    roots: [String: URL], baseline: StatePrecondition
  ) throws -> Set<String>? {
    let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
    func name(_ c: LedgerComponent) -> String {
      c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name
    }
    if request.selections.isEmpty {
      if case .remove = request.operation, request.kinds == [.instructions] {
        let declaration = try store.readDeclaration(prepared: baseline)
        let references = try selectedInstructionReferences(Set(request.names), in: declaration)
        let sections = declaration.components.flatMap { component -> [SectionDeclaration] in
          guard case .instructions(let selection) = component else { return [] }
          return selection.sectionReferences
            + selection.prompts.flatMap { $0.prompt.sectionReferences }
        }
        var selected = Set<String>()
        for section in sections where references.contains(section.reference) {
          let source: String
          if let alias = section.source, alias != "." {
            guard let sourceDeclaration = declaration.sources[alias] else { continue }
            source = try sourceDeclaration.identity(environment: store.environment)
          } else {
            source = "local:" + store.environment.projectDirectory.resolvingSymlinksInPath().path
          }
          for component in ledger.components.values
          where component.kind == "instructions" && component.group == nil
            && component.name == section.name
          {
            if try ledger.sourceIdentity(component.source, roots: roots) == source {
              selected.insert(
                try LedgerImpact.identity(component, ledger: ledger, roots: roots))
            }
          }
        }
        request.selectedIdentities = selected
        return references
      }
      for requested in request.names {
        let matches = try ledger.components.values.filter {
          kinds.contains(DeclaredComponentKind(rawValue: $0.kind)!) && name($0) == requested
        }.map { try LedgerImpact.identity($0, ledger: ledger, roots: roots) }
        guard Set(matches).count <= 1 else {
          throw CoreError.invalidState(
            "component name is ambiguous; select a component from inspection: " + requested)
        }
      }
      return nil
    }
    guard request.names.isEmpty else {
      throw CoreError.invalidState("use names or precise selections, not both")
    }
    switch request.operation {
    case .update, .remove: break
    default: throw CoreError.invalidState("precise selection applies to update or removal")
    }
    let documentDigest =
      try baseline.bytes(for: store.declarationURL).map { "sha256:" + FileHash.sha256Hex(data: $0) }
      ?? "absent"
    let generation = try ResolvedLedgerCodec.digest([
      ResolvedLedgerCodec.digest(ledger), documentDigest,
    ])
    var selected = Set<String>()
    var names = Set<String>()
    var selectedKinds = Set<DeclaredComponentKind>()
    for selection in request.selections {
      guard selection.generation == generation else {
        throw CoreError.invalidState("inspection changed; refresh component selection")
      }
      let entries = try ledger.components.filter {
        try LedgerImpact.identity($0.value, ledger: ledger, roots: roots)
          == selection.identity
      }
      guard let entry = entries.first,
        kinds.contains(DeclaredComponentKind(rawValue: entry.value.kind)!)
      else {
        throw CoreError.notFound("selected component")
      }
      if let occurrence = selection.occurrence {
        let occurrences = ledger.occurrences.filter { entries[$0.component] != nil }
        guard occurrences.contains(where: { $0.id == occurrence }) else {
          throw CoreError.notFound("selected occurrence")
        }
        guard occurrences.count == 1 else {
          throw CoreError.invalidState(
            "this component has multiple contributions; select the complete component or edit its declaration reference"
          )
        }
      }
      selected.insert(selection.identity)
      names.insert(name(entry.value))
      selectedKinds.insert(DeclaredComponentKind(rawValue: entry.value.kind)!)
    }
    request.selectedIdentities = selected
    request.names = names.sorted()
    request.kinds = selectedKinds
    return nil
  }

  private static func selectedInstructionReferences(
    _ names: Set<String>, in declaration: Declaration
  ) throws -> Set<String> {
    let references = Set(
      declaration.components.flatMap { component -> [String] in
        guard case .instructions(let selection) = component else { return [] }
        return selection.sectionReferences.map(\.reference)
          + selection.prompts.flatMap { $0.prompt.sectionReferences.map(\.reference) }
      })
    var selected = Set<String>()
    for name in names {
      let exact = references.filter { $0 == name }
      let matches =
        exact.isEmpty
        ? references.filter { $0.split(separator: ":").last.map(String.init) == name } : exact
      guard matches.count == 1, let reference = matches.first else {
        throw CoreError.notFound("instruction name is missing or ambiguous: " + name)
      }
      selected.insert(reference)
    }
    return selected
  }

  private static func removing(
    _ request: UpdateRequest, from declaration: Declaration, ledger: ResolvedLedger,
    store: StateStore, roots: [String: URL], selectedInstructionReferences: Set<String>?
  ) throws -> Declaration {
    var result = declaration
    let names = Set(request.names)
    let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
    var instructionReferences = Set<String>()
    if let selectedInstructionReferences {
      instructionReferences = selectedInstructionReferences
    } else if kinds.contains(.instructions), let identities = request.selectedIdentities {
      let sections = declaration.components.flatMap { component -> [SectionDeclaration] in
        guard case .instructions(let selection) = component else { return [] }
        return selection.sectionReferences
          + selection.prompts.flatMap { $0.prompt.sectionReferences }
      }
      for section in sections {
        let source: String
        if let alias = section.source, alias != "." {
          guard let declaration = declaration.sources[alias] else { continue }
          source = try declaration.identity(environment: store.environment)
        } else {
          source = "local:" + store.environment.projectDirectory.resolvingSymlinksInPath().path
        }
        if try ledger.components.values.contains(where: { c in
          try c.kind == "instructions" && c.name == section.name
            && ledger.sourceIdentity(c.source, roots: roots) == source
            && identities.contains(
              LedgerImpact.identity(c, ledger: ledger, roots: roots))
        }) {
          instructionReferences.insert(section.reference)
        }
      }
    } else if kinds.contains(.instructions) {
      instructionReferences = try Self.selectedInstructionReferences(names, in: declaration)
    }
    result.components = declaration.components.compactMap { component in
      switch component {
      case .skills(let alias, var selection) where kinds.contains(.skills):
        if let identities = request.selectedIdentities {
          let source = try? declaration.sources[alias]?.identity(environment: store.environment)
          let matches = ledger.components.values.contains { c in
            c.kind == "skills"
              && (try? ledger.sourceIdentity(c.source, roots: roots)) == source
              && (try? LedgerImpact.identity(c, ledger: ledger, roots: roots)).map(
                identities.contains) == true
          }
          if !matches { return component }
        }
        if case .all = selection.select {
          selection.exclude = Array(Set(selection.exclude ?? []).union(names)).sorted()
        } else if case .names(let selected) = selection.select {
          selection.select = .names(selected.filter { !names.contains($0) })
        }
        if request.agents == nil {
          selection.overrides = selection.overrides?.filter { !names.contains($0.key) }
        }
        if let agents = request.agents {
          selection = {
            var original = selection
            for name in names {
              let current = ledger.components.values.first {
                $0.kind == "skills" && PathSafety.sanitizeName($0.name) == name
                  && (try? ledger.sourceIdentity($0.source, roots: roots))
                    == (try? declaration.sources[alias]?.identity(environment: store.environment))
              }
              var overrides = original.overrides ?? [:]
              overrides[name] = SkillOverride(
                agents: current?.recipients.filter { !agents.contains($0) } ?? [],
                mode: original.overrides?[name]?.mode)
              original.overrides = overrides
            }
            return original
          }()
          if let prior = declaration.components.first(where: {
            if case .skills(let a, _) = $0 { a == alias } else { false }
          }), case .skills(_, let original) = prior {
            selection.select = original.select
            selection.exclude = original.exclude
          }
        }
        return .skills(source: alias, selection)
      case .instructions(var selection) where kinds.contains(.instructions):
        selection.sectionReferences.removeAll {
          instructionReferences.contains($0.reference)
        }
        for index in selection.prompts.indices {
          selection.prompts[index].prompt.sectionReferences.removeAll {
            instructionReferences.contains($0.reference)
          }
        }
        selection.prompts.removeAll { $0.prompt.sectionReferences.isEmpty }
        if let agents = request.agents { selection.agents = agents }
        return .instructions(selection)
      default:
        guard kinds.contains(component.kind), names.contains(component.name ?? "") else {
          return component
        }
        if let agents = request.agents {
          let recipients = (component.selectedAgents ?? declaration.defaultAgents).filter {
            !agents.contains($0)
          }
          return component.replacingAgents(recipients)
        }
        return nil
      }
    }
    return result
  }
}

extension ComponentDeclaration {
  fileprivate var selectedAgents: [AgentID]? {
    switch self {
    case .skills(_, let s): s.agents
    case .instructions(let s): s.agents
    case .mcpServer(_, _, let a, _, _, _), .hook(_, _, _, _, _, let a, _, _),
      .subagent(_, _, _, _, _, let a, _, _), .command(_, _, _, _, let a, _, _),
      .lspServer(_, _, _, _, let a, _, _), .permissions(_, _, let a, _, _),
      .ignore(_, _, _, let a, _, _), .plugin(_, _, _, _, _, _, let a, _, _):
      a
    }
  }

  fileprivate func replacingAgents(_ agents: [AgentID]) -> ComponentDeclaration {
    switch self {
    case .skills(let source, var value):
      value.agents = agents
      return .skills(source: source, value)
    case .instructions(var value):
      value.agents = agents
      return .instructions(value)
    case .mcpServer(let n, let t, _, let c, let v, let registry):
      return .mcpServer(
        name: n, transport: t, agents: agents, condition: c, native: v, registry: registry)
    case .hook(let n, let e, let r, let m, let t, _, let c, let v):
      return .hook(
        name: n, event: e, run: r, matcher: m, timeoutSeconds: t, agents: agents, condition: c,
        native: v)
    case .subagent(let n, let d, let p, let m, let t, _, let c, let v):
      return .subagent(
        name: n, description: d, prompt: p, model: m, tools: t, agents: agents, condition: c,
        native: v)
    case .command(let n, let d, let p, let args, _, let c, let v):
      return .command(
        name: n, description: d, prompt: p, parameters: args, agents: agents, condition: c,
        native: v)
    case .lspServer(let n, let r, let l, let o, _, let c, let v):
      return .lspServer(
        name: n, run: r, languages: l, initializationOptions: o, agents: agents, condition: c,
        native: v)
    case .permissions(let n, let r, _, let c, let v):
      return .permissions(name: n, rules: r, agents: agents, condition: c, native: v)
    case .ignore(let n, let p, let u, _, let c, let v):
      return .ignore(name: n, patterns: p, purpose: u, agents: agents, condition: c, native: v)
    case .plugin(let n, let p, let s, let m, let select, let exclude, _, let c, let v):
      return .plugin(
        name: n, path: p, source: s, mode: m, select: select, exclude: exclude, agents: agents,
        condition: c, native: v)
    }
  }
}
