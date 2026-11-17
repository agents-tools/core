import Foundation

extension StateStore {
  /// Reads the complete committed v2 ledger without resolution, recovery or persistent writes.
  public func loadLedger() throws -> ResolvedLedger {
    try loadLedger(limits: .standard)
  }

  /// Reads the single resolved ledger without recovery or persistent writes.
  package func loadLedger(limits: LedgerLimits) throws -> ResolvedLedger {
    try withReadLock {
      _ = try declarationBytes()
      return try readLedger(limits: limits)
    }
  }

  package func readLedger(
    prepared: StatePrecondition? = nil, limits: LedgerLimits = .standard
  ) throws -> ResolvedLedger {
    let bytes =
      try prepared.map { try $0.bytes(for: resolvedURL) }
      ?? ledgerBytes(limits: limits)
    guard let bytes else { return ResolvedLedger() }
    do { return try ResolvedLedgerCodec.decode(bytes, limits: limits) } catch let error
      as DecodingError
    { throw CoreError.invalidState("invalid resolved ledger: " + String(describing: error)) }
  }

  package var ledgerRoots: [String: URL] {
    var roots = [
      "project": environment.projectDirectory, "home": environment.homeDirectory,
      "state": directory,
    ]
    roots[NativeTargetRoute.projectRoot] = environment.projectDirectory.resolvingSymlinksInPath()
    roots[NativeTargetRoute.globalRoot] =
      environment.environment["CLAUDE_CONFIG_DIR"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
      } ?? environment.homeDirectory
    roots[NativeTargetRoute.globalRoot] = roots[NativeTargetRoute.globalRoot]?
      .resolvingSymlinksInPath()
    for agent in AgentID.allCases {
      roots["skills-" + agent.rawValue] = AgentRegistry.installSkillsDirectory(
        for: agent, scope: scope, environment: environment)
      if let file = InstructionLocations.file(for: agent, scope: scope, environment: environment) {
        roots["instructions-" + agent.rawValue] = file.deletingLastPathComponent()
      }
    }
    for route in NativeTargetRoute.allCases {
      roots[route.root] = try? route.logicalDirectory(environment).resolvingSymlinksInPath()
    }
    for route in TransactionLockContext.current(self)?.requestedRoutes ?? []
    where route.isNamed && route.permits(scope) {
      roots[route.root] = try? route.physicalDirectory(environment)
    }
    if let ledger = try? readLedger() {
      for deployment in ledger.deployments {
        guard deployment.target.kind == .registered, let key = deployment.target.root,
          let route = NativeTargetRoute.targetRoute(key), route.isNamed,
          route.permits(scope), deployment.target.path.utf8.elementsEqual(route.basename.utf8),
          Set(deployment.recipients).isSubset(of: route.knownReaders)
        else { continue }
        roots[key] = try? route.physicalDirectory(environment)
      }
    }
    return roots
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

  package func stageLedger(
    producing ledger: @escaping () throws -> ResolvedLedger, limits: LedgerLimits,
    transaction: FileTransaction, prepared: StatePrecondition
  ) throws {
    let original = try prepared.bytes(for: resolvedURL)
    try transaction.replace(
      resolvedURL,
      with: .prepared { directory in
        let bytes =
          try ResolvedLedgerCodec.replacement(ledger(), existing: original, limits: limits)
          ?? original
        guard let bytes else { throw CoreError.invalidState("missing deferred ledger") }
        let file = directory.appendingPathComponent("ledger")
        try bytes.write(to: file)
        return file
      }, expecting: prepared.evidence(for: resolvedURL))
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
    return try RetentionReferences(
      ledger: ResolvedLedgerCodec.decode(bytes, limits: .standard), roots: ledgerRoots)
  }
}
