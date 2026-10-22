import AgentsCore
import Foundation

public enum UpdateOperations {
  /// Resolves a fresh, read-only report under one shared scope lock. Pending recovery stops inspection.
  public static func preview(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> CombinedUpdateReport {
    try preview(scope: scope, environment: environment, checkpoint: { _ in })
  }

  package static func preview(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    checkpoint: @escaping (String) throws -> Void
  ) throws -> CombinedUpdateReport {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock { try UpdatePlan(store: store, checkpoint: checkpoint).report }
  }

  /// Holds the writer lock through preparation, synchronous rendering and optional application.
  /// Returning or throwing before apply cancels. A caller error after apply does not undo the commit.
  public static func withPreparedUpdate<Result>(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try withPreparedUpdate(scope: scope, environment: environment, checkpoint: { _ in }, body)
  }

  package static func withPreparedUpdate<Result>(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    checkpoint: @escaping (String) throws -> Void,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    let store = StateStore(scope: scope, environment: environment)
    let outcome = TransactionOutcome()
    var returned = false
    do {
      return try store.withLock(checkpoint: checkpoint, outcome: outcome) {
        let plan = try UpdatePlan(store: store, checkpoint: checkpoint)
        try plan.validateOwnership()
        let update = PreparedUpdate(plan: plan, outcome: outcome)
        defer { update.invalidate() }
        let result = try body(update)
        returned = true
        return result
      }
    } catch {
      if returned || error is UpdateApplyError {
        throw UpdateApplyError(outcome: outcome, underlyingError: error)
      }
      throw error
    }
  }
}
