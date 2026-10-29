import CPlatform
import Foundation

struct FileObjectIdentity: Codable, Equatable {
  let device: UInt64
  let inode: UInt64
  let kind: mode_t

  init(_ info: stat) {
    device = UInt64(info.st_dev)
    inode = UInt64(info.st_ino)
    kind = info.st_mode & S_IFMT
  }
}

/// Content and physical ownership are separate evidence. Descendant identities let
/// terminal cleanup resume after partial deletion without adopting new entries.
struct FileSnapshot: Codable, Equatable {
  let identity: FileObjectIdentity
  let digest: String
  let executable: Bool
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

  static func read(_ name: String, from parent: DirectoryHandle) throws -> FileSnapshot? {
    guard var before = try parent.info(name) else { return nil }
    let children: [String: FileSnapshot]?
    let payload: Data
    switch before.st_mode & S_IFMT {
    case S_IFDIR:
      let directory = try parent.child(name)
      var opened = stat()
      guard fstat(directory.descriptor, &opened) == 0, platform_same_generation(&before, &opened)
      else {
        throw CoreError.invalidState("directory changed before reading: \(name)")
      }
      var entries: [String: FileSnapshot] = [:]
      for child in try directory.names() {
        guard let value = try read(child, from: directory) else {
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
      payload = Data(try parent.readLink(name).utf8)
    default: throw CoreError.unsafePath("unsupported transaction entry: \(name)")
    }
    guard var after = try parent.info(name), platform_same_generation(&before, &after) else {
      throw CoreError.invalidState("entry changed while reading: \(name)")
    }
    return FileSnapshot(
      identity: FileObjectIdentity(before), digest: FileHash.sha256Hex(data: payload),
      executable: before.st_mode & S_IFMT == S_IFREG && before.st_mode & 0o111 != 0,
      children: children)
  }

  func validate() throws {
    try StateValidation.digest("sha256:" + digest)
    let kinds: [mode_t] = [S_IFDIR, S_IFREG, S_IFLNK]
    guard kinds.contains(identity.kind),
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

  func sameObjects(as current: FileSnapshot) -> Bool {
    guard identity == current.identity else { return false }
    switch (children, current.children) {
    case (nil, nil): return true
    case (let expected?, let actual?):
      return expected.keys == actual.keys
        && expected.allSatisfy { name, value in actual[name].map(value.sameObjects) == true }
    default: return false
    }
  }

  func synchronize(_ name: String, from parent: DirectoryHandle) throws {
    guard try Self.read(name, from: parent) == self else {
      throw CoreError.invalidState("transaction preimage changed before synchronization: \(name)")
    }
    try syncContents(name, from: parent)
    try parent.sync()
    guard try Self.read(name, from: parent) == self else {
      throw CoreError.invalidState("transaction preimage changed during synchronization: \(name)")
    }
  }

  private func syncContents(_ name: String, from parent: DirectoryHandle) throws {
    if let children {
      let directory = try parent.child(name)
      for child in children.keys.sorted() {
        try children[child]!.syncContents(child, from: directory)
      }
      try directory.sync()
    } else if identity.kind == S_IFREG {
      try parent.syncFile(name)
    }
  }

  func remove(
    _ name: String, from parent: DirectoryHandle,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    guard let current = try Self.read(name, from: parent) else {
      try parent.sync()
      return
    }
    guard containsRemaining(current) else {
      throw CoreError.invalidState("transaction cleanup ownership changed: \(name)")
    }
    if let children {
      let directory = try parent.child(name)
      if let info = try parent.info(name), info.st_mode & S_IRWXU != S_IRWXU {
        guard fchmod(directory.descriptor, (info.st_mode & 0o7777) | S_IRWXU) == 0 else {
          throw CoreError.invalidState("cannot make discarded directory writable: \(name)")
        }
      }
      for child in try directory.names() {
        guard let expected = children[child] else {
          throw CoreError.invalidState("unexpected transaction descendant: \(child)")
        }
        try expected.remove(child, from: directory, checkpoint: checkpoint)
      }
      guard try parent.info(name).map(FileObjectIdentity.init) == identity else {
        throw CoreError.invalidState("transaction cleanup identity changed: \(name)")
      }
    }
    guard unlinkat(parent.descriptor, name, children == nil ? 0 : AT_REMOVEDIR) == 0 else {
      throw CoreError.invalidState("cannot discard verified transaction object: \(name)")
    }
    try checkpoint("unlinked")
    try parent.sync()
    try checkpoint("synced")
  }
}

/// Captures existing ancestry and the final entry without following that entry's link.
/// Missing ancestors may be created, but existing ancestors cannot be exchanged.
package struct PathIdentity {
  private let url: URL
  private let physical: URL
  private let entry: FileObjectIdentity?
  private let ancestors: [(URL, FileObjectIdentity)]

  package init(_ url: URL) throws {
    self.url = url
    physical =
      url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    entry = try Self.read(physical)
    var ancestors: [(URL, FileObjectIdentity)] = []
    var parent = physical.deletingLastPathComponent()
    while parent.path != "/" {
      if let value = try Self.read(parent) { ancestors.append((parent, value)) }
      parent.deleteLastPathComponent()
    }
    self.ancestors = ancestors
  }

  package func validate() throws {
    let current = url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    guard current == physical, try Self.read(physical) == entry else {
      throw CoreError.invalidState("path changed during preparation: \(url.path)")
    }
    for (path, value) in ancestors where try Self.read(path) != value {
      throw CoreError.invalidState("path ancestry changed during preparation: \(url.path)")
    }
  }

  private static func read(_ url: URL) throws -> FileObjectIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      if errno == ENOENT { return nil }
      throw CoreError.unsafePath("cannot inspect path: \(url.path)")
    }
    return FileObjectIdentity(value)
  }
}

/// State bytes and presence belong to the same generation as the rendered targets.
package struct StatePrecondition {
  private let files: [(URL, PathIdentity, FileSnapshot?)]

  package init(store: StateStore) throws {
    files = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      ($0, try PathIdentity($0), try FileSnapshot.read(at: $0))
    }
    try validate()
  }

  package func validate(excluding filenames: Set<String> = []) throws {
    for (url, identity, snapshot) in files where !filenames.contains(url.lastPathComponent) {
      try identity.validate()
      guard try FileSnapshot.read(at: url) == snapshot else {
        throw CoreError.invalidState("state changed during preparation: \(url.lastPathComponent)")
      }
    }
  }
}
