import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

extension StateStore {
  /// Takes an existing scope lock without creating files or replaying recovery.
  /// Pending recovery runs the diagnostic callback instead of inspecting inconsistent state.
  /// The body may be retried when a first writer creates the scope lock.
  package func withReadLock<T>(
    onPendingRecovery: () throws -> T = {
      throw CoreError.invalidState("transaction recovery is required before inspection")
    },
    _ body: () throws -> T
  ) throws -> T {
    while true {
      let directory = try openDirectoryIfPresent()
      let descriptor =
        directory.map {
          openat($0.descriptor, ".agents.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } ?? -1
      if directory != nil, descriptor < 0, errno != ENOENT {
        throw CoreError.invalidState("cannot open scope lock for inspection")
      }
      defer { if descriptor >= 0 { close(descriptor) } }
      if descriptor >= 0 {
        while flock(descriptor, LOCK_SH) != 0 {
          if errno != EINTR { throw CoreError.invalidState("cannot acquire scope inspection lock") }
        }
      }
      defer { if descriptor >= 0 { flock(descriptor, LOCK_UN) } }
      if try hasPendingRecovery(in: directory) { return try onPendingRecovery() }
      let result = Result(catching: body)
      // Writers create the lock before mutation and never remove it. A failed
      // unlocked read also needs revalidation before its error can be trusted.
      if descriptor < 0, let current = try openDirectoryIfPresent(),
        try current.info(".agents.lock") != nil || hasPendingRecovery(in: current)
      {
        continue
      }
      return try result.get()
    }
  }

  private func hasPendingRecovery(in directory: DirectoryHandle?) throws -> Bool {
    try directory?.info("transaction.json") != nil || directory?.info("transaction.new") != nil
  }
}
