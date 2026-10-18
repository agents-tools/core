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
  public var declarationURL: URL { directory.appendingPathComponent("agents.json") }
  public var resolvedURL: URL { directory.appendingPathComponent("agents.resolved") }
  public var watchURL: URL { directory.appendingPathComponent("agents.watch") }
  public var cacheDirectory: URL { directory.appendingPathComponent("cache") }

  public func loadDeclaration() throws -> Declaration {
    try withLock(createIfMissing: false) { try readDeclaration() }
  }

  package func readDeclaration() throws -> Declaration {
    let declaration: Declaration = try load(declarationURL) ?? Declaration()
    try declaration.validate(environment: environment)
    return declaration
  }

  public func loadResolved() throws -> ResolvedState {
    try withLock(createIfMissing: false) { try readResolved() }
  }

  package func readResolved() throws -> ResolvedState {
    let lock: ResolvedState = try load(resolvedURL) ?? ResolvedState()
    try lock.validate()
    return lock
  }

  /// Commits both state files through the scope's durable transaction journal.
  public func save(declaration: Declaration, resolved: ResolvedState) throws {
    try withLock {
      try declaration.validate(environment: environment)
      try resolved.validate()
      _ = try readDeclaration()
      _ = try readResolved()
      let transaction = FileTransaction(store: self)
      try transaction.replace(
        declarationURL, content: nil, data: Self.encode(declaration.normalized))
      try transaction.replace(resolvedURL, content: nil, data: Self.encode(resolved.normalized))
      try transaction.commit()
    }
  }

  package func withLock<T>(createIfMissing: Bool = true, _ body: () throws -> T) throws -> T {
    if try openDirectoryIfPresent() == nil, !createIfMissing {
      return try body()
    }
    if !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(".agents.lock").path),
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("transaction.json").path)
    {
      _ = try readDeclaration()
      _ = try readResolved()
    }
    return try FileLock.withLock(at: directory.appendingPathComponent(".agents.lock")) {
      if try FileTransaction.recover(store: self) {
        throw CoreError.transactionRecovered(directory.path)
      }
      return try body()
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

  package static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    return data
  }

  private func load<T: Codable>(_ url: URL) throws -> T? {
    guard let data = try existingData(url) else { return nil }
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

  private func existingData(_ url: URL) throws -> Data? {
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
    return try Data(contentsOf: url)
  }

}
