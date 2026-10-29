import Foundation

package struct TransactionRecoveryDiagnostic {
  package let requiresOwner: Bool
  package let message: String
}

extension FileTransaction {
  package static func recover(
    store: StateStore, outcome: TransactionOutcome? = nil,
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) throws -> Bool {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    guard try directory.info("transaction.json") != nil else {
      guard try directory.info("transaction.new") != nil else { return false }
      let bytes = try directory.read("transaction.new")
      if (try? JSONSerialization.jsonObject(with: bytes)) != nil {
        let journal = try readJournal(bytes)
        guard journal.phase == .preparing, journal.containers.allSatisfy({ $0.identity == nil }),
          journal.entries.allSatisfy({ $0.progress == .queued })
        else {
          throw CoreError.invalidState(
            "missing primary journal; retained transaction.new needs owner action")
        }
      }
      try directory.remove("transaction.new")
      return true
    }
    var recoveredID: UUID?
    do {
      let journal = try readJournal(directory.read("transaction.json"))
      recoveredID = journal.id
      let session = try recoverySession(
        journal, store: store, directory: directory, checkpoint: checkpoint)
      // Validate the journal's scratch file before any recovery mutation.
      if try directory.info("transaction.new") != nil { _ = try directory.read("transaction.new") }
      let observedTerminal = journal.phase == .committed || journal.phase == .rolledBack
      if journal.phase == .applying { try session.rollback() }
      if session.journal.phase == .applying || session.journal.phase == .preparing {
        try session.prepareCleanup()
        session.journal.phase = .rolledBack
        try session.persist(.terminal)
        try session.emit(.phase(.rolledBack))
      }
      try session.cleanup(observedTerminal: observedTerminal)
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
    var retained = [store.directory.appendingPathComponent("transaction.json").path]
    do {
      guard let directory = try store.openDirectoryIfPresent() else {
        return .init(
          requiresOwner: false,
          message:
            "Transaction recovery is pending; the next command that changes this scope will recover it."
        )
      }
      if try directory.info("transaction.json") == nil {
        if try directory.info("transaction.new") != nil {
          let bytes = try directory.read("transaction.new")
          if (try? JSONSerialization.jsonObject(with: bytes)) != nil {
            let incomplete = try readJournal(bytes)
            guard incomplete.phase == .preparing,
              incomplete.containers.allSatisfy({ $0.identity == nil }),
              incomplete.entries.allSatisfy({ $0.progress == .queued })
            else {
              throw CoreError.invalidState(
                "missing primary journal; retained transaction.new needs owner action")
            }
          }
        }
        return .init(
          requiresOwner: false,
          message:
            "Transaction recovery is pending; the next command that changes this scope will recover it."
        )
      }
      let journal = try readJournal(directory.read("transaction.json"))
      retained += journal.entries.compactMap { entry in
        guard journal.containers.indices.contains(entry.container) else { return nil }
        let container = journal.containers[entry.container]
        guard container.name == ".agents-\(journal.id.uuidString)-\(entry.container)" else {
          return nil
        }
        return entry.path.split(separator: "/").dropLast().joined(separator: "/")
          + "/" + container.name
      }
      let session = try recoverySession(
        journal, store: store, directory: directory, checkpoint: { _ in })
      let conflicts = journal.entries.compactMap(\.conflict)
      if !conflicts.isEmpty {
        let details = conflicts.map {
          "\($0.reason); retained locations: \($0.locations.joined(separator: ", "))"
        }
        return .init(
          requiresOwner: true,
          message: "Unresolved transaction conflict; owner action is required. "
            + details.joined(separator: "; ")
            + "; journal: " + directory.url.appendingPathComponent("transaction.json").path)
      }
      try session.inspectRecoveryObjects()
      return .init(
        requiresOwner: false,
        message:
          "Transaction recovery is pending; the next command that changes this scope will recover it."
      )
    } catch {
      return .init(
        requiresOwner: true,
        message:
          "Unresolved transaction conflict; owner action is required: \(error). Retained locations: \(Set(retained).sorted().joined(separator: ", "))."
      )
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
  func requireScope() throws {
    guard try DirectoryHandle(at: directory.url).identity == journal.scope else {
      throw CoreError.invalidState("transaction scope identity changed")
    }
  }

  func requireParent(_ index: Int) throws {
    guard
      try DirectoryHandle(at: parents[index].url).identity == journal.entries[index].parentIdentity
    else {
      throw conflict(index, "destination parent changed")
    }
  }

  func conflict(_ index: Int, _ reason: String) -> CoreError {
    .invalidState(
      "transaction conflict at \(journal.entries[index].path): \(reason); retained container: \(containerLocation(index))"
    )
  }

  func containerLocation(_ index: Int) -> String {
    let entry = journal.entries[index]
    guard journal.containers.indices.contains(entry.container) else {
      return "<invalid container reference \(entry.container)>"
    }
    return entry.path.split(separator: "/").dropLast().joined(separator: "/") + "/"
      + journal.containerName(entry.container)
  }

  func recordConflict(_ index: Int, _ error: Error) throws {
    journal.entries[index].conflict = .init(
      reason: String(describing: error),
      locations: [journal.entries[index].path, containerLocation(index)])
    try persist(.conflict(index, journal.entries[index].progress))
  }

  func validateRecords(store: StateStore) throws {
    try requireScope()
    let paths = TransactionPaths(store: store)
    let keys = try Set(journal.entries.map { try paths.components($0.path).root })
    guard keys == Set(journal.roots.keys), !journal.entries.isEmpty else {
      throw CoreError.invalidState("invalid transaction roots")
    }
    var targets: [URL] = []
    for (index, entry) in journal.entries.enumerated() {
      try requireParent(index)
      let target = parents[index].url.appendingPathComponent(entry.name)
      guard
        !targets.contains(where: {
          PathSafety.isContained(target, in: $0) || PathSafety.isContained($0, in: target)
        }),
        journal.containers.indices.contains(entry.container)
      else {
        throw conflict(index, "overlapping destinations or invalid container")
      }
      targets.append(target)
      try validateProgress(index)
      try entry.preimage?.validate()
      try entry.staged?.validate()
    }
    for index in journal.containers.indices { try validateContainerRecord(index) }
    for (index, entry) in journal.entries.enumerated() {
      if let conflict = entry.conflict,
        conflict.locations != [entry.path, containerLocation(index)]
      {
        throw CoreError.invalidState("invalid transaction conflict locations")
      }
    }
  }

  private func validateContainerRecord(_ index: Int) throws {
    let record = journal.containers[index]
    guard journal.entries.indices.contains(record.entry),
      journal.entries[record.entry].container == index,
      record.name == ".agents-\(journal.id.uuidString)-\(index)",
      record.identity?.isDirectory != false
    else {
      throw CoreError.invalidState("invalid private transaction container evidence")
    }
    for entry in journal.entries where entry.container == index {
      guard entry.parentIdentity == journal.entries[record.entry].parentIdentity else {
        throw CoreError.invalidState("private container belongs to another parent")
      }
      guard entry.progress == .queued || record.identity != nil else {
        throw CoreError.invalidState("sealed operation is missing private container identity")
      }
    }
    try record.cleanup?.validate()
    if let cleanup = record.cleanup {
      guard cleanup.identity == record.identity else {
        throw CoreError.invalidState("terminal container evidence has another identity")
      }
    }
    if journal.phase == .committed || journal.phase == .rolledBack {
      let containsUserData = journal.entries.filter { $0.container == index }.contains { entry in
        [.applied, .restored].contains(entry.progress)
          && TransactionLayout.expected(entry).contains { !$0.objects.isEmpty }
      }
      guard !containsUserData || record.cleanup != nil else {
        throw CoreError.invalidState("terminal container is missing user-object disposal evidence")
      }
    }
  }

  private func validateProgress(_ index: Int) throws {
    let entry = journal.entries[index]
    let allowed: Set<TransactionJournal.Progress>
    switch journal.phase {
    case .preparing: allowed = [.queued, .ready]
    case .applying: allowed = [.ready, .publishing, .applied, .restoring, .restored, .cancelled]
    case .committed: allowed = [.applied]
    case .rolledBack: allowed = [.queued, .ready, .restored, .cancelled]
    }
    let requiresStaging = entry.action == .install && entry.progress != .queued
    guard allowed.contains(entry.progress),
      (entry.staged != nil) == requiresStaging,
      !journal.discarding || journal.phase == .committed || journal.phase == .rolledBack
    else {
      throw conflict(index, "operation progress contradicts its evidence or journal phase")
    }
  }

  func distribution(_ index: Int, permittingDirectoryWrite: Bool = true) throws -> TransactionLayout
  {
    let entry = journal.entries[index]
    try requireParent(index)
    if entry.progress == .queued { return TransactionLayout.expected(entry)[0] }
    let scratch = try container(entry.container)
    let layouts = TransactionLayout.expected(entry)
    var objects: [TransactionScratch: FileSnapshot] = [:]
    for slot in TransactionScratch.objectSlots {
      if let value = try FileSnapshot.read(slot.name(index), from: scratch) {
        objects[slot] = value
      }
    }
    let permitsWrite = permittingDirectoryWrite && entry.progress.permitsDirectoryWrite
    for layout in layouts where Set(layout.objects.keys) == Set(objects.keys) {
      guard
        layout.objects.allSatisfy({ slot, expected in
          expected.matches(objects[slot]!, permittingDirectoryWrite: permitsWrite)
        })
      else { continue }
      if try layout.target.matches(
        entry.name, from: parents[index], permittingDirectoryWrite: permitsWrite)
      {
        return layout
      }
    }
    throw conflict(index, "missing or changed expected target, preimage or rollback quarantine")
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
    let layout = try distribution(index)
    let progress = journal.entries[index].progress
    if progress == .ready {
      try advance(index, to: .cancelled)
      return
    }
    if progress == .cancelled || progress == .restored { return }
    if layout.kind == .prepared {
      try restoreDirectoryPermissions(index, purpose: .cancelRestore)
      _ = try distribution(index, permittingDirectoryWrite: false)
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
    guard try distribution(index, permittingDirectoryWrite: false).kind == .reverted else {
      throw conflict(index, "undo did not restore the expected objects")
    }
    try advance(index, to: .restored)
  }

  private func undo(_ index: Int) throws {
    let entry = journal.entries[index]
    let parent = parents[index]
    let scratch = try container(entry.container)
    try emit(.restoration(index, .validated))
    if entry.preimage != nil {
      if entry.action == .install {
        try scratch.move(
          TransactionScratch.staged.name(index), to: parent, named: entry.name, mode: .exchange
        ) {
          try emit(.restoration(index, .exchanged))
        }
      } else {
        try scratch.move(
          TransactionScratch.preimage.name(index), to: parent, named: entry.name, mode: .exclusive
        ) {
          try emit(.restoration(index, .returned))
        }
      }
    } else if entry.action == .install {
      try parent.move(
        entry.name, to: scratch, named: TransactionScratch.removed.name(index), mode: .exclusive
      ) {
        try emit(.restoration(index, .creationQuarantined))
      }
    }
  }

  func prepareCleanup() throws {
    var userContainers: Set<Int> = []
    var layouts: [Int: TransactionLayout] = [:]
    for index in journal.entries.indices {
      do {
        let layout = try distribution(index)
        layouts[index] = layout
        if [.installed, .reverted].contains(layout.kind), !layout.objects.isEmpty {
          userContainers.insert(journal.entries[index].container)
        }
      } catch {
        try recordConflict(index, error)
        throw error
      }
    }
    for index in journal.containers.indices {
      do {
        try prepareContainerCleanup(
          index, userData: userContainers.contains(index), layouts: layouts)
      } catch {
        try recordConflict(journal.containers[index].entry, error)
        throw error
      }
    }
    for index in journal.entries.indices { journal.entries[index].conflict = nil }
  }

  private func prepareContainerCleanup(
    _ index: Int, userData: Bool, layouts: [Int: TransactionLayout]
  ) throws {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    if record.identity == nil {
      if try parent.info(record.name) != nil, try !parent.child(record.name).names().isEmpty {
        throw conflict(record.entry, "unidentified private container is not empty")
      }
      return
    }
    let handle = try container(index)
    guard userData else { return }
    let snapshot = try FileSnapshot.read(record.name, from: parent)
    guard try handle.objectIdentity == snapshot?.identity else {
      throw conflict(record.entry, "container changed while sealing disposal")
    }
    for entryIndex in journal.entries.indices where journal.entries[entryIndex].container == index {
      for (slot, expected) in layouts[entryIndex]!.objects {
        guard snapshot?.children?[slot.name(entryIndex)] == expected else {
          throw conflict(entryIndex, "expected user object changed while sealing disposal")
        }
      }
    }
    journal.containers[index].cleanup = snapshot
  }

  func inspectRecoveryObjects() throws {
    if journal.discarding {
      for index in journal.entries.indices { try verifyTarget(index) }
    } else {
      for index in journal.entries.indices {
        _ = try distribution(index)
        try inspectDirectoryPermissions(index)
      }
    }
    try validateContainersForDisposal()
  }

  func cleanup(observedTerminal: Bool = false) throws {
    try requireScope()
    if observedTerminal {
      // An observed terminal rename may not have reached its parent barrier.
      // Persist it before deleting any preimage or quarantine, including on retry.
      try directory.syncFile("transaction.json")
      try emit(.terminalSynced)
    }
    try validateCleanupOperations()
    do { try validateContainersForDisposal() } catch {
      if let index = journal.entries.indices.first { try recordConflict(index, error) }
      throw error
    }
    if !journal.discarding {
      journal.discarding = true
      try persist(.discard)
      try emit(.discardIntent)
    }
    for index in journal.containers.indices { try discardContainer(index) }
    try requireScope()
    try directory.removeJournal { try emit(.journalUnlinked) }
    try emit(.journalRemoved)
  }

  private func validateCleanupOperations() throws {
    for index in journal.entries.indices {
      do {
        if journal.discarding {
          try verifyTarget(index)
        } else {
          _ = try distribution(index)
        }
      } catch {
        try recordConflict(index, error)
        throw error
      }
    }
  }

  private func verifyTarget(_ index: Int) throws {
    let entry = journal.entries[index]
    try requireParent(index)
    // Terminal phases have a single distribution; disposal may have removed its scratch slots.
    guard try TransactionLayout.expected(entry)[0].target.matches(entry.name, from: parents[index])
    else {
      throw conflict(
        index,
        journal.phase == .committed
          ? "committed destination changed" : "restored destination changed")
    }
  }

  private func validateContainersForDisposal() throws {
    for index in journal.containers.indices {
      let record = journal.containers[index]
      let parent = parents[record.entry]
      try requireParent(record.entry)
      guard let actual = try parent.info(record.name) else {
        if journal.discarding || record.identity == nil { continue }
        throw conflict(record.entry, "private container disappeared before discard intent")
      }
      if let identity = record.identity {
        guard FileObjectIdentity(actual) == identity else {
          throw conflict(record.entry, "private container identity changed")
        }
        if let expected = record.cleanup {
          let current = try FileSnapshot.read(record.name, from: parent)
          let matches =
            journal.discarding
            ? current.map(expected.containsRemaining) == true : current == expected
          guard matches else { throw conflict(record.entry, "terminal disposal evidence changed") }
        }
      } else if try !parent.child(record.name).names().isEmpty {
        throw conflict(record.entry, "unidentified private container is not empty")
      }
    }
  }

  private func discardContainer(_ index: Int) throws {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    try requireScope()
    try requireParent(record.entry)
    if let identity = record.identity {
      try parent.remove(record.name, expecting: record.cleanup, identity: identity) {
        try emit(.disposal(index, $0))
      }
    } else {
      try parent.removeEmptyDirectory(record.name)
    }
    try emit(.containerRemoved(index))
  }
}
