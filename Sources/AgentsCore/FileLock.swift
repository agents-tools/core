import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package enum FileLock {
  package static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
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
