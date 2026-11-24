import Foundation

struct FileObjectIdentity: Codable, Hashable, Sendable {
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
  let children: [Member]?

  struct Member: Codable, Equatable, Sendable {
    let name: String
    let snapshot: FileSnapshot
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.snapshot == rhs.snapshot
    }
  }

  func child(named name: String) -> FileSnapshot? {
    children?.first { $0.name.utf8.elementsEqual(name.utf8) }?.snapshot
  }

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
    var budget = CaptureBudget()
    let value = try read(name, from: parent, relative: "", budget: &budget) {
      path, kind, bytes, executable in
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
    var budget = CaptureBudget()
    return try read(name, from: parent, relative: "", budget: &budget, collect: nil)
  }

  private struct CaptureBudget {
    var entries = 0
    var bytes = 0
    mutating func consume(_ name: String, info: stat, depth: Int) throws {
      let limits = LedgerLimits.standard
      entries += 1
      let size = info.st_mode & S_IFMT == S_IFREG ? info.st_size : 0
      guard entries <= limits.entries, depth < limits.depth / 4,
        size >= 0, size <= limits.resourceBytes - bytes,
        name.utf8.count <= limits.resourceBytes - bytes - Int(size)
      else { throw CoreError.invalidState("transaction tree exceeds resource limits") }
      bytes += Int(size) + name.utf8.count
    }
  }

  private static func read(
    _ name: String, from parent: DirectoryHandle, relative: String, budget: inout CaptureBudget,
    collect: ((String, mode_t, Data, Bool) -> Void)?
  ) throws -> FileSnapshot? {
    guard let before = try parent.info(name) else { return nil }
    try budget.consume(name, info: before, depth: relative.split(separator: "/").count)
    let children: [Member]?
    let payload: Data
    switch before.st_mode & S_IFMT {
    case S_IFDIR:
      let directory = try parent.child(name, matching: before)
      var entries: [Member] = []
      for child in try directory.names() {
        guard
          let value = try read(
            child, from: directory, relative: relative.isEmpty ? child : relative + "/" + child,
            budget: &budget, collect: collect)
        else {
          throw CoreError.invalidState("entry changed while reading: \(child)")
        }
        entries.append(Member(name: child, snapshot: value))
      }
      entries.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
      children = entries
      // Only content enters the digest; ownership is compared independently.
      payload = try StateStore.encode(
        entries.map {
          [$0.name, "\($0.snapshot.identity.kind):\($0.snapshot.executable):\($0.snapshot.digest)"]
        })
    case S_IFREG:
      children = nil
      payload = try parent.read(
        name, matching: before, maximumBytes: LedgerLimits.standard.resourceBytes)
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
    let members = children ?? []
    guard
      zip(members, members.dropFirst()).allSatisfy({
        $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
      })
    else { throw CoreError.invalidState("duplicate or unordered transaction descendants") }
    for member in members {
      let name = member.name
      let child = member.snapshot
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
        !name.contains("\0")
      else { throw CoreError.invalidState("invalid transaction descendant") }
      try child.validate()
    }
  }

  func containsRemaining(_ current: FileSnapshot) -> Bool {
    guard identity == current.identity else { return false }
    guard let children, let remaining = current.children else { return self == current }
    let recorded = Dictionary(
      uniqueKeysWithValues: children.map { (Data($0.name.utf8), $0.snapshot) })
    return remaining.allSatisfy { member in
      recorded[Data(member.name.utf8)]?.containsRemaining(member.snapshot) == true
    }
  }
}

/// Required journal classification. Optional metadata is required by validation whenever
/// its corresponding object exists in a security-bearing operation.
struct TransactionSecurity: Codable {
  enum Classification: String, Codable { case ordinary, privateMaterialization }
  var preimage: Classification = .ordinary
  var replacement: Classification = .ordinary
  var permissionChange = false
  var ancestry: DirectoryAccessEvidence?
  var preimageAccess: FileAccessEvidence?
  var stagedAccess: FileAccessEvidence?

  var isPrivate: Bool {
    preimage == .privateMaterialization || replacement == .privateMaterialization
  }

  var preimageTreeAccess: [TreeMemberAccess]?
  var stagedTreeAccess: [TreeMemberAccess]?

  func validate(entry: TransactionJournal.Entry) throws {
    guard !isPrivate || ancestry != nil,
      !permissionChange || (replacement == .privateMaterialization && entry.preimage != nil),
      !isPrivate || (entry.preimage == nil) == (preimageAccess == nil),
      replacement != .privateMaterialization || (entry.staged == nil) == (stagedAccess == nil),
      preimage != .privateMaterialization || entry.preimage != nil,
      replacement != .privateMaterialization || entry.action == .install
    else { throw CoreError.invalidState("missing or contradictory transaction security evidence") }
    for (snapshot, access, members) in [
      (entry.preimage, preimageAccess, preimageTreeAccess),
      (entry.staged, stagedAccess, stagedTreeAccess),
    ] {
      if let access {
        guard let snapshot, access.identity == snapshot.identity, access.mode == snapshot.mode,
          snapshot.isRegular || snapshot.identity.isDirectory
        else {
          throw CoreError.invalidState("transaction access evidence belongs to another object")
        }
        try TreeMemberAccess.validate(members, snapshot: snapshot)
      } else if members != nil {
        throw CoreError.invalidState("tree access requires root access evidence")
      }
    }
  }

  func validateObject(
    _ snapshot: FileSnapshot, named name: String, in parent: DirectoryHandle,
    remaining: Bool = false, permittingDirectoryWrite: Bool = false
  )
    throws
  {
    let access: FileAccessEvidence?
    let classification: Classification
    let members: [TreeMemberAccess]?
    if snapshot.identity == preimageAccess?.identity {
      access = preimageAccess
      classification = preimage
      members = preimageTreeAccess
    } else if snapshot.identity == stagedAccess?.identity {
      access = stagedAccess
      classification = replacement
      members = stagedTreeAccess
    } else {
      return
    }
    guard let access else { return }
    if classification == .privateMaterialization {
      _ = try parent.requirePrivateAccess(name, matching: access)
    } else if try parent.accessEvidence(name).map({
      access.admits($0, removal: remaining, directoryWrite: permittingDirectoryWrite)
    }) != true {
      throw CoreError.invalidState("transaction object access changed")
    }
    try TreeMemberAccess.verify(
      members, snapshot: snapshot, named: name, in: parent,
      requirePrivate: classification == .privateMaterialization, remaining: remaining,
      permittingDirectoryWrite: permittingDirectoryWrite)

  }
}

/// Complete, byte-ordered access evidence for real tree members; links remain snapshots.
package struct TreeMemberAccess: Codable, Equatable {
  package let path: String
  package let access: FileAccessEvidence

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.access == rhs.access
  }

  static func capture(
    _ name: String, in parent: DirectoryHandle, snapshot: FileSnapshot,
    requirePrivate: Bool = false
  ) throws -> [Self]? {
    guard snapshot.identity.isDirectory else { return nil }
    var result: [Self] = []
    func walk(_ directory: DirectoryHandle, _ snapshot: FileSnapshot, prefix: String) throws {
      for member in snapshot.children ?? [] {
        let path = prefix + member.name
        let value = member.snapshot
        if value.isSymbolicLink { continue }
        guard let access = try directory.accessEvidence(member.name),
          access.identity == value.identity,
          access.mode == value.mode
        else { throw CoreError.invalidState("tree access changed during capture") }
        if requirePrivate { _ = try directory.requirePrivateAccess(member.name, matching: access) }
        result.append(Self(path: path, access: access))
        if value.identity.isDirectory {
          try walk(directory.child(member.name), value, prefix: path + "/")
        }
      }
    }
    try walk(parent.child(name), snapshot, prefix: "")
    result.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    try validate(result, snapshot: snapshot)
    return result
  }

  static func validateStructure(_ members: [Self]) throws {
    var previous: String?
    guard members.count <= LedgerLimits.standard.entries else {
      throw CoreError.invalidState("tree access exceeds member limit")
    }
    for member in members {
      let parts = member.path.split(separator: "/", omittingEmptySubsequences: false)
      guard !parts.isEmpty, parts.count < LedgerLimits.standard.depth / 4,
        parts.allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
        }),
        previous.map({ $0.utf8.lexicographicallyPrecedes(member.path.utf8) }) ?? true,
        [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(member.access.identity.kind),
        member.access.mode & ~0o7777 == 0
      else { throw CoreError.invalidState("invalid tree access member") }
      previous = member.path
    }
  }

  static func validate(_ members: [Self]?, snapshot: FileSnapshot) throws {
    guard snapshot.identity.isDirectory else {
      guard members == nil else {
        throw CoreError.invalidState("file carries tree access evidence")
      }
      return
    }
    guard let members else { throw CoreError.invalidState("directory lacks tree access evidence") }
    try validateStructure(members)
    var expected: [(String, FileSnapshot)] = []
    func walk(_ value: FileSnapshot, prefix: String) {
      for member in value.children ?? [] {
        let path = prefix + member.name
        if !member.snapshot.isSymbolicLink { expected.append((path, member.snapshot)) }
        walk(member.snapshot, prefix: path + "/")
      }
    }
    walk(snapshot, prefix: "")
    expected.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    guard members.count == expected.count,
      zip(members, expected).allSatisfy({
        $0.path.utf8.elementsEqual($1.0.utf8) && $0.access.identity == $1.1.identity
          && $0.access.mode == $1.1.mode
      })
    else { throw CoreError.invalidState("incomplete or contradictory tree access evidence") }
  }

  static func verify(
    _ members: [Self]?, snapshot: FileSnapshot, named name: String,
    in parent: DirectoryHandle, requirePrivate: Bool, remaining: Bool = false,
    permittingDirectoryWrite: Bool = false
  ) throws {
    try validate(members, snapshot: snapshot)
    guard let members else { return }
    let current = try FileSnapshot.read(name, from: parent)
    guard let current,
      remaining
        ? snapshot.containsRemaining(current)
        : snapshot.matches(current, permittingDirectoryWrite: permittingDirectoryWrite)
    else {
      throw CoreError.invalidState("tree changed while checking access")
    }
    let actual =
      try capture(name, in: parent, snapshot: current, requirePrivate: requirePrivate) ?? []
    let recorded = Dictionary(uniqueKeysWithValues: members.map { (Data($0.path.utf8), $0.access) })
    guard
      remaining
        ? actual.allSatisfy({ item in
          recorded[Data(item.path.utf8)]?.admits(item.access, removal: true) == true
        }) : actual == members
    else {
      throw CoreError.invalidState("tree member access changed")
    }
  }
}
