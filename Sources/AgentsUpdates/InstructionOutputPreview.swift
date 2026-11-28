import AgentsCore
import AgentsInstructions
import AgentsManifest
import Components
import Foundation

enum InstructionOutputPreview {
  static func report(
    _ complete: DeploymentConstruction.Result, previous: ResolvedLedger, store: StateStore,
    baseline: StatePrecondition, roots: [String: URL], sourcePolicy: SourcePolicySnapshot,
    organization: OrganizationInstallEvaluation, initialFindings: [OrganizationPolicyFinding],
    acquisitions: GitAcquisitionCaptures
  ) throws -> CombinedUpdateReport {
    var prior = previous
    prior.deployments.removeAll { !InstructionLocations.isInstructionFormat($0.route) }
    prior.lowerings.removeAll {
      !InstructionLocations.isInstructionFormat($0.format) && $0.format != "agents/chatgpt@1"
        && $0.instructionCopyRecipient == nil
    }
    prior.nativeAuthorities = nil
    prior.marketplacePackages = nil
    prior.marketplaceGraph = nil
    return try LedgerReplay.withPreparedLowerings(
      complete.ledger, store: store, roots: roots, limits: .standard,
      sourcePolicy: sourcePolicy.effective,
      requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin,
      acquisitions: acquisitions
    ) { next, artifacts, resources, workspace in
      let aggregation = try ArtifactAggregation(
        ledger: next, previous: prior, artifacts: artifacts, resources: resources,
        workspace: workspace, store: store, roots: roots,
        replace: false, changingAccess: false, kinds: [.instructions],
        sourcePolicy: sourcePolicy.effective)
      let workspacePolicy = try OrganizationWorkspaceInspection(
        evaluator: organization.evaluator, store: store, ledger: aggregation.ledger,
        previous: previous, roots: roots, inspectDrift: false)
      let policyReport = try organization.policy.report(
        initialFindings
          + organization.instructionPreviewClosure(
            aggregation.ledger, previous: previous, roots: roots)
          + workspacePolicy.findings)
      try policyReport.requireAdmission()
      let lockMissing = try baseline.bytes(for: store.resolvedURL) == nil
      let report = try UpdateReporting.instructions(
        before: prior.domainProjection(roots: roots).instructions,
        after: aggregation.ledger.domainProjection(roots: roots).instructions,
        changes: aggregation.changes, ledger: aggregation.ledger, artifacts: artifacts,
        lockMissing: lockMissing, included: true, store: store,
        stateChanged: prior.lowerings.flatMap(\.artifacts) != next.lowerings.flatMap(\.artifacts),
        conflicts: aggregation.antigravityConflicts, includeUnmanagedForwardingContent: true)
      let locations =
        try UpdateOperations.readLocations(
          declarations: [], ledgers: [aggregation.ledger], store: store, roots: roots)
        + complete.inputs.map(\.url) + aggregation.instructionDecisionLocations
        + sourcePolicy.readDependencies.map(\.url)
        + organization.policy.readDependencies.map(\.url)
      try baseline.validate()
      try sourcePolicy.validate()
      try organization.policy.validate()
      return CombinedUpdateReport(
        scope: store.scope, skills: [], instructions: report, lockMissing: lockMissing,
        hasChanges: report.hasChanges, displayedFingerprint: try ResolvedLedgerCodec.digest(report),
        marketplaceChanges: nil, marketplaceGraphChange: nil,
        organizationPolicy: policyReport.policies.isEmpty ? nil : policyReport,
        archiveRepresentationChanges: nil,
        readLocations: Array(Set(locations)).sorted { $0.path < $1.path }, components: [])
    }
  }
}
