import CPlatform
import Foundation

/// Access metadata is separate from content generations. ACL bytes contain ordered
/// numeric identities and inheritance, never resolved account names or payload bytes.
struct FileAccessEvidence: Codable, Equatable, Sendable {
  enum ACLFormat: String, Codable, Sendable {
    case darwinExternal
    case linuxPOSIX
  }

  let identity: FileObjectIdentity
  let owner: UInt32
  let group: UInt32
  let mode: mode_t
  let aclFormat: ACLFormat
  let acl: Data
  let defaultACL: Data

  static func capture(descriptor: Int32) throws -> Self {
    try read(descriptor: descriptor).evidence
  }

  func validate(descriptor: Int32) throws {
    guard try Self.capture(descriptor: descriptor) == self else {
      throw CoreError.invalidState("filesystem access changed during preparation")
    }
  }

  /// Requires a live owner-readable/writable object with no effective access for
  /// other identities. Root and same-UID adversaries are outside this boundary.
  @discardableResult
  static func requirePrivate(descriptor: Int32) throws -> Self {
    let current = try read(descriptor: descriptor)
    guard current.evidence.owner == geteuid(), current.evidence.mode & 0o7000 == 0,
      current.assessment == 0,
      current.evidence.identity.isDirectory || current.links == 1
    else {
      throw CoreError.invalidState("private filesystem access cannot be established")
    }
    return current.evidence
  }

  /// Traversable ordinary ancestors are allowed. Sticky directories protect an
  /// already-owned child, but ACL deletion/control grants are never excused by sticky.
  @discardableResult
  static func requireNonReplaceableDirectory(
    descriptor: Int32, protectingOwner childOwner: UInt32
  ) throws -> Self {
    let current = try read(descriptor: descriptor)
    let evidence = current.evidence
    let trustedOwner = evidence.owner == geteuid() || evidence.owner == 0
    let stickyProtection =
      evidence.mode & 0o1000 != 0 && (childOwner == geteuid() || childOwner == 0)
    guard evidence.identity.isDirectory, trustedOwner,
      current.assessment & UInt32(PLATFORM_ACCESS_EXTERNAL_CONTROL) == 0,
      current.assessment & UInt32(PLATFORM_ACCESS_EXTERNAL_WRITE) == 0 || stickyProtection,
      platform_access(descriptor, ".", X_OK) == 0
    else {
      throw CoreError.invalidState("filesystem ancestry permits replacement or is unprovable")
    }
    return evidence
  }

  private static func read(descriptor: Int32) throws -> (
    evidence: Self, assessment: UInt32, links: UInt64
  ) {
    var value = platform_file_access()
    guard platform_read_file_access(descriptor, &value) == 0 else {
      throw CoreError.invalidState("cannot capture descriptor access evidence: \(errno)")
    }
    defer { platform_dispose_file_access(&value) }
    #if os(macOS)
      let format = ACLFormat.darwinExternal
    #else
      let format = ACLFormat.linuxPOSIX
    #endif
    let evidence = Self(
      identity: FileObjectIdentity(value.info), owner: value.info.st_uid,
      group: value.info.st_gid, mode: value.info.st_mode & 0o7777, aclFormat: format,
      acl: value.acl.map { Data(bytes: $0, count: value.acl_size) } ?? Data(),
      defaultACL: value.default_acl.map { Data(bytes: $0, count: value.default_acl_size) } ?? Data()
    )
    return (evidence, value.assessment, UInt64(value.info.st_nlink))
  }
}

extension DirectoryHandle {
  func accessEvidence() throws -> FileAccessEvidence {
    try FileAccessEvidence.capture(descriptor: descriptor)
  }

  /// The entry and ACL are read through the same no-follow descriptor. Comparing
  /// this result on every pinned ancestor detects replacement as well as access drift.
  func accessEvidence(_ name: String) throws -> FileAccessEvidence? {
    try requireAccessComponent(name)
    guard let before = try info(name) else { return nil }
    let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else {
      throw CoreError.invalidState("cannot open entry for access evidence")
    }
    defer { close(file) }
    let result = try FileAccessEvidence.capture(descriptor: file)
    guard result.identity == FileObjectIdentity(before),
      let after = try info(name), Self.sameGeneration(before, after)
    else { throw CoreError.invalidState("entry changed while capturing access evidence") }
    return result
  }

  /// Returns an empty verified inode. No producer receives a writable payload
  /// path before verification; inherited ACLs are retained and evaluated as found.
  func createPrivateFile(_ name: String) throws -> PrivateFileHandle {
    try requireAccessComponent(name)
    let parentEvidence = try privateCreationParent()
    let file = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw CoreError.invalidState("cannot create private file: \(errno)") }
    var retained = false
    defer { if !retained { close(file) } }
    var created = stat()
    guard fstat(file, &created) == 0 else {
      throw CoreError.invalidState("cannot identify created private file")
    }
    do {
      let evidence = try FileAccessEvidence.requirePrivate(descriptor: file)
      try parentEvidence.validate(descriptor: descriptor)
      guard try accessEvidence(name) == evidence else {
        throw CoreError.invalidState("private file changed during creation")
      }
      let result = PrivateFileHandle(
        descriptor: file, parent: self, name: name, evidence: evidence,
        parentEvidence: parentEvidence)
      retained = true
      return result
    } catch {
      try? removeEmptyPrivateCreation(
        name, identity: FileObjectIdentity(created), directory: false,
        parentEvidence: parentEvidence)
      throw error
    }
  }

  func createPrivateDirectory(_ name: String) throws -> DirectoryHandle {
    try requireAccessComponent(name)
    let parentEvidence = try privateCreationParent()
    guard mkdirat(descriptor, name, 0o700) == 0 else {
      throw CoreError.invalidState("cannot create private directory: \(errno)")
    }
    guard let created = try info(name) else {
      throw CoreError.invalidState("private directory disappeared during creation")
    }
    do {
      let directory = try child(name, matching: created)
      let evidence = try FileAccessEvidence.requirePrivate(descriptor: directory.descriptor)
      try parentEvidence.validate(descriptor: descriptor)
      guard try accessEvidence(name) == evidence else {
        throw CoreError.invalidState("private directory changed during creation")
      }
      try directory.sync()
      try sync()
      return directory
    } catch {
      try? removeEmptyPrivateCreation(
        name, identity: FileObjectIdentity(created), directory: true, parentEvidence: parentEvidence
      )
      throw error
    }
  }

  private func privateCreationParent() throws -> FileAccessEvidence {
    let evidence = try FileAccessEvidence.requireNonReplaceableDirectory(
      descriptor: descriptor, protectingOwner: geteuid())
    guard platform_access(descriptor, ".", W_OK | X_OK) == 0 else {
      throw CoreError.invalidState("private creation requires writable directory access")
    }
    return evidence
  }

  private func removeEmptyPrivateCreation(
    _ name: String, identity: FileObjectIdentity, directory: Bool,
    parentEvidence: FileAccessEvidence
  ) throws {
    // If the namespace lost its protection, retain the empty object for its owner
    // rather than risking an unlink of an external replacement.
    try parentEvidence.validate(descriptor: descriptor)
    guard try info(name).map(FileObjectIdentity.init) == identity else { return }
    // A failed creation has never received bytes. rmdir also refuses unexpected children.
    guard unlinkat(descriptor, name, directory ? AT_REMOVEDIR : 0) == 0 else { return }
    try sync()
  }
}

/// The parent remains pinned until the last write. Publication, full path ancestry,
/// durable journal ownership and eventual disposal remain the transaction's duties.
final class PrivateFileHandle {
  let descriptor: Int32
  let evidence: FileAccessEvidence
  private let parent: DirectoryHandle
  private let name: String
  private let parentEvidence: FileAccessEvidence

  fileprivate init(
    descriptor: Int32, parent: DirectoryHandle, name: String, evidence: FileAccessEvidence,
    parentEvidence: FileAccessEvidence
  ) {
    self.descriptor = descriptor
    self.parent = parent
    self.name = name
    self.evidence = evidence
    self.parentEvidence = parentEvidence
  }

  deinit { close(descriptor) }

  func write(_ data: Data) throws {
    try parentEvidence.validate(descriptor: parent.descriptor)
    guard try FileAccessEvidence.requirePrivate(descriptor: descriptor) == evidence,
      try parent.accessEvidence(name) == evidence
    else { throw CoreError.invalidState("private file access changed before writing") }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = CPlatform.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CoreError.invalidState("cannot write private file") }
        offset += count
      }
    }
    guard platform_sync(descriptor) == 0 else {
      throw CoreError.invalidState("cannot synchronize private file")
    }
    try parent.sync()
  }
}

private func requireAccessComponent(_ name: String) throws {
  guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
    throw CoreError.invalidState("access operation requires one path component")
  }
}
