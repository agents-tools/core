import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

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
      throw CoreError.invalidState("cannot open writer lock: \(url.path)")
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & 0o170000 == 0o100000 else {
      throw CoreError.unsafePath("writer lock must be a regular file: \(url.path)")
    }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw CoreError.invalidState("cannot acquire writer lock: \(url.path)") }
    }
    return try body(descriptor)
  }
}
