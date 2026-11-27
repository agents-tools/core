import Foundation

/// Archive outputs carry the same per-identity boundary through preview and the publication
/// journal. A link carries coordinates only. Copies and rendered bytes require owner-only inodes.
package struct ArchiveDeploymentAccess {
  let target: TargetPrecondition
  let ancestry: DirectoryAccessEvidence
  let beforeAccess: FileAccessEvidence?
  let members: [TreeMemberAccess]?

  package init(at destination: URL) throws {
    self.target = try TargetPrecondition(destination)
    let parentURL = destination.deletingLastPathComponent()
    ancestry = try DirectoryAccessEvidence.capture(at: parentURL)
    if let snapshot = target.snapshot, snapshot.identity.kind != S_IFLNK {
      guard snapshot.isRegular || snapshot.identity.isDirectory else {
        throw CoreError.unsafePath("invalid private archive destination")
      }
      let parent = try DirectoryHandle(at: parentURL)
      beforeAccess = try parent.requirePrivateAccess(destination.lastPathComponent)
      members = try TreeMemberAccess.capture(
        destination.lastPathComponent, in: parent, snapshot: snapshot, requirePrivate: true)
    } else {
      beforeAccess = nil
      members = nil
    }
  }

  func requirePrivateLinkTarget(_ destination: URL, environment: RuntimeEnvironment) throws {
    let recovery = environment.homeDirectory
      .appendingPathComponent(".agents-source-recovery").resolvingSymlinksInPath()
    let resolved = destination.resolvingSymlinksInPath()
    guard PathSafety.isContained(resolved, in: recovery), resolved.path != recovery.path else {
      throw CoreError.unsafePath("archive link escapes private recovery")
    }
    let parts = PathSafety.relativePath(resolved.path, to: recovery.path).split(separator: "/")
    guard parts.count >= 2, parts[1] == "tree" else {
      throw CoreError.unsafePath("archive link requires a retained tree")
    }
    _ = try DirectoryAccessEvidence.capture(at: resolved)
    let root = try DirectoryHandle(at: recovery)
    let target = try DirectoryHandle(at: resolved)
    _ = try FileAccessEvidence.requirePrivate(descriptor: root.descriptor)
    _ = try FileAccessEvidence.requirePrivate(descriptor: target.descriptor)
  }

  package func memberAccessFingerprint() throws -> String? {
    try members.map { try ResolvedLedgerCodec.digest($0) }
  }

  package func validate() throws {
    let parentURL = target.url.deletingLastPathComponent()
    try ancestry.validate(at: parentURL)
    try target.validate()
    if let beforeAccess, let snapshot = target.snapshot {
      let parent = try DirectoryHandle(at: parentURL)
      _ = try parent.requirePrivateAccess(target.url.lastPathComponent, matching: beforeAccess)
      try TreeMemberAccess.verify(
        members, snapshot: snapshot, named: target.url.lastPathComponent, in: parent,
        requirePrivate: true)
    }
  }
}
