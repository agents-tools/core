import CPlatform
import Foundation

package enum FileLock {
  package static func withLock<T>(
    at url: URL, checkpoint: (String) throws -> Void = { _ in }, _ body: () throws -> T
  ) throws -> T {
    try withDescriptor(at: url, checkpoint: checkpoint) { _ in try body() }
  }

  /// Children may inherit this open file description. Close, never explicitly unlock it:
  /// exclusion ends only when the last owner (including a surviving child) closes it.
  package static func withDescriptor<T>(
    at url: URL, checkpoint: (String) throws -> Void = { _ in }, _ body: (Int32) throws -> T
  ) throws -> T {
    let parent = try DirectoryHandle(
      at: url.deletingLastPathComponent(), create: true, checkpoint: checkpoint)
    let descriptor = openat(
      parent.descriptor, url.lastPathComponent, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw FileSystem.posixError(
        errno, at: url, otherwise: .invalidState("cannot open writer lock: \(url.path)"))
    }
    do {
      // O_CREAT can return a writable fd even when the inherited ACL prevents reopening it.
      try FileSystem.requireAccess(R_OK | W_OK, at: url, parent: parent.descriptor)
    } catch {
      close(descriptor)
      throw error
    }
    return try withDescriptor(descriptor, at: url, checkpoint: checkpoint, body)
  }

  /// Returns nil when no lock exists. Cached inspection must not create one or read unlocked.
  static func withExistingDescriptor<T>(at url: URL, _ body: (Int32) throws -> T) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
      return nil
    }
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent())
    let descriptor = openat(
      parent.descriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else {
      throw FileSystem.posixError(
        errno, at: url, otherwise: .invalidState("cannot open existing lock: \(url.path)"))
    }
    return try withDescriptor(descriptor, at: url, checkpoint: { _ in }, body)
  }

  private static func withDescriptor<T>(
    _ descriptor: Int32, at url: URL, checkpoint: (String) throws -> Void,
    _ body: (Int32) throws -> T
  ) throws -> T {
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & 0o170000 == 0o100000 else {
      throw CoreError.unsafePath("writer lock must be a regular file: \(url.path)")
    }
    while platform_flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      guard errno == EWOULDBLOCK else {
        throw CoreError.invalidState("cannot acquire writer lock: \(url.path)")
      }
      try checkpoint("lock.contended")
      while platform_flock(descriptor, LOCK_EX) != 0 {
        if errno != EINTR {
          throw CoreError.invalidState("cannot acquire writer lock: \(url.path)")
        }
      }
      break
    }
    return try body(descriptor)
  }
}
