import AgentsCore
import AgentsManifest
import AgentsSkills
import Components
import Foundation

/// Read-only policy and CI evaluation. Only the selected policy transport may be consulted.
public enum OrganizationPolicyOperations {
  public static func status(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> OrganizationPolicyReport {
    let snapshot = try OrganizationPolicySnapshot(
      store: StateStore(scope: scope, environment: environment))
    let report = snapshot.report()
    return report.policies.isEmpty
      ? .init(policies: [.init(authority: scope, outcome: .absent)], findings: [])
      : report
  }

  public static func audit(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    requireOrganizationPolicy: Bool = false
  ) throws -> OrganizationPolicyAudit {
    let store = StateStore(scope: scope, environment: environment)
    let policy = try OrganizationPolicySnapshot(store: store)
    var routes = Set<NativeTargetRoute>()
    var installations: [String: SkillInstallationTarget] = [:]
    while true {
      do {
        return try store.withReadLock(footprint: routes, installations: Array(installations.values))
        {
          let hard = try SourcePolicySnapshot(store: store)
          let baseline = try StatePrecondition(store: store)
          let document = try store.declarationBytes(prepared: baseline)
          let declaration = try store.readDeclaration(prepared: baseline)
          let ledger = try store.readLedger(prepared: baseline)
          try environment.requireMCPRegistryRoutes(in: ledger)
          let hasLock = try baseline.bytes(for: store.resolvedURL) != nil
          let roots = store.ledgerRoots(recordedIn: ledger)
          let evaluation = try OrganizationInstallEvaluation(
            policy: policy, store: store, declaration: declaration, bytes: document)
          if evaluation.evaluator.chains.contains(where: { chain in
            chain.mode != .off && chain.layers.contains { $0.rules.failOnDrift }
          }) {
            let footprint = try DeploymentConstruction.routes(ledger)
            let targets = try SkillLifecycle.installationTargets(ledger, store: store)
            guard footprint.isSubset(of: routes),
              Set(targets.keys).isSubset(of: Set(installations.keys))
            else { throw RequiredRoutes(routes: footprint, installations: targets) }
          }
          let managed = try OrganizationWorkspaceInspection(
            evaluator: evaluation.evaluator, store: store, ledger: ledger, roots: roots,
            inspectDrift: true)
          var findings =
            try evaluation.beforeAcquisition()
            + evaluation.closure(hasLock ? ledger : nil, roots: roots) + managed.findings
          if requireOrganizationPolicy && policy.chains.isEmpty {
            findings.append(
              .init(
                subject: .policy, identity: "organization policy", rule: "policy-required",
                authority: scope, document: nil, documentDigest: nil, outcome: .block,
                message: "CI requires an admitted organization policy."))
          }
          var sourceViolations = try sourceViolations(
            hard.effective, declaration: declaration, ledger: ledger, store: store, roots: roots)
          let pendingPolicy: OrganizationPolicyReport?
          if let pending = ledger.pendingDeployment {
            let desired = try pending.desired(in: ledger)
            try environment.requireMCPRegistryRoutes(in: desired)
            let pendingViolations = try hard.effective.violations(
              in: desired, store: store, roots: roots)
            sourceViolations.append(
              contentsOf: pendingViolations.filter { violation in
                !sourceViolations.contains(violation)
              })
            pendingPolicy = try policy.report(
              evaluation.beforeAcquisition() + evaluation.closure(desired, roots: roots))
          } else {
            pendingPolicy = nil
          }
          let closureIssue: String?
          do {
            try MarketplaceChanges.validateInspection(
              declaration, bytes: document, ledger: ledger, store: store)
            closureIssue = nil
          } catch let error as MarketplaceError {
            closureIssue = error.description
          }
          try baseline.validate()
          try hard.validate()
          try policy.validate()
          try managed.validate()
          return OrganizationPolicyAudit(
            scope: scope, hasLock: hasLock, organization: policy.report(findings),
            sourceViolations: sourceViolations, closureIssue: closureIssue,
            pendingMarketplaceDeployment: ledger.pendingDeployment != nil,
            pendingMarketplacePolicy: pendingPolicy)
        }
      } catch let required as RequiredRoutes {
        routes.formUnion(required.routes)
        installations.merge(required.installations, uniquingKeysWith: { _, next in next })
      }
    }
  }

  private static func sourceViolations(
    _ policy: EffectiveSourcePolicy, declaration: Declaration, ledger: ResolvedLedger,
    store: StateStore, roots: [String: URL]
  ) throws -> [SourcePolicyViolation] {
    guard policy.isConfigured else { return [] }
    let recorded = try policy.violations(in: ledger, store: store, roots: roots)
    let authored = try declaration.sourceDeclarations.flatMap { entry -> [SourcePolicyViolation] in
      if entry.source.kind == .local,
        BundleSourceLocation.container(
          of: entry.source.localURL(environment: store.environment), in: store) != nil
      {
        return []
      }
      let origin = try SourceOrigin.declared(entry.source, in: store.environment)
      return policy.violations(for: origin, reference: entry.name)
    }
    return recorded
      + authored.filter { violation in
        !recorded.contains {
          $0.scope == violation.scope && $0.origin == violation.origin
            && $0.reason == violation.reason
        }
      }
  }
}

public struct OrganizationPolicyAudit: Encodable, Sendable {
  public let scope: InstallScope
  public let hasLock: Bool
  public let organization: OrganizationPolicyReport
  public let sourceViolations: [SourcePolicyViolation]
  public let closureIssue: String?
  public let pendingMarketplaceDeployment: Bool
  /// Policy findings for the requested closure. Workspace drift lives in `organization`.
  public let pendingMarketplacePolicy: OrganizationPolicyReport?
  public var isBlocked: Bool {
    organization.isBlocked || !sourceViolations.isEmpty || closureIssue != nil
      || pendingMarketplaceDeployment
  }
}

extension OrganizationPolicySnapshot {
  var evaluator: OrganizationPolicyEvaluator { .init(chains: chains) }

  func admit(_ findings: [OrganizationPolicyFinding] = []) throws {
    try report(findings).requireAdmission()
  }

  func requireSource(_ source: SourceDeclaration, reference: String, in store: StateStore) throws {
    try admit()
    guard evaluator.active else { return }
    try admit(
      evaluator.directSource(
        .declared(source, in: store.environment), root: source.path,
        requirement: source.requirement, reference: reference))
  }
}
