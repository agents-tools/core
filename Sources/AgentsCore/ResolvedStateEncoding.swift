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
}
