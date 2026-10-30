import Foundation

extension TransactionSession {
  /// Verifies every expected distribution and seals disposal evidence for containers that
  /// hold user data. A failure is recorded on the entry or container that caused it.
  func sealDisposal() throws {
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
        try sealContainerDisposal(
          index, userData: userContainers.contains(index), layouts: layouts)
      } catch {
        try recordConflict(journal.containers[index].entry, error)
        throw error
      }
    }
    for index in journal.entries.indices { journal.entries[index].conflict = nil }
  }

  /// Conflicts name the container's representative entry, where they are recorded.
  private func sealContainerDisposal(_ index: Int, userData: Bool, layouts: [TransactionLayout])
    throws
  {
    let record = journal.containers[index]
    guard record.identity != nil else { return try validateContainerForDisposal(index) }
    let handle = try container(index)
    guard userData else {
      journal.containers[index].disposal = nil
      return
    }
    let snapshot = try FileSnapshot.read(record.name, from: parents[record.entry])
    guard try handle.objectIdentity == snapshot?.identity else {
      throw conflict(record.entry, "container changed while sealing disposal")
    }
    for entryIndex in journal.entries.indices where journal.entries[entryIndex].container == index {
      for (slot, expected) in layouts[entryIndex].objects {
        let name = slot.name(entryIndex)
        guard snapshot?.children?[name] == expected else {
          throw conflict(record.entry, "user object \(name) changed while sealing disposal")
        }
      }
    }
    journal.containers[index].disposal = snapshot
  }

  /// Recovery revalidates terminal evidence before disposal.
  func revalidateDisposal() throws {
    try requireScope()
    for index in journal.entries.indices {
      do {
        if journal.disposing {
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

  /// Commit disposes directly: `sealDisposal` verified the distribution and sealed this
  /// evidence immediately before the terminal marker. Deletion still verifies every object.
  func dispose() throws {
    try requireScope()
    if !journal.disposing {
      journal.disposing = true
      try persist(.disposing)
      try emit(.disposalIntent)
    }
    for index in journal.containers.indices { try disposeContainer(index) }
    try requireScope()
    try directory.removeFiles(
      [TransactionJournal.incompleteFileName, TransactionJournal.fileName]
    ) { name in
      if name == TransactionJournal.fileName { try emit(.journalUnlinked) }
    }
    try emit(.journalRemoved)
  }

  func verifyTarget(_ index: Int) throws {
    let entry = journal.entries[index]
    try requireParent(index)
    // Terminal phases have a single distribution; disposal may have removed its slots.
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
      if journal.disposing || record.identity == nil { return }
      throw conflict(record.entry, "private container disappeared before disposal intent")
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
    if let expected = record.disposal {
      let current = try FileSnapshot.read(record.name, from: parent)
      let matches =
        journal.disposing
        ? current.map(expected.containsRemaining) == true : current == expected
      guard matches else { throw conflict(record.entry, "terminal disposal evidence changed") }
    }
  }

  private func disposeContainer(_ index: Int) throws {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    try requireScope()
    try requireParent(record.entry)
    if let identity = record.identity {
      try parent.remove(record.name, expecting: record.disposal, identity: identity) { point in
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
