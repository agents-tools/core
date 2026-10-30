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
    /// Construction is verified; staging is sealed and other recovery slots are absent.
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

  static func containerName(id: UUID, index: Int) -> String { ".agents-\(id.uuidString)-\(index)" }

  func containerName(_ index: Int) -> String { containers[index].name }

  /// Without an identified container or sealed operation, the journal owns no object.
  var isUnstarted: Bool {
    phase == .preparing && containers.allSatisfy { $0.identity == nil }
      && entries.allSatisfy { $0.progress == .queued }
  }
}

/// Container entry names. Each recovery slot holds either private staging or user data.
enum TransactionScratch: String {
  /// Private sealed staging for a creation; publication moves it out of the container.
  case staged
  /// Private sealed staging for an exchange until publication; afterwards the displaced user
  /// preimage, and after undo the withdrawn published object.
  case exchanged
  /// The user object moved aside by a deletion.
  case deleted
  /// The published creation moved aside by undo; it is user data.
  case withdrawn
  /// Private extraction work for prepared content.
  case work

  func name(_ index: Int) -> String { "entry.\(index).\(rawValue)" }
  static let objectSlots: [Self] = [.staged, .exchanged, .deleted, .withdrawn]
  static let probes = (first: "probe-a", second: "probe-b", moved: "probe-c")

  /// The slot that holds an install's sealed staging.
  static func staging(for entry: TransactionJournal.Entry) -> Self {
    entry.preimage == nil ? .staged : .exchanged
  }
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
    let prepared: Self
    let installed: Self
    let reverted: Self
    // Validated records carry staged evidence exactly for installs past construction.
    switch (entry.preimage, entry.staged) {
    case (let original?, let staged?):
      prepared = Self(kind: .prepared, target: .any, objects: [.exchanged: staged])
      installed = Self(kind: .installed, target: .object(staged), objects: [.exchanged: original])
      reverted = Self(kind: .reverted, target: .object(original), objects: [.exchanged: staged])
    case (nil, let staged?):
      prepared = Self(kind: .prepared, target: .any, objects: [.staged: staged])
      installed = Self(kind: .installed, target: .object(staged), objects: [:])
      reverted = Self(
        kind: .reverted, target: .externalTo(staged.identity), objects: [.withdrawn: staged])
    case (let original?, nil):
      prepared = Self(kind: .prepared, target: .any, objects: [:])
      installed = Self(kind: .installed, target: .absent, objects: [.deleted: original])
      reverted = Self(kind: .reverted, target: .object(original), objects: [:])
    case (nil, nil):
      prepared = Self(kind: .prepared, target: .any, objects: [:])
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

  /// Recorded objects and their locations in this distribution. A prepared operation still
  /// has its preimage at the target, which the table does not constrain before publication.
  func objectLocations(
    _ entry: TransactionJournal.Entry
  ) -> [(location: TransactionObjectLocation, object: FileSnapshot)] {
    var locations: [(location: TransactionObjectLocation, object: FileSnapshot)] = []
    if case .object(let expected) = target {
      locations.append((.target, expected))
    } else if kind == .prepared, let original = entry.preimage {
      locations.append((.target, original))
    }
    for slot in TransactionScratch.objectSlots {
      if let expected = objects[slot] { locations.append((.scratch(slot), expected)) }
    }
    return locations
  }
}
