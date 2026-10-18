import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

extension StateStore {
  /// Takes an existing scope lock without creating files or replaying recovery.
  /// Pending recovery runs the diagnostic callback instead of inspecting inconsistent state.
  package func withReadLock<T>(
    onPendingRecovery: () throws -> T = {
      throw CoreError.invalidState("transaction recovery is required before inspection")
    },
    _ body: () throws -> T
  ) throws -> T {
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
    else { return try onPendingRecovery() }
    return try body()
  }
}
