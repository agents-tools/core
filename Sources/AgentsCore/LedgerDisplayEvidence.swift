import Foundation

extension TargetPrecondition {
  package func capturingPublicationAccess() throws -> Self { try capturingAccess() }

  /// A verified adoption or migration binds to the exact file generation shown in its preview.
  package func generationEvidence() throws -> String {
    struct Generation: Encodable {
      let path: String
      let snapshot: FileSnapshot?
    }
    return try ResolvedLedgerCodec.digest(Generation(path: physicalURL.path, snapshot: snapshot))
  }
  /// Stable access semantics omit inode generations, timestamps and private payload digests.
  package func displayEvidence(includeContent: Bool) throws -> String {
    struct Access: Encodable {
      let owner: UInt32
      let group: UInt32
      let mode: UInt32
      let acl: Data
      let defaults: Data
      init(_ evidence: FileAccessEvidence) {
        owner = evidence.owner
        group = evidence.group
        mode = UInt32(evidence.mode)
        acl = evidence.acl
        defaults = evidence.defaultACL
      }
    }
    struct Display: Encodable {
      let path: String
      let exists: Bool
      let content: String?
      let target: Access?
      let ancestry: [Access]
      let linkOwner: UInt32?
      let linkGroup: UInt32?
    }
    let access = try TargetAccessPrecondition.capture(at: physicalURL)
    var ancestry = access.ancestry.directories
    for (root, before) in TransactionLockContext.currentForDisplay?.createdAncestry ?? [] {
      let parent = physicalURL.deletingLastPathComponent()
      // Creating a nested lock directory can also create the parent of a sibling output.
      // A separate branch that appeared after preview must still change its fingerprint.
      let existingDepth = access.ancestry.directories.count
      let sharedDepth = zip(root.pathComponents, parent.pathComponents)
        .prefix { $0.0.utf8.elementsEqual($0.1.utf8) }.count
      let sharesCreatedParent =
        existingDepth > before.directories.count && existingDepth <= sharedDepth
      if parent.path == root.path || parent.path.hasPrefix(root.path + "/") || sharesCreatedParent {
        guard access.ancestry.directories.starts(with: before.directories) else {
          throw CoreError.invalidState("existing publication ancestry access changed")
        }
        if before.directories.count < ancestry.count { ancestry = before.directories }
      }
    }
    return try ResolvedLedgerCodec.digest(
      Display(
        path: physicalURL.path, exists: snapshot != nil,
        content: includeContent ? snapshot?.digest : nil,
        target: access.target.map(Access.init),
        ancestry: ancestry.map(Access.init), linkOwner: access.linkOwner,
        linkGroup: access.linkGroup))
  }
}

extension TargetPrecondition {
  /// Publication may create previously absent ancestry. Existing access and the leaf generation
  /// stay fixed; the transaction separately owns every created container.
  package func validateDuringPublication() throws {
    try validateIdentity()
    if let access {
      let current = try TargetAccessPrecondition.capture(at: physicalURL)
      guard current.target == access.target, current.linkOwner == access.linkOwner,
        current.linkGroup == access.linkGroup,
        current.ancestry.directories.starts(with: access.ancestry.directories)
      else {
        throw CoreError.invalidState(
          "target or existing ancestry access changed during publication")
      }
    }
    try validateSnapshot()
  }
}
