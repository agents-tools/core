import Foundation

package struct TransactionRecoveryDiagnostic {
  package let requiresOwner: Bool
  package let message: String

  static let pendingMessage =
    "Transaction recovery is pending; the next command that changes this scope will recover it."
  static let conflictMessage = "Unresolved transaction conflict; owner action is required"
}

extension FileTransaction {
  package static func recover(
    store: StateStore, outcome: TransactionOutcome? = nil,
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) throws -> Bool {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    let primary = TransactionJournal.fileName
    let incomplete = TransactionJournal.incompleteFileName
    guard try directory.info(primary) != nil else {
      guard try directory.info(incomplete) != nil else { return false }
      // An unstarted journal owns no object, so it is discarded without a journal barrier.
      try requireUnstartedIncompleteJournal(in: directory)
      try directory.remove(incomplete)
      return true
    }
    var recoveredID: UUID?
    do {
      let journal = try readJournal(directory.read(primary))
      recoveredID = journal.id
      let session = try recoverySession(
        journal, store: store, directory: directory, checkpoint: checkpoint)
      // Validate the incomplete next generation before any recovery mutation.
      if try directory.info(incomplete) != nil { _ = try directory.read(incomplete) }
      // Any observed journal may have been renamed without its directory barrier. Persist it
      // before granting permissions, renaming objects or deleting any resource, including on retry.
      try directory.syncFile(primary)
      try session.emit(.journalSynced)
      if journal.phase == .applying { try session.rollback() }
      if session.journal.phase == .applying || session.journal.phase == .preparing {
        try session.sealDisposal()
        try session.finish(.rolledBack)
        try session.emit(.phase(.rolledBack))
      }
      try session.revalidateDisposal()
      if outcome?.journalID == journal.id {
        outcome?.disposition = session.journal.phase == .committed ? .committed : .unchanged
      }
      return true
    } catch {
      // An unreadable journal cannot prove an unchanged or committed outcome.
      if recoveredID == nil || outcome?.journalID == recoveredID {
        outcome?.disposition = .recoveryRequired
      }
      throw error
    }
  }

  package static func recoveryDiagnostic(store: StateStore) -> TransactionRecoveryDiagnostic {
    let journalURL = store.directory.appendingPathComponent(TransactionJournal.fileName)
    var retained = [journalURL.path]
    do {
      guard let directory = try store.openDirectoryIfPresent() else {
        return .init(requiresOwner: false, message: TransactionRecoveryDiagnostic.pendingMessage)
      }
      if try directory.info(TransactionJournal.fileName) == nil {
        if try directory.info(TransactionJournal.incompleteFileName) != nil {
          try requireUnstartedIncompleteJournal(in: directory)
        }
        return .init(requiresOwner: false, message: TransactionRecoveryDiagnostic.pendingMessage)
      }
      let journal = try readJournal(directory.read(TransactionJournal.fileName))
      retained += journal.entries.compactMap(journal.containerLocation(of:))
      let session = try recoverySession(
        journal, store: store, directory: directory, checkpoint: { _ in })
      let conflicts = journal.entries.compactMap(\.conflict)
      if !conflicts.isEmpty {
        let details = conflicts.map {
          "\($0.reason); retained locations: \($0.locations.joined(separator: ", "))"
        }
        return .init(
          requiresOwner: true,
          message: TransactionRecoveryDiagnostic.conflictMessage + ". "
            + details.joined(separator: "; ") + "; journal: " + journalURL.path)
      }
      try session.inspectRecoveryObjects()
      return .init(requiresOwner: false, message: TransactionRecoveryDiagnostic.pendingMessage)
    } catch {
      return .init(
        requiresOwner: true,
        message:
          "\(TransactionRecoveryDiagnostic.conflictMessage): \(error). Retained locations: \(Set(retained).sorted().joined(separator: ", "))."
      )
    }
  }

  /// A lone incomplete journal may be discarded only while it is unparseable or unstarted.
  private static func requireUnstartedIncompleteJournal(in directory: DirectoryHandle) throws {
    let bytes = try directory.read(TransactionJournal.incompleteFileName)
    guard (try? JSONSerialization.jsonObject(with: bytes)) != nil else { return }
    guard try readJournal(bytes).isUnstarted else {
      throw CoreError.invalidState(
        "missing primary journal; retained transaction.new needs owner action")
    }
  }

  private static func readJournal(_ bytes: Data) throws -> TransactionJournal {
    try JSONKeys.validate(bytes)
    let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    guard value?["version"] as? Int == TransactionJournal.currentVersion else {
      throw CoreError.invalidState(
        "transaction journal was written by another version; recover it with the version that wrote it (journal version: \(value?["version"].map(String.init(describing:)) ?? "missing"))"
      )
    }
    do { return try StateStore.decode(bytes, as: TransactionJournal.self) } catch {
      throw CoreError.invalidState("unresolved transaction journal: \(error)")
    }
  }

  private static func recoverySession(
    _ journal: TransactionJournal, store: StateStore,
    directory: DirectoryHandle, checkpoint: @escaping (String) throws -> Void
  ) throws -> TransactionSession {
    let paths = TransactionPaths(store: store)
    var roots: [String: DirectoryHandle] = [:]
    for key in journal.roots.keys {
      let root = try paths.root(key)
      guard try root.identity == journal.roots[key] else {
        throw CoreError.invalidState("transaction root identity changed")
      }
      roots[key] = root
    }
    let parents = try journal.entries.map { try paths.parent(for: $0.path, roots: roots) }
    let session = TransactionSession(
      journal: journal, directory: directory, parents: parents, checkpoint: checkpoint)
    try session.validateRecords(store: store)
    return session
  }
}

extension TransactionSession {
  /// Read-only diagnosis of the distribution recovery would act on.
  func inspectRecoveryObjects() throws {
    for index in journal.entries.indices {
      if journal.disposing {
        try verifyTarget(index)
      } else {
        _ = try distribution(index, permittingDirectoryWrite: true)
        try inspectDirectoryPermissions(index)
      }
    }
    for index in journal.containers.indices { try validateContainerForDisposal(index) }
  }

  func rollback() throws {
    var errors: [String] = []
    for index in journal.entries.indices.reversed() {
      do { try rollbackEntry(index) } catch {
        var reasons = [String(describing: error)]
        if journal.entries[index].progress.permitsDirectoryWrite {
          do { try restoreDirectoryPermissions(index, purpose: .conflictRestore) } catch {
            reasons.append(String(describing: error))
          }
        }
        let failure = CoreError.invalidState(reasons.joined(separator: "; "))
        try recordConflict(index, failure)
        errors.append(String(describing: failure))
      }
    }
    guard errors.isEmpty else {
      throw CoreError.invalidState(
        "unresolved transaction conflicts: " + errors.joined(separator: "; "))
    }
  }

  private func rollbackEntry(_ index: Int) throws {
    let layout = try distribution(index, permittingDirectoryWrite: true)
    let progress = journal.entries[index].progress
    if progress == .ready {
      try advance(index, to: .cancelled)
      return
    }
    if progress == .cancelled || progress == .restored { return }
    if layout.kind == .prepared {
      try restoreDirectoryPermissions(index, purpose: .cancelRestore)
      _ = try distribution(index)
      try advance(index, to: .cancelled)
      return
    }
    if progress != .restoring { try advance(index, to: .restoring) }
    if layout.kind == .installed {
      try grantDirectoryPermissions(index, layout: layout, purpose: .undoGrant)
      try undo(index)
    } else {
      // A visible undo rename may have been interrupted before either parent barrier.
      try parents[index].sync()
      try container(journal.entries[index].container).sync()
    }
    try restoreDirectoryPermissions(index, purpose: .undoRestore)
    try emit(.restoration(index, .synced))
    guard try distribution(index).kind == .reverted else {
      throw conflict(index, "undo did not restore the expected objects")
    }
    try advance(index, to: .restored)
  }

  private func undo(_ index: Int) throws {
    let entry = journal.entries[index]
    let parent = parents[index]
    let container = try self.container(entry.container)
    try emit(.restoration(index, .validated))
    if entry.preimage != nil {
      if entry.action == .install {
        try container.move(
          TransactionSlot.exchanged.name(index), to: parent, named: entry.name,
          mode: .exchange
        ) {
          try emit(.restoration(index, .exchanged))
        }
      } else {
        try container.move(
          TransactionSlot.deleted.name(index), to: parent, named: entry.name, mode: .exclusive
        ) {
          try emit(.restoration(index, .returned))
        }
      }
    } else if entry.action == .install {
      try parent.move(
        entry.name, to: container, named: TransactionSlot.withdrawn.name(index), mode: .exclusive
      ) {
        try emit(.restoration(index, .withdrawn))
      }
    }
  }
}
