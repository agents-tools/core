import CPlatform
import Foundation

/// Pins directory ancestry. Child operations never traverse symbolic links.
final class DirectoryHandle {
  @TaskLocal static var synchronizationObserver: (@Sendable () -> Void)?
  let descriptor: Int32
  let url: URL

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
    at url: URL, create: Bool = false, checkpoint: (AncestryStep) throws -> Void = { _ in }
  ) throws {
    self.url = url.standardizedFileURL
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw CoreError.unsafePath("cannot open filesystem root") }
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

  func names() throws -> [String] {
    guard let stream = fdopendir(dup(descriptor)) else {
      throw CoreError.unsafePath("cannot enumerate \(url.path)")
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = String(cString: platform_entry_name(entry))
      if name != "." && name != ".." { names.append(name) }
    }
    guard errno == 0 else { throw CoreError.unsafePath("cannot enumerate \(url.path)") }
    return names.sorted()
  }

  enum RemovalStep: String { case unlinked, synced }
  struct RemovalPoint {
    /// Relative to the removed entry; empty for the entry itself.
    let path: String
    let step: RemovalStep
  }

  /// Missing descendants are accepted only by callers with a durable discard intent.
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
      throw CoreError.invalidState("transaction cleanup identity changed: \(name)")
    }
    if let expected, observed != expected.identity {
      throw CoreError.invalidState("transaction cleanup ownership changed: \(name)")
    }
    if info.st_mode & S_IFMT == S_IFDIR {
      let directory = try child(name)
      if info.st_mode & S_IRWXU != S_IRWXU {
        guard fchmod(directory.descriptor, (info.st_mode & 0o7777) | S_IRWXU) == 0 else {
          throw CoreError.unsafePath("cannot make discarded directory writable: \(name)")
        }
      }
      for child in try directory.names() {
        if let expected, expected.children?[child] == nil {
          throw CoreError.invalidState("unexpected transaction descendant: \(child)")
        }
        try directory.removeContents(
          child, expected: expected?.children?[child], identity: nil,
          prefix: prefix.isEmpty ? child : prefix + "/" + child, checkpoint: checkpoint)
      }
      try directory.sync()
    } else if let expected, try FileSnapshot.read(name, from: self) != expected {
      throw CoreError.invalidState("transaction cleanup content changed: \(name)")
    }
    guard try self.info(name).map(FileObjectIdentity.init) == observed else {
      throw CoreError.invalidState("transaction cleanup identity changed: \(name)")
    }
    guard unlinkat(descriptor, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0
    else {
      throw CoreError.invalidState("cannot discard filesystem entry: \(name): \(errno)")
    }
    try checkpoint(RemovalPoint(path: prefix, step: .unlinked))
  }

  /// Only an empty unidentified container may be removed; rmdir never erases contents.
  func removeEmptyDirectory(_ name: String) throws {
    guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
      throw CoreError.invalidState("unidentified transaction container is not empty: \(name)")
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

  /// A non-nil injected errno replaces the platform result and takes the same classifier.
  @TaskLocal static var atomicRenameFailure: (@Sendable (RenameMode) -> Int32?)?

  var device: UInt64 { get throws { try objectIdentity.device } }
  var objectIdentity: FileObjectIdentity {
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
  func setPermissions(
    _ lease: DirectoryWriteLease, granting: Bool, checkpoint: (PermissionStep) throws -> Void
  ) throws {
    let mode = granting ? lease.grantedMode : lease.original
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
    if let code = Self.atomicRenameFailure?(mode) { return RenameResult(code: code) }
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
  func makeDirectory(_ name: String, syncParent: Bool = true) throws -> DirectoryHandle {
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

  func writeJournal(_ data: Data, afterWrite: () throws -> Void, afterRename: () throws -> Void)
    throws
  {
    if try info("transaction.new") != nil {
      _ = try read("transaction.new")
      guard unlinkat(descriptor, "transaction.new", 0) == 0 else {
        throw CoreError.invalidState("cannot remove incomplete journal: \(errno)")
      }
    }
    try write("transaction.new", data: data, syncParent: false)
    try afterWrite()
    // A replacing rename is reserved for the journal; publication exchanges or never replaces.
    guard renameat(descriptor, "transaction.new", descriptor, "transaction.json") == 0 else {
      throw CoreError.invalidState("cannot replace transaction.json: \(errno)")
    }
    try afterRename()
    try sync()
  }

  func removeJournal(afterUnlink: () throws -> Void = {}) throws {
    for name in ["transaction.new", "transaction.json"] {
      if try info(name) != nil {
        _ = try read(name)
        guard unlinkat(descriptor, name, 0) == 0 else {
          throw CoreError.invalidState("cannot remove journal: \(errno)")
        }
        if name == "transaction.json" { try afterUnlink() }
      }
    }
    try sync()
  }

  func read(_ name: String, matching expected: stat? = nil) throws -> Data {
    let file = try regularFile(name)
    defer { close(file) }
    var before = stat()
    guard fstat(file, &before) == 0 else {
      throw CoreError.invalidState("cannot identify opened file: \(name)")
    }
    if var expected, !platform_same_generation(&expected, &before) {
      throw CoreError.invalidState("file changed before reading: \(name)")
    }
    var data = Data()
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
        return data
      }
      data.append(contentsOf: buffer.prefix(count))
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
      for (child, value) in children.sorted(by: { $0.key < $1.key }) {
        try directory.synchronizeContents(child, as: value)
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
    synchronizationObserver?()
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
    synchronizationObserver?()
  }
}
