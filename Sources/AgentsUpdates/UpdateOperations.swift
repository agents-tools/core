import AgentsCore
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
    let store = StateStore(scope: scope, environment: environment)
    var admitted = Set<NativeTargetRoute>()
    while true {
      do {
        return try store.withReadLock(footprint: admitted) {
          try UpdatePlan.withPlan(
            request: request, store: store, admitted: admitted,
            checkpoint: checkpoint, provider: RequiredBindingProvider()
          ) { $0.report }
        }
      } catch let required as RequiredRoutes { admitted.formUnion(required.routes) }
    }
  }

  /// Holds admitted locks and borrowed resources through this synchronous, same-thread closure.
  public static func withPreparedUpdate<Result>(
    _ request: UpdateRequest = UpdateRequest(), scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    try withPreparedUpdate(
      request, scope: scope, environment: environment, checkpoint: { _ in }, body)
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
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result {
    let store = StateStore(scope: scope, environment: environment)
    let outcome = TransactionOutcome()
    var delivered = false
    var returned = false
    var admitted = Set<NativeTargetRoute>()
    while true {
      do {
        return try store.withLock(checkpoint: checkpoint, outcome: outcome, footprint: admitted) {
          try UpdatePlan.withPlan(
            request: request, store: store, admitted: admitted,
            checkpoint: checkpoint, provider: provider
          ) { plan in
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
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> UpdateApplyResult {
    try withPreparedUpdate(
      UpdateRequest(operation: .restore), scope: scope, environment: environment
    ) { try $0.apply() }
  }
}
