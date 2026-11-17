import CPlatform
import Foundation

extension StateStore {
  /// Durable admission dependencies for a scope inspection, including absent entries whose
  /// creation changes whether the scope can be read. State-file dependencies belong to the caller.
  package var readLockLocations: [URL] {
    [directory]
      + [
        ".agents.lock", TransactionJournal.fileName, TransactionJournal.incompleteFileName,
        "watch-refs.pending",
      ].map { directory.appendingPathComponent($0) }
  }

  /// Takes an existing scope lock without creating files or replaying recovery.
  /// Pending recovery runs the diagnostic callback instead of inspecting inconsistent state;
  /// by default it throws `CoreError.recoveryPending`.
  /// The body may be retried when a first writer creates the scope lock.
  /// The location callback reports external shared admission dependencies before opening them,
  /// including failed attempts, and may report a location more than once during re-admission.
  package func withReadLock<T>(
    onPendingRecovery: (() throws -> T)? = nil,
    footprint: Set<NativeTargetRoute> = [],
    installations: [SkillInstallationTarget] = [],
    onReadLocation: ((URL) -> Void)? = nil,
    _ body: () throws -> T
  ) throws -> T {
    try withCoordination(
      routes: footprint, installations: installations, writable: false,
      onReadLocation: onReadLocation
    ) {
      try withScopeReadLock(onPendingRecovery: onPendingRecovery, body)
    }
  }

  private func withScopeReadLock<T>(
    onPendingRecovery: (() throws -> T)? = nil,
    _ body: () throws -> T
  ) throws -> T {
    while true {
      let directory = try openDirectoryIfPresent()
      let descriptor =
        directory.map {
          openat($0.descriptor, ".agents.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } ?? -1
      if directory != nil, descriptor < 0, errno != ENOENT {
        throw FileSystem.posixError(
          errno, at: self.directory.appendingPathComponent(".agents.lock"),
          otherwise: .invalidState("cannot open scope lock for inspection"))
      }
      defer { if descriptor >= 0 { close(descriptor) } }
      if descriptor >= 0 {
        while platform_flock(descriptor, LOCK_SH) != 0 {
          if errno != EINTR { throw CoreError.invalidState("cannot acquire scope inspection lock") }
        }
      }
      defer { if descriptor >= 0 { platform_flock(descriptor, LOCK_UN) } }
      if descriptor >= 0, let directory {
        try TransactionLockContext.current(self)?.bindScope(directory, descriptor: descriptor)
      }
      try verifyCoordinationAdmission()
      let pending = try hasPendingRecovery(in: directory)
      let result = Result {
        guard pending else { return try body() }
        guard let onPendingRecovery else {
          throw CoreError.recoveryPending(
            FileTransaction.recoveryDiagnostic(store: self).message)
        }
        return try onPendingRecovery()
      }
      // Writers create the lock before mutation and never remove it. A failed
      // unlocked read also needs revalidation before its error can be trusted.
      if descriptor < 0, let current = try openDirectoryIfPresent(),
        try current.info(".agents.lock") != nil || (!pending && hasPendingRecovery(in: current))
      {
        continue
      }
      return try result.get()
    }
  }

  private func hasPendingRecovery(in directory: DirectoryHandle?) throws -> Bool {
    guard let directory else { return false }
    return try TransactionJournal.isPresent(in: directory)
      || directory.info("watch-refs.pending") != nil
  }
}
