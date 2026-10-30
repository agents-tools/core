import Foundation

enum TransactionObjectLocation: Equatable {
  case target
  case scratch(TransactionScratch)

  var name: String {
    switch self {
    case .target: "target"
    case .scratch(let slot): slot.rawValue
    }
  }
}

extension TransactionSession {
  /// Publishing/restoring intent binds a temporary owner-write bit to the recorded
  /// directory inode. It never grants access through an external replacement.
  func grantDirectoryPermissions(
    _ index: Int, layout: TransactionLayout, purpose: TransactionCheckpoint.Permission
  ) throws {
    for (location, object) in layout.objectLocations(journal.entries[index]) {
      guard let lease = object.writeLease else { continue }
      try setDirectoryPermissions(
        index, location: location, lease: lease, granting: true, purpose: purpose)
    }
  }

  /// Mode restoration uses physical identity independently of byte rollback. A
  /// changed payload is retained, while a known temporary permission can be undone.
  /// Missing inodes or modes outside the recorded pair require owner action.
  func restoreDirectoryPermissions(_ index: Int, purpose: TransactionCheckpoint.Permission)
    throws
  {
    try forEachDirectoryLease(index) { location, lease in
      try setDirectoryPermissions(
        index, location: location, lease: lease, granting: false, purpose: purpose)
    }
  }

  func inspectDirectoryPermissions(_ index: Int) throws {
    guard journal.entries[index].progress.permitsDirectoryWrite else { return }
    try forEachDirectoryLease(index) { location, lease in
      let (parent, name) = try permissionLocation(index, location)
      _ = try parent.child(name).checkedPermissions(lease)
    }
  }

  /// Candidate locations are those of the progress's expected distributions. Each leased
  /// inode is acted on where it is found; one found in no candidate location is a conflict.
  private func forEachDirectoryLease(
    _ index: Int, body: (TransactionObjectLocation, DirectoryWriteLease) throws -> Void
  ) throws {
    let entry = journal.entries[index]
    var candidates: [(location: TransactionObjectLocation, lease: DirectoryWriteLease)] = []
    for layout in TransactionLayout.expected(entry) {
      for (location, object) in layout.objectLocations(entry) {
        guard let lease = object.writeLease,
          !candidates.contains(where: { $0.location == location && $0.lease == lease })
        else { continue }
        candidates.append((location, lease))
      }
    }
    var found: [FileObjectIdentity] = []
    var errors: [String] = []
    for (location, lease) in candidates {
      do {
        let (parent, name) = try permissionLocation(index, location)
        guard try parent.info(name).map(FileObjectIdentity.init) == lease.identity else {
          continue
        }
        found.append(lease.identity)
        try body(location, lease)
      } catch { errors.append(String(describing: error)) }
    }
    if candidates.contains(where: { !found.contains($0.lease.identity) }) {
      errors.append("directory mode restoration is missing its recorded inode")
    }
    guard errors.isEmpty else { throw conflict(index, errors.joined(separator: "; ")) }
  }

  private func permissionLocation(_ index: Int, _ location: TransactionObjectLocation) throws
    -> (DirectoryHandle, String)
  {
    try requireParent(index)
    switch location {
    case .target: return (parents[index], journal.entries[index].name)
    case .scratch(let slot):
      return (try container(journal.entries[index].container), slot.name(index))
    }
  }

  private func setDirectoryPermissions(
    _ index: Int, location: TransactionObjectLocation, lease: DirectoryWriteLease,
    granting: Bool, purpose: TransactionCheckpoint.Permission
  ) throws {
    guard journal.entries[index].progress.permitsDirectoryWrite else {
      throw conflict(index, "directory permission change requires durable intent")
    }
    let (parent, name) = try permissionLocation(index, location)
    try parent.child(name).setPermissions(lease, granting: granting) {
      try emit(.permissions(index, purpose, location, $0))
    }
  }
}
