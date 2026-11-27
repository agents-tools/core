import AgentsCore
import Foundation

public struct BundleImportSelection: Equatable, Sendable {
  public let componentID: String
  public let targets: [AgentID]

  public init(componentID: String, targets: [AgentID]) {
    self.componentID = componentID
    self.targets = targets
  }
}

public struct BundleImportPreview: Sendable {
  public let package: BundlePackage
  public let archiveDigest: String
  public let selections: [BundleImportSelection]
  public let report: CombinedUpdateReport
  /// An ownership conflict detected by the update transaction's normal target admission.
  public let ownershipConflict: String?
  fileprivate let marketplace: (package: VerifiedMarketplacePackage, name: String)?
  fileprivate let bundle: BundleInspection
  fileprivate let environment: RuntimeEnvironment
  fileprivate let replace: Bool
  fileprivate let organization: OrganizationPolicySnapshot
  fileprivate let routes: Set<NativeTargetRoute>
  fileprivate let installations: [String: SkillInstallationTarget]
}

extension BundleOperations {
  /// Plans only the requested entries and recipients. A conflicting native composition may
  /// throw before a report can be produced. Replace opts into the ordinary instruction policy.
  public static func previewImport(
    _ bundle: BundleInspection, selections: [BundleImportSelection], scope: InstallScope,
    environment: RuntimeEnvironment, replace: Bool = false
  ) throws -> BundleImportPreview {
    try makeImportPreview(
      bundle, selections: selections, scope: scope, environment: environment,
      replace: replace, marketplace: nil)
  }

  static func makeImportPreview(
    _ bundle: BundleInspection, selections: [BundleImportSelection], scope: InstallScope,
    environment: RuntimeEnvironment, replace: Bool,
    marketplace: (package: VerifiedMarketplacePackage, name: String)?
  ) throws -> BundleImportPreview {
    guard bundle.package.dependencies == nil else {
      throw MarketplaceError.dependenciesRequireResolution(bundle.package.name)
    }
    let store = StateStore(scope: scope, environment: environment)
    return try BundleInstallation.withStagedSources(
      bundle, selections: selections, store: store, marketplace: marketplace?.package
    ) { installation in
      let request = try installation.importRequest(replace: replace, marketplace: marketplace)
      let (report, conflict, routes, installations) = try UpdateOperations.previewWithOwnership(
        request, scope: scope, environment: environment,
        organizationPolicy: installation.organizationPolicy)
      return BundleImportPreview(
        package: bundle.package, archiveDigest: bundle.archiveDigest, selections: selections,
        report: report, ownershipConflict: conflict, marketplace: marketplace, bundle: bundle,
        environment: environment,
        replace: replace, organization: installation.organizationPolicy, routes: routes,
        installations: installations)
    }
  }

  public static func previewImportLifecycle(
    _ bundle: BundleInspection, selections: [BundleImportSelection],
    intent: LifecycleOperationIntent, scope: InstallScope,
    environment: RuntimeEnvironment, replace: Bool = false
  ) throws -> LifecyclePackageReview<BundleImportPreview, UpdateApplyResult> {
    try reviewImportLifecycle(intent: intent, scope: scope, environment: environment) {
      try previewImport(
        bundle, selections: selections, scope: scope, environment: environment, replace: replace)
    }
  }

  static func reviewImportLifecycle(
    intent: LifecycleOperationIntent, scope: InstallScope, environment: RuntimeEnvironment,
    preview preparePreview: @escaping @Sendable () throws -> BundleImportPreview
  ) throws -> LifecyclePackageReview<BundleImportPreview, UpdateApplyResult> {
    let context = LifecycleContext(scope: scope, environment: environment)
    let (discovery, root) = try context.capturePackageRoot()
    let preview = try preparePreview()
    let plan = try context.packagePlan(
      intent: intent, discovery: discovery, snapshot: preview.organization,
      findings: preview.report.organizationPolicy, ownershipConflict: preview.ownershipConflict
    ) { snapshot in
      let current = try preparePreview()
      try snapshot.requireSameLifecyclePolicy(as: current.organization)
      if let conflict = current.ownershipConflict { throw CoreError.invalidState(conflict) }
    }
    return LifecyclePackageReview(
      report: preview, lifecycle: plan.inspection, ownershipConflict: preview.ownershipConflict,
      plan: plan
    ) { provider in
      performImport(preview, bindingProvider: provider, existingRoot: root) {
        try $0.apply(ifUnchangedFrom: preview.report.displayedFingerprint)
      }
    }
  }

  /// Re-prepares the displayed selection under the writer lock. The closure must call
  /// PreparedUpdate.apply to publish. A changed destination requires a fresh preview.
  public static func withPreparedImport<Result>(
    _ preview: BundleImportPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try prepareImport(preview, bindingProvider: bindingProvider, completion: nil, body)
  }

  /// Reports publication, rollback and outstanding recovery after a prepared import finishes.
  public static func performImport<Value>(
    _ preview: BundleImportPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    performImport(preview, bindingProvider: bindingProvider, existingRoot: nil, body)
  }

  private static func performImport<Value>(
    _ preview: BundleImportPreview, bindingProvider: (any RuntimeBindingProvider)?,
    existingRoot: ExistingProjectRoot?, _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    var outcome = TransactionOutcome()
    var delivered = false
    let result = Result {
      try prepareImport(
        preview, bindingProvider: bindingProvider, completion: { outcome = $0 },
        existingRoot: existingRoot
      ) {
        update in
        delivered = true
        return try body(update)
      }
    }
    let recovered: Bool
    if !delivered, case .failure(let error) = result,
      case CoreError.transactionRecovered = (error as? UpdateApplyError)?.underlyingError ?? error
    {
      recovered = true
    } else {
      recovered = false
    }
    return UpdateOperations.completion(
      result, outcome: outcome, recovered: recovered,
      store: StateStore(scope: preview.report.scope, environment: preview.environment))
  }

  private static func prepareImport<Value>(
    _ preview: BundleImportPreview, bindingProvider: (any RuntimeBindingProvider)?,
    completion: ((TransactionOutcome) -> Void)?, existingRoot: ExistingProjectRoot? = nil,
    _ body: (PreparedUpdate) throws -> Value
  ) throws -> Value {
    if let conflict = preview.ownershipConflict {
      throw CoreError.invalidState(conflict)
    }
    let store = StateStore(scope: preview.report.scope, environment: preview.environment)
    return try BundleInstallation.withStagedSources(
      preview.bundle, selections: preview.selections, store: store,
      marketplace: preview.marketplace?.package
    ) { installation in
      let request = try installation.importRequest(
        replace: preview.replace, marketplace: preview.marketplace)
      return try UpdateOperations.prepare(
        request, scope: store.scope, environment: store.environment, checkpoint: { _ in },
        provider: bindingProvider ?? RequiredBindingProvider(), completion: completion,
        admittedRoutes: preview.routes,
        admittedInstallations: preview.installations,
        admittedOrganizationPolicy: installation.organizationPolicy, existingRoot: existingRoot
      ) { update in
        guard update.report.displayedFingerprint == preview.report.displayedFingerprint else {
          throw CoreError.invalidState("bundle import destination changed; refresh the preview")
        }
        return try body(update)
      }
    }
  }
}

extension BundleInstallation {
  fileprivate func importRequest(
    replace: Bool, marketplace: (package: VerifiedMarketplacePackage, name: String)?
  ) throws -> UpdateRequest {
    var request = UpdateRequest(replace: replace)
    request.bundleInstallation = self
    guard let marketplace else { return request }
    return try marketplace.package.bindingImport(
      request, as: marketplace.name, sourceAliases: members.map(\.alias))
  }
}
