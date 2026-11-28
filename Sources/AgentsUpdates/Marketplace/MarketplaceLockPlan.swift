import AgentsCore
import AgentsManifest
import Foundation

/// The reviewed desired closure has no native authority. Its publication preserves the outer
/// ledger that owns the actual workspace and writes only the declaration and resolved file.
struct MarketplaceLockPlan: PreparedEvidence {
  let report: MarketplaceLockReport
  let store: StateStore
  let baseline: StatePrecondition
  let sourcePolicy: SourcePolicySnapshot
  let organizationPolicy: OrganizationPolicySnapshot
  let graphChange: MarketplaceGraphChange
  let roots: [String: URL]
  let inputs: UpdateInputs
  let declaration: DeclarationChange?
  let ledger: ResolvedLedger
  let acquisitions: GitAcquisitionCaptures
  let requireRecordedTransport: Bool
  let previousReferences: RetentionReferences

  init(
    store: StateStore, baseline: StatePrecondition, sourcePolicy: SourcePolicySnapshot,
    organization: OrganizationInstallEvaluation, initialFindings: [OrganizationPolicyFinding],
    graphChange: MarketplaceGraphChange, previous: ResolvedLedger, desired: ResolvedLedger,
    declaration: DeclarationChange?, roots: [String: URL], resources: [String: URL],
    decisionInputs: [TargetPrecondition], originalInputs: [TargetPrecondition],
    acquisitions: GitAcquisitionCaptures
  ) throws {
    var desired = desired
    desired.nativeAuthorities = nil
    try sourcePolicy.effective.require(desired, store: store, roots: roots)
    if desired.sources.values.contains(where: { $0.archive != nil }) {
      try SourceCache(store: store).requireArchivePublicationAccess()
    }
    let policyReport = try organization.policy.report(
      initialFindings + organization.closure(desired, roots: roots))
    try policyReport.requireAdmission()

    guard
      desired.marketplaceGraph != nil || previous.marketplaceGraph != nil
        || previous.pendingDeployment != nil,
      let bytes = try declaration?.bytes ?? baseline.bytes(for: store.declarationURL)
    else { throw CoreError.notFound("marketplace requirements to lock") }
    let pending = try MarketplacePendingDeploymentRecord(
      ledger: desired, deployed: previous, declarationDigest: BundleArchive.digest(bytes))
    var next = previous
    next.pendingDeployment = pending
    // Validate the exact wire record before asking for writer ownership.
    _ = try ResolvedLedgerCodec.encode(next, limits: .standard)

    self.store = store
    self.acquisitions = acquisitions
    requireRecordedTransport = organization.evaluator.requiresRecordedGitOrigin
    self.baseline = baseline
    self.sourcePolicy = sourcePolicy
    organizationPolicy = organization.policy
    self.graphChange = graphChange
    self.roots = roots
    inputs = try UpdateInputs(
      ledger: desired, roots: roots, resources: resources,
      decisions: decisionInputs, originals: originalInputs)
    self.declaration = declaration
    ledger = next
    previousReferences = try RetentionReferences(ledger: previous, roots: roots)
    report = try MarketplaceLockReport(
      scope: store.scope, pendingDeployment: pending.info, deployedGraph: previous.marketplaceGraph,
      marketplaceGraphChange: MarketplaceGraphUpdate.between(previous, desired),
      marketplaceChanges: MarketplacePackageUpdate.between(previous, desired),
      organizationPolicy: policyReport.policies.isEmpty ? nil : policyReport,
      hasChanges: previous != next || declaration != nil,
      displayedFingerprint: ResolvedLedgerCodec.digest([
        graphChange.stateDigest, graphChange.policyFingerprint, pending.digest,
        pending.declarationDigest, ResolvedLedgerCodec.digest(policyReport.findings),
      ]))
    try validate()
  }

  func validate(excludingTargets targets: Set<String> = []) throws {
    try baseline.validate(excludingTargets: targets)
    try sourcePolicy.validate(excludingTargets: targets)
    try organizationPolicy.validate(excludingTargets: targets)
    try inputs.validate(excludingTargets: targets)
    try graphChange.validateCatalogs(in: store)
  }

  func write(
    checkpoint: @escaping (String) throws -> Void,
    outcome: TransactionOutcome = TransactionOutcome(),
    existingRoot: ExistingProjectRoot? = nil
  ) throws -> MarketplaceLockReport {
    let validateBeforeLock = { try validate() }
    do {
      return try store.withLock(
        checkpoint: checkpoint, outcome: outcome, existingRoot: existingRoot,
        beforeScopeLock: validateBeforeLock
      ) {
        try validate()
        try graphChange.validate(
          baseline, policy: sourcePolicy, organizationPolicy: organizationPolicy, store: store)
        try ledger.validate()
        if let pending = ledger.pendingDeployment {
          try sourcePolicy.effective.require(
            pending.desired(in: ledger), store: store, roots: roots)
        }
        if report.hasChanges {
          let cache = SourceCache(
            store: store, sourcePolicy: sourcePolicy.effective,
            requireRecordedTransport: requireRecordedTransport, acquisitions: acquisitions,
            checkpoint: checkpoint)
          try cache.withArchivePublication(
            previous: previousReferences,
            next: RetentionReferences(ledger: ledger, roots: roots), offline: false
          ) {
            if let pending = ledger.pendingDeployment {
              try cache.retain(
                references: RetentionReferences(ledger: pending.desired(in: ledger), roots: roots))
            }
            let transaction = FileTransaction(
              store: store, outcome: outcome, checkpoint: checkpoint)
            transaction.requireUnchanged(since: self)
            try store.stageDeclaration(declaration, in: transaction, prepared: baseline)
            try store.stageLedger(
              ledger, limits: .standard, transaction: transaction, prepared: baseline)
            try transaction.commit()
          }
        }
        organizationPolicy.rememberVerifiedPolicies()
        return report
      }
    } catch {
      throw UpdateApplyError(outcome: outcome, underlyingError: error)
    }
  }
}

extension MarketplacePendingDeploymentRecord {
  func requireDeclaration(_ bytes: Data?) throws {
    guard let bytes, declarationDigest == BundleArchive.digest(bytes) else {
      throw MarketplaceError.changedPendingDeclaration
    }
  }
}
