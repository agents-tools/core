import Foundation

extension TransactionSession {
  /// Verifies every expected distribution and seals disposal evidence for containers that
  /// hold user data. A failure is recorded on the entry or container that caused it.
  func prepareCleanup() throws {
    let layouts = try journal.entries.indices.map { index in
      do { return try distribution(index) } catch {
        try recordConflict(index, error)
        throw error
      }
    }
    var userContainers: Set<Int> = []
    for (index, layout) in layouts.enumerated()
    where [.installed, .reverted].contains(layout.kind) && !layout.objects.isEmpty {
      userContainers.insert(journal.entries[index].container)
    }
    for index in journal.containers.indices {
      do {
        try sealDisposal(index, userData: userContainers.contains(index), layouts: layouts)
      } catch {
        try recordConflict(journal.containers[index].entry, error)
        throw error
      }
    }
    for index in journal.entries.indices { journal.entries[index].conflict = nil }
  }

  private func sealDisposal(_ index: Int, userData: Bool, layouts: [TransactionLayout]) throws {
    let record = journal.containers[index]
    guard record.identity != nil else { return try validateContainerForDisposal(index) }
    let handle = try container(index)
    guard userData else {
      journal.containers[index].cleanup = nil
      return
    }
    let snapshot = try FileSnapshot.read(record.name, from: parents[record.entry])
    guard try handle.objectIdentity == snapshot?.identity else {
      throw conflict(record.entry, "container changed while sealing disposal")
    }
    for entryIndex in journal.entries.indices where journal.entries[entryIndex].container == index {
      for (slot, expected) in layouts[entryIndex].objects {
        guard snapshot?.children?[slot.name(entryIndex)] == expected else {
          throw conflict(entryIndex, "expected user object changed while sealing disposal")
        }
      }
    }
    journal.containers[index].cleanup = snapshot
  }

  /// Recovery revalidates terminal evidence before disposal.
  func cleanup() throws {
    try requireScope()
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
    for index in journal.containers.indices {
      do { try validateContainerForDisposal(index) } catch {
        try recordConflict(journal.containers[index].entry, error)
        throw error
      }
    }
    try dispose()
  }

  /// Commit disposes directly: `prepareCleanup` verified the distribution and sealed this
  /// evidence immediately before the terminal marker. Deletion still verifies every object.
  func dispose() throws {
    try requireScope()
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

  func verifyTarget(_ index: Int) throws {
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

  /// The only disposal check of a container: its identity and sealed evidence, or, without
  /// a durable identity, that it is absent or empty.
  func validateContainerForDisposal(_ index: Int) throws {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    try requireParent(record.entry)
    guard let actual = try parent.info(record.name) else {
      if journal.discarding || record.identity == nil { return }
      throw conflict(record.entry, "private container disappeared before discard intent")
    }
    guard let identity = record.identity else {
      guard try parent.child(record.name).names().isEmpty else {
        throw conflict(record.entry, "unidentified private container is not empty")
      }
      return
    }
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
  }

  private func discardContainer(_ index: Int) throws {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    try requireScope()
    try requireParent(record.entry)
    if let identity = record.identity {
      try parent.remove(record.name, expecting: record.cleanup, identity: identity) { point in
        try emit(
          point.step == .synced
            ? .containerRemoved(index) : .unlinked(container: index, path: point.path))
      }
    } else {
      try parent.removeEmptyDirectory(record.name)
      try emit(.containerRemoved(index))
    }
  }
}
