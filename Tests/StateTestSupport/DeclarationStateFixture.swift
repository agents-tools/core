import AgentsCore
import AgentsManifest
import Foundation

extension StateStore {
  package func save(declaration: Declaration, resolved: ResolvedState, watch: WatchState? = nil)
    throws
  {
    try withLock {
      try declaration.validate(environment: environment)
      try resolved.validate()
      try watch?.validate()
      let baseline = try StatePrecondition(store: self)
      let previous = try readDeclaration(prepared: baseline)
      var change = try planDeclaration(declaration, replacing: previous, prepared: baseline)
      if change == nil, try declarationBytes(prepared: baseline) == nil {
        change = DeclarationChange(bytes: Data("version: 1\n".utf8))
      }
      let transaction = FileTransaction(store: self)
      transaction.requireUnchanged(since: baseline)
      try stageDeclaration(change, in: transaction, prepared: baseline)
      let existing = try readLedger(prepared: baseline)
      let view = try existing.domainProjection(roots: ledgerRoots)
      guard resolved == ResolvedState() || view == resolved
      else {
        throw CoreError.invalidState("fixture must seed an explicit resolved ledger")
      }
      let ledger = resolved == ResolvedState() ? ResolvedLedger() : existing
      try stageLedger(ledger, limits: .standard, transaction: transaction, prepared: baseline)
      if let watch {
        try transaction.replace(
          watchURL, with: .data(StateStore.encode(watch)),
          expecting: baseline.evidence(for: watchURL))
      }
      try transaction.commit()
    }
  }

}

extension StateStore {
  package func save(
    declaration: Declaration, ledger: ResolvedLedger, watch: WatchState? = nil
  ) throws {
    try withLock {
      try declaration.validate(environment: environment)
      try watch?.validate()
      _ = try readWatch()
      let baseline = try StatePrecondition(store: self)
      let previous = try readDeclaration(prepared: baseline)
      let change =
        try planDeclaration(declaration, replacing: previous, prepared: baseline)
        ?? (try declarationBytes(prepared: baseline) == nil
          ? DeclarationChange(bytes: Data("version: 1\n".utf8)) : nil)
      let transaction = FileTransaction(store: self)
      transaction.requireUnchanged(since: baseline)
      try stageDeclaration(change, in: transaction, prepared: baseline)
      try stageLedger(ledger, limits: .standard, transaction: transaction, prepared: baseline)
      if let watch {
        try transaction.replace(
          watchURL, with: .data(StateStore.encode(watch)),
          expecting: baseline.evidence(for: watchURL))
      }
      try transaction.commit()
    }
  }
}
