import Foundation

/// Scope-owned state locations. User state always belongs to the supplied home directory.
public struct StateStore: Sendable {
  public let scope: InstallScope
  public let environment: RuntimeEnvironment

  public init(scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()) {
    self.scope = scope
    self.environment = environment
  }

  public var directory: URL {
    scope == .project
      ? environment.projectDirectory.appendingPathComponent(".agent")
      : environment.homeDirectory.appendingPathComponent(".agents")
  }
  public var declarationURL: URL { directory.appendingPathComponent(Self.declarationFileName) }
  public var resolvedURL: URL { directory.appendingPathComponent(Self.resolvedFileName) }
  public var watchURL: URL { directory.appendingPathComponent(Self.watchFileName) }
  public var cacheDirectory: URL { directory.appendingPathComponent("cache") }

  package static let declarationFileName = "Agents.swift"
  package static let resolvedFileName = "agents.resolved"
  package static let watchFileName = "agents.watch"
  /// The scope files a state transaction may replace.
  package static let stateFileNames: Set<String> = [
    declarationFileName, resolvedFileName, watchFileName,
  ]

  /// The declaration's bytes, or nil when the scope has no declaration and no lock or watch
  /// state. Lock or watch state without a declaration is `CoreError.missingDeclaration`; a
  /// prepared generation answers from its captured bytes.
  package func declarationBytes(prepared: StatePrecondition? = nil) throws -> Data? {
    func bytes(_ url: URL) throws -> Data? {
      try prepared.map { try $0.bytes(for: url) } ?? existingData(url)
    }
    if let declaration = try bytes(declarationURL) { return declaration }
    guard try bytes(resolvedURL) == nil, try bytes(watchURL) == nil else {
      throw CoreError.missingDeclaration(declarationURL.path)
    }
    return nil
  }

  /// Reads the lock under a shared lock, without recovery or creating files.
  public func loadResolved() throws -> ResolvedState {
    try withReadLock {
      _ = try declarationBytes()
      return try readResolved()
    }
  }

  package func readResolved(prepared: StatePrecondition? = nil) throws -> ResolvedState {
    let lock: ResolvedState = try load(resolvedURL, prepared: prepared) ?? ResolvedState()
    try lock.validate()
    return lock
  }

  /// Reads watch state under a shared lock, without recovery or creating files.
  public func loadWatch() throws -> WatchState {
    try withReadLock {
      _ = try declarationBytes()
      return try readWatch()
    }
  }

  package func readWatch(prepared: StatePrecondition? = nil) throws -> WatchState {
    let watch: WatchState = try load(watchURL, prepared: prepared) ?? WatchState()
    try watch.validate()
    return watch
  }

  /// Publishes a planned declaration change in the transaction, expecting the prepared
  /// generation. Without a change the declaration stays unchanged.
  package func stageDeclaration(
    _ change: DeclarationChange?, in transaction: FileTransaction, prepared: StatePrecondition
  ) throws {
    guard let change else { return }
    try transaction.replace(
      declarationURL, with: .data(change.bytes),
      expecting: prepared.evidence(for: declarationURL))
  }

  package func withLock<T>(
    createIfMissing: Bool = true, checkpoint: @escaping (String) throws -> Void = { _ in },
    outcome: TransactionOutcome? = nil,
    _ body: () throws -> T
  ) throws -> T {
    if try openDirectoryIfPresent() == nil, !createIfMissing {
      return try body()
    }
    // Without a scope lock, journal or ref-cleanup marker, invalid or orphaned state stops the
    // operation before the scope lock exists. Otherwise recovery precedes these checks.
    if ![".agents.lock", TransactionJournal.fileName, "watch-refs.pending"].contains(where: {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }) {
      _ = try readResolved()
      _ = try readWatch()
      _ = try declarationBytes()
    }
    let base = scope == .project ? environment.projectDirectory : environment.homeDirectory
    let physicalDirectory = base.resolvingSymlinksInPath().appendingPathComponent(
      directory.lastPathComponent)
    return try FileLock.withLock(at: physicalDirectory.appendingPathComponent(".agents.lock")) {
      let recovered = try FileTransaction.recover(
        store: self, outcome: outcome, checkpoint: checkpoint)
      _ = try readWatch()
      let cache = SourceCache(store: self, checkpoint: checkpoint)
      let referencesRecovered = try cache.recoverWatchReferences()
      if recovered || referencesRecovered {
        throw CoreError.transactionRecovered(directory.path)
      }
      let result: T
      do {
        result = try body()
      } catch {
        // A handled failure can finish rollback now. A killed process leaves the marker
        // for the next access, which must recover the journal before releasing any ref.
        do {
          _ = try FileTransaction.recover(store: self, outcome: outcome)
          _ = try SourceCache(store: self).recoverWatchReferences()
        } catch {
          outcome?.disposition = .recoveryRequired
        }
        throw error
      }
      _ = try cache.recoverWatchReferences()
      return result
    }
  }

  /// Only the supplied scope root may resolve through links; state and cache ancestry may not.
  func openDirectoryIfPresent() throws -> DirectoryHandle? {
    let root = scope == .project ? environment.projectDirectory : environment.homeDirectory
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    let parent = try DirectoryHandle(at: root.resolvingSymlinksInPath())
    let name = scope == .project ? ".agent" : ".agents"
    guard try parent.info(name) != nil else { return nil }
    return try parent.child(name)
  }

  /// Encodes `agents.resolved` in the layout `StateJSON` describes.
  package static func encodeState<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try StateJSON.format(encoder.encode(value))
  }

  /// Encodes journals, watch state and content hashes. Its bytes feed recorded hashes, so its
  /// layout stays fixed.
  package static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    return data
  }

  private func load<T: Codable>(_ url: URL, prepared: StatePrecondition?) throws -> T? {
    let bytes: Data?
    if let prepared {
      bytes = try prepared.bytes(for: url)
    } else {
      bytes = try existingData(url)
    }
    guard let data = bytes else { return nil }
    do {
      return try Self.decode(data, as: T.self)
    } catch {
      throw CoreError.invalidState("state file \(url.path) could not be decoded: \(error)")
    }
  }

  package static func decode<T: Codable>(_ data: Data, as type: T.Type) throws -> T {
    try JSONKeys.validate(data)
    let value = try JSONDecoder().decode(type, from: data)
    try rejectDiscardedFields(
      JSONSerialization.jsonObject(with: data),
      encoded: JSONSerialization.jsonObject(with: encode(value)))
    return value
  }

  private static func rejectDiscardedFields(_ input: Any, encoded: Any) throws {
    if let input = input as? [String: Any], let encoded = encoded as? [String: Any] {
      for (key, value) in input where !(value is NSNull) {
        guard let counterpart = encoded[key] else {
          throw CoreError.invalidState("unknown state field: \(key)")
        }
        try rejectDiscardedFields(value, encoded: counterpart)
      }
    } else if let input = input as? [Any], let encoded = encoded as? [Any] {
      for (value, counterpart) in zip(input, encoded) {
        try rejectDiscardedFields(value, encoded: counterpart)
      }
    }
  }

  package func existingData(_ url: URL) throws -> Data? {
    guard let directory = try openDirectoryIfPresent(),
      try directory.info(url.lastPathComponent) != nil
    else { return nil }
    return try directory.read(url.lastPathComponent)
  }

}
