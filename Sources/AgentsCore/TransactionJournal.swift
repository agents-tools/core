import Foundation

/// The version is independent of declaration, resolved and watch formats.
struct TransactionJournal: Codable {
  static let currentVersion = 1
  var version = currentVersion
  var id: UUID
  var scope: String
  var roots: [String: String]
  var phase: Phase = .preparing
  var entries: [Entry]
  var containers: [Container]
  /// Only this durable intent permits absent or partially removed disposal objects.
  var discarding = false

  enum Phase: String, Codable { case preparing, applying, committed, rolledBack }
  enum Action: String, Codable { case install, delete }
  enum Progress: String, Codable {
    /// Preimage and container name are durable; construction has no per-object ownership claims.
    case queued
    /// Construction is verified; staged is sealed and other recovery slots are absent.
    case ready
    /// Publication and temporary directory-write intent are durable, with original modes.
    case publishing
    /// Rename parents and original modes are synced; the installed distribution is verified.
    case applied
    /// Undo and directory-write intent are durable; installed or reverted objects may be present.
    case restoring
    /// Undo parents and original modes are synced; reverted objects remain until discard intent.
    case restored
    /// Original modes are restored; publication did not consume private staging.
    case cancelled

    var permitsDirectoryWrite: Bool { self == .publishing || self == .restoring }
  }

  struct Conflict: Codable {
    let reason: String
    /// Scope-relative destinations and container locations, never executable input paths.
    let locations: [String]
  }

  struct Entry: Codable {
    var path: String
    var action: Action
    var preimage: FileSnapshot?
    var parentIdentity: String
    var container: Int
    /// Non-nil exactly when an install has reached ready; never refreshed after sealing.
    /// Modes in both snapshots are the final modes, before any directory-write intent.
    var staged: FileSnapshot?
    var progress: Progress = .queued
    var conflict: Conflict?
    var name: String { String(path.split(separator: "/").last!) }
  }

  struct Container: Codable {
    /// A representative entry pins the parent; the name is derived from id and this array index.
    var entry: Int
    var name: String
    /// Persisted before inserting any object. Without it only an empty rmdir is allowed.
    var identity: FileObjectIdentity?
    /// Present only for terminal disposal containing user data. Missing entries are admitted
    /// only after discarding is durable; private unfinished construction needs no tree evidence.
    var cleanup: FileSnapshot?
  }

  func containerName(_ index: Int) -> String { containers[index].name }
}

enum TransactionScratch: String, CaseIterable {
  case staged, preimage, removed, work
  case probeA = "probe-a"
  case probeB = "probe-b"
  case probeC = "probe-c"
  var name: String { rawValue }
  func name(_ index: Int) -> String { "entry.\(index).\(rawValue)" }
  static let objectSlots: [Self] = [.staged, .preimage, .removed]
}

/// The operation/progress table is the single authority for physical object distribution.
/// A nil expected object means the slot must be absent, not that ownership is unknown.
struct TransactionLayout {
  enum Kind { case prepared, installed, reverted, construction }
  enum Target {
    case any, absent
    case object(FileSnapshot)
    case externalTo(FileObjectIdentity)

    func matches(
      _ name: String, from parent: DirectoryHandle, permittingDirectoryWrite: Bool = false
    ) throws -> Bool {
      switch self {
      case .any: return true
      case .absent: return try parent.info(name) == nil
      case .externalTo(let identity):
        return try parent.info(name).map(FileObjectIdentity.init) != identity
      case .object(let expected):
        guard try parent.info(name).map(FileObjectIdentity.init) == expected.identity else {
          return false
        }
        return try FileSnapshot.read(name, from: parent).map {
          expected.matches($0, permittingDirectoryWrite: permittingDirectoryWrite)
        } == true
      }
    }
  }
  let kind: Kind
  let target: Target
  let objects: [TransactionScratch: FileSnapshot]

  static func expected(_ entry: TransactionJournal.Entry) -> [Self] {
    if entry.progress == .queued { return [Self(kind: .construction, target: .any, objects: [:])] }
    let prepared = Self(
      kind: .prepared, target: .any,
      objects: entry.staged.map { [.staged: $0] } ?? [:])
    let installed: Self
    let reverted: Self
    switch (entry.action, entry.preimage) {
    case (.install, .some(let original)):
      installed = Self(
        kind: .installed, target: .object(entry.staged!), objects: [.staged: original])
      reverted = Self(kind: .reverted, target: .object(original), objects: [.staged: entry.staged!])
    case (.install, .none):
      installed = Self(kind: .installed, target: .object(entry.staged!), objects: [:])
      reverted = Self(
        kind: .reverted, target: .externalTo(entry.staged!.identity),
        objects: [.removed: entry.staged!])
    case (.delete, .some(let original)):
      installed = Self(kind: .installed, target: .absent, objects: [.preimage: original])
      reverted = Self(kind: .reverted, target: .object(original), objects: [:])
    case (.delete, .none):
      installed = Self(kind: .installed, target: .absent, objects: [:])
      reverted = Self(kind: .reverted, target: .any, objects: [:])
    }
    switch entry.progress {
    case .queued: return [Self(kind: .construction, target: .any, objects: [:])]
    case .ready, .cancelled: return [prepared]
    case .publishing:
      if entry.action == .delete, let original = entry.preimage {
        return [Self(kind: .prepared, target: .object(original), objects: [:]), installed]
      }
      return [installed, prepared]
    case .applied: return [installed]
    case .restoring: return [reverted, installed]
    case .restored: return [reverted]
    }
  }
}

enum TransactionCheckpoint {
  enum Change {
    case created, containers
    case entry(Int, TransactionJournal.Progress)
    case terminal, discard
    case conflict(Int, TransactionJournal.Progress)
    var name: String {
      switch self {
      case .created: "created"
      case .containers: "containers"
      case .entry(let index, let progress): "entry.\(index).\(progress.rawValue)"
      case .terminal: "terminal"
      case .discard: "discard"
      case .conflict(let index, let progress): "entry.\(index).\(progress.rawValue).conflict"
      }
    }
  }
  enum Stage: String { case preimageSynced, workCreated, workPrepared, writeCreated, constructed }
  enum Publication: String { case validated, exchanged, created, quarantined, synced }
  enum Restoration: String { case validated, exchanged, returned, creationQuarantined, synced }
  enum PersistenceStep: String { case written, renamed }
  case persisted(TransactionJournal.Phase, Change, PersistenceStep)
  case phase(TransactionJournal.Phase)
  case progress(Int, TransactionJournal.Progress)
  case containerCreated(Int)
  case containersIdentified
  case probe(Int, DirectoryHandle.ProbeStep)
  case stage(Int, Stage)
  case copy(Int, DirectoryHandle.CopyPoint)
  case publication(Int, Publication)
  case restoration(Int, Restoration)
  case permissions(
    Int, TransactionPermissionPurpose, TransactionObjectLocation, DirectoryHandle.PermissionStep)
  case preconditions, commitValidated, terminalSynced, discardIntent
  case disposal(Int, DirectoryHandle.RemovalPoint)
  case containerRemoved(Int)
  case journalUnlinked
  case journalRemoved

  var name: String {
    switch self {
    case .persisted(let phase, let change, let step):
      "journal.\(phase.rawValue).\(change.name).\(step.rawValue)"
    case .phase(let phase): "journal.\(phase.rawValue)"
    case .progress(let index, let progress): "entry.\(index).\(progress.rawValue)"
    case .containerCreated(let index): "container.\(index).created"
    case .containersIdentified: "containers.identified"
    case .probe(let index, let point): "atomic.\(index).\(point.rawValue)"
    case .stage(let index, let point): "stage.\(index).\(point.rawValue)"
    case .copy(let index, let point): "stage.\(index).copy.\(point.path).\(point.step.rawValue)"
    case .publication(let index, let point): "publish.\(index).\(point.rawValue)"
    case .restoration(let index, let point): "restore.\(index).\(point.rawValue)"
    case .permissions(let index, let purpose, let location, let point):
      "permissions.\(index).\(purpose.rawValue).\(location.name).\(point.rawValue)"
    case .preconditions: "publication.preconditions"
    case .commitValidated: "publication.commitValidated"
    case .terminalSynced: "journal.terminalSynced"
    case .discardIntent: "cleanup.intent"
    case .disposal(let index, let point):
      "cleanup.\(index)."
        + (["container"] + point.path.split(separator: "/").dropFirst().map(String.init)).joined(
          separator: "/") + ".\(point.step.rawValue)"
    case .containerRemoved(let index): "cleanup.\(index).removed"
    case .journalUnlinked: "journal.unlinked"
    case .journalRemoved: "journal.removed"
    }
  }
}

extension TransactionSession {
  /// Transitions and their durable evidence promises are changed together.
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
    if next == .publishing { journal.phase = .applying }
    journal.entries[index].progress = next
    journal.entries[index].conflict = nil
    try persist(.entry(index, next))
    try emit(.progress(index, next))
  }
}
