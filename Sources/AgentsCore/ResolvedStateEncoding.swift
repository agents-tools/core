import Foundation

extension ResolvedState {
  /// Producers compare the complete ledger before serializing. An unchanged ledger retains
  /// its original bytes even when a declaration or physical target needs a transaction.
  package func replacementData(comparedTo existing: Data?) throws -> Data? {
    if let existing {
      let previous = try StateStore.decode(existing, as: ResolvedState.self)
      if normalized == previous.normalized { return nil }
    }
    return try StateStore.encodeState(normalized)
  }

  /// The replacement for the prepared generation's lock. A scope whose prepared generation has
  /// neither a lock nor a declaration receives no empty ledger, because lock state without a
  /// declaration stops every later access to the scope.
  package func replacementData(in store: StateStore, prepared: StatePrecondition) throws -> Data? {
    let existing = try prepared.bytes(for: store.resolvedURL)
    if existing == nil, try prepared.bytes(for: store.declarationURL) == nil,
      normalized == ResolvedState().normalized
    {
      return nil
    }
    return try replacementData(comparedTo: existing)
  }
}
