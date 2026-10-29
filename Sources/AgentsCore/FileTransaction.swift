import CPlatform
import Foundation

/// A durable undo journal covers targets, scope state files and cache pruning.
/// The scope writer lock must be held through planning, commit and recovery.
package final class FileTransaction {
  private enum Progress: String, Codable {
    case queued, verifying, ready, publishing, applied, restoring, restored, cancelled
  }
  private struct Entry: Codable {
    var path: String
    var existed: Bool
    var replacement: Bool
    var preimage: FileSnapshot?
    var parentIdentity = ""
    var staging: FileSnapshot?
    var staged: FileSnapshot?
    var work: FileSnapshot?
    var probes: [FileSnapshot] = []
    var progress: Progress = .queued
    var cleanup: [String: FileSnapshot] = [:]
    var discarding = false
    var conflict = false
    var name: String { String(path.split(separator: "/").last!) }
  }
  private struct Journal: Codable {
    var id: UUID
    var scope: String
    var roots: [String: String]
    var phase: Phase
    var entries: [Entry]
  }
  private enum Phase: String, Codable { case preparing, applying, committed, rolledBack }
  private struct Content {
    var url: URL?
    var link: Bool
    var data: Data?
    var expectedHash: String?
    var executableFlags: [String: Bool]?
    var prepare: ((URL) throws -> URL)?
  }
  private let store: StateStore
  private let checkpoint: (String) throws -> Void
  package var validateBeforePublication: () throws -> Void = {}
  var atomicPreflight: (URL) throws -> Void = { try DirectoryHandle.requireAtomicRenames(at: $0) }
  private let outcome: TransactionOutcome
  private var entries: [Entry] = []
  private var contents: [Content] = []
  private var preconditions: [PathIdentity] = []
  private var statePrecondition: StatePrecondition?

  package init(
    store: StateStore, outcome: TransactionOutcome = TransactionOutcome(),
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) {
    self.store = store
    self.checkpoint = checkpoint
    self.outcome = outcome
  }

  package func replace(
    _ destination: URL, content: URL?, link: Bool = false, data: Data? = nil,
    expectedHash: String? = nil, executableFlags: [String: Bool]? = nil
  ) throws {
    if let expectedHash {
      try StateValidation.digest(expectedHash)
      guard content != nil || data != nil else {
        throw CoreError.invalidState("verification requires content")
      }
    }
    let path = try TransactionPaths(store: store).path(for: destination)
    guard !entries.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    if statePrecondition == nil { statePrecondition = try StatePrecondition(store: store) }
    let identity = try PathIdentity(destination)
    let preimage = try FileSnapshot.read(at: destination)
    try identity.validate()
    entries.append(
      Entry(
        path: path, existed: preimage != nil, replacement: content != nil || data != nil,
        preimage: preimage))
    preconditions.append(identity)
    contents.append(
      Content(
        url: content, link: link, data: data, expectedHash: expectedHash,
        executableFlags: executableFlags, prepare: nil))
  }

  /// Builds source content inside journal-owned scratch storage before verified copying.
  func prepare(_ destination: URL, content: @escaping (URL) throws -> URL) throws {
    try replace(destination, content: nil)
    entries[entries.count - 1].replacement = true
    contents[contents.count - 1].prepare = content
  }

  func remove(_ name: String, from parent: DirectoryHandle) throws {
    try replace(parent.url.appendingPathComponent(name), content: nil)
  }

  package func commit() throws {
    guard let directory = try store.openDirectoryIfPresent(),
      try directory.info("transaction.json") == nil, try directory.info("transaction.new") == nil
    else { throw CoreError.invalidState("transaction recovery is required") }
    guard !entries.isEmpty else { return }
    for identity in preconditions { try identity.validate() }
    try statePrecondition?.validate()
    try validateBeforePublication()
    // No destination, ancestry or journal mutation precedes capability checks.
    for entry in entries {
      let destination = try destinationURL(entry.path)
      try atomicPreflight(destination)
    }
    let paths = TransactionPaths(store: store)
    var roots: [String: DirectoryHandle] = [:]
    for entry in entries {
      let key = try paths.components(entry.path).root
      if roots[key] == nil {
        roots[key] = try paths.root(key, create: true, checkpoint: checkpoint)
      }
    }
    let parents = try entries.map {
      try paths.parent(for: $0.path, roots: roots, create: true, checkpoint: checkpoint)
    }
    try Self.validateDestinations(entries, parents: parents)
    for index in entries.indices {
      entries[index].parentIdentity = try parents[index].identity
      try Self.requirePreimage(entries[index], parent: parents[index])
    }
    if entries.contains(where: {
      ["state/agents.watch", "state/agents.resolved"].contains($0.path)
    }) {
      try SourceCache(store: store, checkpoint: checkpoint).beginWatchReferenceUpdate()
    }
    var journal = Journal(
      id: UUID(), scope: try directory.identity,
      roots: try roots.mapValues { try $0.identity }, phase: .preparing, entries: entries)
    outcome.journalID = journal.id
    do {
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("journal.preparing")
      var probedDevices: Set<UInt64> = []
      for index in entries.indices {
        var info = stat()
        guard fstat(parents[index].descriptor, &info) == 0 else {
          throw CoreError.invalidState("cannot identify publication filesystem")
        }
        if probedDevices.insert(UInt64(info.st_dev)).inserted {
          try probeAtomics(index, journal: &journal, directory: directory, parent: parents[index])
        }
      }
      for index in entries.indices {
        do {
          try stage(index, journal: &journal, directory: directory, parent: parents[index])
        } catch {
          // A live producer can seal its incomplete scratch on failure. Recovery
          // after process death uses only evidence already persisted by that producer.
          if [.queued, .verifying].contains(journal.entries[index].progress) {
            try? sealIncompleteScratch(
              index, journal: &journal, directory: directory, parent: parents[index])
          }
          throw error
        }
      }
      try checkpoint("publication.preconditions")
      try statePrecondition?.validate()
      for identity in preconditions { try identity.validate() }
      try validateBeforePublication()
      for (index, entry) in journal.entries.enumerated() {
        try Self.requirePreimage(entry, parent: parents[index])
      }
      journal.phase = .applying
      outcome.disposition = .recoveryRequired
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("journal.applying")
      for index in entries.indices {
        try preconditions[index].validate()
        try publish(index, journal: &journal, directory: directory, parent: parents[index])
      }
      try validateRemainingState(journal)
      try Self.verifyFinal(journal, parents: parents)
      try Self.prepareCleanup(&journal, parents: parents)
      journal.phase = .committed
      try checkpoint("journal.committing")
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      outcome.disposition = .committed
      try checkpoint("journal.committed")
      try Self.cleanup(&journal, directory: directory, parents: parents, checkpoint: checkpoint)
    } catch {
      do {
        _ = try Self.recover(store: store, outcome: outcome)
        var retained = try directory.info("transaction.json") != nil
        for index in journal.entries.indices {
          for suffix in Self.scratchSuffixes {
            if try parents[index].info(Self.temporaryName(journal, index, suffix)) != nil {
              retained = true
            }
          }
        }
        if retained { outcome.disposition = .recoveryRequired }
      } catch {
        outcome.disposition = .recoveryRequired
      }
      throw error
    }
  }

  private func probeAtomics(
    _ index: Int, journal: inout Journal, directory: DirectoryHandle, parent: DirectoryHandle
  ) throws {
    let first = Self.temporaryName(journal, index, "probe-a")
    let second = Self.temporaryName(journal, index, "probe-b")
    let third = Self.temporaryName(journal, index, "probe-c")
    for name in [first, second] {
      try parent.write(name, data: Data())
      guard let snapshot = try FileSnapshot.read(name, from: parent) else {
        throw CoreError.invalidState("missing atomic capability probe")
      }
      journal.entries[index].probes.append(snapshot)
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("atomic.\(index).created.\(journal.entries[index].probes.count)")
    }
    try parent.rename(first, to: second, swap: true) {
      try checkpoint("atomic.\(index).exchanged")
    }
    guard platform_rename_exclusive(parent.descriptor, first, second) != 0,
      errno == EEXIST || errno == ENOTEMPTY
    else { throw CoreError.unsupported("atomic no-replace publication is required") }
    try parent.renameExclusive(first, to: third) {
      try checkpoint("atomic.\(index).exclusive")
    }
    let probes = journal.entries[index].probes
    guard try FileSnapshot.read(second, from: parent) == probes[0],
      try FileSnapshot.read(third, from: parent) == probes[1],
      try parent.info(first) == nil
    else { throw Self.conflict(journal.entries[index], "atomic probe ownership changed") }
    try checkpoint("atomic.\(index).verified")
  }

  private func destinationURL(_ path: String) throws -> URL {
    let paths = TransactionPaths(store: store)
    let components = try paths.components(path)
    // Root resolution is configuration-owned and does not create directories.
    return try paths.rootURL(components.root).appendingPathComponent(
      components.descendants.joined(separator: "/"))
  }

  private func stage(
    _ index: Int, journal: inout Journal, directory: DirectoryHandle, parent: DirectoryHandle
  ) throws {
    let entry = journal.entries[index]
    let staged = Self.temporaryName(journal, index, "new")
    try entry.preimage?.synchronize(entry.name, from: parent)
    try checkpoint("stage.\(index).preimage")
    var content = contents[index]
    if let prepare = content.prepare {
      let work = Self.temporaryName(journal, index, "work")
      try parent.makeDirectory(work)
      journal.entries[index].work = try Self.mutableSnapshot(
        work, from: parent, previous: journal.entries[index].work)
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("prepare.\(index).directory")
      let root = parent.url.appendingPathComponent(work)
      let source = try prepare(root)
      guard PathSafety.isContained(source.resolvingSymlinksInPath(), in: root) else {
        throw CoreError.unsafePath("prepared content escapes transaction staging")
      }
      journal.entries[index].work = try Self.mutableSnapshot(
        work, from: parent, previous: journal.entries[index].work)
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      content.url = source
      content.expectedHash = "sha256:" + (try FileHash.folderHash(source))
      content.executableFlags = try FileHash.executableFlags(source)
      try checkpoint("prepare.\(index).ready")
    }
    if let data = content.data {
      try parent.write(
        staged, data: data,
        preservingMetadataOf: entry.preimage?.identity.kind == UInt32(S_IFREG) ? entry.name : nil)
      journal.entries[index].staging = try FileSnapshot.read(staged, from: parent)
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("stage.\(index).written")
    } else if let source = content.url {
      if content.link {
        try parent.link(
          staged, destination: Self.linkDestination(source, parent: parent.url, store: store))
      } else {
        try Self.validateCopy(source)
        let origin = source.resolvingSymlinksInPath()
        try parent.copy(
          staged, from: DirectoryHandle(at: origin.deletingLastPathComponent()),
          named: origin.lastPathComponent,
          checkpoint: { step in
            journal.entries[index].staging = try Self.mutableSnapshot(
              staged, from: parent, previous: journal.entries[index].staging)
            try Self.persist(journal, directory: directory, checkpoint: checkpoint)
            try checkpoint("stage.\(index).copy.\(step)")
          })
      }
    }
    // Completed construction remains private and mutable until verification seals it.
    if entry.replacement {
      journal.entries[index].staging = try Self.mutableSnapshot(
        staged, from: parent, previous: journal.entries[index].staging)
    }
    journal.entries[index].progress = .verifying
    try Self.persist(journal, directory: directory, checkpoint: checkpoint)
    try checkpoint("stage.\(index).ready")
    if let data = content.data, try parent.read(staged) != data {
      throw CoreError.invalidState("staged content bytes mismatch")
    }
    if let expectedHash = content.expectedHash {
      let hash: String
      if content.link, let source = content.url {
        hash = try FileHash.folderHash(source)
      } else if content.data == nil {
        hash = try FileHash.folderHash(parent.child(staged))
      } else {
        hash = try FileHash.sha256Hex(data: parent.read(staged))
      }
      guard "sha256:" + hash == expectedHash else {
        throw CoreError.invalidState("staged content digest mismatch")
      }
      try checkpoint("stage.\(index).verified")
    }
    if let flags = content.executableFlags {
      let actual =
        try content.link
        ? FileHash.executableFlags(content.url!) : FileHash.executableFlags(parent.child(staged))
      guard actual == flags else {
        throw CoreError.invalidState("staged content executable mode mismatch")
      }
    }
    guard try FileSnapshot.read(staged, from: parent) == journal.entries[index].staging else {
      throw CoreError.invalidState("staged content changed during verification")
    }
    journal.entries[index].staged = journal.entries[index].staging
    journal.entries[index].progress = .ready
    try Self.persist(journal, directory: directory, checkpoint: checkpoint)
    try checkpoint("stage.\(index).sealed")
    try checkpoint("stage.\(index)")
  }

  private static func mutableSnapshot(
    _ name: String, from parent: DirectoryHandle, previous: FileSnapshot?
  ) throws -> FileSnapshot? {
    let actual = try FileSnapshot.read(name, from: parent)
    if let previous, previous.identity != actual?.identity {
      throw CoreError.invalidState("transaction scratch identity changed: \(name)")
    }
    return actual
  }

  private func sealIncompleteScratch(
    _ index: Int, journal: inout Journal, directory: DirectoryHandle, parent: DirectoryHandle
  ) throws {
    if let work = journal.entries[index].work {
      journal.entries[index].work = try Self.mutableSnapshot(
        Self.temporaryName(journal, index, "work"), from: parent, previous: work)
    }
    if let staging = journal.entries[index].staging {
      let actual = try Self.mutableSnapshot(
        Self.temporaryName(journal, index, "new"), from: parent, previous: staging)
      if journal.entries[index].progress == .verifying,
        actual.map({ staging.sameObjects(as: $0) }) != true
      {
        throw CoreError.invalidState("staging ownership changed during verification")
      }
      journal.entries[index].staging = actual
    }
    try Self.persist(journal, directory: directory, checkpoint: { _ in })
  }

  private func publish(
    _ index: Int, journal: inout Journal, directory: DirectoryHandle, parent: DirectoryHandle
  ) throws {
    var entry = journal.entries[index]
    let staged = Self.temporaryName(journal, index, "new")
    let backup = Self.temporaryName(journal, index, "old")
    try Self.requirePreimage(entry, parent: parent)
    guard try FileSnapshot.read(staged, from: parent) == entry.staged,
      !entry.replacement || entry.staged != nil
    else { throw Self.conflict(entry, "staged object changed") }
    entry.progress = .publishing
    journal.entries[index] = entry
    try Self.persist(journal, directory: directory, checkpoint: checkpoint)
    try checkpoint("publish.\(index).intent")
    try validateRemainingState(journal)
    try Self.requirePreimage(entry, parent: parent)
    try checkpoint("publish.\(index).validated")
    if entry.replacement {
      if entry.existed {
        try parent.rename(staged, to: entry.name, swap: true) {
          try checkpoint("replace.\(index).renamed")
        }
        try checkpoint("publish.\(index).synced")
        guard try FileSnapshot.read(staged, from: parent) == entry.preimage else {
          throw Self.conflict(entry, "displaced preimage changed")
        }
        try checkpoint("publish.\(index).displaced")
        try parent.renameExclusive(staged, to: backup) {
          try checkpoint("publish.\(index).retained")
        }
      } else {
        try parent.renameExclusive(staged, to: entry.name) {
          try checkpoint("replace.\(index).renamed")
        }
        try checkpoint("publish.\(index).synced")
      }
    } else if entry.existed {
      try parent.renameExclusive(entry.name, to: backup) {
        try checkpoint("replace.\(index).renamed")
      }
      try checkpoint("publish.\(index).synced")
      guard try FileSnapshot.read(backup, from: parent) == entry.preimage else {
        throw Self.conflict(entry, "quarantined preimage changed")
      }
    }
    guard try FileSnapshot.read(entry.name, from: parent) == entry.staged else {
      throw Self.conflict(entry, "published object changed")
    }
    journal.entries[index].progress = .applied
    try Self.persist(journal, directory: directory, checkpoint: checkpoint)
    try checkpoint("replace.\(index)")
  }

  private func validateRemainingState(_ journal: Journal) throws {
    let published = Set(
      journal.entries.filter {
        $0.progress == .applied && $0.path.hasPrefix("state/")
      }.map(\.name))
    try statePrecondition?.validate(excluding: published)
  }

  /// Recovers only after validating and pinning every root, parent and object record.
  package static func recover(
    store: StateStore, outcome: TransactionOutcome? = nil,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws -> Bool {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    guard try directory.info("transaction.json") != nil else {
      guard try directory.info("transaction.new") != nil else { return false }
      _ = try directory.read("transaction.new")
      try directory.remove("transaction.new")
      return true
    }
    var journal: Journal
    do {
      journal = try StateStore.decode(directory.read("transaction.json"), as: Journal.self)
    } catch {
      outcome?.disposition = .recoveryRequired
      throw CoreError.invalidState("unresolved transaction journal: \(error)")
    }
    do {
      let parents = try recoveryParents(journal, store: store, directory: directory)
      if try directory.info("transaction.new") != nil { _ = try directory.read("transaction.new") }
      if journal.phase == .applying {
        var conflicts: [String] = []
        for index in journal.entries.indices.reversed() {
          do {
            try rollback(
              index, journal: &journal, directory: directory, parent: parents[index],
              checkpoint: checkpoint)
            journal.entries[index].conflict = false
          } catch {
            journal.entries[index].conflict = true
            conflicts.append("\(journal.entries[index].path): \(error)")
          }
          try persist(journal, directory: directory, checkpoint: checkpoint)
        }
        guard conflicts.isEmpty else {
          throw CoreError.invalidState(
            "unresolved transaction conflicts: " + conflicts.joined(separator: "; "))
        }
      }
      if journal.phase == .applying || journal.phase == .preparing {
        if journal.phase == .applying { try verifyFinal(journal, parents: parents, rollback: true) }
        try prepareCleanup(&journal, parents: parents)
        journal.phase = .rolledBack
        try persist(journal, directory: directory, checkpoint: checkpoint)
      }
      try verifyFinal(journal, parents: parents, rollback: journal.phase == .rolledBack)
      try cleanup(&journal, directory: directory, parents: parents, checkpoint: checkpoint)
      if outcome?.journalID == journal.id {
        outcome?.disposition = journal.phase == .committed ? .committed : .unchanged
      }
      return true
    } catch {
      if outcome?.journalID == journal.id { outcome?.disposition = .recoveryRequired }
      throw error
    }
  }

  private static func recoveryParents(
    _ journal: Journal, store: StateStore, directory: DirectoryHandle
  ) throws -> [DirectoryHandle] {
    guard journal.scope == (try directory.identity) else {
      throw CoreError.invalidState("transaction journal belongs to another scope location")
    }
    let paths = TransactionPaths(store: store)
    let keys = try Set(journal.entries.map { try paths.components($0.path).root })
    guard keys == Set(journal.roots.keys) else {
      throw CoreError.invalidState("invalid transaction roots")
    }
    var roots: [String: DirectoryHandle] = [:]
    for key in keys {
      let root = try paths.root(key)
      guard try root.identity == journal.roots[key] else {
        throw CoreError.invalidState("transaction root identity changed")
      }
      roots[key] = root
    }
    let parents = try journal.entries.map { try paths.parent(for: $0.path, roots: roots) }
    try validateDestinations(journal.entries, parents: parents)
    for (index, entry) in journal.entries.enumerated() {
      guard entry.parentIdentity == (try parents[index].identity),
        entry.existed == (entry.preimage != nil),
        entry.cleanup.keys.allSatisfy({ scratchSuffixes.contains($0) })
      else { throw conflict(entry, "invalid parent or object evidence") }
      let allowed: [Progress]
      switch journal.phase {
      case .preparing: allowed = [.queued, .verifying, .ready]
      case .applying: allowed = [.ready, .publishing, .applied, .restoring, .restored, .cancelled]
      case .committed: allowed = [.applied]
      case .rolledBack: allowed = [.queued, .verifying, .ready, .restored, .cancelled]
      }
      guard allowed.contains(entry.progress) else {
        throw conflict(entry, "operation progress contradicts the journal phase")
      }
      for snapshot in [entry.preimage, entry.staging, entry.staged, entry.work].compactMap({ $0 })
        + Array(entry.cleanup.values) + entry.probes
      { try snapshot.validate() }
      if ![.queued, .verifying].contains(entry.progress), entry.replacement, entry.staged == nil {
        throw conflict(entry, "missing staged identity")
      }
    }
    return parents
  }

  private static func rollback(
    _ index: Int, journal: inout Journal, directory: DirectoryHandle, parent: DirectoryHandle,
    checkpoint: (String) throws -> Void
  ) throws {
    let entry = journal.entries[index]
    if [.queued, .verifying, .ready, .cancelled].contains(entry.progress) {
      journal.entries[index].progress = .cancelled
    } else if entry.progress != .restored {
      journal.entries[index].progress = .restoring
      try persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("restore.\(index).intent")
      let target = try FileSnapshot.read(entry.name, from: parent)
      let stagedName = temporaryName(journal, index, "new")
      let backup = temporaryName(journal, index, "old")
      let staged = try FileSnapshot.read(stagedName, from: parent)
      let old = try FileSnapshot.read(backup, from: parent)
      if let preimage = entry.preimage {
        if target == preimage {
          // Before publication, or after an interrupted restoration exchange.
          guard !entry.replacement || staged == entry.staged || old == entry.staged else {
            throw conflict(entry, "missing transaction postimage")
          }
        } else if entry.replacement {
          guard let postimage = entry.staged, target == postimage else {
            throw conflict(entry, "recovery destination is external or changed")
          }
          let original: String
          if staged == preimage, old == nil {
            original = stagedName
          } else if old == preimage, staged == nil {
            original = backup
          } else {
            throw conflict(entry, "missing or changed displaced preimage")
          }
          try checkpoint("restore.\(index).validated")
          try parent.rename(original, to: entry.name, swap: true) {
            try checkpoint("restore.\(index).renamed")
          }
          guard try FileSnapshot.read(original, from: parent) == postimage,
            try FileSnapshot.read(entry.name, from: parent) == preimage
          else { throw conflict(entry, "recovery exchange displaced an external object") }
        } else {
          guard target == nil, old == preimage else {
            throw conflict(entry, "quarantine or recovery destination changed")
          }
          try checkpoint("restore.\(index).validated")
          try parent.renameExclusive(backup, to: entry.name) {
            try checkpoint("restore.\(index).renamed")
          }
          guard try FileSnapshot.read(entry.name, from: parent) == preimage else {
            throw conflict(entry, "restored preimage changed")
          }
        }
      } else if let postimage = entry.staged {
        let removed = temporaryName(journal, index, "removed")
        let quarantined = try FileSnapshot.read(removed, from: parent)
        if staged == postimage, quarantined == nil, target != postimage {
          // No-replace never consumed staging; a concurrent creator is untouched.
          journal.entries[index].progress = .cancelled
        } else if target == postimage, staged == nil, quarantined == nil {
          try checkpoint("restore.\(index).validated")
          try parent.renameExclusive(entry.name, to: removed) {
            try checkpoint("restore.\(index).remove.unlinked")
          }
          guard try FileSnapshot.read(removed, from: parent) == postimage else {
            throw conflict(entry, "creation rollback quarantined an external object")
          }
        } else if quarantined != postimage || staged != nil || target == postimage {
          throw conflict(entry, "missing or changed creation evidence")
        }
        try parent.sync()
        try checkpoint("restore.\(index).remove.synced")
      }
      if journal.entries[index].progress != .cancelled {
        journal.entries[index].progress = .restored
      }
    }
    // A visible reverse rename is not a durability barrier, including on retry.
    try parent.sync()
    try checkpoint("restore.\(index).synced")
    try persist(journal, directory: directory, checkpoint: checkpoint)
    try checkpoint("restore.\(index)")
  }

  private static func requirePreimage(_ entry: Entry, parent: DirectoryHandle) throws {
    guard try FileSnapshot.read(entry.name, from: parent) == entry.preimage else {
      throw conflict(entry, "preparation is stale; prepare again")
    }
  }

  private static func verifyFinal(
    _ journal: Journal, parents: [DirectoryHandle], rollback: Bool = false
  ) throws {
    for (index, entry) in journal.entries.enumerated() {
      try requireParent(entry, parent: parents[index])
      if rollback {
        if entry.progress == .restored, entry.preimage != nil {
          try requirePreimage(entry, parent: parents[index])
        } else if let staged = entry.staged,
          try FileSnapshot.read(entry.name, from: parents[index])?.identity == staged.identity
        {
          throw conflict(entry, "creation is still published")
        }
      } else {
        guard try FileSnapshot.read(entry.name, from: parents[index]) == entry.staged else {
          throw conflict(entry, "committed destination changed")
        }
      }
    }
  }

  private static func requireParent(_ entry: Entry, parent: DirectoryHandle) throws {
    guard try DirectoryHandle(at: parent.url).identity == entry.parentIdentity else {
      throw conflict(entry, "destination parent changed")
    }
  }

  private static func prepareCleanup(_ journal: inout Journal, parents: [DirectoryHandle]) throws {
    for index in journal.entries.indices {
      let entry = journal.entries[index]
      var cleanup: [String: FileSnapshot] = [:]
      for suffix in scratchSuffixes {
        guard
          let actual = try FileSnapshot.read(
            temporaryName(journal, index, suffix), from: parents[index])
        else { continue }
        let candidates: [FileSnapshot?]
        switch suffix {
        case "probe-a", "probe-b", "probe-c": candidates = entry.probes.map(Optional.some)
        case "work": candidates = [entry.work]
        case "removed": candidates = [entry.staged]
        case "old": candidates = [entry.preimage, entry.staged]
        default: candidates = [entry.staged ?? entry.staging, entry.preimage]
        }
        guard candidates.contains(where: { $0 == actual }) else {
          throw conflict(entry, "unverified recovery object: \(suffix)")
        }
        cleanup[suffix] = actual
      }
      if journal.phase == .preparing {
        if let staged = entry.staging, cleanup["new"] != staged {
          throw conflict(entry, "missing staging evidence")
        }
      }
      if entry.progress == .cancelled, let staged = entry.staged, cleanup["new"] != staged {
        throw conflict(entry, "missing unpublished staging evidence")
      }
      if let work = entry.work, cleanup["work"] != work {
        throw conflict(entry, "missing scratch evidence")
      }
      guard entry.probes.allSatisfy({ cleanup.values.contains($0) }) else {
        throw conflict(entry, "missing atomic probe evidence")
      }
      journal.entries[index].cleanup = cleanup
    }
  }

  private static func cleanup(
    _ journal: inout Journal, directory: DirectoryHandle, parents: [DirectoryHandle],
    checkpoint: (String) throws -> Void
  ) throws {
    try requireScope(journal, directory: directory)
    try directory.syncFile("transaction.json")
    try checkpoint("journal.terminalSynced")
    try requireScope(journal, directory: directory)
    // Validate the whole disposal plan before deleting the first resource.
    for (index, entry) in journal.entries.enumerated() {
      try requireParent(entry, parent: parents[index])
      for suffix in scratchSuffixes {
        let actual = try FileSnapshot.read(
          temporaryName(journal, index, suffix), from: parents[index])
        if let expected = entry.cleanup[suffix] {
          guard
            entry.discarding ? actual.map(expected.containsRemaining) ?? true : actual == expected
          else { throw conflict(entry, "cleanup evidence changed: \(suffix)") }
        } else if actual != nil {
          throw conflict(entry, "unrecorded cleanup object: \(suffix)")
        }
      }
    }
    for index in journal.entries.indices {
      journal.entries[index].discarding = true
      try persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("cleanup.\(index).intent")
      try requireScope(journal, directory: directory)
      try requireParent(journal.entries[index], parent: parents[index])
      for suffix in journal.entries[index].cleanup.keys.sorted() {
        try journal.entries[index].cleanup[suffix]!.remove(
          temporaryName(journal, index, suffix), from: parents[index],
          checkpoint: { try checkpoint("cleanup.\(index).\(suffix).\($0)") })
      }
      try checkpoint("cleanup.\(index)")
    }
    try directory.remove("transaction.new")
    try directory.remove("transaction.json")
    try checkpoint("journal.removed")
  }

  private static func requireScope(_ journal: Journal, directory: DirectoryHandle) throws {
    guard try DirectoryHandle(at: directory.url).identity == journal.scope else {
      throw CoreError.invalidState("transaction scope identity changed")
    }
  }

  private static func validateDestinations(_ entries: [Entry], parents: [DirectoryHandle]) throws {
    var paths: [URL] = []
    for (index, entry) in entries.enumerated() {
      let path = parents[index].url.appendingPathComponent(entry.name)
      guard
        !paths.contains(where: {
          PathSafety.isContained(path, in: $0) || PathSafety.isContained($0, in: path)
        })
      else { throw CoreError.invalidState("overlapping transaction destinations") }
      paths.append(path)
    }
  }

  private static func conflict(_ entry: Entry, _ reason: String) -> CoreError {
    .invalidState("transaction conflict at \(entry.path): \(reason)")
  }

  private static func temporaryName(_ journal: Journal, _ index: Int, _ suffix: String) -> String {
    ".agents-\(journal.id.uuidString)-\(index).\(suffix)"
  }

  private static let scratchSuffixes = [
    "old", "new", "removed", "work", "probe-a", "probe-b", "probe-c",
  ]

  private static func persist(
    _ journal: Journal, directory: DirectoryHandle,
    checkpoint: (String) throws -> Void
  ) throws {
    try directory.remove("transaction.new")
    try directory.write("transaction.new", data: StateStore.encode(journal))
    try directory.rename("transaction.new", to: "transaction.json") {
      try checkpoint("journal.\(journal.phase.rawValue).renamed")
    }
  }
  package static func linkDestination(_ source: URL, parent: URL, store: StateStore) -> String {
    let root = (store.scope == .project ? store.environment.projectDirectory : store.directory)
      .resolvingSymlinksInPath()
    let source = source.resolvingSymlinksInPath()
    if PathSafety.isContained(source, in: root) {
      let from = parent.pathComponents
      let to = source.pathComponents
      let common = zip(from, to).prefix(while: { $0 == $1 }).count
      return (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(
        separator: "/")
    }
    return source.path
  }

  /// A copied subtree keeps relative links that stay inside it, dangling ones included.
  private static func validateCopy(_ source: URL) throws {
    guard let root = PathSafety.realPath(source.path),
      let entries = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let entry as URL in entries {
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        entries.skipDescendants()
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        guard !destination.hasPrefix("/"), try PathSafety.linkStaysInside(entry, root: root)
        else {
          throw CoreError.unsafePath("copy symlink escapes installed subtree: \(entry.path)")
        }
      }
    }
  }
}
