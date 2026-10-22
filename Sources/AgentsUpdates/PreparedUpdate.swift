import AgentsCore
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Valid only on the preparing thread, inside `withPreparedUpdate`. Any apply attempt consumes it.
/// Render `report` directly; re-entering scope operations while this handle is active can deadlock.
public final class PreparedUpdate {
  public let report: CombinedUpdateReport
  private var plan: UpdatePlan?
  private let outcome: TransactionOutcome
  private let owner = pthread_self()
  private let gate = NSLock()
  private var active = true
  private var attempted = false

  init(plan: UpdatePlan, outcome: TransactionOutcome) {
    self.plan = plan
    report = plan.report
    self.outcome = outcome
  }

  public func apply() throws -> UpdateApplyResult {
    let plan = try gate.withLock {
      guard active, !attempted, let plan else {
        throw CoreError.invalidState("prepared update is inactive, consumed or on another thread")
      }
      attempted = true
      guard pthread_equal(owner, pthread_self()) != 0 else {
        throw CoreError.invalidState("prepared update belongs to another thread")
      }
      return plan
    }
    do {
      return try plan.apply(outcome: outcome)
    } catch {
      plan.recover(outcome: outcome)
      throw UpdateApplyError(outcome: outcome, underlyingError: error)
    }
  }

  func invalidate() {
    gate.withLock {
      active = false
      plan = nil
    }
  }
}
