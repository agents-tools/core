import AgentsCore
import AgentsManifest
import Foundation

public struct SourcePolicyInspection: Sendable, Encodable {
  public let effective: EffectiveSourcePolicy
  public let readDependencies: [ReadDependency]
}

public struct SourcePolicyAudit: Sendable, Encodable {
  public let scope: InstallScope
  public let hasLock: Bool
  public let policy: SourcePolicyInspection
  public let violations: [SourcePolicyViolation]
}

/// Source policy can be inspected and audited without acquisition, recovery or writes.
public enum SourcePolicyOperations {
  public static func policyURL(
    scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> URL {
    SourcePolicySnapshot.policyURL(in: StateStore(scope: scope, environment: environment))
  }

  public static func inspect(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> SourcePolicyInspection {
    let snapshot = try SourcePolicySnapshot(
      store: StateStore(scope: scope, environment: environment))
    return .init(effective: snapshot.effective, readDependencies: snapshot.readDependencies)
  }

  /// Evaluates the complete committed provenance. `hasLock` indicates whether an exact closure
  /// was available for the audit. Unresolved declarations require an ordinary install preview.
  public static func audit(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> SourcePolicyAudit {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let snapshot = try SourcePolicySnapshot(store: store)
      let baseline = try StatePrecondition(store: store)
      _ = try store.declarationBytes(prepared: baseline)
      let ledger = try store.readLedger(prepared: baseline)
      try environment.requireMCPRegistryRoutes(in: ledger)
      if let pending = ledger.pendingDeployment {
        try environment.requireMCPRegistryRoutes(in: pending.desired(in: ledger))
      }
      let failures = try snapshot.effective.violations(
        in: ledger, store: store, roots: store.ledgerRoots(recordedIn: ledger))
      try baseline.validate()
      try snapshot.validate()
      return .init(
        scope: scope, hasLock: try baseline.bytes(for: store.resolvedURL) != nil,
        policy: .init(
          effective: snapshot.effective,
          readDependencies: snapshot.readDependencies
            + [.entry(store.declarationURL), .entry(store.resolvedURL)]),
        violations: failures)
    }
  }
}
