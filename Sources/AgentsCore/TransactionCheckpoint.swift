import Foundation

/// Names are unique within one transaction and never contain host path components. A caller
/// that nests transactions under one checkpoint stream prefixes each nested transaction's names.
enum TransactionCheckpoint {
  enum Change {
    case created, containers
    case entry(Int, TransactionJournal.Progress)
    case terminal, disposing
    case conflict(Int, TransactionJournal.Progress)
    var name: String {
      switch self {
      case .created: "created"
      case .containers: "containers"
      case .entry(let index, let progress): "entry.\(index).\(progress.rawValue)"
      case .terminal: "terminal"
      case .disposing: "disposing"
      case .conflict(let index, let progress): "entry.\(index).\(progress.rawValue).conflict"
      }
    }
  }
  enum Stage: String { case preimageSynced, workCreated, workPrepared, writeCreated, constructed }
  enum Publication: String { case validated, exchanged, created, deleted, synced }
  enum Restoration: String { case validated, exchanged, returned, withdrawn, synced }
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
  /// Creation of a missing registered root or of its ancestors.
  case rootAncestry(String, DirectoryHandle.AncestryStep)
  /// Creation of an entry's missing destination parent or of its ancestors below the root.
  case parentAncestry(entry: Int, DirectoryHandle.AncestryStep)
  case containerCreated(Int)
  case containersIdentified
  case probe(Int, DirectoryHandle.ProbeStep)
  case stage(Int, Stage)
  case copy(Int, DirectoryHandle.CopyPoint)
  case publication(Int, Publication)
  case restoration(Int, Restoration)
  case permissions(Int, Permission, TransactionObjectLocation, DirectoryHandle.PermissionStep)
  case preconditions, commitValidated, journalSynced, disposalIntent
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
    case .parentAncestry(let index, let step): "ancestry.entry.\(index).\(step.name)"
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
    case .disposalIntent: "disposal.intent"
    case .unlinked(let index, let path):
      "disposal.\(index).unlinked" + (path.isEmpty ? "" : "." + path)
    case .containerRemoved(let index): "disposal.\(index).removed"
    case .journalUnlinked: "journal.unlinked"
    case .journalRemoved: "journal.removed"
    }
  }

  /// Whether `name` follows the rename that makes a journal generation visible.
  static func isJournalPublished(_ name: String) -> Bool {
    name.hasPrefix("journal.") && name.hasSuffix("." + PersistenceStep.renamed.rawValue)
  }
}
