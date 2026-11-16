import Foundation

extension TargetPrecondition {
  package func capturingPublicationAccess() throws -> Self { try capturingAccess() }
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
    return try ResolvedLedgerCodec.digest(
      Display(
        path: physicalURL.path, exists: snapshot != nil,
        content: includeContent ? snapshot?.digest : nil,
        target: access.target.map(Access.init),
        ancestry: access.ancestry.directories.map(Access.init), linkOwner: access.linkOwner,
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
    guard try FileSnapshot.read(at: url) == snapshot else {
      throw CoreError.invalidState("target changed during preparation: \(url.path)")
    }
  }
}
