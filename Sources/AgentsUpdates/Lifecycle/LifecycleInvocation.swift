import AgentsCore
import AgentsInstructions
import AgentsManifest
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct LifecycleInvocation: Sendable {
  let context: LifecycleContext
  let discovery: LifecycleDiscovery
  let inspection: LifecycleInspection
  let pre: LifecycleEvent
  let post: LifecycleEvent?
  let receipt: LifecycleTrustRecord?
  let offline: Bool
  let policyFingerprint: String?
  let requireInstallPreview: Bool
  let usesPendingClosure: Bool
  let preflight: (@Sendable (OrganizationPolicySnapshot) throws -> Void)?

  init(
    context: LifecycleContext, discovery: LifecycleDiscovery? = nil,
    pre: LifecycleEvent, post: LifecycleEvent? = nil, offline: Bool = false, policy: Policy,
    requireInstallPreview: Bool = false, usesPendingClosure: Bool = false,
    preflight: (@Sendable (OrganizationPolicySnapshot) throws -> Void)? = nil
  ) {
    self.context = context
    let discovery = discovery ?? context.discover()
    self.discovery = discovery
    self.pre = pre
    self.post = post
    self.offline = offline
    self.requireInstallPreview = requireInstallPreview
    self.preflight = preflight
    self.usesPendingClosure = usesPendingClosure
    policyFingerprint = policy.snapshot?.fingerprint
    let observation = Result { try context.trustReceipt(discovery.root) }
    receipt = try? observation.get()
    inspection = context.inspection(
      discovery, events: Set([pre] + (post.map { [$0] } ?? [])), policy: policy.withheld,
      receipt: observation)
  }

  struct Policy {
    let snapshot: OrganizationPolicySnapshot?
    let withheld: LifecycleWithholding?
  }

  static func policy(
    context: LifecycleContext, offline: Bool, expected: String?, requireInstallPreview: Bool,
    snapshot: OrganizationPolicySnapshot? = nil, findings: OrganizationPolicyReport? = nil
  ) -> Policy {
    if context.disabled { return Policy(snapshot: nil, withheld: .disabled) }
    do {
      let current =
        try snapshot ?? OrganizationPolicySnapshot(store: context.store, offline: offline)
      if current.statuses.contains(where: { $0.outcome != .loaded })
        || current.loadFindings.contains(where: { $0.rule == "policy-unavailable" })
      {
        return Policy(snapshot: current, withheld: .policyUnavailable)
      }
      if current.chains.contains(where: { chain in
        chain.mode != .off && chain.layers.contains { $0.rules.executableDenyAll }
      }) {
        return Policy(snapshot: current, withheld: .policyDenied)
      }
      guard expected == nil || expected == current.fingerprint else {
        return Policy(snapshot: current, withheld: .policyDenied)
      }
      if current.report().isBlocked || findings?.isBlocked == true {
        return Policy(snapshot: current, withheld: .packageAdmission)
      }
      if requireInstallPreview {
        do {
          let (_, conflict, _, _) = try UpdateOperations.previewWithOwnership(
            UpdateRequest(), scope: context.store.scope, environment: context.store.environment,
            organizationPolicy: current)
          if conflict != nil { return Policy(snapshot: current, withheld: .packageAdmission) }
        } catch CoreError.recoveryPending {
          return Policy(snapshot: current, withheld: .recoveryPending)
        } catch {
          return Policy(snapshot: current, withheld: .packageAdmission)
        }
      }
      return Policy(snapshot: current, withheld: nil)
    } catch {
      return Policy(snapshot: nil, withheld: .policyUnavailable)
    }
  }

  func validateRoot() throws {
    if let project = discovery.root {
      guard try LifecycleProjectIdentity(context.openProject()) == project else {
        throw CoreError.invalidState("The reviewed project root changed.")
      }
    }
  }

  private func validateInstalledPolicy(_ policy: OrganizationPolicySnapshot) throws {
    let store = context.store
    try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let declaration = try store.readDeclaration(prepared: baseline)
      let bytes = try store.declarationBytes(prepared: baseline)
      let ledger = try store.readLedger(prepared: baseline)
      let selected =
        try usesPendingClosure ? ledger.pendingDeployment?.desired(in: ledger) : ledger
      let evaluation = try OrganizationInstallEvaluation(
        policy: policy, store: store, declaration: declaration, bytes: bytes)
      try policy.admit(
        evaluation.beforeAcquisition()
          + evaluation.closure(
            selected, roots: store.ledgerRoots(recordedIn: ledger)))
      try baseline.validate()
    }
  }

  private struct Withheld: Error {
    let reason: LifecycleWithholding
    var diagnostics: [LifecycleDiagnostic] = []
  }

  private func handoff<Value>(
    _ captured: CapturedLifecycleAction, _ start: (DirectoryHandle) throws -> Value
  ) throws -> Value {
    LifecycleOperations.checkpoint?.notify(.beforeHandoff)
    if Task.isCancelled { throw Withheld(reason: .cancelled) }
    do {
      try context.store.withReadLock {}
    } catch {
      throw Withheld(reason: .recoveryPending)
    }
    let policy = Self.policy(
      context: context, offline: offline, expected: policyFingerprint,
      requireInstallPreview: requireInstallPreview)
    if let reason = policy.withheld { throw Withheld(reason: reason) }
    if let snapshot = policy.snapshot, snapshot.evaluator.active {
      do {
        if captured.value.event == pre {
          try preflight?(snapshot)
        } else {
          try validateInstalledPolicy(snapshot)
        }
      } catch { throw Withheld(reason: .packageAdmission) }
    }

    func requireCurrentSource() throws {
      let current = context.discover()
      if current.administratorInvalid {
        throw Withheld(
          reason: .administratorSourceInvalid,
          diagnostics: current.diagnostics.filter { $0.source.authority == .administrator })
      }
      guard current.root == discovery.root else { throw Withheld(reason: .projectChanged) }
      guard current.actions.contains(where: captured.matches) else {
        throw Withheld(
          reason: .sourceChanged,
          diagnostics: current.diagnostics.filter { $0.source == captured.source })
      }
    }

    func admitAndStart() throws -> Value {
      if Task.isCancelled { throw Withheld(reason: .cancelled) }
      if context.disabled { throw Withheld(reason: .disabled) }
      if captured.source.authority == .project {
        let latest: LifecycleTrustRecord?
        do { latest = try context.trustReceipt(discovery.root) } catch {
          throw Withheld(reason: .receiptUnavailable)
        }
        guard latest?.revision == receipt?.revision, latest?.digest == captured.digest else {
          throw Withheld(reason: .trustChanged)
        }
      }
      let directory: DirectoryHandle
      switch context.store.scope {
      case .project:
        guard let expected = discovery.root, let opened = try? context.openProject(),
          (try? LifecycleProjectIdentity(opened)) == expected
        else { throw Withheld(reason: .projectChanged) }
        directory = opened
      case .user:
        guard let home = try? context.openHome() else { throw Withheld(reason: .sourceChanged) }
        directory = home
      }
      do { try policy.snapshot?.validate() } catch { throw Withheld(reason: .policyUnavailable) }
      if Task.isCancelled { throw Withheld(reason: .cancelled) }
      let launched = try start(directory)
      LifecycleOperations.checkpoint?.notify(.handedOff)
      return launched
    }

    try requireCurrentSource()
    if captured.source.authority == .project, let root = discovery.root {
      var waited = false
      do {
        return try context.withHandoff(
          for: root, onContention: { waited = true },
          {
            if waited { try requireCurrentSource() }
            return try admitAndStart()
          })
      } catch let refusal as Withheld {
        throw refusal
      } catch let failure as DuplexProcessError {
        throw failure
      } catch {
        throw Withheld(reason: Task.isCancelled ? .cancelled : .receiptUnavailable)
      }
    }
    return try admitAndStart()
  }

  enum Pending {
    case complete(LifecycleActionResult)
    case web(LifecycleHTTPTransfer)
  }

  func run(
    _ event: LifecycleEvent, test: Bool, client: LifecycleHTTPClient, session: URLSession,
    withheld: LifecycleWithholding? = nil,
    onDispatch: (@Sendable (LifecycleActionSummary) -> Void)? = nil
  ) async -> [Pending] {
    let actions = discovery.actions.filter { $0.value.event == event }
    let summaries = inspection.actions.filter { $0.event == event }
    guard !actions.isEmpty else { return [] }
    guard
      let payload = try? JSONEncoder().encode(
        LifecyclePayload(event: event, scope: context.store.scope, test: test))
    else {
      return summaries.map { .complete(.withheld($0, reason: .packageAdmission)) }
    }

    var results: [Pending] = []
    for (action, summary) in zip(actions, summaries) {
      if let reason = withheld ?? summary.withheld {
        results.append(.complete(.withheld(summary, reason: reason)))
        continue
      }
      do {
        switch action.value.body {
        case .command:
          let process = try handoff(action) {
            try LifecycleCommand.spawn(action, in: $0, environment: context.store.environment)
          }
          onDispatch?(summary)
          let result = await LifecycleCommand.finish(process, action: summary, payload: payload)
          results.append(.complete(result))
        case .http:
          guard
            let input = LifecycleHTTPInput(
              action: action.value, environment: context.store.environment.environment,
              payload: payload)
          else {
            results.append(.complete(.withheld(summary, reason: .headerExpansionRefused)))
            continue
          }
          let transfer = try handoff(action) { _ in
            client.start(input.request, in: session, action: summary)
          }
          onDispatch?(summary)
          if test {
            results.append(.complete(await transfer.result()))
          } else {
            results.append(.web(transfer))
          }
        }
      } catch let refusal as Withheld {
        results.append(
          .complete(
            .withheld(
              summary, reason: refusal.reason, diagnostics: refusal.diagnostics)))
      } catch {
        results.append(.complete(LifecycleCommand.launchFailed(summary)))
      }
    }
    return results
  }

  static func drain(
    _ results: [Pending], by deadline: ContinuousClock.Instant? = nil
  ) async -> [LifecycleActionResult] {
    var completed: [LifecycleActionResult] = []
    for result in results {
      switch result {
      case .complete(let action): completed.append(action)
      case .web(let transfer): completed.append(await transfer.result(drainBy: deadline))
      }
    }
    return completed
  }
}

extension LifecycleOperations {
  public static func simulate(
    _ event: LifecycleEvent = .postInstall, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> LifecycleTestReview {
    let context = LifecycleContext(scope: scope, environment: environment)
    let policy = LifecycleInvocation.policy(
      context: context, offline: false, expected: nil, requireInstallPreview: true)
    let plan = LifecycleInvocation(
      context: context, pre: event, policy: policy, requireInstallPreview: true)
    return LifecycleTestReview(inspection: plan.inspection, plan: plan)
  }

  public static func executeTest(
    _ review: LifecycleTestReview,
    onDispatch: (@Sendable (LifecycleActionSummary) -> Void)? = nil
  ) async -> LifecycleSubmission<[LifecycleActionResult]> {
    await review.confirmation.submit {
      checkpoint?.notify(.confirmationClaimed)
      let client = LifecycleHTTPClient()
      let session = client.session()
      defer { session.invalidateAndCancel() }
      return await LifecycleInvocation.drain(
        review.plan.run(
          review.plan.pre, test: true, client: client, session: session, onDispatch: onDispatch))
    }
  }
}

extension UpdateOperations {
  /// Read-only package and lifecycle preparation with an explicit operation intent.
  public static func previewLifecycle(
    _ request: UpdateRequest = UpdateRequest(), intent: LifecycleOperationIntent,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LifecyclePackageReview<CombinedUpdateReport, UpdateApplyResult> {
    let context = LifecycleContext(scope: scope, environment: environment)
    let (discovery, existingRoot) = try context.capturePackageRoot()
    let offline = request.deployPendingMarketplace
    let snapshot = try OrganizationPolicySnapshot(store: context.store, offline: offline)
    let (report, conflict, _, _) = try previewWithOwnership(
      request, scope: scope, environment: environment, organizationPolicy: snapshot)
    let plan = try context.packagePlan(
      intent: intent, discovery: discovery, offline: offline, snapshot: snapshot,
      findings: report.organizationPolicy, ownershipConflict: conflict
    ) { current in
      let (_, currentConflict, _, _) = try previewWithOwnership(
        request, scope: scope, environment: environment, organizationPolicy: current)
      if let currentConflict { throw CoreError.invalidState(currentConflict) }
    }
    return LifecyclePackageReview(
      report: report, lifecycle: plan.inspection, ownershipConflict: conflict, plan: plan
    ) { bindingProvider in
      perform(
        request, scope: scope, environment: environment, bindingProvider: bindingProvider,
        checkpoint: { try LifecycleOperations.transactionCheckpointForTesting?($0) },
        existingRoot: existingRoot,
        expectedFingerprint: offline ? report.displayedFingerprint : nil
      ) { try $0.apply(ifUnchangedFrom: report.displayedFingerprint) }
    }
  }

  /// Consumes a reviewed invocation. Effects are owned by the same in-memory confirmation.
  public static func perform<Report: Sendable, Value: Sendable>(
    _ review: LifecyclePackageReview<Report, Value>,
    bindingProvider: (any RuntimeBindingProvider)? = nil,
    onDispatch: (@Sendable (LifecycleActionSummary) -> Void)? = nil
  ) async -> LifecycleSubmission<LifecycleInvocationResult<Value>> {
    await review.confirmation.submit {
      LifecycleOperations.checkpoint?.notify(.confirmationClaimed)
      let plan = review.plan
      let client = LifecycleHTTPClient()
      let session = client.session()
      defer { session.invalidateAndCancel() }
      let pre = await plan.run(
        plan.pre, test: false, client: client, session: session, onDispatch: onDispatch)
      let package: UpdateCompletion<Value>
      do {
        try Task.checkCancellation()
        try plan.validateRoot()
        package = review.apply(bindingProvider)
      } catch {
        package = completion(
          .failure(error), outcome: TransactionOutcome(), recovered: false,
          store: plan.context.store)
      }
      let postReason: LifecycleWithholding?
      if Task.isCancelled {
        postReason = .cancelled
      } else if package.recovery.pending || package.recoveredBeforePreparation {
        postReason = .recoveryPending
      } else if case .success = package.result, package.disposition != .rolledBack,
        package.disposition != .recoveryRequired
      {
        postReason = nil
      } else {
        postReason = .packageDidNotComplete
      }
      let post: [LifecycleInvocation.Pending]
      if let event = plan.post {
        post = await plan.run(
          event, test: false, client: client, session: session, withheld: postReason,
          onDispatch: onDispatch)
      } else {
        post = []
      }
      let deadline = ContinuousClock.now + .seconds(10)
      return await LifecycleInvocationResult(
        package: package, pre: LifecycleInvocation.drain(pre, by: deadline),
        post: LifecycleInvocation.drain(post, by: deadline))
    }
  }
}

extension InstructionOperations {
  /// Reviews the same request used by updateInstalled, with pre-compile lifecycle intent.
  public static func previewCompilation(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(), replace: Bool = false
  ) throws -> LifecyclePackageReview<CombinedUpdateReport, UpdateApplyResult> {
    try UpdateOperations.previewLifecycle(
      installedUpdateRequest(
        scope: scope, agents: agents, environment: environment, replace: replace),
      intent: .compile, scope: scope, environment: environment)
  }
}

extension LifecycleContext {
  func capturePackageRoot() throws -> (LifecycleDiscovery, ExistingProjectRoot?) {
    let existing = try? store.captureExistingProjectRoot()
    let discovery = discover()
    try existing?.validateForLifecycle()
    return (discovery, existing)
  }

  func packagePlan(
    intent: LifecycleOperationIntent, discovery: LifecycleDiscovery, offline: Bool = false,
    snapshot: OrganizationPolicySnapshot, findings: OrganizationPolicyReport?,
    ownershipConflict: String? = nil, usesPendingClosure: Bool = false,
    preflight: (@Sendable (OrganizationPolicySnapshot) throws -> Void)? = nil
  ) throws -> LifecycleInvocation {
    let events = intent.events
    let policy = LifecycleInvocation.policy(
      context: self, offline: offline, expected: nil, requireInstallPreview: false,
      snapshot: snapshot, findings: findings)
    let plan = LifecycleInvocation(
      context: self, discovery: discovery, pre: events.pre, post: events.post, offline: offline,
      policy: ownershipConflict == nil
        ? policy : .init(snapshot: snapshot, withheld: .packageAdmission),
      usesPendingClosure: usesPendingClosure, preflight: preflight)
    try plan.validateRoot()
    return plan
  }
}

extension OrganizationPolicySnapshot {
  func requireSameLifecyclePolicy(as fresh: Self) throws {
    guard fingerprint == fresh.fingerprint else {
      throw CoreError.invalidState("Organization policy changed during lifecycle admission.")
    }
  }
}
