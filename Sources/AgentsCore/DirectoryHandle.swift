import CPlatform
import Foundation

/// Pins directory ancestry. Child operations never traverse symbolic links.
final class DirectoryHandle {
  let descriptor: Int32
  let url: URL

  init(
    at url: URL, create: Bool = false, checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    self.url = url.standardizedFileURL
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw CoreError.unsafePath("cannot open filesystem root") }
    defer { if current >= 0 { close(current) } }
    for (index, component) in self.url.pathComponents.dropFirst().enumerated() {
      // macOS exposes these root-owned system directories through immutable aliases.
      // All task-controlled components, including every cache ancestor, use O_NOFOLLOW.
      let systemAlias = index == 0 && platform_system_alias(component)
      if create {
        var info = stat()
        if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          guard errno == ENOENT, mkdirat(current, component, 0o700) == 0 else {
            throw FileSystem.posixError(
              errno, at: self.url, otherwise: .unsafePath("cannot create directory: \(url.path)"))
          }
          try FileSystem.requireAccess(
            R_OK | W_OK | X_OK, at: self.url, parent: current, name: component)
          try checkpoint("directory.created.\(component)")
        }
        // An existing entry may have been published by an interrupted creator.
        try Self.synchronize(current)
        try checkpoint("directory.synced.\(component)")
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

  /// Deletes an owned subtree, granting owner access only to directories being discarded.
  func remove(_ name: String, checkpoint: (String) throws -> Void = { _ in }) throws {
    if let info = try info(name) {
      if info.st_mode & S_IFMT == S_IFDIR {
        let directory = try child(name)
        if info.st_mode & S_IRWXU != S_IRWXU {
          guard fchmod(directory.descriptor, (info.st_mode & 0o7777) | S_IRWXU) == 0 else {
            throw CoreError.unsafePath("cannot make discarded directory writable: \(name)")
          }
        }
        for entry in try directory.names() { try directory.remove(entry) }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
          throw CoreError.unsafePath("cannot remove directory: \(name)")
        }
      } else if unlinkat(descriptor, name, 0) != 0 {
        throw CoreError.unsafePath("cannot remove entry: \(name)")
      }
      try checkpoint("unlinked")
    }
    // An absent entry may reflect an interrupted unlink whose parent was never synced.
    try sync()
    try checkpoint("synced")
  }

  func rename(
    _ name: String, to destination: String, swap: Bool = false,
    afterRename: () throws -> Void = {}
  ) throws {
    let result =
      swap
      ? platform_exchange(descriptor, name, destination)
      : renameat(descriptor, name, descriptor, destination)
    guard result == 0 else {
      if swap, errno == ENOSYS || errno == ENOTSUP || errno == EINVAL {
        throw CoreError.unsupported("atomic exchange is required: \(errno)")
      }
      throw CoreError.invalidState("cannot replace \(destination): \(errno)")
    }
    try afterRename()
    try sync()
  }

  func renameExclusive(
    _ name: String, to destination: String, afterRename: () throws -> Void = {}
  ) throws {
    guard platform_rename_exclusive(descriptor, name, destination) == 0 else {
      let code = errno
      if code == EEXIST || code == ENOTEMPTY {
        throw CoreError.invalidState("transaction destination already exists: \(destination)")
      }
      if code == ENOSYS || code == ENOTSUP || code == EINVAL {
        throw CoreError.unsupported("atomic no-replace publication is required: \(code)")
      }
      throw CoreError.invalidState("cannot publish exclusively \(destination): \(code)")
    }
    try afterRename()
    try sync()
  }

  /// Checks flag admission without creating any object. FileTransaction also probes
  /// the actual filesystem with journal-owned objects before publishing targets.
  static func requireAtomicRenames(at destination: URL) throws {
    var ancestor = destination.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
      ancestor.deleteLastPathComponent()
    }
    let directory = try DirectoryHandle(at: ancestor.resolvingSymlinksInPath())
    let prefix = ".agents-probe-" + UUID().uuidString
    for exclusive in [false, true] {
      let result =
        exclusive
        ? platform_rename_exclusive(directory.descriptor, prefix + ".a", prefix + ".b")
        : platform_exchange(directory.descriptor, prefix + ".a", prefix + ".b")
      guard result < 0, errno == ENOENT else {
        throw CoreError.unsupported(
          "atomic exchange and no-replace publication are required: \(errno)")
      }
    }
  }

  func makeDirectory(_ name: String) throws {
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
    try sync()
  }

  func sync() throws {
    try Self.synchronize(descriptor)
  }

  func link(_ name: String, destination: String) throws {
    guard symlinkat(destination, descriptor, name) == 0 else {
      throw FileSystem.posixError(
        errno, at: url.appendingPathComponent(name),
        otherwise: .invalidState("cannot create link: \(name)"))
    }
    try sync()
  }

  func write(
    _ name: String, data: Data, mode: mode_t = 0o600, preservingMetadataOf original: String? = nil
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
      let source = try regularFile(original)
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
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
    guard count >= 0, count < buffer.count - 1 else {
      throw FileSystem.posixError(
        count < 0 ? errno : 0, at: url.appendingPathComponent(name),
        otherwise: .unsafePath("invalid symbolic link"))
    }
    return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func syncFile(_ name: String) throws {
    let file = try regularFile(name)
    defer { close(file) }
    try Self.synchronize(file)
    try sync()
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
  }

  /// Copies through pinned descriptors, including modes, ACLs and extended attributes.
  func copy(
    _ name: String, from source: DirectoryHandle, named original: String,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws {
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
      try checkpoint("directory")
      let destination = try child(name)
      let origin = try source.child(original)
      for entry in try origin.names() {
        try destination.copy(entry, from: origin, named: entry, checkpoint: checkpoint)
      }
      try Self.copyMetadata(from: origin.descriptor, to: destination.descriptor, mode: info.st_mode)
    case S_IFLNK:
      try link(name, destination: source.readLink(original))
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
      try FileSystem.requireAccess(
        R_OK | W_OK, at: url.appendingPathComponent(name), parent: descriptor)
      guard platform_copy_data(origin, destination) == 0 else {
        throw CoreError.invalidState("cannot copy file content")
      }
      try Self.copyMetadata(from: origin, to: destination, mode: info.st_mode)
    default: throw CoreError.unsafePath("unsupported filesystem entry: \(original)")
    }
    try sync()
    try checkpoint("entry")
  }

  private static func copyMetadata(from origin: Int32, to destination: Int32, mode: mode_t) throws {
    guard platform_copy_metadata(origin, destination, mode) == 0 else {
      throw CoreError.invalidState("cannot preserve filesystem metadata: \(errno)")
    }
  }
}
