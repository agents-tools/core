import Foundation

/// Exact content identity. Discovery roots are namespaces within this content, not versions.
package struct SourceSnapshotID: Hashable, Sendable {
  package let source: String
  package let revision: String

  package init(source: String, revision: String) {
    self.source = source
    self.revision = revision
  }
}

/// A borrowed view, valid only while its source session is open. Stable output uses `snapshot`
/// and relative paths. `liveRoot` exists only for actual local authoring sources.
package struct SourceSnapshot {
  package let snapshot: SourceSnapshotID
  package let pin: SourceRevision?
  package let root: URL
  package let discoveryPath: String
  /// Actual local source root before `discoveryPath`, with its declaring home. Pinned local
  /// sources retain this origin; remote-contained syntax has none. It does not permit editing.
  package let localEnvironment: SourceEnvironment?
  package let liveRoot: URL?
  package let packageIdentity: String

  package init(
    snapshot: SourceSnapshotID, pin: SourceRevision?, root: URL, discoveryPath: String = ".",
    localEnvironment: SourceEnvironment? = nil, liveRoot: URL? = nil,
    packageIdentity: String? = nil
  ) throws {
    self.snapshot = snapshot
    self.packageIdentity = packageIdentity ?? snapshot.source
    self.pin = pin
    self.root = root
    self.discoveryPath = try PathSafety.sanitizeSubpath(discoveryPath)
    self.localEnvironment = localEnvironment
    self.liveRoot = liveRoot
    _ = try directory()
  }

  package func directory() throws -> URL { try resource(discoveryPath) }

  /// Both authored spelling and real symlink resolution must remain in the snapshot.
  package func resource(_ path: String) throws -> URL {
    guard !path.hasPrefix("~") else { throw CoreError.unsafePath("resource must be relative") }
    let file = try PathSafety.resolvedChild(base: root, subpath: path)
    guard PathSafety.isContained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath())
    else { throw CoreError.unsafePath("resource escapes its source snapshot: \(path)") }
    return file
  }

  /// Directory resources may contain links below their top-level entry as well.
  package func validateResourceTree(_ directory: URL) throws {
    _ = try relativePath(directory)
    guard let real = PathSafety.realPath(root.path),
      let entries = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let entry as URL in entries {
      try Task.checkCancellation()
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
        try !PathSafety.linkStaysInside(entry, root: real)
      {
        throw CoreError.unsafePath("resource symlink escapes source snapshot")
      }
    }
  }

  package func relativePath(_ url: URL) throws -> String {
    let path = PathSafety.relativePath(url.path, to: root.path)
    _ = try resource(path)
    return path
  }
}

/// Stable reconstruction coordinates. Contained sources borrow the enclosing package's exact
/// tree; resource paths remain relative to that tree. No borrowed URL is part of this evidence.
package struct SourceSnapshotEvidence: Equatable, Sendable {
  package let snapshot: SourceSnapshotID
  package let pin: SourceRevision?
  package let source: LockedSource?
  package let container: SourceSnapshotID?
}
