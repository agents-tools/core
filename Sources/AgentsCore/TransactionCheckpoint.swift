import Foundation

/// Names are unique within one transaction and never contain host path components.
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
  enum Permission: String {
    case publicationGrant = "publish.grant"
    case publicationRestore = "publish.restore"
    case undoGrant = "undo.grant"
    case undoRestore = "undo.restore"
    case cancelRestore = "cancel.restore"
    case conflictRestore = "conflict.restore"
  }
  case persisted(TransactionJournal.Phase, Change, PersistenceStep)
  case phase(TransactionJournal.Phase)
  case progress(Int, TransactionJournal.Progress)
  /// Creation of a missing registered root or one of its ancestors.
  case rootAncestry(String, DirectoryHandle.AncestryStep)
  /// Creation of a missing destination parent at a level below its root.
  case parentCreated(entry: Int, level: Int)
  case containerCreated(Int)
  case containersIdentified
  case probe(Int, DirectoryHandle.ProbeStep)
  case stage(Int, Stage)
  case copy(Int, DirectoryHandle.CopyPoint)
  case publication(Int, Publication)
  case restoration(Int, Restoration)
  case permissions(Int, Permission, TransactionObjectLocation, DirectoryHandle.PermissionStep)
  case preconditions, commitValidated, journalSynced, discardIntent
  /// The path is relative to the container; empty names the container itself.
  case unlinked(container: Int, path: String)
  /// The container's removal and its parent barrier are complete.
  case containerRemoved(Int)
  case journalUnlinked
  case journalRemoved

  var name: String {
    switch self {
    case .persisted(let phase, let change, let step):
      "journal.\(phase.rawValue).\(change.name).\(step.rawValue)"
    case .phase(let phase): "journal.\(phase.rawValue)"
    case .progress(let index, let progress): "entry.\(index).\(progress.rawValue)"
    case .rootAncestry(let root, let step): "ancestry.\(root).\(step.name)"
    case .parentCreated(let index, let level): "ancestry.entry.\(index).\(level).created"
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
    case .journalSynced: "journal.synced"
    case .discardIntent: "cleanup.intent"
    case .unlinked(let index, let path):
      "cleanup.\(index).unlinked" + (path.isEmpty ? "" : "." + path)
    case .containerRemoved(let index): "cleanup.\(index).removed"
    case .journalUnlinked: "journal.unlinked"
    case .journalRemoved: "journal.removed"
    }
  }
}
