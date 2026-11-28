import AgentsCore
import AgentsInstructions
import AgentsManifest
import Foundation

struct RequiredBindingProvider: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    throw CoreError.invalidState("this materialization requires a runtime binding provider")
  }
}

public enum UpdateOperations {
  public static func preview(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> CombinedUpdateReport {
    try preview(request, scope: scope, environment: environment, checkpoint: { _ in })
  }

  package static func preview(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    checkpoint: @escaping (String) throws -> Void
  ) throws -> CombinedUpdateReport {
    try withPreview(request, scope: scope, environment: environment, checkpoint: checkpoint) {
      plan, _, _ in plan.report
    }
  }

  static func previewInstructionOutputs(
    scope: InstallScope, environment: RuntimeEnvironment
  ) throws -> CombinedUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    let organization = try OrganizationPolicySnapshot(store: store)
    let acquisitions = GitAcquisitionCaptures()
    return try withReadPlan(store: store) { admitted, installations in
      try UpdatePlan.withPlan(
        request: UpdateRequest(kinds: [.instructions]), store: store, admitted: admitted,
        installations: installations, checkpoint: { _ in }, provider: RequiredBindingProvider(),
        organizationPolicy: organization, acquisitions: acquisitions,
        instructionPreview: { $0 },
        { _ in throw CoreError.invalidState("instruction output preview requires compilation") })
    }
  }

  static func previewWithOwnership(
    _ request: UpdateRequest, scope: InstallScope, environment: RuntimeEnvironment,
    organizationPolicy: OrganizationPolicySnapshot? = nil
  ) throws -> (
    CombinedUpdateReport, String?, Set<NativeTargetRoute>, [String: SkillInstallationTarget]
  ) {
    try withPreview(
      request, scope: scope, environment: environment, organizationPolicy: organizationPolicy
    ) { plan, routes, installations in
      do {
        try plan.requireOwnership()
        return (plan.report, nil, routes, installations)
      } catch {
        return (plan.report, String(describing: error), routes, installations)
      }
    }
  }

  private static func withPreview<Result>(
    _ request: UpdateRequest, scope: InstallScope, environment: RuntimeEnvironment,
    checkpoint: @escaping (String) throws -> Void = { _ in },
    organizationPolicy: OrganizationPolicySnapshot? = nil,
    acquisitions: GitAcquisitionCaptures = .init(),
    _ body: (UpdatePlan, Set<NativeTargetRoute>, [String: SkillInstallationTarget]) throws -> Result
  ) throws -> Result {
    let store = StateStore(scope: scope, environment: environment)
    try request.capturedAddition?.validate(request, in: store)
    let organization =
      try organizationPolicy
      ?? OrganizationPolicySnapshot(
        store: store, offline: request.restoresOffline)
    return try withReadPlan(store: store) { admitted, installations in
      try UpdatePlan.withPlan(
        request: request, store: store, admitted: admitted, installations: installations,
        checkpoint: checkpoint, provider: RequiredBindingProvider(),
        organizationPolicy: organization, acquisitions: acquisitions
      ) { try body($0, admitted, installations) }
    }
  }

  static func marketplaceLockPlan(
    _ request: UpdateRequest, store: StateStore, organizationPolicy: OrganizationPolicySnapshot
  ) throws -> MarketplaceLockPlan {
    let acquisitions = GitAcquisitionCaptures()
    return try withReadPlan(store: store) { admitted, installations in
      try UpdatePlan.withPlan(
        request: request, store: store, admitted: admitted, installations: installations,
        checkpoint: { _ in }, provider: RequiredBindingProvider(),
        organizationPolicy: organizationPolicy, acquisitions: acquisitions, marketplaceLock: { $0 }
      ) { _ in throw CoreError.invalidState("a lock-only write requires a marketplace resolution") }
    }
  }

  static func withReadPlan<Result>(
    store: StateStore,
    _ body: (Set<NativeTargetRoute>, [String: SkillInstallationTarget]) throws -> Result
  ) throws -> Result {
    var admitted = Set<NativeTargetRoute>()
    var installations: [String: SkillInstallationTarget] = [:]
    while true {
      do {
        return try store.withReadLock(
          footprint: admitted, installations: Array(installations.values)
        ) {
          try body(admitted, installations)
        }
      } catch let required as RequiredRoutes {
        admitted.formUnion(required.routes)
        installations.merge(required.installations, uniquingKeysWith: { _, next in next })
      }
    }
  }

  /// Holds admitted locks and borrowed resources through this synchronous, same-thread closure.
  public static func withPreparedUpdate<Result>(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try prepare(
      request, scope: scope, environment: environment, checkpoint: { _ in },
      provider: bindingProvider ?? RequiredBindingProvider(), body)
  }

  package static func withPreparedUpdate<Result>(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    checkpoint: @escaping (String) throws -> Void,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try prepare(
      request, scope: scope, environment: environment, checkpoint: checkpoint,
      provider: RequiredBindingProvider(), body)
  }

  package static func prepare<Result>(
    _ request: UpdateRequest, scope: InstallScope, environment: RuntimeEnvironment,
    checkpoint: @escaping (String) throws -> Void, provider: any RuntimeBindingProvider,
    completion: ((TransactionOutcome) -> Void)? = nil,
    admittedRoutes: Set<NativeTargetRoute> = [],
    admittedInstallations: [String: SkillInstallationTarget] = [:],
    admittedOrganizationPolicy: OrganizationPolicySnapshot? = nil,
    expectedFingerprint: String? = nil,
    existingRoot: ExistingProjectRoot? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    let store = StateStore(scope: scope, environment: environment)
    try request.capturedAddition?.validate(request, in: store)
    let outcome = TransactionOutcome()
    defer { completion?(outcome) }
    var delivered = false
    var returned = false
    var admitted = admittedRoutes
    var installations = admittedInstallations
    let organization =
      try admittedOrganizationPolicy
      ?? OrganizationPolicySnapshot(
        store: store, offline: request.restoresOffline)
    let acquisitions = GitAcquisitionCaptures()
    var preflight: UpdatePlan.Admission?
    if expectedFingerprint != nil || OrganizationPolicySnapshot.configured(store) {
      do {
        preflight = try withPreview(
          request, scope: scope, environment: environment, organizationPolicy: organization,
          acquisitions: acquisitions
        ) { plan, routes, targets in
          admitted.formUnion(routes)
          installations.merge(targets, uniquingKeysWith: { _, selected in selected })
          return plan.admission
        }
      } catch let error as CoreError {
        guard case .recoveryPending = error, expectedFingerprint == nil else { throw error }
        // The ordinary writer owns pending recovery and reports that the command must be retried.
      }
    }
    if let expectedFingerprint, preflight?.fingerprint != expectedFingerprint {
      throw CoreError.invalidState("marketplace deployment changed; refresh the preview")
    }
    let validatePreflight: () throws -> Void = { try preflight?.validate() }
    while true {
      do {
        try validatePreflight()
        return try store.withLock(
          checkpoint: checkpoint, outcome: outcome, footprint: admitted,
          installations: Array(installations.values), existingRoot: existingRoot,
          beforeScopeLock: validatePreflight
        ) {
          try UpdatePlan.withPlan(
            request: request, store: store, admitted: admitted, installations: installations,
            checkpoint: checkpoint, provider: provider, organizationPolicy: organization,
            acquisitions: acquisitions
          ) { plan in
            if let preflight, plan.report.displayedFingerprint != preflight.fingerprint {
              throw CoreError.invalidState(
                "update inputs changed after organization policy admission")
            }
            do {
              try plan.requireOwnership()
            } catch let error as InstructionError {
              throw UpdateApplyError(outcome: outcome, underlyingError: error)
            }
            let update = PreparedUpdate(plan: plan, outcome: outcome)
            defer { update.invalidate() }
            delivered = true
            let result = try body(update)
            returned = true
            return result
          }
        }
      } catch let required as RequiredRoutes where !delivered {
        admitted.formUnion(required.routes)
        installations.merge(required.installations, uniquingKeysWith: { _, next in next })
      } catch {
        if returned || error is UpdateApplyError {
          throw UpdateApplyError(outcome: outcome, underlyingError: error)
        }
        throw error
      }
    }
  }

  static func withDomainUpdate<Result>(
    _ request: UpdateRequest, scope: InstallScope, environment: RuntimeEnvironment,
    checkpoint: @escaping (String) throws -> Void = { _ in },
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    do {
      return try withPreparedUpdate(
        request, scope: scope, environment: environment, checkpoint: checkpoint, body)
    } catch let error as UpdateApplyError {
      if case .unchanged = error.disposition { throw error.underlyingError }
      throw error
    }
  }

  static func declarationSnapshot(_ store: StateStore) throws -> (Declaration, String) {
    try store.withReadLock {
      let document = try store.declarationDocument(prepared: nil)
      return (try store.readDeclaration(), document?.digest ?? "absent")
    }
  }

  public static func restore(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    bindingProvider: (any RuntimeBindingProvider)? = nil, offline: Bool = false
  ) throws -> UpdateApplyResult {
    try withPreparedUpdate(
      UpdateRequest(operation: .restore, offline: offline), scope: scope, environment: environment,
      bindingProvider: bindingProvider
    ) { try $0.apply() }
  }
}
