import Foundation

enum TransactionObjectLocation {
  case target
  case scratch(TransactionScratch)

  var name: String {
    switch self {
    case .target: "target"
    case .scratch(let slot): slot.rawValue
    }
  }
}

enum TransactionPermissionPurpose: String {
  case publicationGrant = "publish.grant"
  case publicationRestore = "publish.restore"
  case undoGrant = "undo.grant"
  case undoRestore = "undo.restore"
  case cancelRestore = "cancel.restore"
  case conflictRestore = "conflict.restore"
}

extension TransactionSession {
  /// Publishing/restoring intent binds a temporary owner-write bit to the recorded
  /// directory inode. It never grants access through an external replacement.
  func grantDirectoryPermissions(
    _ index: Int, layout: TransactionLayout, purpose: TransactionPermissionPurpose
  ) throws {
    let entry = journal.entries[index]
    var objects: [(TransactionObjectLocation, FileSnapshot)] = []
    if case .object(let expected) = layout.target {
      objects.append((.target, expected))
    } else if layout.kind == .prepared, let original = entry.preimage {
      objects.append((.target, original))
    }
    for slot in TransactionScratch.objectSlots {
      if let expected = layout.objects[slot] { objects.append((.scratch(slot), expected)) }
    }
    for (location, expected) in objects where expected.needsDirectoryWriteLease {
      try setDirectoryPermissions(
        index, location: location, expected: expected, mode: expected.mode | 0o200, purpose: purpose
      )
    }
  }

  /// Mode restoration uses physical identity independently of byte rollback. A
  /// changed payload is retained, while a known temporary permission can be undone.
  /// Missing inodes or modes outside the recorded pair require owner action.
  func restoreDirectoryPermissions(_ index: Int, purpose: TransactionPermissionPurpose) throws {
    try forEachDirectoryPermission(index) { location, expected in
      try setDirectoryPermissions(
        index, location: location, expected: expected, mode: expected.mode, purpose: purpose)
    }
  }

  func inspectDirectoryPermissions(_ index: Int) throws {
    guard journal.entries[index].progress.permitsDirectoryWrite else { return }
    try forEachDirectoryPermission(index) { location, expected in
      let (parent, name) = try permissionLocation(index, location)
      _ = try parent.child(name).checkedPermissions(
        expecting: expected.identity, from: expected.mode)
    }
  }

  private func forEachDirectoryPermission(
    _ index: Int, body: (TransactionObjectLocation, FileSnapshot) throws -> Void
  ) throws {
    let entry = journal.entries[index]
    let expected = [entry.preimage, entry.staged].compactMap { $0 }
      .filter(\.needsDirectoryWriteLease)
    guard !expected.isEmpty else { return }
    var found: [FileObjectIdentity] = []
    var errors: [String] = []
    let locations: [TransactionObjectLocation] =
      [.target]
      + TransactionScratch.objectSlots.map { .scratch($0) }
    for location in locations {
      do {
        let (parent, name) = try permissionLocation(index, location)
        guard let identity = try parent.info(name).map(FileObjectIdentity.init),
          let object = expected.first(where: { $0.identity == identity })
        else { continue }
        found.append(identity)
        try body(location, object)
      } catch { errors.append(String(describing: error)) }
    }
    if expected.contains(where: { !found.contains($0.identity) }) {
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
    _ index: Int, location: TransactionObjectLocation, expected: FileSnapshot, mode: mode_t,
    purpose: TransactionPermissionPurpose
  ) throws {
    guard journal.entries[index].progress.permitsDirectoryWrite else {
      throw conflict(index, "directory permission change requires durable intent")
    }
    let (parent, name) = try permissionLocation(index, location)
    let directory = try parent.child(name)
    try directory.setPermissions(mode, expecting: expected.identity, from: expected.mode) {
      try emit(.permissions(index, purpose, location, $0))
    }
  }
}
