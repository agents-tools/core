import Foundation

/// One commit or recovery pass over the scope journal under the writer lock.
final class TransactionSession {
  var journal: TransactionJournal
  let directory: DirectoryHandle
  let parents: [DirectoryHandle]
  let checkpoint: (String) throws -> Void
  /// Devices whose atomic renames passed a probe during this session only; `st_dev` values
  /// can be reused by another filesystem after an unmount.
  var capableDevices: Set<UInt64> = []

  init(
    journal: TransactionJournal, directory: DirectoryHandle, parents: [DirectoryHandle],
    checkpoint: @escaping (String) throws -> Void
  ) {
    self.journal = journal
    self.directory = directory
    self.parents = parents
    self.checkpoint = checkpoint
  }

  func emit(_ point: TransactionCheckpoint) throws { try checkpoint(point.name) }

  func persist(_ change: TransactionCheckpoint.Change) throws {
    try requireScope()
    try directory.replaceFile(
      TransactionJournal.fileName, through: TransactionJournal.incompleteFileName,
      with: StateStore.encode(journal),
      afterWrite: {
        try emit(.persisted(journal.phase, change, .written))
      },
      afterRename: {
        try emit(.persisted(journal.phase, change, .renamed))
      })
  }

  /// Transitions and their durable evidence promises are changed together. The first
  /// publishing entry also moves a preparing journal to applying in the same write.
  func advance(_ index: Int, to next: TransactionJournal.Progress) throws {
    let previous = journal.entries[index].progress
    let legal: [TransactionJournal.Progress: Set<TransactionJournal.Progress>] = [
      .queued: [.ready], .ready: [.publishing, .cancelled],
      .publishing: [.applied, .restoring, .cancelled], .applied: [.restoring],
      .restoring: [.restored], .restored: [], .cancelled: [],
    ]
    guard legal[previous]?.contains(next) == true else {
      throw conflict(index, "illegal progress transition: \(previous) -> \(next)")
    }
    if next == .publishing, journal.phase == .preparing { try changePhase(to: .applying) }
    journal.entries[index].progress = next
    journal.entries[index].conflict = nil
    try persist(.entry(index, next))
    try emit(.progress(index, next))
  }

  /// The terminal marker is durable before any disposal.
  func finish(_ phase: TransactionJournal.Phase) throws {
    try changePhase(to: phase)
    try persist(.terminal)
  }

  private func changePhase(to next: TransactionJournal.Phase) throws {
    let legal: [TransactionJournal.Phase: Set<TransactionJournal.Phase>] = [
      .preparing: [.applying, .rolledBack], .applying: [.committed, .rolledBack],
      .committed: [], .rolledBack: [],
    ]
    guard legal[journal.phase]?.contains(next) == true else {
      throw CoreError.invalidState(
        "illegal transaction phase transition: \(journal.phase) -> \(next)")
    }
    journal.phase = next
  }

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
    return journal.containerLocation(of: entry)
      ?? "<invalid container reference \(entry.container)>"
  }

  func recordConflict(_ index: Int, _ error: Error) throws {
    journal.entries[index].conflict = .init(
      reason: String(describing: error),
      locations: [journal.entries[index].path, containerLocation(index)])
    try persist(.conflict(index, journal.entries[index].progress))
  }

  func container(_ index: Int) throws -> DirectoryHandle {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    guard let expected = record.identity,
      try parent.info(record.name).map(FileObjectIdentity.init) == expected
    else {
      throw conflict(record.entry, "private container identity changed or is missing")
    }
    let handle = try parent.child(record.name)
    guard try handle.objectIdentity == expected else {
      throw conflict(record.entry, "private container changed while opening")
    }
    return handle
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
      record.name == TransactionJournal.containerName(id: journal.id, index: index),
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
    try record.disposal?.validate()
    if let disposal = record.disposal {
      guard disposal.identity == record.identity else {
        throw CoreError.invalidState("terminal container evidence has another identity")
      }
    }
    if journal.phase == .committed || journal.phase == .rolledBack {
      let containsUserData = journal.entries.filter { $0.container == index }.contains { entry in
        [.applied, .restored].contains(entry.progress)
          && TransactionLayout.expected(entry).contains { !$0.objects.isEmpty }
      }
      guard !containsUserData || record.disposal != nil else {
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
      !journal.disposing || journal.phase == .committed || journal.phase == .rolledBack
    else {
      throw conflict(index, "operation progress contradicts its evidence or journal phase")
    }
  }

  /// Matches the target and every recovery slot against the operation/progress table.
  /// Only interrupted publishing or restoring may observe a leased owner-write bit.
  func distribution(_ index: Int, permittingDirectoryWrite: Bool = false) throws
    -> TransactionLayout
  {
    let entry = journal.entries[index]
    try requireParent(index)
    let layouts = TransactionLayout.expected(entry)
    if entry.progress == .queued { return layouts[0] }
    let container = try self.container(entry.container)
    var objects: [TransactionSlot: FileSnapshot] = [:]
    for slot in TransactionSlot.objectSlots {
      if let value = try FileSnapshot.read(slot.name(index), from: container) {
        objects[slot] = value
      }
    }
    let permitsWrite = permittingDirectoryWrite && entry.progress.permitsDirectoryWrite
    for layout in layouts where Set(layout.objects.keys) == Set(objects.keys) {
      guard
        layout.objects.allSatisfy({ slot, expected in
          guard let actual = objects[slot] else { return false }
          return expected.matches(actual, permittingDirectoryWrite: permitsWrite)
        })
      else { continue }
      if try layout.target.matches(
        entry.name, from: parents[index], permittingDirectoryWrite: permitsWrite)
      {
        return layout
      }
    }
    let expected = Set(layouts.flatMap(\.objects.keys)).map { $0.name(index) }.sorted()
    throw conflict(
      index,
      "missing or changed expected target or recovery slot object; expected slots: "
        + (expected.isEmpty ? "none" : expected.joined(separator: ", ")))
  }
}
