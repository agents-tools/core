import Foundation

struct FileObjectIdentity: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let kind: mode_t

  var isDirectory: Bool { kind == S_IFDIR }

  init(_ info: stat) {
    device = UInt64(info.st_dev)
    inode = UInt64(info.st_ino)
    kind = info.st_mode & S_IFMT
  }
}

/// A recorded directory inode whose final mode lacks owner-write. While `publishing` or
/// `restoring` intent is durable it admits the original mode or that mode plus owner-write.
struct DirectoryWriteLease: Equatable {
  let identity: FileObjectIdentity
  let originalMode: mode_t

  init?(_ snapshot: FileSnapshot) {
    guard snapshot.identity.isDirectory, snapshot.mode & 0o200 == 0 else { return nil }
    identity = snapshot.identity
    originalMode = snapshot.mode
  }

  var grantedMode: mode_t { originalMode | 0o200 }

  func admits(_ mode: mode_t) -> Bool { mode == originalMode || mode == grantedMode }
}

/// Content and physical ownership are separate evidence. Descendant identities let
/// terminal disposal resume after partial deletion without adopting new entries.
struct FileSnapshot: Codable, Equatable, Sendable {
  let identity: FileObjectIdentity
  let digest: String
  let executable: Bool
  /// Final permission bits. Only publishing/restoring may temporarily add directory owner-write.
  let mode: mode_t
  let children: [String: FileSnapshot]?

  static func read(at url: URL) throws -> FileSnapshot? {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw FileSystem.posixError(errno, at: url, otherwise: .unsafePath("cannot inspect target"))
    }
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent().resolvingSymlinksInPath())
    return try read(url.lastPathComponent, from: parent)
  }

  struct Capture {
    let snapshot: FileSnapshot?
    let contentHash: String
    let executableFlags: [String: Bool]
    let bytes: Data?
  }

  static func captureFile(at url: URL) throws -> Capture {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT {
        return Capture(
          snapshot: nil, contentHash: FileHash.hashRecords([]), executableFlags: [:], bytes: nil)
      }
      throw FileSystem.posixError(errno, at: url, otherwise: .unsafePath("cannot inspect target"))
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw CoreError.unsafePath("expected regular file: \(url.path)")
    }
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent().resolvingSymlinksInPath())
    return try capture(url.lastPathComponent, from: parent)
  }

  /// The snapshot and content verification consume the same opened-file bytes.
  static func capture(_ name: String, from parent: DirectoryHandle) throws -> Capture {
    var records: [(String, Data)] = []
    var rootBytes: Data?
    var flags: [String: Bool] = [:]
    let value = try read(name, from: parent, relative: "") { path, kind, bytes, executable in
      guard !path.isEmpty else {
        if kind == S_IFREG {
          rootBytes = bytes
          flags[""] = executable
        }
        return
      }
      switch kind {
      case S_IFDIR: records.append((path, Data("directory".utf8)))
      case S_IFREG:
        records.append((path, Data("file\0".utf8) + bytes))
        flags[path] = executable
      case S_IFLNK: records.append((path, Data("link\0".utf8) + bytes))
      default: break
      }
    }
    return Capture(
      snapshot: value,
      contentHash: value?.isRegular == true ? value!.digest : FileHash.hashRecords(records),
      executableFlags: flags, bytes: rootBytes)
  }

  static func read(_ name: String, from parent: DirectoryHandle) throws -> FileSnapshot? {
    try read(name, from: parent, relative: "", collect: nil)
  }

  private static func read(
    _ name: String, from parent: DirectoryHandle, relative: String,
    collect: ((String, mode_t, Data, Bool) -> Void)?
  ) throws -> FileSnapshot? {
    guard let before = try parent.info(name) else { return nil }
    let children: [String: FileSnapshot]?
    let payload: Data
    switch before.st_mode & S_IFMT {
    case S_IFDIR:
      let directory = try parent.child(name, matching: before)
      var entries: [String: FileSnapshot] = [:]
      for child in try directory.names() {
        guard
          let value = try read(
            child, from: directory, relative: relative.isEmpty ? child : relative + "/" + child,
            collect: collect)
        else {
          throw CoreError.invalidState("entry changed while reading: \(child)")
        }
        entries[child] = value
      }
      children = entries
      // Only content enters the digest; ownership is compared independently.
      payload = try StateStore.encode(
        entries.mapValues { "\($0.identity.kind):\($0.executable):\($0.digest)" })
    case S_IFREG:
      children = nil
      payload = try parent.read(name, matching: before)
    case S_IFLNK:
      children = nil
      payload = try parent.readLinkData(name)
    default: throw CoreError.unsafePath("unsupported transaction entry: \(name)")
    }
    guard let after = try parent.info(name), DirectoryHandle.sameGeneration(before, after) else {
      throw CoreError.invalidState("entry changed while reading: \(name)")
    }
    collect?(relative, before.st_mode & S_IFMT, payload, before.st_mode & 0o111 != 0)
    return FileSnapshot(
      identity: FileObjectIdentity(before), digest: FileHash.sha256Hex(data: payload),
      executable: before.st_mode & S_IFMT == S_IFREG && before.st_mode & 0o111 != 0,
      mode: before.st_mode & 0o7777,
      children: children)
  }

  var writeLease: DirectoryWriteLease? { DirectoryWriteLease(self) }

  func matches(_ current: Self, permittingDirectoryWrite: Bool) -> Bool {
    if self == current { return true }
    guard permittingDirectoryWrite, let lease = writeLease, lease.admits(current.mode) else {
      return false
    }
    return Self(
      identity: identity, digest: digest, executable: executable, mode: current.mode,
      children: children) == current
  }

  var isRegular: Bool { identity.kind == S_IFREG }
  var isSymbolicLink: Bool { identity.kind == S_IFLNK }

  func validate() throws {
    try StateValidation.digest("sha256:" + digest)
    let kinds: [mode_t] = [S_IFDIR, S_IFREG, S_IFLNK]
    guard kinds.contains(identity.kind), mode & ~0o7777 == 0,
      (identity.kind == S_IFDIR) == (children != nil)
    else { throw CoreError.invalidState("invalid transaction object evidence") }
    for (name, child) in children ?? [:] {
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
        !name.contains("\0")
      else { throw CoreError.invalidState("invalid transaction descendant") }
      try child.validate()
    }
  }

  func containsRemaining(_ current: FileSnapshot) -> Bool {
    guard identity == current.identity else { return false }
    guard let children, let remaining = current.children else { return self == current }
    return remaining.allSatisfy { name, value in children[name]?.containsRemaining(value) == true }
  }
}
