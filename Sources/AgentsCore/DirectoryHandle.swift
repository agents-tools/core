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

  init(at url: URL) throws {
    self.url = url.standardizedFileURL
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw CoreError.unsafePath("cannot open filesystem root") }
    for (index, component) in self.url.pathComponents.dropFirst().enumerated() {
      // macOS exposes these root-owned system directories through immutable aliases.
      // All task-controlled components, including every cache ancestor, use O_NOFOLLOW.
      let systemAlias = index == 0 && ["var", "tmp", "etc"].contains(component)
      let next = openat(
        current, component, O_RDONLY | O_DIRECTORY | (systemAlias ? 0 : O_NOFOLLOW) | O_CLOEXEC)
      close(current)
      guard next >= 0 else { throw CoreError.unsafePath("unsafe directory: \(url.path)") }
      current = next
    }
    descriptor = current
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
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
  }

  func remove(_ name: String) throws {
    guard let info = try info(name) else { return }
    if info.st_mode & S_IFMT == S_IFDIR {
      let directory = try child(name)
      for entry in try directory.names() { try directory.remove(entry) }
      guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
        throw CoreError.unsafePath("cannot remove directory: \(name)")
      }
    } else if unlinkat(descriptor, name, 0) != 0 {
      throw CoreError.unsafePath("cannot remove entry: \(name)")
    }
    try sync()
  }

  func rename(_ name: String, to destination: String, swap: Bool = false) throws {
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
    try sync()
  }

  func makeDirectory(_ name: String) throws {
    guard mkdirat(descriptor, name, 0o700) == 0 else {
      throw CoreError.invalidState("cannot create directory: \(name)")
    }
    try sync()
  }

  func sync() throws {
    guard fsync(descriptor) == 0 else { throw CoreError.invalidState("cannot sync \(url.path)") }
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
    guard fsync(file) == 0 else { throw CoreError.invalidState("cannot sync \(name)") }
    try sync()
  }

  func copy(_ name: String, from source: DirectoryHandle, named original: String) throws {
    guard let info = try source.info(original) else { throw CoreError.notFound(original) }
    switch info.st_mode & S_IFMT {
    case S_IFDIR:
      guard mkdirat(descriptor, name, 0o700) == 0 else {
        throw CoreError.invalidState("cannot stage directory")
      }
      let destination = try child(name)
      let origin = try source.child(original)
      for entry in try origin.names() { try destination.copy(entry, from: origin, named: entry) }
      try destination.sync()
    case S_IFLNK:
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      let count = readlinkat(source.descriptor, original, &buffer, buffer.count - 1)
      guard count >= 0, count < buffer.count - 1 else {
        throw CoreError.unsafePath("invalid symbolic link")
      }
      try link(
        name,
        destination: String(
          decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    case S_IFREG:
      let file = openat(source.descriptor, original, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw CoreError.unsafePath("cannot read \(original)") }
      defer { close(file) }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = read(file, &buffer, buffer.count)
        guard count >= 0 else { throw CoreError.invalidState("cannot read \(original)") }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      try write(name, data: data, mode: info.st_mode & 0o777)
    default: throw CoreError.unsafePath("unsupported filesystem entry: \(original)")
    }
    try sync()
  }
}
