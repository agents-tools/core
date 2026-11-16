import AgentsCore

/// The outer operation's disposition after writer-lock recovery and cleanup have returned.
public enum UpdateTerminalDisposition: String, Sendable {
  case unchanged, rolledBack, committed, recoveryRequired
}

public struct UpdateCompletion<Value> {
  public let result: Result<Value, any Error>
  public let disposition: UpdateTerminalDisposition
  public let recoveredBeforePreparation: Bool
  public let recovery: RecoveryInspection
}

extension UpdateCompletion: Sendable where Value: Sendable {}

extension UpdateOperations {
  /// Returns only after the synchronous closure, source lifetime and outer scope cleanup end.
  /// UI consumers reprepare and compare the displayed fingerprint inside this closure.
  public static func perform<Value>(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    perform(
      request, scope: scope, environment: environment, bindingProvider: bindingProvider,
      checkpoint: { _ in }, body)
  }

  package static func perform<Value>(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    bindingProvider: (any RuntimeBindingProvider)? = nil,
    checkpoint: @escaping (String) throws -> Void,
    _ body: (PreparedUpdate) throws -> Value
  ) -> UpdateCompletion<Value> {
    var disposition = UpdateTerminalDisposition.unchanged
    var delivered = false
    var recovered = false
    let result = Result {
      do {
        return try prepare(
          request, scope: scope, environment: environment, checkpoint: checkpoint,
          provider: bindingProvider ?? RequiredBindingProvider(),
          completion: { outcome in
            switch outcome.disposition {
            case .committed: disposition = .committed
            case .recoveryRequired: disposition = .recoveryRequired
            case .unchanged: disposition = outcome.publicationStarted ? .rolledBack : .unchanged
            }
          }
        ) { update in
          delivered = true
          return try body(update)
        }
      } catch {
        let underlying = (error as? UpdateApplyError)?.underlyingError ?? error
        if !delivered, case CoreError.transactionRecovered = underlying { recovered = true }
        throw error
      }
    }
    let store = StateStore(scope: scope, environment: environment)
    let recovery: RecoveryInspection
    do {
      recovery = try store.withReadLock(
        onPendingRecovery: {
          let diagnostic = FileTransaction.recoveryDiagnostic(store: store)
          return .init(
            pending: true, requiresOwner: diagnostic.requiresOwner, diagnostic: diagnostic.message)
        }, { .init(pending: false, requiresOwner: false, diagnostic: nil) })
    } catch {
      // Failure to inspect cleanup is itself material; do not downgrade it to success.
      recovery = .init(
        pending: true, requiresOwner: true,
        diagnostic: "recovery or cleanup could not be verified; retain this scope for diagnosis")
    }
    if recovery.pending, disposition != .committed { disposition = .recoveryRequired }
    return UpdateCompletion(
      result: result, disposition: disposition,
      recoveredBeforePreparation: recovered, recovery: recovery)
  }
}
