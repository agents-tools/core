import Foundation

extension StateStore {
  /// Internal v2 access preserves the existing read/recovery boundary; public v1 readers reject v2.
  package func loadLedger(limits: LedgerLimits) throws -> ResolvedLedger {
    try withReadLock {
      _ = try declarationBytes()
      guard let bytes = try ledgerBytes(limits: limits) else {
        throw CoreError.notFound("resolved ledger")
      }
      return try ResolvedLedgerCodec.decode(bytes, limits: limits)
    }
  }

  package func stageLedger(
    _ ledger: ResolvedLedger, limits: LedgerLimits, transaction: FileTransaction,
    prepared: StatePrecondition
  ) throws {
    if let bytes = try ResolvedLedgerCodec.replacement(
      ledger, existing: prepared.bytes(for: resolvedURL), limits: limits)
    {
      try transaction.replace(
        resolvedURL, with: .data(bytes), expecting: prepared.evidence(for: resolvedURL))
    }
  }

  private func ledgerBytes(limits: LedgerLimits) throws -> Data? {
    guard let directory = try openDirectoryIfPresent(),
      try directory.info(Self.resolvedFileName) != nil
    else { return nil }
    return try directory.read(Self.resolvedFileName, maximumBytes: limits.encodedBytes)
  }

  /// Ref cleanup consumes the committed closure after physical journal recovery.
  func retentionReferences() throws -> RetentionReferences {
    guard let bytes = try ledgerBytes(limits: .standard) else { return RetentionReferences() }
    struct Version: Decodable { let version: Int }
    // This boundary is used only by recovery's cache reconciliation, never to reinterpret v2
    // as a v1 lifecycle model. Admission bounds decoding before examining the version.
    try LedgerAdmission.check(bytes, limits: LedgerLimits.standard)
    let version = try JSONDecoder().decode(Version.self, from: bytes).version
    if version == 2 {
      return try RetentionReferences(
        ledger: ResolvedLedgerCodec.decode(bytes, limits: LedgerLimits.standard),
        roots: [
          "project": environment.projectDirectory, "home": environment.homeDirectory,
          "state": directory,
        ])
    }
    let resolved = try StateStore.decode(bytes, as: ResolvedState.self)
    return try RetentionReferences(resolved: resolved, cache: SourceCache(store: self))
  }
}
