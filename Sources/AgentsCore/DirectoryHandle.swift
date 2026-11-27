import CPlatform
import Foundation

/// Pins directory ancestry. Child operations never traverse symbolic links.
package final class DirectoryHandle {
  struct SynchronizationObserver: Sendable {
    let didSynchronize: @Sendable () -> Void
  }

  @TaskLocal static var synchronizationObserver: SynchronizationObserver?
  let descriptor: Int32
  package let url: URL

  /// Depth counts levels above the opened directory; 0 is the directory itself.
  enum AncestryStep {
    case created(depth: Int)
    /// The parent barrier that makes a created component durable.
    case synced(depth: Int)

    var name: String {
      switch self {
      case .created(let depth): "created.\(depth)"
      case .synced(let depth): "synced.\(depth)"
      }
    }
  }

  /// With `create`, every component's parent is synced. Checkpoints mark only components
  /// this call creates, so their names and number do not depend on the host path.
  init(
    at url: URL, create: Bool = false, reportMissing: Bool = false,
    checkpoint: (AncestryStep) throws -> Void = { _ in }
  ) throws {
    self.url = url.standardizedFileURL
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else {
      if let exhaustion = OpenFileLimitError(errno, at: self.url) { throw exhaustion }
      throw CoreError.unsafePath("cannot open filesystem root")
    }
    defer { if current >= 0 { close(current) } }
    let components = self.url.pathComponents.dropFirst()
    for (index, component) in components.enumerated() {
      // macOS exposes these root-owned system directories through immutable aliases.
      // All task-controlled components, including every cache ancestor, use O_NOFOLLOW.
      let systemAlias = index == 0 && platform_system_alias(component)
      if create {
        let depth = components.count - 1 - index
        var info = stat()
        var created = false
        if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          guard errno == ENOENT, mkdirat(current, component, 0o700) == 0 else {
            throw FileSystem.posixError(
              errno, at: self.url, otherwise: .unsafePath("cannot create directory: \(url.path)"))
          }
          try FileSystem.requireAccess(
            R_OK | W_OK | X_OK, at: self.url, parent: current, name: component)
          created = true
          try checkpoint(.created(depth: depth))
        }
        // An existing entry may have been published by an interrupted creator.
        try Self.synchronize(current)
        if created { try checkpoint(.synced(depth: depth)) }
      }
      let next = openat(
        current, component, O_RDONLY | O_DIRECTORY | (systemAlias ? 0 : O_NOFOLLOW) | O_CLOEXEC)
      guard next >= 0 else {
        if reportMissing && errno == ENOENT { throw CoreError.notFound(self.url.path) }
        throw FileSystem.posixError(
          errno, at: self.url, otherwise: .unsafePath("unsafe directory: \(url.path)"))
      }
      close(current)
      current = next
    }
    if create {
      try FileSystem.requireAccess(R_OK | W_OK | X_OK, at: self.url, parent: current, name: ".")
    }
    descriptor = current
    current = -1
  }

  private init(parent: DirectoryHandle, name: String) throws {
    url = parent.url.appendingPathComponent(name)
    descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw FileSystem.posixError(
        errno, at: url, otherwise: .unsafePath("unsafe directory: \(url.path)"))
    }
  }

  deinit { close(descriptor) }

  func child(_ name: String) throws -> DirectoryHandle {
    try DirectoryHandle(parent: self, name: name)
  }

  /// Opens a child directory only if it is still the generation `expected` described.
  func child(_ name: String, matching expected: stat) throws -> DirectoryHandle {
    let directory = try child(name)
    var opened = stat()
    guard fstat(directory.descriptor, &opened) == 0, Self.sameGeneration(expected, opened) else {
      throw CoreError.invalidState("directory changed before reading: \(name)")
    }
    return directory
  }

  static func sameGeneration(_ first: stat, _ second: stat) -> Bool {
    var first = first
    var second = second
    return platform_same_generation(&first, &second)
  }

  func info(_ name: String) throws -> stat? {
    var value = stat()
    if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw FileSystem.posixError(
      errno, at: url.appendingPathComponent(name),
      otherwise: .unsafePath("cannot inspect \(url.appendingPathComponent(name).path)"))
  }

  package func names(maximumCount: Int = .max) throws -> [String] {
    let copy = dup(descriptor)
    guard copy >= 0 else {
      if let exhaustion = OpenFileLimitError(errno, at: url) { throw exhaustion }
      throw CoreError.unsafePath("cannot enumerate \(url.path)")
    }
    guard let stream = fdopendir(copy) else {
      let code = errno
      close(copy)
      if let exhaustion = OpenFileLimitError(code, at: url) { throw exhaustion }
      throw CoreError.unsafePath("cannot enumerate \(url.path)")
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      guard let name = String(validatingCString: platform_entry_name(entry)) else {
        throw CoreError.unsafePath("filesystem entry is not valid UTF-8")
      }
      if name != "." && name != ".." {
        guard names.count < maximumCount else {
          throw CoreError.invalidSource("directory entry budget at " + url.path)
        }
        names.append(name)
      }
    }
    guard errno == 0 else { throw CoreError.unsafePath("cannot enumerate \(url.path)") }
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  enum RemovalStep: String { case unlinked, synced }
  struct RemovalPoint {
    /// Relative to the removed entry; empty for the entry itself.
    let path: String
    let step: RemovalStep
  }

  /// Missing descendants are accepted only by callers with a durable disposal intent.
  /// Private trees and verified user objects share the same descriptor-relative deleter.
  func remove(
    _ name: String, expecting expected: FileSnapshot? = nil,
    identity expectedIdentity: FileObjectIdentity? = nil,
    checkpoint: (RemovalPoint) throws -> Void = { _ in }
  ) throws {
    try removeContents(
      name, expected: expected, identity: expectedIdentity, prefix: "",
      checkpoint: checkpoint)
    // An absent entry may be an interrupted unlink whose parent was not synced.
    try sync()
    try checkpoint(RemovalPoint(path: "", step: .synced))
  }

  private func removeContents(
    _ name: String, expected: FileSnapshot?, identity: FileObjectIdentity?, prefix: String,
    checkpoint: (RemovalPoint) throws -> Void
  ) throws {
    guard let info = try info(name) else { return }
    let observed = FileObjectIdentity(info)
    if let identity, observed != identity {
      throw CoreError.invalidState("removal identity changed: \(name)")
    }
    if let expected, observed != expected.identity {
      throw CoreError.invalidState("removal ownership changed: \(name)")
    }
    if info.st_mode & S_IFMT == S_IFDIR {
      let directory = try child(name)
      if info.st_mode & S_IRWXU != S_IRWXU {
        guard fchmod(directory.descriptor, (info.st_mode & 0o7777) | S_IRWXU) == 0 else {
          throw CoreError.unsafePath("cannot make removed directory writable: \(name)")
        }
      }
      let recorded = expected?.children.map {
        Dictionary(uniqueKeysWithValues: $0.map { (Data($0.name.utf8), $0.snapshot) })
      }
      for child in try directory.names() {
        if expected != nil, recorded?[Data(child.utf8)] == nil {
          throw CoreError.invalidState("unexpected descendant during removal: \(child)")
        }
        try directory.removeContents(
          child, expected: recorded?[Data(child.utf8)], identity: nil,
          prefix: prefix.isEmpty ? child : prefix + "/" + child, checkpoint: checkpoint)
      }
      try directory.sync()
    } else if let expected, try FileSnapshot.read(name, from: self) != expected {
      throw CoreError.invalidState("removal content changed: \(name)")
    }
    guard try self.info(name).map(FileObjectIdentity.init) == observed else {
      throw CoreError.invalidState("removal identity changed: \(name)")
    }
    guard unlinkat(descriptor, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0
    else {
      throw CoreError.invalidState("cannot remove filesystem entry: \(name): \(errno)")
    }
    try checkpoint(RemovalPoint(path: prefix, step: .unlinked))
  }

  /// rmdir never erases contents; an absent entry still receives the parent barrier.
  func removeEmptyDirectory(_ name: String) throws {
    guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
      let code = errno
      throw CoreError.invalidState(
        "cannot remove directory: \(name): \(code) (\(String(cString: strerror(code))))")
    }
    try sync()
  }

  enum RenameMode: Sendable { case exchange, exclusive }
  enum RenameResult: Equatable {
    case success
    case exists(Int32)
    case unsupported(Int32)
    case failure(Int32)

    init(code: Int32) {
      if code == 0 {
        self = .success
      } else if code == EEXIST || code == ENOTEMPTY {
        self = .exists(code)
      } else if [EINVAL, ENOSYS, ENOTSUP, EOPNOTSUPP].contains(code) {
        self = .unsupported(code)
      } else {
        self = .failure(code)
      }
    }

    func requireSuccess(_ operation: String) throws {
      switch self {
      case .success: return
      case .exists(let code):
        throw CoreError.invalidState(
          "transaction destination already exists: \(operation): \(code) (\(String(cString: strerror(code))))"
        )
      case .unsupported(let code):
        throw CoreError.unsupported(
          "atomic rename is required: \(operation): \(code) (\(String(cString: strerror(code))))")
      case .failure(let code):
        throw CoreError.invalidState(
          "cannot \(operation): \(code) (\(String(cString: strerror(code))))")
      }
    }
  }

  struct AtomicRenameFailure: Sendable {
    let mode: RenameMode
    let code: Int32
  }

  /// A matching injected errno replaces the platform result and takes the same classifier.
  @TaskLocal static var atomicRenameFailure: AtomicRenameFailure?

  var device: UInt64 { get throws { try objectIdentity.device } }
  package var objectIdentity: FileObjectIdentity {
    get throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0 else {
        throw CoreError.invalidState("cannot identify directory")
      }
      return FileObjectIdentity(info)
    }
  }

  enum PermissionStep: String { case changed, synced }

  /// Only the lease's recorded directory inode may receive its temporary owner-write bit.
  func grant(_ lease: DirectoryWriteLease, checkpoint: (PermissionStep) throws -> Void) throws {
    try setPermissions(lease.grantedMode, lease: lease, checkpoint: checkpoint)
  }

  func restore(_ lease: DirectoryWriteLease, checkpoint: (PermissionStep) throws -> Void) throws {
    try setPermissions(lease.originalMode, lease: lease, checkpoint: checkpoint)
  }

  private func setPermissions(
    _ mode: mode_t, lease: DirectoryWriteLease, checkpoint: (PermissionStep) throws -> Void
  ) throws {
    let current = try checkedPermissions(lease)
    if current != mode {
      guard fchmod(descriptor, mode) == 0 else {
        let code = errno
        throw CoreError.invalidState(
          "cannot set directory permissions: \(code) (\(String(cString: strerror(code))))")
      }
      try checkpoint(.changed)
    }
    // A visible mode may be an interrupted chmod whose metadata barrier did not complete.
    try sync()
    var value = stat()
    guard fstat(descriptor, &value) == 0, value.st_mode & 0o7777 == mode else {
      throw CoreError.invalidState("directory permissions changed before synchronization")
    }
    try checkpoint(.synced)
  }

  func checkedPermissions(_ lease: DirectoryWriteLease) throws -> mode_t {
    var value = stat()
    guard fstat(descriptor, &value) == 0, FileObjectIdentity(value) == lease.identity else {
      throw CoreError.invalidState("recorded directory identity changed")
    }
    let current = value.st_mode & 0o7777
    guard lease.admits(current) else {
      throw CoreError.invalidState(
        "directory permissions changed beyond transaction intent: \(url.path)")
    }
    return current
  }

  func atomicRename(
    _ name: String, to parent: DirectoryHandle, named destination: String,
    mode: RenameMode
  ) -> RenameResult {
    if let failure = Self.atomicRenameFailure, failure.mode == mode {
      return RenameResult(code: failure.code)
    }
    let result =
      mode == .exchange
      ? platform_exchange(descriptor, name, parent.descriptor, destination)
      : platform_rename_exclusive(descriptor, name, parent.descriptor, destination)
    return RenameResult(code: result == 0 ? 0 : errno)
  }

  func move(
    _ name: String, to parent: DirectoryHandle, named destination: String,
    mode: RenameMode, afterRename: () throws -> Void = {}
  ) throws {
    try atomicRename(name, to: parent, named: destination, mode: mode).requireSuccess(
      "rename \(destination)")
    try afterRename()
    try parent.sync()
    if self !== parent { try sync() }
  }

  enum ProbeStep: String {
    case firstCreated, secondCreated, exchanged, collisionChecked, moved, verified
  }

  /// The descriptor is a private container on the publication device; the caller names
  /// three absent probe entries inside it.
  func requireAtomicRenames(
    first a: String, second b: String, moved c: String, checkpoint: (ProbeStep) throws -> Void
  ) throws {
    try write(
      a, data: Data("a".utf8), syncParent: false, afterCreate: { try checkpoint(.firstCreated) })
    try write(
      b, data: Data("b".utf8), syncParent: false, afterCreate: { try checkpoint(.secondCreated) })
    let first = try info(a).map(FileObjectIdentity.init)
    let second = try info(b).map(FileObjectIdentity.init)
    // Exchange must preserve both entries and exchange their physical identities.
    try atomicRename(a, to: self, named: b, mode: .exchange).requireSuccess("exchange atomic probe")
    try checkpoint(.exchanged)
    guard try info(a).map(FileObjectIdentity.init) == second,
      try info(b).map(FileObjectIdentity.init) == first
    else {
      throw CoreError.unsupported("atomic exchange did not preserve probe objects")
    }
    // An occupied destination must refuse publication and preserve both inodes.
    let collision = atomicRename(a, to: self, named: b, mode: .exclusive)
    switch collision {
    case .exists: break
    case .success:
      throw CoreError.unsupported("exclusive rename replaced an occupied probe")
    case .unsupported, .failure:
      try collision.requireSuccess("check exclusive atomic probe collision")
    }
    try checkpoint(.collisionChecked)
    guard try info(a).map(FileObjectIdentity.init) == second,
      try info(b).map(FileObjectIdentity.init) == first
    else {
      throw CoreError.unsupported("exclusive rename changed occupied probe objects")
    }
    // The same primitive must admit an absent destination, not merely reject all calls.
    try atomicRename(a, to: self, named: c, mode: .exclusive).requireSuccess(
      "move exclusive atomic probe")
    try checkpoint(.moved)
    guard try info(a) == nil, try info(c).map(FileObjectIdentity.init) == second else {
      throw CoreError.unsupported("exclusive rename did not move the probe object")
    }
    try checkpoint(.verified)
  }

  @discardableResult
  func makeDirectory(
    _ name: String, syncParent: Bool = true, afterCreate: () throws -> Void = {}
  ) throws -> DirectoryHandle {
    if try info(name) != nil {
      try FileSystem.requireAccess(
        R_OK | W_OK | X_OK, at: url.appendingPathComponent(name), parent: descriptor)
    }
    guard mkdirat(descriptor, name, 0o700) == 0 else {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .invalidState("cannot create directory: \(name)"))
    }
    try FileSystem.requireAccess(
      R_OK | W_OK | X_OK, at: url.appendingPathComponent(name), parent: descriptor)
    try afterCreate()
    let directory = try child(name)
    guard fchmod(directory.descriptor, 0o700) == 0 else {
      throw CoreError.invalidState("cannot set directory permissions")
    }
    if syncParent { try sync() }
    return directory
  }

  func sync() throws {
    try Self.synchronize(descriptor)
  }

  func link(_ name: String, destination: String, syncParent: Bool = true) throws {
    guard symlinkat(destination, descriptor, name) == 0 else {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .invalidState("cannot create link: \(name)"))
    }
    if syncParent { try sync() }
  }

  func write(
    _ name: String, data: Data, mode: mode_t = 0o600, preservingMetadataOf original: String? = nil,
    originalParent: DirectoryHandle? = nil, syncParent: Bool = true,
    afterCreate: () throws -> Void = {}
  ) throws {
    if try info(name) != nil {
      try FileSystem.requireAccess(
        R_OK | W_OK, at: url.appendingPathComponent(name), parent: descriptor)
    }
    let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard file >= 0 else {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .invalidState("cannot stage \(name)"))
    }
    defer { close(file) }
    try afterCreate()
    try FileSystem.requireAccess(
      R_OK | W_OK, at: url.appendingPathComponent(name), parent: descriptor)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = CPlatform.write(
          file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CoreError.invalidState("cannot write \(name)") }
        offset += count
      }
    }
    if let original {
      let source = try (originalParent ?? self).regularFile(original)
      defer { close(source) }
      var attributes = stat()
      guard fstat(source, &attributes) == 0 else {
        throw CoreError.invalidState("cannot inspect file metadata")
      }
      try Self.copyMetadata(from: source, to: file, mode: attributes.st_mode)
    } else {
      guard fchmod(file, mode) == 0 else { throw CoreError.invalidState("cannot set permissions") }
      try Self.synchronize(file)
    }
    if syncParent { try sync() }
  }

  /// Replaces an index or journal whose update is serialized by its writer lock.
  func replaceFile(
    _ name: String, through staging: String, with data: Data, mode: mode_t = 0o600,
    afterWrite: () throws -> Void, afterRename: () throws -> Void
  ) throws {
    if try info(staging) != nil {
      _ = try read(staging)
      guard unlinkat(descriptor, staging, 0) == 0 else {
        throw CoreError.invalidState("cannot remove \(staging): \(errno)")
      }
    }
    try write(staging, data: data, mode: mode, syncParent: false)
    try afterWrite()
    guard renameat(descriptor, staging, descriptor, name) == 0 else {
      throw CoreError.invalidState("cannot replace \(name): \(errno)")
    }
    try afterRename()
    try sync()
  }

  /// Unlinks each present regular file in order, then syncs this directory once.
  func removeFiles(_ names: [String], afterUnlink: (String) throws -> Void = { _ in }) throws {
    for name in names {
      if try info(name) != nil {
        _ = try read(name)
        guard unlinkat(descriptor, name, 0) == 0 else {
          throw CoreError.invalidState("cannot remove \(name): \(errno)")
        }
        try afterUnlink(name)
      }
    }
    try sync()
  }

  func read(_ name: String, matching expected: stat? = nil, maximumBytes: Int? = nil) throws -> Data
  {
    var data = Data()
    try readChunks(name, matching: expected, maximumBytes: maximumBytes) {
      data.append(contentsOf: $0)
    }
    return data
  }

  @discardableResult
  func readChunks(
    _ name: String, matching expected: stat?, maximumBytes: Int?,
    verifyAccess: (Int32) throws -> Void = { _ in },
    _ consume: (UnsafeRawBufferPointer) throws -> Void
  ) throws -> Int {
    let file = try regularFile(name)
    defer { close(file) }
    var before = stat()
    guard fstat(file, &before) == 0 else {
      throw CoreError.invalidState("cannot identify opened file: \(name)")
    }
    if var expected, !platform_same_generation(&expected, &before) {
      throw CoreError.invalidState("file changed before reading: \(name)")
    }
    try verifyAccess(file)
    if let maximumBytes, before.st_size > maximumBytes {
      throw CoreError.invalidState("file byte budget: \(name)")
    }
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = CPlatform.read(file, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else {
        throw FileSystem.posixError(
          errno, at: url.appendingPathComponent(name),
          otherwise: .invalidState("cannot read \(name)"))
      }
      if count == 0 {
        var after = stat()
        guard fstat(file, &after) == 0, platform_same_generation(&before, &after) else {
          throw CoreError.invalidState("file changed while reading: \(name)")
        }
        try verifyAccess(file)
        return total
      }
      if let maximumBytes, count > maximumBytes - total {
        throw CoreError.invalidState("file byte budget: \(name)")
      }
      try buffer.withUnsafeBytes {
        try consume(UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
      total += count
    }
  }

  func readLink(_ name: String) throws -> String {
    String(decoding: try readLinkData(name), as: UTF8.self)
  }

  func readLinkData(_ name: String) throws -> Data {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
    guard count >= 0, count < buffer.count - 1 else {
      throw FileSystem.posixError(
        count < 0 ? errno : 0, at: url.appendingPathComponent(name),
        otherwise: .unsafePath("invalid symbolic link"))
    }
    return Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
  }

  func syncFile(_ name: String, includingParent: Bool = true) throws {
    let file = try regularFile(name)
    defer { close(file) }
    try Self.synchronize(file)
    if includingParent { try sync() }
  }

  /// Syncs a verified object's file contents, then each directory level after its children,
  /// then this parent.
  func synchronize(_ name: String, as snapshot: FileSnapshot) throws {
    guard try FileSnapshot.read(name, from: self) == snapshot else {
      throw CoreError.invalidState("transaction preimage changed before synchronization: \(name)")
    }
    try synchronizeContents(name, as: snapshot)
    try sync()
  }

  private func synchronizeContents(_ name: String, as snapshot: FileSnapshot) throws {
    if let children = snapshot.children {
      let directory = try child(name)
      for member in children {
        try directory.synchronizeContents(member.name, as: member.snapshot)
      }
      try directory.sync()
    } else if snapshot.isRegular {
      try syncFile(name, includingParent: false)
    }
  }

  var identity: String {
    get throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0 else {
        throw CoreError.invalidState("cannot identify directory")
      }
      return FileHash.sha256Hex(data: Data("\(url.path)\0\(info.st_dev)\0\(info.st_ino)".utf8))
    }
  }

  private func regularFile(_ name: String) throws -> Int32 {
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    var info = stat()
    guard file >= 0 else {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .unsafePath("cannot open file: \(name)"))
    }
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(file)
      throw CoreError.unsafePath("expected regular file: \(name)")
    }
    return file
  }

  private static func synchronize(_ file: Int32) throws {
    guard platform_sync(file) == 0 else {
      throw CoreError.invalidState("cannot sync filesystem entry: \(errno)")
    }
    synchronizationObserver?.didSynchronize()
  }

  enum CopyStep: String { case directoryCreated, fileCreated, linkCreated, entryCopied }
  struct CopyPoint {
    let path: String
    let step: CopyStep
  }

  /// Copies through pinned descriptors, including modes, ACLs and extended attributes.
  func copy(
    _ name: String, from source: DirectoryHandle, named original: String,
    prefix: String = "", syncParent: Bool = true,
    checkpoint: (CopyPoint) throws -> Void = { _ in }
  ) throws {
    let path = prefix.isEmpty ? name : prefix + "/" + name
    guard let info = try source.info(original) else { throw CoreError.notFound(original) }
    switch info.st_mode & S_IFMT {
    case S_IFDIR:
      if try self.info(name) != nil {
        try FileSystem.requireAccess(
          R_OK | W_OK | X_OK, at: url.appendingPathComponent(name), parent: descriptor)
      }
      guard mkdirat(descriptor, name, 0o700) == 0 else {
        throw FileSystem.posixError(
          errno, at: url.appendingPathComponent(name),
          otherwise: .invalidState("cannot stage directory"))
      }
      try FileSystem.requireAccess(
        R_OK | W_OK | X_OK, at: url.appendingPathComponent(name), parent: descriptor)
      try checkpoint(CopyPoint(path: path, step: .directoryCreated))
      let destination = try child(name)
      let origin = try source.child(original)
      for entry in try origin.names() {
        try destination.copy(
          entry, from: origin, named: entry, prefix: path, syncParent: false, checkpoint: checkpoint
        )
      }
      try Self.copyMetadata(from: origin.descriptor, to: destination.descriptor, mode: info.st_mode)
    case S_IFLNK:
      try link(name, destination: source.readLink(original), syncParent: false)
      try checkpoint(CopyPoint(path: path, step: .linkCreated))
      guard platform_copy_link_metadata(source.descriptor, original, descriptor, name) == 0 else {
        throw CoreError.invalidState("cannot preserve link metadata: \(errno)")
      }
    case S_IFREG:
      if try self.info(name) != nil {
        try FileSystem.requireAccess(
          R_OK | W_OK, at: url.appendingPathComponent(name), parent: descriptor)
      }
      let origin = try source.regularFile(original)
      defer { close(origin) }
      let destination = openat(
        descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard destination >= 0 else {
        throw FileSystem.posixError(
          errno, at: url.appendingPathComponent(name), otherwise: .unsafePath("cannot copy file"))
      }
      defer { close(destination) }
      try checkpoint(CopyPoint(path: path, step: .fileCreated))
      try FileSystem.requireAccess(
        R_OK | W_OK, at: url.appendingPathComponent(name), parent: descriptor)
      guard platform_copy_data(origin, destination) == 0 else {
        throw CoreError.invalidState("cannot copy file content")
      }
      try Self.copyMetadata(from: origin, to: destination, mode: info.st_mode)
    default: throw CoreError.unsafePath("unsupported filesystem entry: \(original)")
    }
    if syncParent { try sync() }
    if !prefix.isEmpty { try checkpoint(CopyPoint(path: path, step: .entryCopied)) }
  }

  private static func copyMetadata(from origin: Int32, to destination: Int32, mode: mode_t) throws {
    guard platform_copy_metadata(origin, destination, mode) == 0 else {
      throw CoreError.invalidState("cannot preserve filesystem metadata: \(errno)")
    }
    synchronizationObserver?.didSynchronize()
  }
}

extension DirectoryHandle {
  package static func readDirectory(at url: URL) throws -> DirectoryHandle {
    try DirectoryHandle(at: url)
  }

  package static func readDirectoryIfPresent(at url: URL) throws -> DirectoryHandle? {
    do { return try DirectoryHandle(at: url, reportMissing: true) } catch CoreError.notFound {
      return nil
    }
  }

  /// Reads from this directory generation. Directories and links are classified without opening
  /// them, and the bytes and mode must come from the same observed regular file.
  package func observeRegularFile(
    _ name: String, maximumBytes: Int, requireUnshared: Bool = false
  ) throws -> RegularFileObservation {
    guard let entry = try info(name) else { return .missing }
    let identity = FileObjectIdentity(entry)
    guard entry.st_mode & S_IFMT == S_IFREG, !requireUnshared || entry.st_nlink == 1 else {
      return .other(identity)
    }
    let bytes = try read(name, matching: entry, maximumBytes: maximumBytes)
    guard let current = try info(name), Self.sameGeneration(entry, current) else {
      throw CoreError.invalidState("file changed while reading: " + name)
    }
    return .regular(identity, executable: entry.st_mode & 0o111 != 0, bytes: bytes)
  }

  package func directory(_ name: String) throws -> DirectoryHandle? {
    guard let generation = try info(name) else { return nil }
    return try child(name, matching: generation)
  }

  package func createDirectoryIfAbsent(_ name: String) throws -> DirectoryHandle {
    if mkdirat(descriptor, name, 0o755) != 0, errno != EEXIST {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .invalidState("cannot create directory: " + name))
    }
    let directory = try child(name)
    try sync()
    return directory
  }

  package func createDirectoryExclusively(_ name: String) throws -> DirectoryHandle {
    try makeDirectory(name)
  }

  package func readRegularFile(_ name: String, maximumBytes: Int) throws -> Data {
    try read(name, maximumBytes: maximumBytes)
  }

  package func readRegularFileIfPresent(_ name: String, maximumBytes: Int) throws -> Data? {
    guard try info(name) != nil else { return nil }
    return try readRegularFile(name, maximumBytes: maximumBytes)
  }

  package func publishIndex(
    _ name: String, data: Data, beforeRename: () throws -> Void
  ) throws {
    try replaceFile(
      name, through: "." + name + ".stage", with: data, mode: 0o644,
      afterWrite: beforeRename, afterRename: {})
  }

  package func regularFileSize(_ name: String) throws -> Int {
    guard let info = try info(name), info.st_mode & 0o170000 == 0o100000,
      let size = Int(exactly: info.st_size), size >= 0
    else { throw CoreError.unsafePath("expected regular file: " + name) }
    return size
  }

  package func capturePortableTree(
    _ name: String, limits: LedgerLimits = .standard, recursive: Bool = true,
    admitting: @escaping (String) throws -> Void
  ) throws -> (entries: [LedgerEntry], objects: [String: Data]) {
    try FileSnapshot.capturePortableTree(
      name, from: self, limits: limits, recursive: recursive, admitting: admitting)
  }

  /// Syncs a private generation before making its complete directory visible. A collision
  /// leaves the existing generation intact and lets the caller verify its contents.
  package func publishDirectory(
    named name: String, files: [String: Data], beforeCommit: () throws -> Void = {}
  ) throws -> Bool {
    try publishDirectory(named: name, beforeCommit: beforeCommit) { directory in
      for filename in files.keys.sorted() {
        try directory.write(filename, data: files[filename]!, mode: 0o644, syncParent: false)
      }
    }
  }

  package func publishPortableTree(
    named name: String, entries: [LedgerEntry], objects: [String: Data],
    beforeCommit: () throws -> Void
  ) throws -> Bool {
    let resource = LedgerResource(
      kind: .embedded, source: "", path: ".", hash: "", entries: entries)
    let tree = try LedgerResources.validatedEntries(resource)
    guard tree["."]?.kind == .directory else {
      throw CoreError.invalidSource("portable output must have a directory root")
    }
    return try publishDirectory(named: name, beforeCommit: beforeCommit) { directory in
      func populate(_ parent: DirectoryHandle, prefix: String) throws {
        for entry in children[prefix] ?? [] {
          try Task.checkCancellation()
          let name = String(entry.path.split(separator: "/").last!)
          switch entry.kind {
          case .directory:
            let child = try parent.makeDirectory(name, syncParent: false)
            try populate(child, prefix: entry.path)
            guard fchmod(child.descriptor, 0o755) == 0 else {
              throw CoreError.invalidState("cannot set portable directory permissions")
            }
            try child.sync()
          case .file:
            guard let object = entry.object, let data = objects[object] else {
              throw CoreError.invalidSource("missing portable output file")
            }
            try parent.write(
              name, data: data, mode: entry.executable ? 0o755 : 0o644, syncParent: false)
          case .symlink:
            guard let link = entry.link else {
              throw CoreError.invalidSource("missing output link")
            }
            try parent.link(name, destination: link, syncParent: false)
          }
        }
      }
      let children = Dictionary(
        grouping: entries.filter { $0.path != "." },
        by: { $0.path.split(separator: "/").dropLast().joined(separator: "/") })
      try populate(directory, prefix: "")
    }
  }

  package func publishRegularFile(
    named name: String, bytes: Data, afterCommit: () -> Void = {},
    beforeCommit: () throws -> Void = {}
  ) throws -> Bool {
    let staging = ".stage-" + UUID().uuidString
    let directory = try makeDirectory(staging, syncParent: false)
    let identity = try directory.objectIdentity
    defer { try? remove(staging, identity: identity) }
    try directory.write("artifact", data: bytes, mode: 0o644)
    try Task.checkCancellation()
    try beforeCommit()
    guard
      case .regular(_, false, let stagedBytes) = try directory.observeRegularFile(
        "artifact", maximumBytes: bytes.count, requireUnshared: true),
      stagedBytes == bytes
    else {
      throw CoreError.invalidState("staged file changed before publication")
    }
    let result = directory.atomicRename("artifact", to: self, named: name, mode: .exclusive)
    if case .exists = result { return false }
    try result.requireSuccess("publish file " + name)
    afterCommit()
    try sync()
    return true
  }

  package func publishDirectory(
    named name: String, beforeCommit: () throws -> Void, afterCommit: () -> Void = {},
    populate: (DirectoryHandle) throws -> Void
  ) throws -> Bool {
    let staging = ".stage-" + UUID().uuidString
    let directory = try makeDirectory(staging, syncParent: false)
    let identity = try directory.objectIdentity
    var moved = false
    defer { if !moved { try? remove(staging, identity: identity) } }
    try populate(directory)
    guard fchmod(directory.descriptor, 0o755) == 0 else {
      throw CoreError.invalidState("cannot set release directory permissions")
    }
    try directory.sync()
    try Task.checkCancellation()
    try beforeCommit()
    guard try info(staging).map(FileObjectIdentity.init) == identity else {
      throw CoreError.invalidState("staged directory changed before publication")
    }
    let result = atomicRename(staging, to: self, named: name, mode: .exclusive)
    if case .exists = result {
      try sync()
      return false
    }
    try result.requireSuccess("publish directory " + name)
    moved = true
    afterCommit()
    try sync()
    return true
  }
}

package enum RegularFileObservation {
  case missing
  case other(FileObjectIdentity)
  case regular(FileObjectIdentity, executable: Bool, bytes: Data)
}
