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
    let declaration: Declaration = try load(declarationURL) ?? Declaration()
    try declaration.validate(environment: environment)
    return declaration
  }

  public func loadResolved() throws -> ResolvedState {
    let lock: ResolvedState = try load(resolvedURL) ?? ResolvedState()
    try lock.validate()
    return lock
  }

  /// Serializes cooperating writers and atomically replaces each state file.
  public func save(declaration: Declaration, resolved: ResolvedState) throws {
    try declaration.validate(environment: environment)
    try resolved.validate()
    _ = try loadDeclaration()
    _ = try loadResolved()
    try withLock {
      _ = try loadDeclaration()
      _ = try loadResolved()
      let transaction = FileTransaction()
      try transaction.replace(
        declarationURL, content: nil, data: Self.encode(declaration.normalized))
      try transaction.replace(resolvedURL, content: nil, data: Self.encode(resolved.normalized))
      try transaction.commit()
    }
  }

  package func withLock<T>(_ body: () throws -> T) throws -> T {
    try FileLock.withLock(at: directory.appendingPathComponent(".agents.lock"), body)
  }

  package static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    return data
  }

  private func load<T: Decodable>(_ url: URL) throws -> T? {
    guard let data = try existingData(url) else { return nil }
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw CoreError.invalidState("state file \(url.path) could not be decoded: \(error)")
    }
  }

  private func existingData(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

}
