import AgentsCore
import Foundation

public struct MarketplaceLockReport: Codable, Equatable, Sendable {
  public let scope: InstallScope
  public let pendingDeployment: MarketplacePendingDeployment
  public let deployedGraph: MarketplaceGraph?
  public let marketplaceGraphChange: MarketplaceGraphUpdate?
  public let marketplaceChanges: [MarketplacePackageUpdate]?
  public let organizationPolicy: OrganizationPolicyReport?
  public let hasChanges: Bool
  public let displayedFingerprint: String
}

public struct MarketplaceLockPreview: Sendable {
  public let resolution: MarketplaceResolution
  public let report: MarketplaceLockReport
  fileprivate let request: MarketplaceResolutionRequest
  fileprivate let environment: RuntimeEnvironment
  fileprivate let captured: MarketplacePreparation?
  fileprivate let observations: String
  fileprivate let organization: OrganizationPolicySnapshot
}

public struct MarketplaceDeploymentPreview: Sendable {
  public let report: CombinedUpdateReport
  public let ownershipConflict: String?
  fileprivate let environment: RuntimeEnvironment
  fileprivate let replace: Bool
}

extension MarketplaceOperations {
  /// Resolves and freezes the selected recipients while leaving native targets untouched.
  public static func previewLockOnly(
    _ request: MarketplaceResolutionRequest = .reconcile, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> MarketplaceLockPreview {
    let store = StateStore(scope: scope, environment: environment)
    let preparation = try MarketplacePreparation(
      request, store: store, usingPendingResolution: true, hostedAccess: hostedAccess)
    let report = try preparation.withUpdateRequest(store: store, replace: false) { update in
      try UpdateOperations.marketplaceLockPlan(
        update, store: store, organizationPolicy: preparation.organizationPolicy
      ).report
    }
    return MarketplaceLockPreview(
      resolution: preparation.resolution, report: report, request: request,
      environment: environment, captured: preparation.usesHostedCatalog ? preparation : nil,
      observations: preparation.solution.observationDigest,
      organization: preparation.organizationPolicy)
  }

  /// Rechecks the reviewed inputs and commits only the declaration and pending resolution.
  /// Publication failures report their durable disposition in `UpdateApplyError`.
  @discardableResult
  public static func writeLockOnly(_ preview: MarketplaceLockPreview) throws
    -> MarketplaceLockReport
  {
    try writeLockOnly(preview, checkpoint: { _ in })
  }

  package static func writeLockOnly(
    _ preview: MarketplaceLockPreview, checkpoint: @escaping (String) throws -> Void
  ) throws -> MarketplaceLockReport {
    try withReviewedLockPlan(preview) { try $0.write(checkpoint: checkpoint) }
  }

  private static func withReviewedLockPlan<Value>(
    _ preview: MarketplaceLockPreview, _ body: (MarketplaceLockPlan) throws -> Value
  ) throws -> Value {
    let store = StateStore(scope: preview.report.scope, environment: preview.environment)
    let preparation: MarketplacePreparation
    if let captured = preview.captured {
      preparation = try captured.revalidating(in: store)
    } else {
      preparation = try MarketplacePreparation(
        preview.request, store: store, usingPendingResolution: true)
    }
    guard preview.observations == preparation.solution.observationDigest else {
      throw CoreError.invalidState("marketplace catalog changed; refresh the preview")
    }
    return try preparation.withUpdateRequest(store: store, replace: false) { update in
      let plan = try UpdateOperations.marketplaceLockPlan(
        update, store: store, organizationPolicy: preparation.organizationPolicy)
      guard preview.report.displayedFingerprint == plan.report.displayedFingerprint else {
        throw CoreError.invalidState("marketplace lock candidate changed; refresh the preview")
      }
      return try body(plan)
    }
  }

  public static func previewLockOnlyLifecycle(
    _ request: MarketplaceResolutionRequest = .reconcile, intent: LifecycleOperationIntent,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> LifecyclePackageReview<MarketplaceLockPreview, MarketplaceLockReport> {
    let context = LifecycleContext(scope: scope, environment: environment)
    let (discovery, root) = try context.capturePackageRoot()
    let preview = try previewLockOnly(
      request, scope: scope, environment: environment, hostedAccess: hostedAccess)
    let plan = try context.packagePlan(
      intent: intent, discovery: discovery, snapshot: preview.organization,
      findings: preview.report.organizationPolicy, usesPendingClosure: true
    ) { snapshot in
      try withReviewedLockPlan(preview) {
        try snapshot.requireSameLifecyclePolicy(as: $0.organizationPolicy)
      }
    }
    return LifecyclePackageReview(
      report: preview, lifecycle: plan.inspection, ownershipConflict: nil, plan: plan
    ) { _ in
      let outcome = TransactionOutcome()
      let result = Result {
        try withReviewedLockPlan(preview) {
          try $0.write(checkpoint: { _ in }, outcome: outcome, existingRoot: root)
        }
      }
      var recovered = false
      if case .failure(let error) = result,
        case CoreError.transactionRecovered = (error as? UpdateApplyError)?.underlyingError ?? error
      {
        recovered = true
      }
      return UpdateOperations.completion(
        result, outcome: outcome, recovered: recovered, store: context.store)
    }
  }

  public static func previewFrozenLifecycle(
    intent: LifecycleOperationIntent, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(), replace: Bool = false
  ) throws -> LifecyclePackageReview<CombinedUpdateReport, UpdateApplyResult> {
    try UpdateOperations.previewLifecycle(
      frozenDeploymentRequest(replace: replace), intent: intent, scope: scope,
      environment: environment)
  }

  /// Previews the pending closure using its exact frozen resources without catalog discovery.
  public static func previewFrozenDeployment(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    replace: Bool = false
  ) throws -> MarketplaceDeploymentPreview {
    let (report, conflict, _, _) = try UpdateOperations.previewWithOwnership(
      frozenDeploymentRequest(replace: replace), scope: scope, environment: environment)
    return MarketplaceDeploymentPreview(
      report: report, ownershipConflict: conflict, environment: environment, replace: replace)
  }

  /// Publishes the reviewed frozen deployment and retires the pending closure atomically.
  public static func deployFrozen(
    _ preview: MarketplaceDeploymentPreview,
    bindingProvider: (any RuntimeBindingProvider)? = nil
  ) throws -> UpdateApplyResult {
    if let conflict = preview.ownershipConflict { throw CoreError.invalidState(conflict) }
    let checkpoint: (String) throws -> Void = { _ in }
    return try UpdateOperations.prepare(
      frozenDeploymentRequest(replace: preview.replace), scope: preview.report.scope,
      environment: preview.environment, checkpoint: checkpoint,
      provider: bindingProvider ?? RequiredBindingProvider(),
      expectedFingerprint: preview.report.displayedFingerprint
    ) { try $0.apply(ifUnchangedFrom: preview.report.displayedFingerprint) }
  }

  /// Creates an offline deployment for callers using the shared preview and transaction lifecycle.
  public static func frozenDeploymentRequest(replace: Bool = false) -> UpdateRequest {
    var request = UpdateRequest(operation: .restore, replace: replace)
    request.deployPendingMarketplace = true
    return request
  }
}
