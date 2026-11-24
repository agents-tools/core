import Foundation

/// Tracks the generation established by its own journal, not preparatory cache publications.
package final class TransactionOutcome {
  package enum Disposition { case unchanged, committed, recoveryRequired }
  private var reportedDisposition: Disposition = .unchanged
  package var disposition: Disposition {
    get { terminal == .committed ? .committed : reportedDisposition }
    set {
      reportedDisposition = newValue
      if newValue == .recoveryRequired { recoveryPending = true }
    }
  }
  package enum Terminal { case committed, rolledBack }
  package private(set) var terminal: Terminal?
  package var recoveryPending = false
  var journalID: UUID?
  package var publicationStarted = false

  func recordTerminal(_ phase: TransactionJournal.Phase) {
    guard phase == .committed || phase == .rolledBack else { return }
    terminal = phase == .committed ? .committed : .rolledBack
    disposition = phase == .committed ? .committed : .unchanged
  }

  func requireRecovery() {
    recoveryPending = true
    if terminal == nil { disposition = .recoveryRequired }
  }

  package init() {}
}
