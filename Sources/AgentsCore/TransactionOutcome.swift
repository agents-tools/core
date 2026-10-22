import Foundation

/// Tracks the generation established by its own journal, not preparatory cache publications.
package final class TransactionOutcome {
  package enum Disposition { case unchanged, committed, recoveryRequired }
  package var disposition: Disposition = .unchanged
  var journalID: UUID?

  package init() {}
}
