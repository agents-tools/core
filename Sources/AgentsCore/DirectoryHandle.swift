import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

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
      let systemAlias = index == 0 && ["var", "tmp", "etc"].contains(component)
      if create {
        var info = stat()
        if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          guard errno == ENOENT, mkdirat(current, component, 0o700) == 0 else {
            throw CoreError.unsafePath("cannot create directory: \(url.path)")
          }
          try checkpoint("directory.created.\(component)")
        }
        // An existing entry may have been published by an interrupted creator.
        try Self.synchronize(current)
        try checkpoint("directory.synced.\(component)")
      }
      let next = openat(
        current, component, O_RDONLY | O_DIRECTORY | (systemAlias ? 0 : O_NOFOLLOW) | O_CLOEXEC)
      guard next >= 0 else { throw CoreError.unsafePath("unsafe directory: \(url.path)") }
      close(current)
      current = next
    }
    descriptor = current
    current = -1
  }

  private init(parent: DirectoryHandle, name: String) throws {
    url = parent.url.appendingPathComponent(name)
    descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CoreError.unsafePath("unsafe directory: \(url.path)") }
  }

  deinit { close(descriptor) }

  func child(_ name: String) throws -> DirectoryHandle {
    try DirectoryHandle(parent: self, name: name)
  }

  func info(_ name: String) throws -> stat? {
    var value = stat()
    if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw CoreError.unsafePath("cannot inspect \(url.appendingPathComponent(name).path)")
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
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    guard errno == 0 else { throw CoreError.unsafePath("cannot enumerate \(url.path)") }
    return names.sorted()
  }

  func remove(_ name: String, checkpoint: (String) throws -> Void = { _ in }) throws {
    if let info = try info(name) {
      if info.st_mode & S_IFMT == S_IFDIR {
        let directory = try child(name)
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
    let result: Int32
    if swap {
      #if canImport(Darwin)
        result = renameatx_np(descriptor, name, descriptor, destination, UInt32(RENAME_SWAP))
      #else
        throw CoreError.unsupported("atomic directory exchange requires renameatx_np")
      #endif
    } else {
      result = renameat(descriptor, name, descriptor, destination)
    }
    guard result == 0 else {
      throw CoreError.invalidState("cannot replace \(destination): \(errno)")
    }
    try afterRename()
    try sync()
  }

  func makeDirectory(_ name: String) throws {
    guard mkdirat(descriptor, name, 0o700) == 0 else {
      throw CoreError.invalidState("cannot create directory: \(name)")
    }
    try sync()
  }

  func sync() throws {
    try Self.synchronize(descriptor)
  }

  func link(_ name: String, destination: String) throws {
    guard symlinkat(destination, descriptor, name) == 0 else {
      throw CoreError.invalidState("cannot create link: \(name)")
    }
    try sync()
  }

  func write(_ name: String, data: Data, mode: mode_t = 0o600) throws {
    let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard file >= 0 else { throw CoreError.invalidState("cannot stage \(name)") }
    defer { close(file) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Foundation.write(
          file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw CoreError.invalidState("cannot write \(name)") }
        offset += count
      }
    }
    guard fchmod(file, mode) == 0 else { throw CoreError.invalidState("cannot set permissions") }
    try Self.synchronize(file)
    try sync()
  }

  func read(_ name: String) throws -> Data {
    let file = try regularFile(name)
    defer { close(file) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      guard count >= 0 else { throw CoreError.invalidState("cannot read \(name)") }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  func readLink(_ name: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
    guard count >= 0, count < buffer.count - 1 else {
      throw CoreError.unsafePath("invalid symbolic link")
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
    guard file >= 0 else { throw CoreError.unsafePath("cannot open file: \(name)") }
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(file)
      throw CoreError.unsafePath("expected regular file: \(name)")
    }
    return file
  }

  private static func synchronize(_ file: Int32) throws {
    guard fsync(file) == 0 else { throw CoreError.invalidState("cannot sync filesystem entry") }
    #if canImport(Darwin)
      guard fcntl(file, F_FULLFSYNC) == 0 else {
        throw CoreError.invalidState("cannot flush filesystem entry to storage")
      }
    #endif
  }

  /// Copies through pinned descriptors, including modes, ACLs and extended attributes.
  func copy(
    _ name: String, from source: DirectoryHandle, named original: String,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    guard let info = try source.info(original) else { throw CoreError.notFound(original) }
    switch info.st_mode & S_IFMT {
    case S_IFDIR:
      guard mkdirat(descriptor, name, 0o700) == 0 else {
        throw CoreError.invalidState("cannot stage directory")
      }
      try checkpoint("directory")
      let destination = try child(name)
      let origin = try source.child(original)
      for entry in try origin.names() {
        try destination.copy(entry, from: origin, named: entry, checkpoint: checkpoint)
      }
      try Self.copyMetadata(from: origin.descriptor, to: destination.descriptor, mode: info.st_mode)
    case S_IFLNK:
      try link(name, destination: source.readLink(original))
      let origin = openat(source.descriptor, original, O_RDONLY | O_SYMLINK | O_CLOEXEC)
      let destination = openat(descriptor, name, O_RDONLY | O_SYMLINK | O_CLOEXEC)
      defer {
        close(origin)
        close(destination)
      }
      guard origin >= 0, destination >= 0 else {
        throw CoreError.unsafePath("cannot copy link metadata")
      }
      try Self.copyMetadata(from: origin, to: destination, mode: info.st_mode)
    case S_IFREG:
      let origin = try source.regularFile(original)
      defer { close(origin) }
      let destination = openat(
        descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard destination >= 0 else { throw CoreError.unsafePath("cannot copy file") }
      defer { close(destination) }
      guard fcopyfile(origin, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
        throw CoreError.invalidState("cannot copy file content")
      }
      try Self.copyMetadata(from: origin, to: destination, mode: info.st_mode)
    default: throw CoreError.unsafePath("unsupported filesystem entry: \(original)")
    }
    try sync()
    try checkpoint("entry")
  }

  private static func copyMetadata(from origin: Int32, to destination: Int32, mode: mode_t) throws {
    guard fcopyfile(origin, destination, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
      fchmod(destination, mode & 0o7777) == 0
    else { throw CoreError.invalidState("cannot preserve filesystem metadata") }
    try synchronize(destination)
  }
}
