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
    let parent = try DirectoryHandle(
      at: url.deletingLastPathComponent(), create: true, checkpoint: checkpoint)
    let descriptor = openat(
      parent.descriptor, url.lastPathComponent, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw CoreError.invalidState("cannot open writer lock: \(url.path)")
    }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw CoreError.invalidState("cannot acquire writer lock: \(url.path)") }
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
