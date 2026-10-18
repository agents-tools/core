import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

extension StateStore {
  /// Takes an existing scope lock without creating files or replaying recovery.
  /// A pending transaction must be recovered by a mutating operation before inspection.
  package func withReadLock<T>(_ body: () throws -> T) throws -> T {
    guard let directory = try openDirectoryIfPresent() else { return try body() }
    let descriptor = openat(directory.descriptor, ".agents.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno != ENOENT {
      throw CoreError.invalidState("cannot open scope lock for inspection")
    }
    defer { if descriptor >= 0 { close(descriptor) } }
    if descriptor >= 0 {
      while flock(descriptor, LOCK_SH) != 0 {
        if errno != EINTR { throw CoreError.invalidState("cannot acquire scope inspection lock") }
      }
    }
    defer { if descriptor >= 0 { flock(descriptor, LOCK_UN) } }
    guard try directory.info("transaction.json") == nil,
      try directory.info("transaction.new") == nil
    else { throw CoreError.invalidState("transaction recovery is required before inspection") }
    return try body()
  }
}
