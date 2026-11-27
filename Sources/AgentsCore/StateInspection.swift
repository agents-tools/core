import CPlatform
import Foundation

extension StateStore {
  package func validateHeldScope() throws {
    guard let context = TransactionLockContext.current(self) else {
      throw CoreError.invalidState("publication requires scope coordination")
    }
    try context.requireHeldScope()
  }

  package var configurationJSONURL: URL? {
    scope == .user ? directory.appendingPathComponent(Self.configurationJSONFileName) : nil
  }

  package func stateEntryExists(_ name: String) throws -> Bool {
    try openDirectoryIfPresent()?.info(name) != nil
  }

  package func configurationInputBytes(_ name: String) throws -> Data? {
    guard let directory = try openDirectoryIfPresent(),
      try directory.info(name) != nil
    else { return nil }
    return try directory.read(name, maximumBytes: LedgerLimits.standard.encodedBytes)
  }

  /// Metadata and admission entries, including absent paths. Only the supplied scope root
  /// resolves through links; state-directory and lock links do not grant new path authority.
  package var metadataReadLocations: [URL] {
    let root = scope == .project ? environment.projectDirectory : environment.homeDirectory
    let roots = [root, root.resolvingSymlinksInPath()]
    return roots
      + roots.flatMap { root in
        let directory = root.appendingPathComponent(self.directory.lastPathComponent)
        return [directory]
          + [
            Self.declarationFileName, Self.resolvedFileName, Self.watchFileName, ".agents.lock",
            TransactionJournal.fileName, TransactionJournal.incompleteFileName,
            "watch-refs.pending",
          ].map { directory.appendingPathComponent($0) }
          + (scope == .user
            ? [directory.appendingPathComponent(Self.configurationJSONFileName)] : [])
      }
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
