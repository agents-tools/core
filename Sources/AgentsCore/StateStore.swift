import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

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
      let oldDeclaration = try existingData(declarationURL)
      let oldResolved = try existingData(resolvedURL)
      do {
        try Self.encode(declaration.normalized).write(to: declarationURL, options: .atomic)
        try Self.encode(resolved.normalized).write(to: resolvedURL, options: .atomic)
      } catch {
        try restore(oldDeclaration, at: declarationURL)
        try restore(oldResolved, at: resolvedURL)
        throw error
      }
    }
  }

  package func withLock<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".agents.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CoreError.invalidState("cannot open state lock: \(path)") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw CoreError.invalidState("cannot lock state: \(path)")
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
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

  private func restore(_ data: Data?, at url: URL) throws {
    if let data {
      try data.write(to: url, options: .atomic)
    } else if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
