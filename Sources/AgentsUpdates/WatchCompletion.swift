import AgentsCore
import AgentsSkills

extension UpdateOperations {
  /// Acknowledges exactly the displayed content in its captured scope and environment.
  public static func performWatch(
    _ status: WatchStatus,
    operations: WatchOperations = SkillOperations.watchOperations()
  ) -> UpdateCompletion<WatchChange> {
    performWatch(operations.previewSeen(status), operations: operations)
  }

  /// Uses WatchOperations' single subscription writer, then reports its actual outer terminal.
  public static func performWatch(
    _ preview: WatchMutationPreview,
    operations: WatchOperations = SkillOperations.watchOperations()
  ) -> UpdateCompletion<WatchChange> {
    let outcome = TransactionOutcome()
    var recovered = false
    let result = Result {
      do { return try operations.apply(preview, outcome: outcome) } catch {
        if case CoreError.transactionRecovered = error { recovered = true }
        throw error
      }
    }
    return completion(result, outcome: outcome, recovered: recovered, store: preview.store)
  }
}
